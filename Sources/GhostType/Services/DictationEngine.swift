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
    private let vad = VAD() // VAD for chunking
    
    // State
    private var isRecording = false
    private var slidingWindowTimer: Timer?
    private let windowLoopInterval: TimeInterval = 0.5 // 500ms Tick
    private var sessionStartSampleIndex: Int64 = 0 // Track session start for isolation
    
    // Chunking State
    private var committedSampleIndex: Int64 = 0
    private var vadReadIndex: Int64 = 0 // Tracks how much we've fed to VAD
    private var lastCommittedTokens: [Int] = []

    // Phase 4: Active Window Context
    private var activeContext: ActiveWindowContext?

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
        
        // Phase 4: Capture Context at start
        self.activeContext = accessibilityManager.getActiveWindowContext()
        if let context = activeContext {
            print("🧠 Context: [\(context.appName)] - \"\(context.windowTitle)\"")
            // We capture context here. It will be used in transcribe calls.
        }

        // Reset state for new session
        ringBuffer.clear()
        sessionStartSampleIndex = ringBuffer.totalSamplesWritten
        committedSampleIndex = sessionStartSampleIndex
        vadReadIndex = sessionStartSampleIndex

        // Reset Accumulator
        Task { await accumulator.reset() }
        vad.reset()
        lastCommittedTokens = []
        
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
            
            // Get final accumulated text
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
            await self?.processVADAndChunking()
        }
    }
    
    private func processVADAndChunking() async {
        let end = ringBuffer.totalSamplesWritten
        
        // Feed new samples to VAD
        // Note: ringBuffer.snapshot is cheap (copy). We take samples from vadReadIndex to end.
        let vadSamples = ringBuffer.snapshot(from: vadReadIndex, to: end)
        if !vadSamples.isEmpty {
             let event = vad.process(buffer: vadSamples, sampleRate: Double(audioSampleRate))
             vadReadIndex = end // Advance VAD cursor

             if event == .speechEnd {
                 // Trigger chunk finalization
                 print("🗣️ VAD: Speech End Detected. Finalizing Chunk.")
                 await finalizeChunk(upTo: end)
             }
        }
        
        // Run sliding window inference on UNCOMMITTED audio (partial)
        await processOnePass(isFinal: false)
    }

    /// Commits the audio from `committedSampleIndex` to `upTo` as a finalized chunk.
    private func finalizeChunk(upTo: Int64) async {
        let segment = ringBuffer.snapshot(from: committedSampleIndex, to: upTo)
        guard !segment.isEmpty else { return }
        
        // Transcribe with context
        guard let buffer = AudioBufferBridge.createBuffer(from: segment, sampleRate: Double(audioSampleRate)) else { return }
        
        // Construct Text Context
        let textContext = activeContext.map { "App: \($0.appName), Window: \($0.windowTitle)" }
        
        // We need to fetch tokens to update context
        if let result = await transcriptionManager.transcribe(buffer: buffer, promptTokens: lastCommittedTokens, textContext: textContext) {
            // Append to accumulator
            await accumulator.append(text: result.text, tokens: result.tokens)

            // Update pointers
            committedSampleIndex = upTo
            lastCommittedTokens = await accumulator.getContext()

            print("✅ Chunk Finalized: \"\(result.text)\"")
        }
    }

    private func processOnePass(isFinal: Bool = false) async {
        let end = ringBuffer.totalSamplesWritten
        
        // If final, we process everything uncommitted.
        // If not final, we limit to max 30s lookback from end, but NOT before committedSampleIndex
        // The "Sliding Window" now effectively slides on the *uncommitted* portion (plus maybe some overlap if we wanted, but let's keep it simple).
        
        // Actually, we should transcribe from committedSampleIndex to end (Partial).
        let effectiveStart = committedSampleIndex

        // Safety: If uncommitted audio is > 30s, we cap it.
        // Although VAD should have triggered by now. If not, we just transcribe the last 30s of uncommitted.
        let maxSamples = Int64(30 * audioSampleRate)
        let safeStart = max(effectiveStart, end - maxSamples)

        let segment = ringBuffer.snapshot(from: safeStart, to: end)

        guard !segment.isEmpty else {
            // If empty, just emit what we have in accumulator
            if isFinal {
                let text = await accumulator.getFullText()
                // self.callbackQueue.async { self.onFinalText?(text) } // Done in stop()
            }
            return
        }

        // Optional RMS Gate for partials (skip inference if silence)
        // But if VAD didn't trigger End, we assume speech is ongoing or silence is short.
        // We can use VAD state to optimize?
        if vad.state == .silence && !isFinal {
             // If VAD thinks we are silent, we might just return the committed text + empty partial
             let committedText = await accumulator.getFullText()
             self.callbackQueue.async { self.onPartialRawText?(committedText) }
             return
        }
        
        guard let buffer = AudioBufferBridge.createBuffer(from: segment, sampleRate: Double(audioSampleRate)) else { return }

        // Construct Text Context
        let textContext = activeContext.map { "App: \($0.appName), Window: \($0.windowTitle)" }

        // Transcribe partial
        guard let result = await transcriptionManager.transcribe(buffer: buffer, promptTokens: lastCommittedTokens, textContext: textContext) else { return }

        let partialText = result.text

        // Combine with accumulated text
        let fullText = await accumulator.getFullText()
        let combined = (fullText + " " + partialText).trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Emit result
        self.callbackQueue.async {
            self.onPartialRawText?(combined)
            // Note: We don't call onFinalText here unless isFinal is true, but handleFinalText logic in stop() handles it.
        }

        // If this is the final pass called by stop(), we should technically commit it.
        // But stop() handles logic manually.
        if isFinal {
             await accumulator.append(text: partialText, tokens: result.tokens)
        }
    }
}
