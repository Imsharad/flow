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
    
    // Chunked Streaming State
    private var lastCommittedSampleIndex: Int64 = 0
    private var committedText: String = ""
    private var textContext: String = ""

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
        lastCommittedSampleIndex = sessionStartSampleIndex
        committedText = ""

        // Capture Context
        if let context = accessibilityManager.getActiveWindowContext() {
            textContext = context
            print("🧠 DictationEngine: Captured Context: \(textContext)")
        } else {
            textContext = ""
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
        
        // 1. Define the "Pending" segment
        // We accumulate from the last committed point.
        let effectiveStart = lastCommittedSampleIndex
        let pendingSamples = end - effectiveStart
        
        // Safety cap: If pending audio is > 28s, we force a commit to avoid Whisper limit
        let maxPendingSamples = Int64(28 * audioSampleRate)
        var forceCommit = false
        if pendingSamples > maxPendingSamples {
            print("⚠️ DictationEngine: Pending audio > 28s. Forcing commit.")
            forceCommit = true
        }

        let segment = ringBuffer.snapshot(from: effectiveStart, to: end)
        guard !segment.isEmpty else { return }
        
        // 2. VAD Check (RMS)
        let rms = sqrt(segment.reduce(0) { $0 + $1 * $1 } / Float(segment.count))
        
        let sensitivity = UserDefaults.standard.double(forKey: "micSensitivity")
        let threshold = sensitivity > 0 ? sensitivity : 0.005

        // If entirely silent and not final/forced, skip
        if rms < threshold && !isFinal && !forceCommit {
            return
        }
        
        // 3. Speech End Detection
        // Check for silence at the tail (0.7s)
        let silenceDurationSamples = Int(0.7 * Double(audioSampleRate))
        var shouldCommit = isFinal || forceCommit

        // Only trigger commit if we have a decent chunk (>2s) + silence
        if !shouldCommit && segment.count > Int(2.0 * Double(audioSampleRate)) + silenceDurationSamples {
            let tail = segment.suffix(silenceDurationSamples)
            let tailRms = sqrt(tail.reduce(0) { $0 + $1 * $1 } / Float(tail.count))
            if tailRms < threshold {
                shouldCommit = true
            }
        }

        // 🌉 Bridge to AVAudioPCMBuffer
        guard let buffer = AudioBufferBridge.createBuffer(from: segment, sampleRate: Double(audioSampleRate)) else {
            print("❌ DictationEngine: Failed to create audio buffer")
            return
        }
        
        // 🦄 Unicorn Stack: Hybrid Transcription
        // Pass previous committed text + window context as prompt
        let combinedContext = textContext + " " + committedText
        let promptContext = String(combinedContext.suffix(500))
        
        guard let newText = await transcriptionManager.transcribe(buffer: buffer, prompt: promptContext) else {
            // Processing cancelled or failed
            return
        }
        
        // 4. Update State
        if shouldCommit {
            // Commit the text
            if !newText.isEmpty {
                 committedText += (committedText.isEmpty ? "" : " ") + newText
            }
            lastCommittedSampleIndex = end // Advance cursor

            // Emit committed result
            self.callbackQueue.async {
                self.onPartialRawText?(self.committedText)
                if isFinal {
                    self.onFinalText?(self.committedText)
                }
            }
        } else {
            // Live update (committed + partial)
            let fullText = (committedText.isEmpty ? "" : committedText + " ") + newText
            self.callbackQueue.async {
                self.onPartialRawText?(fullText)
            }
        }
    }
}

