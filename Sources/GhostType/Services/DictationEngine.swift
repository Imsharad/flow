import Foundation

/// Local dictation engine (single-process).
///
/// This mirrors the PRD pipeline boundaries so we can later swap the implementation
/// to an XPC service without changing the UI layer.
@MainActor
final class DictationEngine {
    // Callbacks (invoked on `callbackQueue`).
    var onSpeechStart: (() -> Void)?
    var onSpeechEnd: (() -> Void)?
    var onPartialRawText: ((String) -> Void)?
    var onFinalText: ((String) -> Void)?

    private let callbackQueue: DispatchQueue

    private let audioSampleRate: Int = 16000
    nonisolated(unsafe) private let ringBuffer: AudioRingBuffer

    // Services
    private let audioManager = AudioInputManager.shared
    
    // Orchestration
    let transcriptionManager: TranscriptionManager
    private let accumulator: TranscriptionAccumulator
    private let accessibilityManager: AccessibilityManager
    
    // State
    private var isRecording = false
    private var slidingWindowTimer: Timer?
    private let windowLoopInterval: TimeInterval = 0.5 // 500ms Tick
    private var sessionStartSampleIndex: Int64 = 0 // Track session start for isolation
    
    // VAD & Chunking State
    private var speechState: SpeechState = .silence
    private var silenceDuration: TimeInterval = 0
    private var lastSpeechEndTime: TimeInterval = 0
    private let silenceThresholdSeconds: TimeInterval = 0.7 // As per progress.md
    private let maxSpeechDurationBeforeCommit: TimeInterval = 25.0 // Force commit if speech too long
    private var currentChunkStartTime: TimeInterval = 0

    // Context State
    private var activeWindowContext: (title: String, bundleID: String)?

    enum SpeechState {
        case silence
        case speaking
    }

    init(
        callbackQueue: DispatchQueue = .main
    ) {
        self.callbackQueue = callbackQueue
        // Initialize Manager (Shared instance logic should ideally be lifted to App)
        self.transcriptionManager = TranscriptionManager() 
        self.accumulator = TranscriptionAccumulator()
        self.ringBuffer = AudioRingBuffer(capacitySamples: 16000 * 180) 
        self.accessibilityManager = AccessibilityManager()
    }
    
    // For testing injection
    init(
         transcriptionManager: TranscriptionManager,
         accumulator: TranscriptionAccumulator,
         ringBuffer: AudioRingBuffer,
         accessibilityManager: AccessibilityManager = AccessibilityManager()) {
        self.callbackQueue = .main
        self.transcriptionManager = transcriptionManager
        self.accumulator = accumulator
        self.ringBuffer = ringBuffer
        self.accessibilityManager = accessibilityManager
    }

    nonisolated func pushAudio(samples: [Float]) {
        ringBuffer.write(samples)
    }

    func manualTriggerStart() {
        if !isRecording {
             handleSpeechStart()
        }
    }

    func manualTriggerEnd() {
        stop()
    }
    
    func warmUp(completion: (() -> Void)? = nil) {
        // Manager handles warmup state implicitly
        completion?()
    }

    // MARK: - Internals

    private func handleSpeechStart() {
        guard !isRecording else { return }
        
        // Reset state for new session
        ringBuffer.clear()
        sessionStartSampleIndex = ringBuffer.totalSamplesWritten // Mark session start AFTER clear
        accumulator.reset()
        speechState = .silence
        silenceDuration = 0
        currentChunkStartTime = Date().timeIntervalSince1970

        // Capture Context (Title, App)
        self.activeWindowContext = accessibilityManager.getActiveWindowContext()
        if let ctx = self.activeWindowContext {
            print("👁️ DictationEngine: Context captured - \(ctx.title) (\(ctx.bundleID))")
        }
        
        // Start audio capture
        do {
            try audioManager.start()
        } catch {
            print("❌ DictationEngine: Failed to start audio manager: \(error)")
            return
        }
        
        isRecording = true
        
        // Notify UI
        DispatchQueue.main.async { [weak self] in
            self?.onSpeechStart?()
        }
        
        startSlidingWindow()
    }
    
    func stop() {
        guard isRecording else { return }
        isRecording = false
        print("🛑 DictationEngine: Stopping...")
        
        audioManager.stop()
        stopSlidingWindow()
        
        // Final drain
        Task(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            
            // Force one final transcription of the complete buffer
            // We treat the final buffer as a "confirmed" chunk to ensure everything is captured
            await self.processOnePass(forceCommit: true)
            
            // For now, we manually trigger speech end callback after final processing
            // In hybrid mode, implicit "final text" is just the last update.
            let fullText = await self.accumulator.getFullText()
            
            DispatchQueue.main.async { [weak self] in
                self?.onFinalText?(fullText)
                self?.onSpeechEnd?()
            }
        }
    }

    // MARK: - Sliding Window Logic
    
    private func startSlidingWindow() {
        stopSlidingWindow()
        // Main Thread Timer for simplicity, but heavy work is in Task
        slidingWindowTimer = Timer.scheduledTimer(withTimeInterval: windowLoopInterval, repeats: true) { [weak self] _ in
            self?.processWindow()
        }
    }
    
    private func stopSlidingWindow() {
        slidingWindowTimer?.invalidate()
        slidingWindowTimer = nil
    }
    
    private func processWindow() {
        Task(priority: .userInitiated) { [weak self] in
            await self?.processOnePass(forceCommit: false)
        }
    }
    
    private func processOnePass(forceCommit: Bool = false) async {
        let end = ringBuffer.totalSamplesWritten

        // In this new model, we want to look at the buffer since the last "commit" or session start.
        // However, ringBuffer is continuous. We need to define a window.
        // Simple approach: Always look back max 30s for VAD check, but for transcription we might need context.

        // Let's stick to the sliding window approach but add state logic.
        // If we are "Speaking", we keep updating "Partial".
        // If we detect "Silence" AFTER "Speaking", we "Commit" the previous segment.

        let maxSamples = Int64(30 * audioSampleRate)
        let effectiveStart = max(sessionStartSampleIndex, end - maxSamples)
        
        let segment = ringBuffer.snapshot(from: effectiveStart, to: end)
        
        guard !segment.isEmpty else { return }
        
        // 1. VAD Check
        // RMS Energy Gate
        let rms = sqrt(segment.reduce(0) { $0 + $1 * $1 } / Float(segment.count))
        let isSilence = rms < 0.005
        
        // 2. State Machine Transition
        if !isSilence {
            // Speech detected
            speechState = .speaking
            silenceDuration = 0
            // print("🗣️ Speaking...")
        } else {
            if speechState == .speaking {
                silenceDuration += windowLoopInterval // approximate
                // print("🤫 Silence... \(silenceDuration)s")
            }
        }
        
        // 3. Logic
        // If we have been silent for > threshold, OR forced commit -> Commit
        // Else -> Partial Update

        let shouldCommit = (speechState == .speaking && silenceDuration > silenceThresholdSeconds) || forceCommit

        // 🌉 Bridge to AVAudioPCMBuffer
        guard let buffer = AudioBufferBridge.createBuffer(from: segment, sampleRate: Double(audioSampleRate)) else {
            print("❌ DictationEngine: Failed to create audio buffer")
            return
        }
        
        // Context Handling
        let previousTokens = await accumulator.getContext()
        // Provide both text (for Cloud) and tokens (for Local)
        let contextText = await accumulator.getFullText()

        // Combine previous text with Window Context
        var promptString = ""
        if let winCtx = activeWindowContext {
            promptString = "Context: \(winCtx.title) (\(winCtx.bundleID)). "
        }
        promptString += contextText

        // Truncate context text if too long to avoid huge prompt costs/latency in cloud
        let truncatedContextText = String(promptString.suffix(800))

        let context = TranscriptionContext(prompt: truncatedContextText, tokens: previousTokens)

        // 🦄 Unicorn Stack: Hybrid Transcription
        let processingStart = Date()
        
        guard let result = await transcriptionManager.transcribe(buffer: buffer, context: context) else {
            // Processing cancelled or failed
            return
        }
        
        let processingDuration = Date().timeIntervalSince(processingStart)
        // print("🎙️ DictationEngine: Transcribed \"\(result.text.prefix(20))...\" in \(String(format: "%.3f", processingDuration))s")
        
        if shouldCommit {
            print("✅ DictationEngine: Committing segment: \"\(result.text)\"")
            await accumulator.append(text: result.text, tokens: result.tokens)

            // Reset state
            speechState = .silence
            silenceDuration = 0

            // Advance session start index to avoid re-transcribing committed audio?
            // Actually, for sliding window to work with context, we usually want to slide forward.
            // But `ringBuffer.snapshot` takes (start, end).
            // If we commit, we should effectively "move" the start point so we don't re-transcribe the old part.
            // YES. This is key for "Chunked Streaming".
            // We advance `sessionStartSampleIndex` to `end`.

            // HOWEVER: We need to be careful not to cut off the very end if it was silence.
            // But `end` is the current write head.
            // If we commit, we assume everything in the buffer was processed.

            sessionStartSampleIndex = end

            // Emit Finalized Text (Accumulated)
            let fullText = await accumulator.getFullText()
            self.callbackQueue.async {
                self.onFinalText?(fullText)
            }

        } else {
            // Partial Update
            // We combine accumulated text + current partial
            let accumulated = await accumulator.getFullText()
            let fullDisplay = accumulated + " " + result.text

            self.callbackQueue.async {
                self.onPartialRawText?(fullDisplay)
            }
        }
    }
}
