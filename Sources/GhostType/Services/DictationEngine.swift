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
    
    // Chunking / VAD State
    private var currentSegmentStart: Int64 = 0
    private var lastSpeechTimestamp: Date? = nil
    private let silenceDurationThresholdSeconds: TimeInterval = 0.7
    private var isSpeechActive = false

    // Sensitivity
    @Published var silenceThresholdRMS: Float = 0.005

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
        currentSegmentStart = sessionStartSampleIndex
        lastSpeechTimestamp = nil
        isSpeechActive = false

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
        
        // 1. VAD Check on the tail (last 500ms)
        let tailLength = Int64(0.5 * Double(audioSampleRate))
        let tailStart = max(currentSegmentStart, end - tailLength)
        let tailSegment = ringBuffer.snapshot(from: tailStart, to: end)

        var isTailSilent = true
        if !tailSegment.isEmpty {
            let rms = sqrt(tailSegment.reduce(0) { $0 + $1 * $1 } / Float(tailSegment.count))
            isTailSilent = rms < silenceThresholdRMS
        }

        // Update VAD State
        if !isTailSilent {
            lastSpeechTimestamp = Date()
            isSpeechActive = true
        }

        // Determine if segment is complete (silence duration > threshold)
        // Only trigger segment complete if we previously had speech active
        let timeSinceLastSpeech = Date().timeIntervalSince(lastSpeechTimestamp ?? Date.distantPast)
        let isSegmentComplete = isSpeechActive && isTailSilent && (timeSinceLastSpeech > silenceDurationThresholdSeconds)

        // Safety: If segment > 28s, force flush to avoid Whisper 30s limit clipping
        let durationSamples = end - currentSegmentStart
        let durationSec = Double(durationSamples) / Double(audioSampleRate)
        let forceFlush = durationSec > 28.0
        
        let shouldFinalize = isFinal || isSegmentComplete || forceFlush
        
        // Determine audio range for this pass
        // If finalizing: up to 'end' (or end of speech if we could detect it, but using 'end' is safer for now)
        // If partial: up to 'end'
        let audioToTranscribe = ringBuffer.snapshot(from: currentSegmentStart, to: end)
        
        guard !audioToTranscribe.isEmpty else { return }

        // Skip transcription if purely silent since start of segment (and not final)
        // This avoids transcribing background noise at the start
        if !isSpeechActive && !isFinal {
            // Keep waiting for speech
            return
        }
        
        // 🌉 Bridge to AVAudioPCMBuffer
        guard let buffer = AudioBufferBridge.createBuffer(from: audioToTranscribe, sampleRate: Double(audioSampleRate)) else {
            print("❌ DictationEngine: Failed to create audio buffer")
            return
        }
        
        // 🦄 Unicorn Stack: Hybrid Transcription
        // Retrieve context from accumulator
        let contextTokens = await accumulator.getContext()
        
        guard let (text, tokens) = await transcriptionManager.transcribeWithTokens(buffer: buffer, promptTokens: contextTokens) else {
            return
        }
        
        if shouldFinalize {
            // Append to accumulator
            await accumulator.append(text: text, tokens: tokens)

            // Emit full text
            let fullText = await accumulator.getFullText()
            self.callbackQueue.async {
                self.onPartialRawText?(fullText)
                // If it was final (user stopped), emit final
                if isFinal {
                    self.onFinalText?(fullText)
                }
            }

            // Advance segment
            currentSegmentStart = end
            isSpeechActive = false // Reset speech flag for next segment

            print("✅ DictationEngine: Segment finalized. Text: \"\(text)\"")

        } else {
            // Partial update
            let previousText = await accumulator.getFullText()
            let combined = previousText.isEmpty ? text : previousText + " " + text

            self.callbackQueue.async {
                self.onPartialRawText?(combined)
            }
        }
    }
}
