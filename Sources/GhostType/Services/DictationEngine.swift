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
    
    // Chunked Streaming State
    private var lastCommittedSampleIndex: Int64 = 0
    private var silenceDuration: TimeInterval = 0
    private let silenceThreshold: Float = 0.005
    private let maxSilenceDuration: TimeInterval = 0.7 // 700ms silence to commit
    private let minSpeechDurationBeforeCommit: TimeInterval = 2.0 // Don't commit tiny blips
    private let maxSpeechDurationBeforeCommit: TimeInterval = 25.0 // Force commit at 25s
    private var lastActivityTime: Date = Date()

    // Context
    private var capturedContext: String = ""


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
        
        // Capture Context
        // We do this on the main thread or ensure ContextManager is safe.
        // Since we are MainActor, it's fine.
        self.capturedContext = ContextManager.shared.generateContextPrompt()
        print("🧠 DictationEngine: Context set to: \(self.capturedContext)")

        // Reset state for new session
        ringBuffer.clear()
        accumulator.reset()
        sessionStartSampleIndex = ringBuffer.totalSamplesWritten // Mark session start AFTER clear
        lastCommittedSampleIndex = sessionStartSampleIndex
        silenceDuration = 0
        lastActivityTime = Date()
        
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
            
            // Force one final transcription of the complete buffer from last commit
            await self.processOnePass(forceFinalize: true)
            
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
            await self?.processOnePass(forceFinalize: false)
        }
    }
    
    private func processOnePass(forceFinalize: Bool = false) async {
        let currentHead = ringBuffer.totalSamplesWritten
        
        // If we haven't moved forward, skip
        if currentHead <= lastCommittedSampleIndex { return }
        
        // 1. Get the newly recorded segment since last commit
        // We actually want to transcribe from `lastCommittedSampleIndex` to `currentHead`
        // But we might need to look back a bit if we are doing sliding window...
        // However, in "Chunked Streaming", we commit segments.
        // So the "Active Segment" is always `lastCommittedSampleIndex` ... `currentHead`.
        
        let activeSegment = ringBuffer.snapshot(from: lastCommittedSampleIndex, to: currentHead)
        guard !activeSegment.isEmpty else { return }
        
        // 2. VAD / Silence Detection on the *tail* of the segment (last 0.5s)
        let tailLength = Int(0.5 * Double(audioSampleRate))
        let tailSegment = activeSegment.suffix(tailLength)
        let rms = sqrt(tailSegment.reduce(0) { $0 + $1 * $1 } / Float(tailSegment.count))

        let isSilent = rms < silenceThreshold

        if isSilent {
            silenceDuration += windowLoopInterval
        } else {
            silenceDuration = 0
            lastActivityTime = Date()
        }

        // 3. RMS Gate (Skip processing if pure silence and haven't committed in a while)
        let segmentDuration = Double(activeSegment.count) / Double(audioSampleRate)

        // If it's silence and we don't have enough speech to commit, just return to save CPU.
        // Unless we are forcing finalize.
        if !forceFinalize && isSilent && segmentDuration < minSpeechDurationBeforeCommit {
             return
        }
        
        // 4. Decision: Commit vs Partial
        // We commit if:
        // A) Silence > maxSilenceDuration AND segment duration > minSpeechDuration
        // B) Segment duration > maxSpeechDurationBeforeCommit (Force commit to avoid buffer overflow)
        // C) forceFinalize is true

        let shouldCommit = forceFinalize ||
                           (isSilent && silenceDuration > maxSilenceDuration && segmentDuration > minSpeechDurationBeforeCommit) ||
                           (segmentDuration > maxSpeechDurationBeforeCommit)

        // 🌉 Bridge to AVAudioPCMBuffer
        guard let buffer = AudioBufferBridge.createBuffer(from: activeSegment, sampleRate: Double(audioSampleRate)) else {
            print("❌ DictationEngine: Failed to create audio buffer")
            return
        }
        
        // 5. Transcribe
        // Pass the accumulated context as prompt
        let previousTranscript = await accumulator.getFullText()

        // Truncate previous transcript to last 1000 chars to avoid token limit overflow (approx 250-300 tokens)
        // Context window is usually 224 tokens, so we should be conservative.
        let truncatedTranscript = String(previousTranscript.suffix(800))

        // Combine system/window context with previous transcript for the full prompt
        let fullPrompt = (capturedContext + " " + truncatedTranscript).trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard let text = await transcriptionManager.transcribe(buffer: buffer, prompt: fullPrompt) else {
            return
        }
        
        // 5. Update State
        if shouldCommit {
            print("✅ DictationEngine: Committing chunk: \"\(text)\"")
            await accumulator.append(text: text, tokens: []) // We don't have tokens here yet unless we update Manager return type
            lastCommittedSampleIndex = currentHead
            silenceDuration = 0

            // Emit concatenated result
            let fullText = await accumulator.getFullText()
            self.callbackQueue.async {
                self.onPartialRawText?(fullText)
            }
        } else {
            // Partial update
            // Show Accumulated + Current Partial
            let combined = (previousTranscript + " " + text).trimmingCharacters(in: .whitespacesAndNewlines)
            self.callbackQueue.async {
                self.onPartialRawText?(combined)
            }
        }
    }
}
