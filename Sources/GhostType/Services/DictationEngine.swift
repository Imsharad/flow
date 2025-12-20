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
    
    // Chunking / VAD State
    private var committedSampleIndex: Int64 = 0
    private var silenceStartTime: Date?
    private let silenceThreshold: Float = 0.005 // RMS threshold
    private let minSilenceDuration: TimeInterval = 0.7 // Silence needed to trigger commit

    // Concurrency Control
    private var isProcessingWindow = false

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
        silenceStartTime = nil
        isProcessingWindow = false

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
            
            // Wait for any running window to finish (simple spin-wait or just risk it?
            // In MainActor context, we can't spin-wait easily.
            // We'll rely on isProcessingWindow check inside the task to avoid collision,
            // but for stop() we want to force it.

            // Force one final transcription of the complete buffer
            await self.processFinalCommit(force: true)
            
            // For now, we manually trigger speech end callback after final processing
            // In hybrid mode, implicit "final text" is just the last update.
            let fullText = await self.accumulator.getFullText()
            
            DispatchQueue.main.async { [weak self] in
                self?.onFinalText?(fullText)
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
        // Guard against overlapping tasks
        guard !isProcessingWindow else { return }
        isProcessingWindow = true

        Task(priority: .userInitiated) { [weak self] in
            defer { self?.isProcessingWindow = false }
            await self?.processVADAndTranscribe()
        }
    }
    
    private func processVADAndTranscribe() async {
        let currentEnd = ringBuffer.totalSamplesWritten

        // 1. Check VAD on recent audio (last 0.5s) to detect silence
        // We only check if we have enough uncommitted audio to justify checking
        if currentEnd - committedSampleIndex > Int64(0.5 * Double(audioSampleRate)) {
            let recentSamples = ringBuffer.snapshot(from: max(committedSampleIndex, currentEnd - Int64(0.5 * Double(audioSampleRate))), to: currentEnd)
            let rms = sqrt(recentSamples.reduce(0) { $0 + $1 * $1 } / Float(recentSamples.count))

            if rms < silenceThreshold {
                if silenceStartTime == nil {
                    silenceStartTime = Date()
                } else if Date().timeIntervalSince(silenceStartTime!) > minSilenceDuration {
                    // Silence persisted > 0.7s -> Commit Chunk
                    // Ensure chunk is long enough (>1s) to be meaningful
                    if (currentEnd - committedSampleIndex) > Int64(1.0 * Double(audioSampleRate)) {
                        await processFinalCommit(force: false)
                        silenceStartTime = nil // Reset silence tracker
                        return // Skip partial update
                    }
                }
            } else {
                silenceStartTime = nil // Speech active
            }
        }

        // 2. Partial Update (Streaming)
        // If not committing, show what we have so far
        await processPartial()
    }

    private func processFinalCommit(force: Bool) async {
        let end = ringBuffer.totalSamplesWritten
        let start = committedSampleIndex
        
        // If force is true, we take everything.
        // If not force, we might want to trim the silence tail, but for simplicity let's take it all.
        
        let chunkSamples = ringBuffer.snapshot(from: start, to: end)
        guard !chunkSamples.isEmpty else { return }
        
        guard let buffer = AudioBufferBridge.createBuffer(from: chunkSamples, sampleRate: Double(audioSampleRate)) else { return }
        
        // Context from accumulator
        let contextTokens = await accumulator.getContext()
        let contextText = await accumulator.getFullText() // For Cloud
        
        print("💾 DictationEngine: Committing chunk (\(String(format: "%.2f", Double(chunkSamples.count)/16000.0))s)...")

        do {
            let result = try await transcriptionManager.transcribeFinal(buffer: buffer, prompt: contextText, promptTokens: contextTokens)

            // Success
            await accumulator.append(text: result.text, tokens: result.tokens)
            committedSampleIndex = end // Advance pointer

            // Emit full text
            let fullText = await accumulator.getFullText()
            self.callbackQueue.async {
                self.onPartialRawText?(fullText)
            }

        } catch {
            print("❌ DictationEngine: Commit failed: \(error)")
        }
    }

    private func processPartial() async {
        let end = ringBuffer.totalSamplesWritten
        let start = committedSampleIndex
        
        let chunkSamples = ringBuffer.snapshot(from: start, to: end)
        guard !chunkSamples.isEmpty else { return }
        
        // Don't transcribe tiny fragments (<0.2s) as partials to save compute
        if chunkSamples.count < Int(0.2 * Double(audioSampleRate)) { return }
        
        guard let buffer = AudioBufferBridge.createBuffer(from: chunkSamples, sampleRate: Double(audioSampleRate)) else { return }
        
        // Context
        let contextTokens = await accumulator.getContext()
        let contextText = await accumulator.getFullText()

        if let result = await transcriptionManager.transcribe(buffer: buffer, prompt: contextText, promptTokens: contextTokens) {
             let fullText = contextText + " " + result.text
             self.callbackQueue.async {
                 self.onPartialRawText?(fullText)
             }
        }
    }
}
