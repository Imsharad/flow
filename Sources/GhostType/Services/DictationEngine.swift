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
    
    // VAD State
    private var committedSampleIndex: Int64 = 0
    private var silenceDuration: TimeInterval = 0.0
    private let minSilenceDuration: TimeInterval = 0.7
    private let maxRecordingDuration: TimeInterval = 30.0
    private let maxSegmentDuration: TimeInterval = 28.0 // Force commit before 30s limit
    private var lastSpeechActivityTime: Date = Date()
    private var isSpeechActive: Bool = false

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

        // Reset VAD state
        silenceDuration = 0.0
        lastSpeechActivityTime = Date()
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
            await self.processOnePass(forceFinal: true)
            
            // Get final full text
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
            await self?.processOnePass(forceFinal: false)
        }
    }
    
    private func processOnePass(forceFinal: Bool = false) async {
        let currentHead = ringBuffer.totalSamplesWritten
        
        // 1. Analyze for VAD (Activity Detection)
        // Look at new audio since last check (simplified) or just last 0.5s
        let vadWindowSize = Int64(0.5 * Double(audioSampleRate))
        let vadStart = max(sessionStartSampleIndex, currentHead - vadWindowSize)
        let vadSegment = ringBuffer.snapshot(from: vadStart, to: currentHead)
        
        let rms = sqrt(vadSegment.reduce(0) { $0 + $1 * $1 } / Float(max(1, vadSegment.count)))
        let isSilent = rms <= 0.005
        
        if !isSilent {
            isSpeechActive = true
            silenceDuration = 0.0
            lastSpeechActivityTime = Date()
        } else {
            silenceDuration += windowLoopInterval
        }
        
        // 2. Determine if we should Commit (Segment Finalization)
        // Conditions:
        // A. Force Final (Stop called)
        // B. Silence > Threshold AND Speech was active (Natural pause)
        // C. Segment length > Max Duration (Forced split to avoid model overflow)

        let uncommittedLength = Double(currentHead - committedSampleIndex) / Double(audioSampleRate)

        let shouldCommit = forceFinal ||
                           (isSpeechActive && silenceDuration >= minSilenceDuration) ||
                           (uncommittedLength >= maxSegmentDuration)

        if shouldCommit && uncommittedLength > 0.1 { // Ignore tiny segments
             // print("🔄 DictationEngine: Committing segment (Force=\(forceFinal), Silence=\(silenceDuration), Len=\(uncommittedLength)s)")
             await transcribeSegment(from: committedSampleIndex, to: currentHead, isFinal: true)

             // Advance committed pointer
             committedSampleIndex = currentHead

             // Reset state
             isSpeechActive = false
             silenceDuration = 0.0

        } else if isRecording {
            // Partial Update (Streaming UI)
            // Transcribe from committedIndex to Head WITHOUT updating committedIndex
            // This gives the user "live" feedback
            await transcribeSegment(from: committedSampleIndex, to: currentHead, isFinal: false)
        }
    }

    private func transcribeSegment(from start: Int64, to end: Int64, isFinal: Bool) async {
        let segment = ringBuffer.snapshot(from: start, to: end)
        guard !segment.isEmpty else { return }
        
        // 🌉 Bridge to AVAudioPCMBuffer
        guard let buffer = AudioBufferBridge.createBuffer(from: segment, sampleRate: Double(audioSampleRate)) else {
            print("❌ DictationEngine: Failed to create audio buffer")
            return
        }
        
        // Get context from accumulator
        let promptText = await accumulator.getFullText() // For Cloud
        let promptTokens = await accumulator.getContext() // For Local
        
        // Transcribe
        guard let result = await transcriptionManager.transcribe(
            buffer: buffer,
            prompt: promptText.isEmpty ? nil : promptText,
            promptTokens: promptTokens.isEmpty ? nil : promptTokens
        ) else {
            return
        }
        
        if isFinal {
            // Append to accumulator
            await accumulator.append(text: result.text, tokens: result.tokens ?? [])

            // Emit accumulated text
            let fullText = await accumulator.getFullText()
            self.callbackQueue.async {
                self.onPartialRawText?(fullText) // Update UI with full finalized text
            }
        } else {
            // Temporary preview
            // Combine confirmed text + partial text
            let confirmedText = await accumulator.getFullText()
            let partialText = result.text
            let combined = confirmedText + (confirmedText.isEmpty ? "" : " ") + partialText

            self.callbackQueue.async {
                self.onPartialRawText?(combined)
            }
        }
    }
}
