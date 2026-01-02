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
    private var capturedContext: String?
    
    // VAD & Chunking State
    private var lastProcessedSampleIndex: Int64 = 0
    private var uncommittedStartIndex: Int64 = 0
    private var silenceDuration: TimeInterval = 0
    private let silenceThreshold: TimeInterval = 0.7
    private let silenceRMSThreshold: Float = 0.005

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
        uncommittedStartIndex = sessionStartSampleIndex
        lastProcessedSampleIndex = sessionStartSampleIndex
        silenceDuration = 0

        accumulator.reset()
        capturedContext = nil

        // Capture context asynchronously
        Task { @MainActor in
            if let ctx = self.accessibilityManager.getActiveWindowContext() {
                self.capturedContext = "Writing in \(ctx.appName) (\(ctx.windowTitle))."
                print("🧠 DictationEngine: Context Captured: \(self.capturedContext ?? "")")
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
            
            // Force one final transcription of the pending buffer
            await self.finalizeSession()
            
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
            await self?.processVADAndTranscribe()
        }
    }
    
    private func processVADAndTranscribe() async {
        guard isRecording else { return }

        let currentTotal = ringBuffer.totalSamplesWritten
        let newSamplesCount = currentTotal - lastProcessedSampleIndex
        
        // 1. Analyze for Silence
        if newSamplesCount > 0 {
            let recentAudio = ringBuffer.snapshot(from: lastProcessedSampleIndex, to: currentTotal)
            let rms = sqrt(recentAudio.reduce(0) { $0 + $1 * $1 } / Float(recentAudio.count))

            if rms < silenceRMSThreshold {
                silenceDuration += windowLoopInterval
            } else {
                silenceDuration = 0
            }

            lastProcessedSampleIndex = currentTotal
        }
        
        // 2. Decide: Commit (Chunk) or Preview
        if silenceDuration > silenceThreshold {
            // COMMIT PHASE
            // We have a stable silence. Commit the speech before the silence.
            // We assume speech ended around (currentTotal - silenceDurationSamples)
            // But for simplicity, we commit everything up to now because silence won't transcribe to much anyway,
            // or we can trim.
            // Whisper handles silence at end well usually.

            let chunkEnd = currentTotal
            let chunkLen = chunkEnd - uncommittedStartIndex

            // Only commit if we have significant audio (> 0.5s worth)
            if chunkLen > Int64(0.5 * Double(audioSampleRate)) {
                 await performTranscription(start: uncommittedStartIndex, end: chunkEnd, isCommit: true)
                 uncommittedStartIndex = chunkEnd
            }

        } else {
            // PREVIEW PHASE
            // Transcribe from uncommitted start to now for live feedback
             await performTranscription(start: uncommittedStartIndex, end: currentTotal, isCommit: false)
        }
    }

    private func finalizeSession() async {
        let currentTotal = ringBuffer.totalSamplesWritten
        if currentTotal > uncommittedStartIndex {
            await performTranscription(start: uncommittedStartIndex, end: currentTotal, isCommit: true)
        }
    }

    private func performTranscription(start: Int64, end: Int64, isCommit: Bool) async {
        let segment = ringBuffer.snapshot(from: start, to: end)
        guard !segment.isEmpty else { return }
        
        guard let buffer = AudioBufferBridge.createBuffer(from: segment, sampleRate: Double(audioSampleRate)) else { return }
        
        // Context from accumulator
        // We use the full text of previous segments as prompt
        var contextText = await accumulator.getFullText()
        
        // If accumulator is empty, use captured context to prime the model
        if contextText.isEmpty, let initialContext = capturedContext {
            contextText = initialContext
        }
        
        // Truncate context to avoid token limit overflow (heuristic: 800 chars)
        if contextText.count > 800 {
            contextText = String(contextText.suffix(800))
        }
        
        // Transcribe
        guard let text = await transcriptionManager.transcribe(buffer: buffer, prompt: contextText) else { return }
        
        if isCommit {
            // Append to accumulator
            // Note: we don't have tokens back from TranscriptionManager easily yet, passing empty.
            await accumulator.append(text: text, tokens: [])

            let fullText = await accumulator.getFullText()
            self.callbackQueue.async {
                self.onPartialRawText?(fullText)
                // Implicitly "Final" for this chunk, but user session continues.
                // onFinalText might be reserved for Session End?
                // Usually dictation updates existing text.
                // If we want to replace text, we send the full accumulated text.
            }
        } else {
            // Preview
            let previewFullText = contextText + (contextText.isEmpty ? "" : " ") + text
             self.callbackQueue.async {
                self.onPartialRawText?(previewFullText)
            }
        }

        if isCommit && !isRecording {
             // If we are stopping, emit final
             let final = await accumulator.getFullText()
             self.callbackQueue.async {
                 self.onFinalText?(final)
             }
        }
    }
}

