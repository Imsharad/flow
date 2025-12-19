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
    
    // State
    private var isRecording = false
    private var slidingWindowTimer: Timer?
    private let windowLoopInterval: TimeInterval = 0.5 // 500ms Tick
    private var sessionStartSampleIndex: Int64 = 0 // Track session start for isolation
    
    // VAD & Chunking State
    private var lastCommittedSampleIndex: Int64 = 0
    private var silenceDuration: TimeInterval = 0
    private let silenceThreshold: Float = 0.005
    private let minSilenceDurationToCommit: TimeInterval = 0.7
    private var currentContextTokens: [Int] = []

    // Tracks if we are currently in a "speech" segment (based on simple VAD)
    private var inSpeechSegment = false

    init(
        callbackQueue: DispatchQueue = .main
    ) {
        self.callbackQueue = callbackQueue
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
        completion?()
    }

    // MARK: - Internals

    private func handleSpeechStart() {
        guard !isRecording else { return }
        
        // Reset state for new session
        ringBuffer.clear()
        sessionStartSampleIndex = ringBuffer.totalSamplesWritten
        lastCommittedSampleIndex = sessionStartSampleIndex

        // Reset accumulators
        Task { await accumulator.reset() }
        currentContextTokens = []
        silenceDuration = 0
        inSpeechSegment = false
        
        // Start audio capture
        do {
            try audioManager.start()
        } catch {
            print("❌ DictationEngine: Failed to start audio manager: \(error)")
            return
        }
        
        isRecording = true
        
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
            
            // Force commit of remaining audio
            await self.processChunk(isFinal: true)
            
            let finalText = await self.accumulator.getFullText()
            
            DispatchQueue.main.async { [weak self] in
                self?.onFinalText?(finalText)
                self?.onSpeechEnd?()
            }
        }
    }

    // MARK: - Sliding Window Logic
    
    private func startSlidingWindow() {
        stopSlidingWindow()
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
            await self?.processChunk(isFinal: false)
        }
    }
    
    private func processChunk(isFinal: Bool = false) async {
        let end = ringBuffer.totalSamplesWritten
        
        // Data available since last commit
        let availableSamples = end - lastCommittedSampleIndex
        if availableSamples <= 0 { return }
        
        // 1. Analyze for VAD (Silence Detection) on the NEW data (approx)
        // We look at the last 500ms (windowLoopInterval) to check for silence
        let lookbackSamples = Int64(windowLoopInterval * Double(audioSampleRate))
        let vadStartIndex = max(lastCommittedSampleIndex, end - lookbackSamples)
        let vadSegment = ringBuffer.snapshot(from: vadStartIndex, to: end)
        
        let rms = sqrt(vadSegment.reduce(0) { $0 + $1 * $1 } / Float(max(1, vadSegment.count)))
        let isSilent = rms < silenceThreshold
        
        if isSilent {
            silenceDuration += windowLoopInterval
        } else {
            silenceDuration = 0
            inSpeechSegment = true
        }
        
        // 2. Decide whether to Commit (Chunk) or just Preview
        // Commit if:
        // - We have enough silence (>0.7s) AND we were previously in speech
        // - OR isFinal=true
        // - OR Buffer is getting too full (> 30s uncommitted)
        
        let uncommittedDuration = Double(availableSamples) / Double(audioSampleRate)
        let shouldCommit = isFinal || (inSpeechSegment && silenceDuration >= minSilenceDurationToCommit) || (uncommittedDuration > 28.0)
        
        if shouldCommit {
            // Commit the chunk from lastCommittedSampleIndex to end (or slightly before end if silence?)
            // For simplicity, we commit everything up to `end`.
            // Ideally we'd trim the trailing silence, but Whisper handles it okay.

            let chunk = ringBuffer.snapshot(from: lastCommittedSampleIndex, to: end)

            guard let buffer = AudioBufferBridge.createBuffer(from: chunk, sampleRate: Double(audioSampleRate)) else {
                return
            }

            // Transcribe with Context
            // If it's a "Force Commit" due to buffer full but no silence, we might chop a word.
            // But with 30s buffer, it's rare to have NO silence for 30s.

            if let result = await transcriptionManager.transcribeWithContext(buffer: buffer, promptTokens: currentContextTokens) {
                let (text, tokens) = result

                // Accumulate
                await accumulator.append(text: text, tokens: tokens)

                // Update Context
                // We keep the last N tokens (accumulator handles storage, but we need to feed it back)
                // Actually `transcribeWithContext` returns the NEW tokens for this segment.
                // We should append them to our running context or let accumulator manage it.
                // The `accumulator` already stores `lastTokens`.
                currentContextTokens = await accumulator.getContext()

                // Emit Full Text (Accumulated)
                let fullText = await accumulator.getFullText()
                self.callbackQueue.async {
                    self.onPartialRawText?(fullText)
                }

                // Advance Commit Pointer
                lastCommittedSampleIndex = end

                // Reset State
                inSpeechSegment = false
                if isSilent {
                     // If we committed due to silence, we are now "reset" effectively
                }
            }

        } else {
            // Just Preview (Optional)
            // If we want real-time feedback *during* the phrase, we can transcribe the uncommitted chunk
            // temporarily and append it to the accumulated text for the UI, but NOT commit it.

            // NOTE: This adds compute load. "GhostType" aims for efficiency?
            // "Real Inference" task implies we want real-time text.
            // So yes, we should preview.

            let chunk = ringBuffer.snapshot(from: lastCommittedSampleIndex, to: end)
            if chunk.count > 1600 { // at least 0.1s
                guard let buffer = AudioBufferBridge.createBuffer(from: chunk, sampleRate: Double(audioSampleRate)) else { return }

                // For preview, we DON'T pass context tokens usually, or we pass them but ignore result tokens.
                // Actually, passing context helps prediction even for partials.
                // But we use `transcribe` (simple) or `transcribeWithContext`?
                // Let's use `transcribe` which returns String.

                if let partialText = await transcriptionManager.transcribe(buffer: buffer, prompt: nil) {
                    let accumulated = await accumulator.getFullText()
                    let combined = accumulated + (accumulated.isEmpty ? "" : " ") + partialText

                    self.callbackQueue.async {
                        self.onPartialRawText?(combined)
                    }
                }
            }
        }
    }
}
