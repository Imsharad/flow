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
    private var lastCommittedSampleIndex: Int64 = 0
    private var silenceDuration: TimeInterval = 0

    // Config
    public var micSensitivity: Float {
        let val = UserDefaults.standard.float(forKey: "micSensitivity")
        return val > 0 ? val : 0.005
    }


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

    // Phase 4: Active Window Context
    func injectContext(_ context: String) {
        // We can prepend this to the accumulator or handle it as a system prompt.
        // For simplicity, we just append it as a "header" segment to the accumulator
        // but without tokens (so it doesn't mess up token context too much if not tokenized).
        // Or better, we just rely on TranscriptionManager to handle "prompt" if we pass it explicitly.
        // But our design passes `context` from accumulator.
        // So we should seed the accumulator.
        Task {
            // Encode context to tokens if possible?
            // For now, just add text. The Local service might ignore text-only context if it wants tokens.
            // But we can update TranscriptionManager to handle this.
            // Actually, we'll just set it as the initial text context.
            await accumulator.reset() // Clear previous session
            await accumulator.append(text: context, tokens: [])
        }
    }

    // MARK: - Internals

    private func handleSpeechStart() {
        guard !isRecording else { return }
        
        // Reset state for new session
        ringBuffer.clear()
        sessionStartSampleIndex = ringBuffer.totalSamplesWritten // Mark session start AFTER clear
        lastCommittedSampleIndex = sessionStartSampleIndex
        silenceDuration = 0

        // Capture & Inject Context
        if let context = AccessibilityManager.shared.getActiveWindowContext() {
             print("🧠 DictationEngine: Injected Context: \"\(context)\"")
             injectContext(context)
        } else {
             Task {
                 await accumulator.reset()
             }
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
            
            // Force one final transcription of the remaining buffer as a commit
            await self.processOnePass(forceCommit: true)
            
            // For now, we manually trigger speech end callback after final processing
            // In hybrid mode, implicit "final text" is just the last update.
            
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
            await self?.processOnePass(forceCommit: false)
        }
    }
    
    private func processOnePass(forceCommit: Bool = false) async {
        let end = ringBuffer.totalSamplesWritten

        // We only care about what hasn't been committed yet
        // But for context, we might look back, but here we treat `lastCommittedSampleIndex` as the start of the current "thought".
        let effectiveStart = lastCommittedSampleIndex
        
        let segment = ringBuffer.snapshot(from: effectiveStart, to: end)
        
        guard !segment.isEmpty else { return }
        
        // RMS Calculation
        let rms = sqrt(segment.reduce(0) { $0 + $1 * $1 } / Float(segment.count))
        
        // VAD Logic
        if rms < micSensitivity {
            silenceDuration += windowLoopInterval
        } else {
            silenceDuration = 0
        }

        let segmentDuration = Double(segment.count) / Double(audioSampleRate)

        // Decision: Should we commit this chunk?
        // 1. Force Commit (Stop called)
        // 2. Natural Pause (Silence > 0.7s AND Segment > 1.0s to avoid chopping too aggressively)
        let shouldCommit = forceCommit || (silenceDuration > 0.7 && segmentDuration > 1.0)

        // If it's pure silence and we haven't said anything new, don't bother transcribing
        if !shouldCommit && rms < micSensitivity && segmentDuration < 30.0 {
             // Just wait, unless buffer is getting too full (30s)
             return
        }
        
        // 🌉 Bridge to AVAudioPCMBuffer
        guard let buffer = AudioBufferBridge.createBuffer(from: segment, sampleRate: Double(audioSampleRate)) else {
            print("❌ DictationEngine: Failed to create audio buffer")
            return
        }
        
        // Prepare Context
        let currentContextText = await accumulator.getFullText()
        let currentContextTokens = await accumulator.getContext()
        let context = TranscriptionContext(text: currentContextText, tokens: currentContextTokens)

        // 🦄 Unicorn Stack: Hybrid Transcription
        let processingStart = Date()
        
        // If forceCommit or shouldCommit, we treat this as a "Final" for this chunk
        // Note: We might want to pass `isFinal` hint to the transcriber if supported, but currently we just transcribe.

        guard let result = await transcriptionManager.transcribe(buffer: buffer, context: context) else {
            return
        }
        
        let processingDuration = Date().timeIntervalSince(processingStart)
        // print("🎙️ DictationEngine: Transcribed chunk in \(String(format: "%.3f", processingDuration))s")
        
        if shouldCommit {
            // Commit to accumulator
            await accumulator.append(text: result.text, tokens: result.tokens)
            lastCommittedSampleIndex = end // Advance the commit pointer
            silenceDuration = 0 // Reset silence counter after commit

            let fullText = await accumulator.getFullText()

            self.callbackQueue.async {
                self.onPartialRawText?(fullText) // Update UI with full text
            }
            print("✅ DictationEngine: Committed Chunk: \"\(result.text)\"")

        } else {
            // Intermediate update
            // We do NOT append to accumulator yet.
            // We just show (Committed + Current Partial)

            let fullDisplay = currentContextText + " " + result.text

            self.callbackQueue.async {
                self.onPartialRawText?(fullDisplay)
            }
        }
    }
}
