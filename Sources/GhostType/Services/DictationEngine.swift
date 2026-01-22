import Foundation

/// Local dictation engine (single-process).
///
/// This mirrors the PRD pipeline boundaries so we can later swap the implementation
/// to an XPC service without changing the UI layer.
@MainActor
final class DictationEngine: ObservableObject {
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
    private var lastCommittedSampleIndex: Int64 = 0 // For chunked streaming
    private var silenceDuration: TimeInterval = 0.0 // Track silence for chunking


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
        lastCommittedSampleIndex = sessionStartSampleIndex
        silenceDuration = 0.0

        Task {
            await accumulator.reset()

            // Context Injection
            if let context = audioManager.accessibilityManager.getActiveWindowContext() {
                print("🧠 DictationEngine: Context captured: \"\(context)\"")

                // Tokenize and seed accumulator
                if let tokens = await transcriptionManager.tokenize(context) {
                    await accumulator.append(text: "", tokens: tokens)
                    print("🧠 DictationEngine: Seeded accumulator with \(tokens.count) context tokens.")
                } else {
                    print("⚠️ DictationEngine: Failed to tokenize context (Model not loaded yet?)")
                }
            }
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
        let end = ringBuffer.totalSamplesWritten
        
        // Calculate uncommitted segment
        let effectiveStart = max(lastCommittedSampleIndex, sessionStartSampleIndex)

        // Safety check: if uncommitted segment is too long (> 30s), force a commit?
        // Or if we are just streaming.
        // For now, let's snapshot everything since last commit.
        let segment = ringBuffer.snapshot(from: effectiveStart, to: end)
        
        guard !segment.isEmpty else { return }
        
        // RMS Energy Gate
        // Need to check RMS of *recent* samples to detect current silence
        // Let's look at the last 500ms for silence detection
        let recentSamplesCount = Int(0.5 * Double(audioSampleRate))
        let recentSegment = segment.suffix(recentSamplesCount)
        let rms = sqrt(recentSegment.reduce(0) { $0 + $1 * $1 } / Float(max(1, recentSegment.count)))
        
        let isSilent = rms <= 0.005
        if isSilent {
            silenceDuration += windowLoopInterval
        } else {
            silenceDuration = 0.0
        }
        
        // Chunking Logic
        // Commit if:
        // 1. Silence > 0.7s AND we have uncommitted content
        // 2. OR isFinal (forced stop)
        // 3. OR uncommitted content > 28s (panic commit to avoid context window overflow)
        
        let uncommittedDuration = Double(segment.count) / Double(audioSampleRate)
        let shouldCommit = isFinal || (silenceDuration > 0.7 && uncommittedDuration > 0.5) || uncommittedDuration > 28.0
        
        guard let buffer = AudioBufferBridge.createBuffer(from: segment, sampleRate: Double(audioSampleRate)) else {
            return
        }
        
        let contextTokens = await accumulator.getContext()
        
        if shouldCommit {
             // COMMIT PHASE
             // Transcribe safely
             // print("🎙️ DictationEngine: Committing chunk (\(String(format: "%.1f", uncommittedDuration))s)...")

             guard let (text, tokens) = await transcriptionManager.transcribe(buffer: buffer, promptTokens: contextTokens) else {
                 return
             }

             await accumulator.append(text: text, tokens: tokens)

             // Update pointer
             lastCommittedSampleIndex = end

             // Emit Full Text
             let fullText = await accumulator.getFullText()
             self.callbackQueue.async {
                 self.onPartialRawText?(fullText) // Update preview with stable text
                 if isFinal {
                     self.onFinalText?(fullText)
                 }
             }

             if shouldCommit && !isFinal {
                 // Reset silence after commit to avoid double commits?
                 // silenceDuration = 0.0 // Actually, keep it until speech starts? No, reset logic handles it.
             }

        } else {
             // PREVIEW PHASE
             // Only transcribe if not silent (to save battery) or if we want to update the tail
             // If completely silent, we might skip, but user might be pausing.
             // If silenceDuration > 0.2, maybe skip preview update to avoid jitter?

             if isSilent && silenceDuration > 0.2 {
                 return // Optimization: Don't re-transcribe static silence
             }

             guard let (text, _) = await transcriptionManager.transcribe(buffer: buffer, promptTokens: contextTokens) else {
                 return
             }

             let stableText = await accumulator.getFullText()
             let previewText = stableText.isEmpty ? text : stableText + " " + text

             self.callbackQueue.async {
                 self.onPartialRawText?(previewText)
             }
        }
    }
}

