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
    
    // Chunking State
    private var currentChunkStartSampleIndex: Int64 = 0



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
        currentChunkStartSampleIndex = sessionStartSampleIndex
        Task { await accumulator.reset() }
        
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
        
        // Chunking Logic
        let chunkStart = max(sessionStartSampleIndex, currentChunkStartSampleIndex)
        let samplesPending = end - chunkStart
        
        // 1. Force chunk if > 28s (Safe margin for Whisper 30s window)
        let maxSamples = Int64(28 * audioSampleRate)
        var shouldCommit = isFinal
        
        if samplesPending > maxSamples {
             shouldCommit = true
             print("⚠️ DictationEngine: Forced chunking due to length (>28s)")
        }
        
        // 2. VAD Check for natural silence
        // If pending > 2s, check last 0.8s for silence
        let minDurationForCheck = Int64(2 * audioSampleRate)
        let silenceCheckDuration = Int64(0.8 * audioSampleRate)
        let silenceThreshold: Float = 0.005 // TODO: Load from prefs

        if !shouldCommit && samplesPending > minDurationForCheck {
            let tailStart = end - silenceCheckDuration
            let tailSegment = ringBuffer.snapshot(from: tailStart, to: end)
            if !tailSegment.isEmpty {
                let rms = sqrt(tailSegment.reduce(0) { $0 + $1 * $1 } / Float(tailSegment.count))
                if rms < silenceThreshold {
                    shouldCommit = true
                    // print("✂️ DictationEngine: Silence detected (RMS: \(rms)), committing chunk.")
                }
            }
        }

        let segment = ringBuffer.snapshot(from: chunkStart, to: end)

        guard !segment.isEmpty else { return }

        // RMS Energy Gate to prevent silence hallucinations on very short segments
        if samplesPending < minDurationForCheck {
             let rms = sqrt(segment.reduce(0) { $0 + $1 * $1 } / Float(segment.count))
             if rms < silenceThreshold { return }
        }
        
        // 🌉 Bridge to AVAudioPCMBuffer
        guard let buffer = AudioBufferBridge.createBuffer(from: segment, sampleRate: Double(audioSampleRate)) else {
            print("❌ DictationEngine: Failed to create audio buffer")
            return
        }
        
        // Context from previous chunks
        let contextTokens = await accumulator.getContext()

        // 🦄 Unicorn Stack: Hybrid Transcription
        // let processingStart = Date()
        
        guard let result = await transcriptionManager.transcribe(buffer: buffer, promptTokens: contextTokens) else {
            // Processing cancelled or failed
            return
        }
        
        let (text, tokens) = result
        
        // let processingDuration = Date().timeIntervalSince(processingStart)
        // print("🎙️ DictationEngine: Transcribed \"\(text.prefix(20))...\"")

        if shouldCommit {
            // Commit to accumulator
            await accumulator.append(text: text, tokens: tokens ?? [])
            currentChunkStartSampleIndex = end // Advance chunk start

            let fullText = await accumulator.getFullText()

            self.callbackQueue.async {
                self.onPartialRawText?(fullText) // Update UI with full text
                if isFinal {
                    self.onFinalText?(fullText)
                }
            }
        } else {
             // Preview
             let committedText = await accumulator.getFullText()
             let previewText = committedText + (committedText.isEmpty ? "" : " ") + text

             self.callbackQueue.async {
                 self.onPartialRawText?(previewText)
             }
        }
    }
}

