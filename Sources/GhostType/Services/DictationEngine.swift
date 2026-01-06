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
    private let accessibilityManager = AccessibilityManager()
    
    // Orchestration
    let transcriptionManager: TranscriptionManager
    private let accumulator: TranscriptionAccumulator
    // private let consensusService: ConsensusServiceProtocol // Temporarily unused in Hybrid Mode v1
    
    // State
    private var isRecording = false
    private var slidingWindowTimer: Timer?
    private let windowLoopInterval: TimeInterval = 0.5 // 500ms Tick
    private var sessionStartSampleIndex: Int64 = 0 // Track session start for isolation
    
    // VAD State
    private var lastSpeechSampleIndex: Int64 = 0
    private var silenceStartTime: Date?
    private let silenceThresholdSeconds: TimeInterval = 0.7
    private var lastProcessedSampleIndex: Int64 = 0

    // Context State
    private var staticContext: ActiveWindowContext?

    init(
        callbackQueue: DispatchQueue = .main
    ) {
        self.callbackQueue = callbackQueue
        // Initialize Manager (Shared instance logic should ideally be lifted to App)
        self.transcriptionManager = TranscriptionManager() 
        self.accumulator = TranscriptionAccumulator()
        self.ringBuffer = AudioRingBuffer(capacitySamples: 16000 * 180) 
    }
    
    // For testing injection
    init(
         transcriptionManager: TranscriptionManager,
         accumulator: TranscriptionAccumulator,
         ringBuffer: AudioRingBuffer) {
        self.callbackQueue = .main
        self.transcriptionManager = transcriptionManager
        self.accumulator = accumulator
        self.ringBuffer = ringBuffer
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
        
        // Capture Static Context (Snapshot of current app)
        // We do this BEFORE we switch focus or anything, ideally.
        // But GhostType floats over, so focus *should* still be on target app?
        // Actually, if user clicks GhostType, focus might change.
        // We assume Hotkey triggered this, so focus is likely on target.
        staticContext = accessibilityManager.getActiveWindowContext()
        if let ctx = staticContext {
            print("🧠 DictationEngine: Context captured - App: \(ctx.appName), Window: \(ctx.windowTitle)")
        } else {
            print("🧠 DictationEngine: No context captured.")
        }

        // Reset state for new session
        ringBuffer.clear()
        sessionStartSampleIndex = ringBuffer.totalSamplesWritten // Mark session start AFTER clear
        lastProcessedSampleIndex = sessionStartSampleIndex
        silenceStartTime = nil

        Task {
            await accumulator.reset()
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
            await self.processOnePass(isFinal: true)
            
            // Get the final full text from accumulator
            let fullText = await self.accumulator.getFullText()
            
            DispatchQueue.main.async { [weak self] in
                // In hybrid mode, implicit "final text" is just the last update.
                // We emit the full text one last time to be sure.
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
            await self?.processOnePass(isFinal: false)
        }
    }
    
    private func processOnePass(isFinal: Bool = false) async {
        let end = ringBuffer.totalSamplesWritten

        // Logic:
        // 1. Check if we have new data since last processed
        // 2. Check for silence to trigger chunk finalization

        // Look back 30 seconds, but never before session start
        // NOTE: If we are Chunking, we want to look back from 'lastProcessedSampleIndex' to 'end'
        // But Whisper works best with context.
        // If we finalize a chunk, we move 'lastProcessedSampleIndex' forward.

        // For partial updates (UI), we want to transcribe from `lastProcessedSampleIndex` to `end`.
        
        let start = lastProcessedSampleIndex
        let segment = ringBuffer.snapshot(from: start, to: end)
        
        guard !segment.isEmpty else { return }
        
        // RMS Energy Gate
        let rms = sqrt(segment.reduce(0) { $0 + $1 * $1 } / Float(segment.count))
        let isSilent = rms < 0.005
        
        if isSilent {
            if silenceStartTime == nil {
                silenceStartTime = Date()
            }
        } else {
            silenceStartTime = nil
            lastSpeechSampleIndex = end // Mark last known speech
        }
        
        // Check if we should finalize a chunk (Silence > 0.7s OR buffer too long > 28s)
        let silenceDuration = silenceStartTime.map { Date().timeIntervalSince($0) } ?? 0
        let segmentDuration = Double(segment.count) / Double(audioSampleRate)
        let shouldFinalize = (silenceDuration > silenceThresholdSeconds && segmentDuration > 2.0) || segmentDuration > 28.0 || isFinal

        // Prepare context
        // Merge Static Context + Conversation History
        // NOTE: WhisperKit mostly uses `promptTokens` for previous text.
        // We can't easily inject "App Name" via tokens unless we encode it.
        // For Phase 4 MVP, we will just stick to conversation history (accumulator).
        // If we wanted to add app context, we might prepend it as text prompt if using API,
        // but for Tokens we'd need to encode "Context: [App] [Window]" then add it.
        // For now, we just log it (Phase 4 Step 1 is "Capture", using it is Step 2/Optimization).

        let contextTokens = await accumulator.getContext()

        // 🌉 Bridge to AVAudioPCMBuffer
        guard let buffer = AudioBufferBridge.createBuffer(from: segment, sampleRate: Double(audioSampleRate)) else {
            return
        }
        
        // Transcribe
        guard let result = await transcriptionManager.transcribe(buffer: buffer, promptTokens: contextTokens) else {
            return
        }
        
        let partialText = result.text
        
        // If final or chunked, commit to accumulator
        if shouldFinalize && !partialText.isEmpty {
            await accumulator.append(text: partialText, tokens: result.tokens)

            // Advance window to end of this segment
            // NOTE: Ideally we cut exactly at silence start, but simplifying to 'end' is safer for now
            // to avoid cutting off trailing phonemes.
            // A better VAD would give us the exact sample index of silence start.
            // For now, if we detected silence, we can try to back off to where silence started?
            // Or just advance. If we advance to 'end', we might lose the "silence" buffer for next phrase?
            // Actually, if it's silent, we can safely advance.

            lastProcessedSampleIndex = end
            silenceStartTime = nil // Reset silence timer

             // Notify UI with FULL text (accumulated + nothing pending)
            let fullText = await accumulator.getFullText()
            self.callbackQueue.async {
                self.onPartialRawText?(fullText)
                if isFinal {
                     self.onFinalText?(fullText)
                }
            }

        } else {
            // Just a partial update
            // Notify UI with FULL text (accumulated + partial)
            let accumulatedText = await accumulator.getFullText()
            let combined = accumulatedText.isEmpty ? partialText : accumulatedText + " " + partialText

            self.callbackQueue.async {
                self.onPartialRawText?(combined)
                if isFinal {
                    self.onFinalText?(combined)
                }
            }
        }
    }
}
