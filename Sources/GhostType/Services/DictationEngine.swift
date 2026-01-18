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
    
    // Chunking & Context
    private var committedSampleIndex: Int64 = 0
    private var activeContext: String? = nil

    // VAD tracking for Chunking
    private var lastSilenceStart: Double? = nil
    private let minSilenceDurationSeconds: Double = 0.7


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
        accumulator.clear()

        // Capture Context (Active Window)
        if let context = accessibilityManager.getActiveWindowContext() {
            // Format context string: "Writing in [App] - [Title]"
            // This is a simple prompt engineering trick
            self.activeContext = "System Context: User is typing in \(context.appName) - \(context.windowTitle).\n"
            print("🧠 Context Captured: \(self.activeContext ?? "")")
        } else {
            self.activeContext = nil
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

        // We always process from the last committed point
        // But we cap the duration to 30s max for the current chunk to avoid model overflow
        // If the chunk > 30s, we force a commit at 30s (handled by maxSamples logic)

        let maxSamples = Int64(30 * audioSampleRate)
        // If current uncommitted audio > 30s, force commit the head
        // However, standard Whisper needs the tail.
        // Chunking strategy:
        // We only commit when VAD says silence OR if isFinal is true.
        // If audio grows too long (>30s) without silence, we might lose data with ring buffer snapshotting?
        // Actually, ringBuffer stores 180s.
        // We want to snapshot from `committedSampleIndex` to `end`.
        // If this length > 30s, we should probably grab the first 30s and commit it?
        // Or better, just grab the last 30s and risk losing the middle?
        // No, we want to accumulate.
        
        // Revised Strategy:
        // We take `committedSampleIndex` to `end`.
        // If > 30s, we take the *first* 29s, transcribe it as final, commit it, and move `committedSampleIndex`.
        // This handles "continuous speech without silence".

        var effectiveEnd = end
        var forceFinalize = isFinal

        let durationSamples = end - committedSampleIndex
        if durationSamples > maxSamples {
            // Buffer overflow protection: Force chunk the first 29s
            effectiveEnd = committedSampleIndex + Int64(29 * audioSampleRate)
            forceFinalize = true
            print("⚠️ DictationEngine: Forced chunking due to length > 30s")
        }

        let segment = ringBuffer.snapshot(from: committedSampleIndex, to: effectiveEnd)
        
        guard !segment.isEmpty else { return }
        
        // RMS Energy Gate
        let rms = sqrt(segment.reduce(0) { $0 + $1 * $1 } / Float(segment.count))
        
        // VAD Logic for "Natural Chunking"
        // If silence detected for > 0.7s, mark as final to "commit" this phrase
        // This keeps context updated and UI responsive
        if !forceFinalize && rms < 0.005 {
             // Silence
             // We need to track *duration* of silence.
             // But we are polling every 0.5s.
             // If we see silence, we can't be sure it's long enough without state.
             // Simple heuristic: If the *entire* last 0.5s was silent? No, snapshot is the whole buffer.

             // Better: If the segment end has low energy?
             // Let's rely on `forceFinalize` (end of session) or overflow for now.
             // Advanced VAD is tricky without frame-level processing.
             // We'll stick to: Commit only on Stop or Overflow for V1 of Chunking.
             // Users usually pause.
             // Wait! The user requirement says "Implement VAD-based chunked streaming".
             // We can check if the *last 1 second* of the segment is silent.
             let last1SecSamples = Int(1.0 * Double(audioSampleRate))
             if segment.count > last1SecSamples {
                 let suffix = segment.suffix(last1SecSamples)
                 let suffixRms = sqrt(suffix.reduce(0) { $0 + $1 * $1 } / Float(suffix.count))
                 if suffixRms < 0.005 {
                     // Tail is silent. We can safely finalize this chunk.
                     forceFinalize = true
                     // But we should trim the silence from the next chunk start?
                     // For simplicity, we just commit up to effectiveEnd.
                 }
             }
        }

        guard rms > 0.005 || forceFinalize else {
            return
        }
        
        // 🌉 Bridge
        guard let buffer = AudioBufferBridge.createBuffer(from: segment, sampleRate: Double(audioSampleRate)) else {
            return
        }
        
        // Prepare Prompt
        // If it's the very first chunk, use `activeContext`.
        // If we have committed segments, use `accumulator.contextTokens`.
        // Note: activeContext is text, contextTokens are IDs.
        // Our updated TranscriptionManager supports both.
        
        let promptText = (accumulator.contextTokens.isEmpty) ? activeContext : nil
        let promptTokens = (accumulator.contextTokens.isEmpty) ? nil : accumulator.contextTokens

        // Transcribe
        guard let (text, tokens) = await transcriptionManager.transcribe(
            buffer: buffer,
            prompt: promptText,
            promptTokens: promptTokens
        ) else {
            return
        }
        
        // Logic:
        // If `forceFinalize` is true, we commit this text to accumulator.
        // And we update `committedSampleIndex` to `effectiveEnd`.
        
        if forceFinalize {
            accumulator.commit(text: text, tokens: tokens)
            committedSampleIndex = effectiveEnd

            // Emit FULL text (History + Current Chunk (which is now history))
            self.callbackQueue.async {
                self.onPartialRawText?(self.accumulator.fullText)
                if isFinal {
                     // Real end of session
                    self.onFinalText?(self.accumulator.fullText)
                }
            }
        } else {
            // Partial Result
            // We combine Accumulator + Current Partial
            let combined = accumulator.fullText + (accumulator.fullText.isEmpty ? "" : " ") + text
             self.callbackQueue.async {
                self.onPartialRawText?(combined)
            }
        }
    }
}
