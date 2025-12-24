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
    private let contextManager = ContextManager()
    
    // Orchestration
    let transcriptionManager: TranscriptionManager
    private let accumulator: TranscriptionAccumulator
    // private let consensusService: ConsensusServiceProtocol // Temporarily unused in Hybrid Mode v1
    
    // State
    private var isRecording = false
    private var slidingWindowTimer: Timer?
    private let windowLoopInterval: TimeInterval = 0.5 // 500ms Tick
    private var sessionStartSampleIndex: Int64 = 0 // Track session start for isolation
    


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
        accumulator.reset() // Clear previous context
        sessionStartSampleIndex = ringBuffer.totalSamplesWritten // Mark session start AFTER clear
        
        // Capture initial context
        Task { [weak self] in
            guard let self = self else { return }
            if let context = await self.contextManager.getCurrentContext() {
                print("🧠 DictationEngine: Captured Context: \(context.description)")
                // Inject context into accumulator as initial "history"
                // Ideally we format this as a prompt, e.g. "Previous context: ..."
                // For now, let's just use the window title/app as a hint.
                let contextString = "Context: \(context.appName) - \(context.windowTitle). "
                await self.accumulator.append(text: contextString, tokens: [])
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
        // Look back 30 seconds, but never before session start
        let maxSamples = Int64(30 * audioSampleRate)
        let effectiveStart = max(sessionStartSampleIndex, end - maxSamples)
        
        let segment = ringBuffer.snapshot(from: effectiveStart, to: end)
        
        guard !segment.isEmpty else { return }
        
        // RMS Energy Gate to prevent silence hallucinations
        let rms = sqrt(segment.reduce(0) { $0 + $1 * $1 } / Float(segment.count))
        
        guard rms > 0.005 else {
            return
        }
        
        // 🌉 Bridge to AVAudioPCMBuffer
        guard let buffer = AudioBufferBridge.createBuffer(from: segment, sampleRate: Double(audioSampleRate)) else {
            print("❌ DictationEngine: Failed to create audio buffer")
            return
        }
        
        // Get context from accumulator
        let contextText = await accumulator.getFullText()

        // 🦄 Unicorn Stack: Hybrid Transcription
        let processingStart = Date()
        
        guard let text = await transcriptionManager.transcribe(buffer: buffer, prompt: contextText) else {
            // Processing cancelled or failed
            return
        }
        
        let processingDuration = Date().timeIntervalSince(processingStart)
        // print("🎙️ DictationEngine: Transcribed \"\(text.prefix(20))...\" in \(String(format: "%.3f", processingDuration))s")
        
        // Emit result
        self.callbackQueue.async {
            self.onPartialRawText?(text)
            if isFinal {
                Task {
                    // Update accumulator with finalized text
                    // We need a way to get tokens here ideally, but for now we just pass text
                    // If we need tokens for detailed accumulator logic, we might need to change transcribe signature to return tokens too.
                    // But for now, just text context is a big improvement.
                    // Also, we use a fake tokens array for now or modify accumulator to accept just text if needed,
                    // but Accumulator expects tokens.
                    // Actually, LocalTranscriptionService returns just String.
                    // We might need to rethink Accumulator to do encoding internally or lazily.
                    // For now, let's just append text and empty tokens to Accumulator.
                    await self.accumulator.append(text: text, tokens: [])
                    self.onFinalText?(text)
                }
            }
        }

        if isFinal {
             // Commit this segment so next pass starts fresh
             sessionStartSampleIndex = end
        }
    }
}

