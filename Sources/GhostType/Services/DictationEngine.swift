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
    
    // Dependencies
    private let accessibilityManager: AccessibilityManager

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
    private var committedText: String = ""
    private var committedTokens: [Int] = []
    private var lastCommittedSampleIndex: Int64 = 0
    private var isProcessingChunk = false

    init(
        callbackQueue: DispatchQueue = .main,
        accessibilityManager: AccessibilityManager = AccessibilityManager() // Default injection
    ) {
        self.callbackQueue = callbackQueue
        self.accessibilityManager = accessibilityManager
        // Initialize Manager (Shared instance logic should ideally be lifted to App)
        self.transcriptionManager = TranscriptionManager() 
        self.accumulator = TranscriptionAccumulator()
        self.ringBuffer = AudioRingBuffer(capacitySamples: 16000 * 180) 
    }
    
    // For testing injection
    init(
         transcriptionManager: TranscriptionManager,
         accumulator: TranscriptionAccumulator,
         ringBuffer: AudioRingBuffer,
         accessibilityManager: AccessibilityManager) {
        self.callbackQueue = .main
        self.transcriptionManager = transcriptionManager
        self.accumulator = accumulator
        self.ringBuffer = ringBuffer
        self.accessibilityManager = accessibilityManager
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
        
        // Reset Chunked Streaming State
        committedText = ""
        committedTokens = []
        lastCommittedSampleIndex = sessionStartSampleIndex
        isProcessingChunk = false

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
        
        // 🚀 Context Injection: Get active window context
        if let context = accessibilityManager.getActiveWindowContext() {
            print("🧠 DictationEngine: Injecting context: \"\(context)\"")

            Task(priority: .userInitiated) { [weak self] in
                guard let self = self else { return }
                // Encode the context string into tokens
                // We add a preamble like "Context: {App}: {Title}. "
                let preamble = "Context: \(context). "
                if let tokens = await self.transcriptionManager.tokenize(text: preamble) {
                    print("🧠 DictationEngine: Context tokenized (\(tokens.count) tokens). Seeding committedTokens.")
                    await MainActor.run {
                        self.committedTokens = tokens
                    }
                } else {
                     print("⚠️ DictationEngine: Context tokenization failed (model not ready?). Ignoring context.")
                }
            }
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
        guard !isProcessingChunk else { return } // Simple re-entrancy guard
        isProcessingChunk = true
        defer { isProcessingChunk = false }

        let end = ringBuffer.totalSamplesWritten
        
        // Chunking Logic: We process from lastCommittedSampleIndex
        let effectiveStart = lastCommittedSampleIndex
        let pendingDurationSamples = end - effectiveStart
        let pendingDurationSec = Double(pendingDurationSamples) / Double(audioSampleRate)

        // Don't process if too short (unless final)
        if !isFinal && pendingDurationSec < 0.2 {
             return
        }

        // Snapshot the pending buffer
        let segment = ringBuffer.snapshot(from: effectiveStart, to: end)
        
        guard !segment.isEmpty else { return }
        
        // RMS Energy Gate - Use UserDefaults setting
        let silenceThreshold = Float(UserDefaults.standard.double(forKey: "micSensitivity"))
        // Fallback if 0 (not set) or invalid
        let effectiveSilenceThreshold = (silenceThreshold > 0) ? silenceThreshold : 0.005

        let rms = sqrt(segment.reduce(0) { $0 + $1 * $1 } / Float(segment.count))
        
        // If overall energy is too low, we might skip processing, BUT we need to check chunks.
        // If we are strict, we might skip silent blocks entirely.

        // VAD / Chunking Decision
        let minSilenceDuration: Double = 0.7
        let maxChunkDuration: Double = 28.0 // Safety buffer before 30s limit

        var shouldCommit = false
        var commitEndTime = end

        if isFinal {
            shouldCommit = true
        } else if pendingDurationSec > maxChunkDuration {
            // Force commit if too long
            shouldCommit = true
            print("⚠️ DictationEngine: Forcing commit due to duration limit (>28s)")
        } else if pendingDurationSec > 2.0 {
            // Check for silence at the tail
            let tailSamples = Int(minSilenceDuration * Double(audioSampleRate))
            if segment.count > tailSamples {
                let tail = segment.suffix(tailSamples)
                let tailRMS = sqrt(tail.reduce(0) { $0 + $1 * $1 } / Float(tail.count))
                if tailRMS < effectiveSilenceThreshold {
                    shouldCommit = true
                }
            }
        }
        
        // 🌉 Bridge to AVAudioPCMBuffer
        guard let buffer = AudioBufferBridge.createBuffer(from: segment, sampleRate: Double(audioSampleRate)) else {
            print("❌ DictationEngine: Failed to create audio buffer")
            return
        }
        
        // 🦄 Unicorn Stack: Hybrid Transcription
        let processingStart = Date()
        
        // Pass accumulated tokens as prompt
        guard let result = await transcriptionManager.transcribe(buffer: buffer, promptTokens: committedTokens) else {
            // Processing cancelled or failed
            return
        }
        
        let (text, tokens) = result

        let processingDuration = Date().timeIntervalSince(processingStart)
        // print("🎙️ DictationEngine: Transcribed in \(String(format: "%.3f", processingDuration))s")
        
        if shouldCommit {
            // Append to committed
            committedText = (committedText + " " + text).trimmingCharacters(in: .whitespacesAndNewlines)

            // Update tokens context (Keep last 224)
            let combinedTokens = committedTokens + tokens
            if combinedTokens.count > 224 {
                committedTokens = Array(combinedTokens.suffix(224))
            } else {
                committedTokens = combinedTokens
            }

            // Advance cursor
            lastCommittedSampleIndex = end

            // Emit full text
            let fullText = committedText
            self.callbackQueue.async {
                self.onPartialRawText?(fullText)
                if isFinal {
                    self.onFinalText?(fullText)
                }
            }

             // Debug log
             // print("✅ DictationEngine: Committed Chunk: \"\(text)\" (Total: \(committedText.count) chars)")

        } else {
            // Provisional update
            let fullText = (committedText + " " + text).trimmingCharacters(in: .whitespacesAndNewlines)
            self.callbackQueue.async {
                self.onPartialRawText?(fullText)
            }
        }
    }
}
