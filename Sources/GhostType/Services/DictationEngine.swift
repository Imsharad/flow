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
    private var committedText: String = ""
    private var lastCommittedSampleIndex: Int64 = 0
    private var silenceStart: Date?

    // Context
    private var activeContext: String = ""


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
        
        // Capture context immediately (async to not block UI, but fast enough)
        Task(priority: .userInitiated) {
            let context = AccessibilityManager().getActiveWindowContext()
            await MainActor.run {
                self.activeContext = context
                print("Context captured: \(context)")
            }
        }

        // Reset state for new session
        ringBuffer.clear()
        sessionStartSampleIndex = ringBuffer.totalSamplesWritten // Mark session start AFTER clear
        lastCommittedSampleIndex = sessionStartSampleIndex
        committedText = ""
        silenceStart = nil
        
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
        let start = lastCommittedSampleIndex
        let segment = ringBuffer.snapshot(from: start, to: end)
        
        guard !segment.isEmpty else { return }
        
        // VAD Logic
        let rms = sqrt(segment.reduce(0) { $0 + $1 * $1 } / Float(segment.count))
        let sensitivity = UserDefaults.standard.double(forKey: "micSensitivity")
        let threshold = sensitivity > 0 ? sensitivity : 0.005

        let isSilence = rms < Float(threshold)
        if isSilence {
            if silenceStart == nil { silenceStart = Date() }
        } else {
            silenceStart = nil
        }
        
        // Chunking Logic
        let pendingDuration = Double(segment.count) / Double(audioSampleRate)
        let silenceDuration = silenceStart.map { Date().timeIntervalSince($0) } ?? 0

        // Commit if:
        // 1. Silence > 0.7s AND we have at least 1s of audio
        // 2. OR Pending duration > 25s (forced commit to stay in context window)
        // 3. OR isFinal (forced stop)
        let shouldCommit = (isSilence && silenceDuration > 0.7 && pendingDuration > 1.0) || pendingDuration > 25.0 || isFinal

        // Optimization: If purely silence and no pending text of value, skip transcription (unless committing to advance cursor)
        if isSilence && pendingDuration < 1.0 && !shouldCommit {
            return
        }

        // Construct Prompt
        // Context + last 500 chars of committed text for continuity
        let committedTail = String(committedText.suffix(500))
        let prompt = "\(activeContext)\n\(committedTail)"
        
        // 🌉 Bridge to AVAudioPCMBuffer
        guard let buffer = AudioBufferBridge.createBuffer(from: segment, sampleRate: Double(audioSampleRate)) else {
            print("❌ DictationEngine: Failed to create audio buffer")
            return
        }
        
        // 🦄 Unicorn Stack: Hybrid Transcription
        guard let text = await transcriptionManager.transcribe(buffer: buffer, prompt: prompt) else {
            // Processing cancelled or failed
            return
        }
        
        // Update State
        if shouldCommit {
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                 committedText += (committedText.isEmpty ? "" : " ") + cleaned
            }
            lastCommittedSampleIndex = end
            silenceStart = nil // Reset silence timer after commit

            let fullText = committedText
            self.callbackQueue.async {
                self.onPartialRawText?(fullText)
                if isFinal {
                    self.onFinalText?(fullText)
                }
            }
             // print("✅ DictationEngine: Committed chunk: \"\(cleaned)\" (Total: \(committedText.count) chars)")
        } else {
             // Preview only
             let fullText = (committedText + " " + text).trimmingCharacters(in: .whitespacesAndNewlines)
             self.callbackQueue.async {
                 self.onPartialRawText?(fullText)
                 // Note: We don't call onFinalText unless isFinal is true (handled in shouldCommit branch)
             }
        }
    }
}

