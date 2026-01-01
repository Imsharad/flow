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
    // private let consensusService: ConsensusServiceProtocol // Temporarily unused in Hybrid Mode v1
    
    // State
    private var isRecording = false
    private var slidingWindowTimer: Timer?
    private let windowLoopInterval: TimeInterval = 0.5 // 500ms Tick
    private var sessionStartSampleIndex: Int64 = 0 // Track session start for isolation
    private var lastCommitSampleIndex: Int64 = 0 // Last committed chunk end

    // Active Context
    private var capturedContext: String?

    // VAD Configuration
    // We use a simple silence check in processWindow for now, but real VAD logic is in processOnePass
    private let minSilenceDuration = 0.7

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
        
        // Reset state for new session
        ringBuffer.clear()
        sessionStartSampleIndex = ringBuffer.totalSamplesWritten // Mark session start AFTER clear
        lastCommitSampleIndex = sessionStartSampleIndex

        // Capture context
        if let context = AccessibilityManager.shared.getActiveWindowContext() {
            self.capturedContext = "User is in app: \(context.appName). Window: \(context.windowTitle)."
            print("👁️ DictationEngine: Context captured - \(self.capturedContext ?? "None")")
        } else {
            self.capturedContext = nil
        }

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
            await self.processOnePass(forceCommit: true)
            
            DispatchQueue.main.async { [weak self] in
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
        let currentWriteIndex = ringBuffer.totalSamplesWritten

        // 1. Determine what to process
        // We process from the last committed point to the current point
        // If the segment is too long (> 30s), we might need to clamp, but VAD should handle that naturally.

        // Safety check: Don't process if we haven't advanced
        if currentWriteIndex <= lastCommitSampleIndex { return }
        
        let start = lastCommitSampleIndex
        let end = currentWriteIndex
        
        let segment = ringBuffer.snapshot(from: start, to: end)
        guard !segment.isEmpty else { return }
        
        // 2. VAD & Silence Detection
        // Calculate RMS of the *end* of the segment to check if user has paused
        // We look at the last 500ms
        let tailLength = min(segment.count, Int(0.5 * Double(audioSampleRate)))
        let tail = segment.suffix(tailLength)
        let tailRms = sqrt(tail.reduce(0) { $0 + $1 * $1 } / Float(tail.count))
        
        // Threshold for "Speech End"
        let isSilence = tailRms < 0.005

        // Decision Logic:
        // - If forceCommit (Stop button): Commit everything.
        // - If isSilence (Speech Pause): Commit everything (Chunking).
        // - Else (Still talking): Just get intermediate result (Streaming), DO NOT COMMIT.

        let shouldCommit = forceCommit || isSilence
        
        // 🌉 Bridge to AVAudioPCMBuffer
        guard let buffer = AudioBufferBridge.createBuffer(from: segment, sampleRate: Double(audioSampleRate)) else {
            print("❌ DictationEngine: Failed to create audio buffer")
            return
        }
        
        // 3. Transcription
        let contextTokens = await accumulator.getContext()
        
        // Context Injection logic
        // Only inject context for the very first chunk if accumulator is empty
        // OR always inject if using Cloud (via prompt text)
        var finalPrompt: String? = nil
        if await accumulator.getFullText().isEmpty {
            finalPrompt = capturedContext
        }
        
        // TODO: Pass context text prompt too if needed for Cloud
        // let contextText = await accumulator.getFullText()

        let (text, tokens) = await transcriptionManager.transcribe(buffer: buffer, prompt: finalPrompt, promptTokens: contextTokens)
        
        guard let transcribedText = text else { return }

        // 4. Update State
        if shouldCommit {
             // Append to accumulator
            if let tokens = tokens {
                await accumulator.append(text: transcribedText, tokens: tokens)
            } else {
                 // Fallback if no tokens (Cloud), just append text
                 // Create dummy tokens or ignore context for cloud for now
                 await accumulator.append(text: transcribedText, tokens: [])
            }

            // Advance commit pointer
            lastCommitSampleIndex = end

            // Full text update
            let fullText = await accumulator.getFullText()

            // Emit final update for this chunk
            self.callbackQueue.async {
                self.onPartialRawText?(fullText)
                if forceCommit {
                    self.onFinalText?(fullText)
                }
            }
        } else {
            // Streaming partial (Overlay on top of committed text)
            let committedText = await accumulator.getFullText()
            let partialResult = committedText + (committedText.isEmpty ? "" : " ") + transcribedText

            self.callbackQueue.async {
                self.onPartialRawText?(partialResult)
            }
        }
    }
}
