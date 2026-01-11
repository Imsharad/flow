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
    private let vad = VAD() // Internal VAD for chunking
    
    // State
    private var isRecording = false
    private var slidingWindowTimer: Timer?
    private let windowLoopInterval: TimeInterval = 0.5 // 500ms Tick for partial UI updates
    private var sessionStartSampleIndex: Int64 = 0 // Track session start for isolation
    
    // Chunking State
    private var currentChunkStartIndex: Int64 = 0
    private var isProcessingChunk = false

    // Context
    private var currentContext: String?

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

        // Feed VAD
        Task { @MainActor in
            self.processVAD(samples: samples)
        }
    }

    private func processVAD(samples: [Float]) {
        guard isRecording else { return }

        if let event = vad.process(buffer: samples) {
            switch event {
            case .speechStarted:
                // Just logging or UI feedback could go here
                print("🗣️ VAD: Speech Started")

            case .speechEnded:
                print("🤐 VAD: Speech Ended. Finalizing chunk.")
                // Trigger chunk finalization
                finalizeCurrentChunk()
            }
        }
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
        currentChunkStartIndex = sessionStartSampleIndex

        vad.reset()
        Task { await accumulator.reset() } // Reset accumulator

        // Context Injection (Phase 4)
        if let context = accessibilityManager.getActiveWindowContext() {
            // Format context string for transcription prompt
            // "Active App: Notes. Window: Weekly Meeting Notes."
            self.currentContext = "Active App: \(context.appName). Window: \(context.windowTitle)."
            print("🧠 DictationEngine: Context injected: \(self.currentContext ?? "")")
        } else {
            self.currentContext = nil
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
            
            // Force one final transcription of whatever is left
            await self.finalizeCurrentChunk(isSessionEnd: true)
            
            // Get full text from accumulator
            let fullText = await self.accumulator.getFullText()
            
            DispatchQueue.main.async { [weak self] in
                self?.onFinalText?(fullText)
                self?.onSpeechEnd?()
            }
        }
    }

    private func finalizeCurrentChunk(isSessionEnd: Bool = false) {
        // Mark that we are processing a chunk (could be used for additional logic)
        isProcessingChunk = true

        Task(priority: .userInitiated) {
            let end = ringBuffer.totalSamplesWritten
            let start = currentChunkStartIndex

            // Avoid processing empty or extremely short chunks
            if end - start < Int64(0.5 * Double(audioSampleRate)) { // < 0.5s
                if isSessionEnd {
                     // Still update current position just in case
                } else {
                    isProcessingChunk = false
                    return
                }
            }

            // Process the chunk as final (High Priority)
            await processSegment(start: start, end: end, isFinal: true, priority: .high)

            // Move the chunk start to the current end
            // Note: This must be done CAREFULLY. If we do it here, we assume transcription succeeded.
            // But even if it failed, we probably want to move forward to avoid getting stuck?
            // Yes, advance.
            currentChunkStartIndex = end
            isProcessingChunk = false
        }
    }

    // MARK: - Sliding Window Logic
    
    private func startSlidingWindow() {
        stopSlidingWindow()
        // Main Thread Timer for partial updates
        slidingWindowTimer = Timer.scheduledTimer(withTimeInterval: windowLoopInterval, repeats: true) { [weak self] _ in
            self?.processWindow()
        }
    }
    
    private func stopSlidingWindow() {
        slidingWindowTimer?.invalidate()
        slidingWindowTimer = nil
    }
    
    private func processWindow() {
        guard isRecording else { return }
        // If we are already processing a final chunk, skip partials to reduce load/contention
        guard !isProcessingChunk else { return }

        Task(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            let end = ringBuffer.totalSamplesWritten
            // Transcribe from current chunk start to now (Partial - Low Priority)
            await self.processSegment(start: self.currentChunkStartIndex, end: end, isFinal: false, priority: .low)
        }
    }
    
    private func processSegment(start: Int64, end: Int64, isFinal: Bool, priority: TranscriptionManager.TranscriptionPriority) async {
        let segment = ringBuffer.snapshot(from: start, to: end)
        
        guard !segment.isEmpty else { return }
        
        // RMS Energy Gate (still useful for partials)
        let rms = sqrt(segment.reduce(0) { $0 + $1 * $1 } / Float(segment.count))
        if rms < 0.005 && !isFinal {
            // Skip processing silent partials to save compute
            return
        }
        
        // 🌉 Bridge to AVAudioPCMBuffer
        guard let buffer = AudioBufferBridge.createBuffer(from: segment, sampleRate: Double(audioSampleRate)) else {
            print("❌ DictationEngine: Failed to create audio buffer")
            return
        }
        
        // Get context from accumulator
        let contextTokens = await accumulator.getContext()
        
        // Construct Prompt:
        // For Cloud, we use `currentContext` (text).
        // For Local, we use `contextTokens` (continuation).
        // We pass both.

        guard let (text, tokens) = await transcriptionManager.transcribe(
            buffer: buffer,
            prompt: currentContext,
            promptTokens: contextTokens,
            priority: priority
        ) else {
            // If transcription returned nil, it was cancelled or failed.
            // If it was final, we might want to retry or log error?
            // For now, we accept data loss on error/cancel, but Priority system should prevent cancel of Final.
            return
        }
        
        // Update Accumulator if final
        if isFinal {
            // Use returned tokens (or empty if nil)
            await accumulator.append(text: text, tokens: tokens ?? [])
        }

        // Combine accumulated text + current partial
        // If final, the "current partial" IS the final text for this segment.
        // We get full text from accumulator (which now includes this segment).
        // If partial, we append current partial text to accumulator's finalized text.

        let accumulated = await accumulator.getFullText()

        let combined: String
        if isFinal {
             combined = accumulated
        } else {
             // For partial, we haven't appended `text` to accumulator yet.
             combined = (accumulated + " " + text).trimmingCharacters(in: .whitespaces)
        }
        
        // Emit result
        self.callbackQueue.async {
            self.onPartialRawText?(combined)
        }
    }
}
