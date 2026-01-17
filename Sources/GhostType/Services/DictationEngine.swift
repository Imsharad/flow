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
    private var textContext: String?

    // Chunking State
    private var committedText: String = ""
    private var committedSampleIndex: Int64 = 0
    private var lastSilenceDuration: TimeInterval = 0
    private var isProcessingChunk = false
    


    init(
        callbackQueue: DispatchQueue = .main,
        accessibilityManager: AccessibilityManager = AccessibilityManager()
    ) {
        self.callbackQueue = callbackQueue
        // Initialize Manager (Shared instance logic should ideally be lifted to App)
        self.transcriptionManager = TranscriptionManager() 
        self.accumulator = TranscriptionAccumulator()
        self.ringBuffer = AudioRingBuffer(capacitySamples: 16000 * 180) 
        self.accessibilityManager = accessibilityManager
    }
    
    // For testing injection
    init(
         transcriptionManager: TranscriptionManager,
         accumulator: TranscriptionAccumulator,
         ringBuffer: AudioRingBuffer,
         accessibilityManager: AccessibilityManager = AccessibilityManager()) {
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
        
        // Capture Context
        if let context = accessibilityManager.getActiveWindowContext() {
            self.textContext = "I am writing in \(context.appName) in a window titled \(context.windowTitle)."
            print("🧠 DictationEngine: Captured Context: \(self.textContext!)")
        } else {
            self.textContext = nil
        }

        // Reset state for new session
        ringBuffer.clear()
        sessionStartSampleIndex = ringBuffer.totalSamplesWritten // Mark session start AFTER clear
        
        // Reset Chunking State
        committedText = ""
        committedSampleIndex = sessionStartSampleIndex
        lastSilenceDuration = 0
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
        // Prevent overlapping tasks if one is taking too long
        guard !isProcessingChunk else { return }

        Task(priority: .userInitiated) { [weak self] in
            await self?.processOnePass(isFinal: false)
        }
    }
    
    private func processOnePass(isFinal: Bool = false) async {
        isProcessingChunk = true
        defer { isProcessingChunk = false }
        
        let end = ringBuffer.totalSamplesWritten
        
        // 1. Calculate Silence on recent window (0.5s)
        let vadWindowSamples = Int64(0.5 * Double(audioSampleRate))
        let vadStart = max(sessionStartSampleIndex, end - vadWindowSamples)
        let vadSegment = ringBuffer.snapshot(from: vadStart, to: end)
        let rms = calculateRMS(vadSegment)
        
        if rms < 0.005 {
            lastSilenceDuration += 0.5
        } else {
            lastSilenceDuration = 0
        }
        
        // 2. Determine if we should commit
        let uncommittedSamples = end - committedSampleIndex
        let uncommittedDuration = Double(uncommittedSamples) / Double(audioSampleRate)
        
        // Commit if:
        // - Silence > 0.7s AND we have at least 2s of audio
        // - OR isFinal (user stopped)
        // - OR uncommitted > 28s (force commit to avoid losing context/accuracy)
        let shouldCommit = (lastSilenceDuration > 0.7 && uncommittedDuration > 2.0) || isFinal || uncommittedDuration > 28.0
        
        // Construct Prompt: Window Context + Committed Text Tail
        let contextTail = String(committedText.suffix(500))
        let prompt = (textContext ?? "") + (contextTail.isEmpty ? "" : " ... " + contextTail)
        
        if shouldCommit {
             // --- COMMIT LOGIC ---
             let segment = ringBuffer.snapshot(from: committedSampleIndex, to: end)
             guard !segment.isEmpty else {
                 if isFinal { callbackQueue.async { self.onFinalText?(self.committedText) } }
                 return
             }

             guard let buffer = AudioBufferBridge.createBuffer(from: segment, sampleRate: Double(audioSampleRate)) else { return }

             if let text = await transcriptionManager.transcribe(buffer: buffer, prompt: String(prompt)) {
                 if !text.isEmpty {
                     committedText += (committedText.isEmpty ? "" : " ") + text
                     // Advance pointer
                     committedSampleIndex = end
                 }
             }

             // Emit
             let finalText = committedText
             callbackQueue.async {
                 self.onPartialRawText?(finalText)
                 if isFinal {
                     self.onFinalText?(finalText)
                 }
             }

        } else {
            // --- PARTIAL LOGIC ---
            let segment = ringBuffer.snapshot(from: committedSampleIndex, to: end)
            guard !segment.isEmpty else { return }

            // Skip inference if current segment is pure silence
            if calculateRMS(segment) < 0.005 { return }

            guard let buffer = AudioBufferBridge.createBuffer(from: segment, sampleRate: Double(audioSampleRate)) else { return }

            if let text = await transcriptionManager.transcribe(buffer: buffer, prompt: String(prompt)) {
                let fullText = committedText + (committedText.isEmpty ? "" : " ") + text
                callbackQueue.async {
                    self.onPartialRawText?(fullText)
                }
            }
        }
    }

    private func calculateRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        return sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
    }
}

