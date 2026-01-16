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
    weak var accessibilityManager: AccessibilityManager?
    
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
    private var lastConfirmedText: String = ""
    private var lastTokens: [Int] = []
    private var lastChunkEndSampleIndex: Int64 = 0
    private var contextPrompt: String?

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
        lastConfirmedText = ""
        lastTokens = []
        lastChunkEndSampleIndex = sessionStartSampleIndex

        // Capture Context
        if let info = accessibilityManager?.getActiveWindowContext() {
            contextPrompt = "Context: \(info.appName) - \(info.windowTitle)"
            print("🤖 DictationEngine: Captured Context [\(contextPrompt ?? "")]")
        } else {
            contextPrompt = nil
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

        // Use lastChunkEndSampleIndex as start, but respect max 30s window from end
        // If the chunk is longer than 30s, we might lose data, but we assume VAD chunks are smaller.
        let maxSamples = Int64(30 * audioSampleRate)
        let effectiveStart = max(lastChunkEndSampleIndex, end - maxSamples)
        
        let segment = ringBuffer.snapshot(from: effectiveStart, to: end)
        
        guard !segment.isEmpty else { return }
        
        // RMS Energy Gate
        let rms = sqrt(segment.reduce(0) { $0 + $1 * $1 } / Float(segment.count))
        
        // Silence detection for chunking (if not explicitly final)
        // Check last 0.7s (approx 11200 samples)
        var isSilenceDetected = false
        if !isFinal && segment.count > 11200 {
            let tail = segment.suffix(11200)
            let tailRms = sqrt(tail.reduce(0) { $0 + $1 * $1 } / Float(tail.count))
            if tailRms < 0.005 {
                isSilenceDetected = true
            }
        }

        // If it's pure silence and we have no pending text, just advance the cursor (VAD skip)
        if rms < 0.005 && !isFinal {
            // Only advance if we are sure there's nothing interesting.
            // But be careful not to skip start of speech.
            return
        }
        
        // 🌉 Bridge to AVAudioPCMBuffer
        guard let buffer = AudioBufferBridge.createBuffer(from: segment, sampleRate: Double(audioSampleRate)) else {
            print("❌ DictationEngine: Failed to create audio buffer")
            return
        }
        
        // 🦄 Unicorn Stack: Hybrid Transcription with Context
        let processingStart = Date()
        
        // Pass the Accumulated Context (tokens)
        let (transcribedText, tokens) = await transcriptionManager.transcribe(
            buffer: buffer,
            prompt: contextPrompt,
            promptTokens: lastTokens
        )

        guard let newText = transcribedText else { return }
        
        let processingDuration = Date().timeIntervalSince(processingStart)
        
        // Construct Full Text
        let fullText = lastConfirmedText.isEmpty ? newText : lastConfirmedText + " " + newText

        // Decide whether to commit
        let shouldCommit = isFinal || (isSilenceDetected && !newText.isEmpty)

        if shouldCommit {
            print("💾 DictationEngine: Committing chunk: \"\(newText.prefix(20))...\"")
            lastConfirmedText = fullText
            lastChunkEndSampleIndex = end
            if let t = tokens {
                lastTokens = t
            }

            self.callbackQueue.async {
                self.onPartialRawText?(fullText) // Update UI with latest confirmed
                if isFinal {
                    self.onFinalText?(fullText)
                }
            }
        } else {
            // Partial Update
            self.callbackQueue.async {
                self.onPartialRawText?(fullText)
            }
        }
    }
}

