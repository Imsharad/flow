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
    
    // Chunking State
    private var committedSampleIndex: Int64 = 0
    private var lastSpeechTime: Date = Date()
    private var isCommitting: Bool = false
    private let silenceThreshold: Float = 0.005
    private let minSilenceDuration: TimeInterval = 0.7

    // Context
    private var textContext: String?


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
        committedSampleIndex = sessionStartSampleIndex
        accumulator.reset()
        lastSpeechTime = Date()
        isCommitting = false

        // Capture Context
        if let context = accessibilityManager.getActiveWindowContext() {
            self.textContext = "Context: \(context.appName) - \(context.windowTitle)."
            print("🧠 DictationEngine: Captured Context = \(self.textContext!)")
        } else {
            self.textContext = nil
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
            
            // For now, we manually trigger speech end callback after final processing
            // In hybrid mode, implicit "final text" is just the last update.
            
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
            await self?.processOnePass(isFinal: false)
        }
    }
    
    private func processOnePass(isFinal: Bool = false) async {
        guard !isCommitting else { return }

        let end = ringBuffer.totalSamplesWritten

        // Always start from committed point for the current chunk
        // But clamp to max 30s lookback from end if we haven't committed in a long time (fail safe)
        // Ideally we commit often enough that this doesn't happen.
        let maxSamples = Int64(30 * audioSampleRate)
        let safeStart = max(committedSampleIndex, end - maxSamples)
        
        // If we are forcing isFinal, we take everything.
        // If not, we take what we have since last commit.
        
        let segment = ringBuffer.snapshot(from: safeStart, to: end)
        guard !segment.isEmpty else {
            // If empty, just emit what we have
            if isFinal {
                await self.accumulator.append(text: "", tokens: [])
                let fullText = await self.accumulator.getFullText()
                self.callbackQueue.async {
                    self.onFinalText?(fullText)
                }
            }
            return
        }
        
        // RMS Calculation
        let rms = sqrt(segment.reduce(0) { $0 + $1 * $1 } / Float(segment.count))
        
        // VAD State Update
        if rms > silenceThreshold {
            lastSpeechTime = Date()
        }
        let silenceDuration = Date().timeIntervalSince(lastSpeechTime)

        // Decide if we should COMMIT (Finalize this chunk) or PROVISIONAL (Stream)
        // Commit if:
        // 1. isFinal (Session ended)
        // 2. Silence > 0.7s AND we have enough data (> 1s) to be worth committing

        let samplesSinceCommit = end - committedSampleIndex
        let secondsSinceCommit = Double(samplesSinceCommit) / Double(audioSampleRate)

        let shouldCommit = isFinal || (silenceDuration > minSilenceDuration && secondsSinceCommit > 1.0)
        
        // 🌉 Bridge to AVAudioPCMBuffer
        guard let buffer = AudioBufferBridge.createBuffer(from: segment, sampleRate: Double(audioSampleRate)) else {
            print("❌ DictationEngine: Failed to create audio buffer")
            return
        }
        
        // Get Context Tokens
        let contextTokens = await accumulator.getContext()
        
        // Prepare Prompt String (Text Context + Accumulated Text for Cloud/First Chunk)
        var promptString: String? = self.textContext
        let accumulatedText = await accumulator.getFullText()
        if !accumulatedText.isEmpty {
             if let ctx = self.textContext {
                  promptString = ctx + " " + accumulatedText
             } else {
                  promptString = accumulatedText
             }
        }
        
        if shouldCommit {
            isCommitting = true
            // print("🔒 DictationEngine: Committing chunk (Duration: \(String(format: "%.2f", secondsSinceCommit))s)...")

            // Perform Transcription (Wait for it, don't let it be cancelled easily if we can help it)
            // Note: TranscriptionManager cancels previous task. Since we set isCommitting=true,
            // no new provisional tasks will start. The only thing that could cancel us is if we called transcribe again.

            if let result = await transcriptionManager.transcribe(buffer: buffer, promptTokens: contextTokens, prompt: promptString) {
                // Success
                await accumulator.append(text: result.text, tokens: result.tokens ?? [])
                committedSampleIndex = end

                let fullText = await accumulator.getFullText()
                self.callbackQueue.async {
                    self.onPartialRawText?(fullText)
                    if isFinal {
                        self.onFinalText?(fullText)
                    }
                }
            } else {
                 print("⚠️ DictationEngine: Commit failed or cancelled")
                 if isFinal {
                     // If final commit failed, still try to return what we have
                     let fullText = await accumulator.getFullText()
                     self.callbackQueue.async { self.onFinalText?(fullText) }
                 }
            }

            isCommitting = false

        } else {
            // Provisional - Streaming
            // Only process if RMS > silence threshold OR we have some speech history recently
            // If it's pure silence, we might skip to save energy, BUT we need to clear provisional text if user stopped speaking?
            // If silence is long, we would have committed.
            // If silence is short, we might still be in a pause.

            if rms < silenceThreshold && secondsSinceCommit < 0.5 {
                // Very short silence at start, maybe skip
                return
            }

            if let result = await transcriptionManager.transcribe(buffer: buffer, promptTokens: contextTokens, prompt: promptString) {
                let currentFullText = await accumulator.getFullText()
                let provisionalText = result.text
                let combined = currentFullText.isEmpty ? provisionalText : currentFullText + " " + provisionalText

                self.callbackQueue.async {
                    self.onPartialRawText?(combined)
                }
            }
        }
    }
}

