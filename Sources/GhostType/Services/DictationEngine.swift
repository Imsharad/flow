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
    
    private let vad = VAD() // VAD State Machine
    private var chunkStartSampleIndex: Int64 = 0 // Start of current VAD chunk

    // Services
    private let accessibilityManager = AccessibilityManager()

    init(
        callbackQueue: DispatchQueue = .main
    ) {
        self.callbackQueue = callbackQueue
        // Initialize Manager (Shared instance logic should ideally be lifted to App)
        self.transcriptionManager = TranscriptionManager() 
        self.accumulator = TranscriptionAccumulator()
        self.ringBuffer = AudioRingBuffer(capacitySamples: 16000 * 180) 

        setupVAD()
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

        setupVAD()
    }

    private func setupVAD() {
        // VAD Event Handlers
        vad.onSpeechEnd = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                print("🔇 DictationEngine: VAD Speech End Detected. Finalizing Chunk.")
                // Finalize the current chunk
                await self.processOnePass(isFinal: true)
                // Advance the chunk start index.
                // Important: 'totalSamplesWritten' is nonisolated(unsafe) but Atomic/Lock-free in implementation usually.
                // However, DictationEngine is @MainActor, so accessing ringBuffer properties might be isolated if ringBuffer was an actor.
                // ringBuffer is a class. We should verify thread safety or ensure we read it safely.
                // AudioRingBuffer is lock-free but 'totalSamplesWritten' reads an Int64. On 64-bit systems this is atomic.
                self.chunkStartSampleIndex = self.ringBuffer.totalSamplesWritten
            }
        }
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
        sessionStartSampleIndex = ringBuffer.totalSamplesWritten
        chunkStartSampleIndex = sessionStartSampleIndex // Reset chunk start
        
        // Reset Accumulator and VAD
        Task { await accumulator.reset() }
        vad.reset()

        // Start audio capture
        do {
            try audioManager.start()
        } catch {
            print("❌ DictationEngine: Failed to start audio manager: \(error)")
            return
        }
        
        isRecording = true
        
        // Capture Window Context
        if let context = accessibilityManager.getActiveWindowContext() {
             print("🪟 Active Context: \(context.appName) - \(context.windowTitle)")
             // Store it for use in transcription
             self.currentTextContext = "Context: App: \(context.appName), Window: \(context.windowTitle)."
        } else {
             self.currentTextContext = nil
        }

        // Notify UI
        DispatchQueue.main.async { [weak self] in
            self?.onSpeechStart?()
        }
        
        startSlidingWindow()
    }
    
    private var currentTextContext: String?

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
        // Chunking Strategy:
        // Instead of always looking back 30s from 'end', we look back to 'chunkStartSampleIndex'.
        // This ensures we are processing the *current natural phrase*.

        // Safety: Cap at 30s max to prevent context window overflow if VAD doesn't trigger
        let maxSamples = Int64(30 * audioSampleRate)
        let chunkDurationSamples = end - chunkStartSampleIndex
        
        let effectiveStart: Int64
        if chunkDurationSamples > maxSamples {
            // Force a cut if speech is too long (fallback)
             effectiveStart = end - maxSamples
        } else {
             effectiveStart = chunkStartSampleIndex
        }

        let segment = ringBuffer.snapshot(from: effectiveStart, to: end)
        
        guard !segment.isEmpty else { return }
        
        // Feed VAD (State Machine Update)
        // Note: processOnePass runs every 0.5s. 'segment' is growing.
        // VAD needs the *new* audio since last check ideally, but VAD on the whole sliding window tail is acceptable for RMS check.
        // Actually, we should feed the NEW samples to VAD.
        // BUT: 'segment' here is the accumulated chunk.
        // Let's rely on the RMS check inside this loop for now, and update the VAD state.
        
        // Calculate RMS of the LATEST 0.5s (approx) for VAD sensitivity
        let windowSamples = Int(windowLoopInterval * Double(audioSampleRate))
        let tailCount = min(segment.count, windowSamples)
        let tailSegment = Array(segment.suffix(tailCount))

        vad.process(segment: tailSegment, sampleRate: Double(audioSampleRate))

        // RMS Gate for *Inference* (Optimization: don't transcribe pure silence)
        // We use the same threshold as VAD or slightly lower.
        // If VAD says silence, we might still want to finalize if we were speaking.
        
        // 🌉 Bridge to AVAudioPCMBuffer
        guard let buffer = AudioBufferBridge.createBuffer(from: segment, sampleRate: Double(audioSampleRate)) else {
            print("❌ DictationEngine: Failed to create audio buffer")
            return
        }
        
        // 🦄 Unicorn Stack: Hybrid Transcription
        let processingStart = Date()
        
        // Get Context from Accumulator
        let contextTokens = await accumulator.getContext()

        // Transcribe with Context
        guard let result = await transcriptionManager.transcribe(
            buffer: buffer,
            contextTokens: contextTokens,
            contextText: currentTextContext
        ) else {
             return
        }

        let text = result.text
        let tokens = result.tokens

        // If Final, commit to accumulator
        if isFinal {
            await accumulator.append(text: text, tokens: tokens)
        }
        
        let processingDuration = Date().timeIntervalSince(processingStart)

        // Combine accumulated text + current partial
        let previousText = await accumulator.getFullText()
        let combinedText = previousText + (previousText.isEmpty ? "" : " ") + text
        
        // Emit result
        self.callbackQueue.async {
            self.onPartialRawText?(combinedText)
            if isFinal {
                // If it's a chunk finalization, we don't necessarily emit "onFinalText" for the whole session yet,
                // but for the UI it looks like a stream update.
                // However, the UI expects "onFinalText" only when stopping?
                // The current UI might treat onFinalText as "Session Done".
                // So we should only emit onPartialRawText until the very end of the session.
                // UNLESS this call came from stop().
                // We can differentiate by checking isRecording status, but that's handled in stop().

                // Let's keep emitting partials for chunks.
                // The actual "Session End" final text is emitted in stop().
            }
        }
    }
}

