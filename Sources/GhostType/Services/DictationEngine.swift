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
        
        // 1. Capture Context (Snapshot of active window)
        // We do this on MainActor before background work starts
        self.capturedContext = ContextManager.shared.getContextPrompt()
        // print("🧠 DictationEngine: Context captured: \"\(capturedContext)\"")

        // Reset state for new session
        ringBuffer.clear()
        sessionStartSampleIndex = ringBuffer.totalSamplesWritten // Mark session start AFTER clear
        
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
        
        // 1. Calculate duration of current segment
        // We accumulate from sessionStartSampleIndex.
        // We rely on VAD logic below to commit chunks and advance sessionStartSampleIndex.
        // Safety cap: If segment > 25s, we force commit to avoid context window overflow.
        
        let chunkLength = end - sessionStartSampleIndex
        let chunkSeconds = Double(chunkLength) / Double(audioSampleRate)
        let maxSpeechDurationBeforeCommit: TimeInterval = 25.0
        
        // 2. Check for Silence (VAD) at the end of the buffer
        // Look at the last 0.5s for silence detection
        let silenceWindowSamples = Int64(0.5 * Double(audioSampleRate))
        var isSilence = false
        
        if chunkLength > silenceWindowSamples {
            let silenceStart = end - silenceWindowSamples
            let silenceSegment = ringBuffer.snapshot(from: silenceStart, to: end)
            let silenceRMS = sqrt(silenceSegment.reduce(0) { $0 + $1 * $1 } / Float(silenceSegment.count))
            isSilence = silenceRMS < 0.005 // Silence threshold
        }

        // 3. Determine if we should commit this chunk
        // Conditions:
        // - isFinal (Stop button pressed) -> Force commit
        // - Silence detected AND segment > 2s (avoid chopping too fast/mid-sentence pauses)
        // - Segment > 25s (Force commit to avoid context window overflow)

        let shouldCommit = isFinal || (isSilence && chunkSeconds > 2.0) || (chunkSeconds > maxSpeechDurationBeforeCommit)

        // 4. Get the segment audio
        let segment = ringBuffer.snapshot(from: sessionStartSampleIndex, to: end)

        guard !segment.isEmpty else { return }

        // RMS check for the whole segment if it's short and we are not forcing a commit
        if !shouldCommit {
             let segmentRMS = sqrt(segment.reduce(0) { $0 + $1 * $1 } / Float(segment.count))
             if segmentRMS < 0.005 { return }
        }
        
        // 🌉 Bridge to AVAudioPCMBuffer
        guard let buffer = AudioBufferBridge.createBuffer(from: segment, sampleRate: Double(audioSampleRate)) else {
            print("❌ DictationEngine: Failed to create audio buffer")
            return
        }
        
        // 5. Get context from accumulator for prompt
        // We pass the last ~800 chars as prompt context to help Whisper maintain coherence
        let accumulatedText = await accumulator.getFullText()

        // 🦄 Unicorn Stack: Prompt Engineering
        // Combine captured context (Window info) + accumulated text (previous chunks)
        // If accumulated text is empty, we lead with context.
        // If we have accumulated text, we prioritize that for coherence, but maybe prepend context?
        // WhisperKit prompt works best with just previous tokens.
        // But for Cloud, we want the "I am working in X..." prompt.

        // Strategy:
        // - If accumulatedText is empty (First chunk), use `capturedContext`.
        // - If accumulatedText exists, use `capturedContext` + " " + `accumulatedText`.
        // - Truncate safely.

        var combinedPrompt = capturedContext
        if !accumulatedText.isEmpty {
            combinedPrompt += " " + accumulatedText
        }
        
        // Truncate to avoid massive prompts (approx 800 chars)
        let prompt = String(combinedPrompt.suffix(800))

        // 🦄 Unicorn Stack: Hybrid Transcription
        guard let result = await transcriptionManager.transcribe(buffer: buffer, prompt: prompt) else {
            // Processing cancelled or failed
            return
        }
        
        let (text, tokens) = result
        
        if shouldCommit {
            // Commit to accumulator
            await accumulator.append(text: text, tokens: tokens ?? [])

            // Advance session start to current end
            sessionStartSampleIndex = end

            // Emit full accumulated text
            let fullText = await accumulator.getFullText()
            self.callbackQueue.async {
                self.onPartialRawText?(fullText)
                if isFinal {
                    self.onFinalText?(fullText)
                }
            }
            // print("✅ DictationEngine: Committed chunk: \"\(text)\"")
        } else {
            // Tentative result (Streaming preview)
            // Combine committed text + tentative text
            let fullText = accumulatedText.isEmpty ? text : accumulatedText + " " + text
            self.callbackQueue.async {
                self.onPartialRawText?(fullText)
            }
        }
    }
}

