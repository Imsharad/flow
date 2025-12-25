import Foundation
import AVFoundation
import Accelerate

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
    private var sessionStartSampleIndex: Int64 = 0 // Track session start
    private var capturedContext: AppContext?

    // Chunked Streaming State
    private var committedSampleIndex: Int64 = 0
    private var silenceDuration: TimeInterval = 0.0
    private let silenceThreshold: TimeInterval = 0.7 // 700ms silence to commit
    private let maxUncommittedDuration: TimeInterval = 28.0 // Force commit if > 28s to avoid losing context
    


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
        
        // Capture context
        capturedContext = ContextManager.shared.getActiveContext()
        print("🌍 DictationEngine: Context - App: \(capturedContext?.appName ?? "N/A"), Window: \(capturedContext?.windowTitle ?? "N/A")")

        // Reset state for new session
        ringBuffer.clear()
        sessionStartSampleIndex = ringBuffer.totalSamplesWritten // Mark session start AFTER clear
        committedSampleIndex = sessionStartSampleIndex
        silenceDuration = 0.0
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
        let currentHead = ringBuffer.totalSamplesWritten

        // We only process from committed index up to now
        let effectiveStart = max(sessionStartSampleIndex, committedSampleIndex)
        let samplesToProcess = currentHead - effectiveStart

        // If nothing new, skip
        if samplesToProcess <= 0 { return }
        
        // Safety: If buffer wrapped around (very long session > 3m), we might lose data.
        // But ring buffer is 180s.

        let segment = ringBuffer.snapshot(from: effectiveStart, to: currentHead)
        
        guard !segment.isEmpty else { return }
        
        // RMS Energy Gate
        let rms = sqrt(segment.reduce(0) { $0 + $1 * $1 } / Float(segment.count))
        
        // Update Silence Duration
        if rms < 0.005 {
            silenceDuration += windowLoopInterval
        } else {
            silenceDuration = 0.0
        }

        // Determine if we should commit (VAD-based Chunking)
        // 1. Is Final?
        // 2. Silence > 0.7s AND we have enough audio (> 1s) to be a phrase?
        // 3. Uncommitted audio > 28s (Whisper limit is 30s)

        let uncommittedSeconds = Double(samplesToProcess) / Double(audioSampleRate)
        let shouldCommit = isFinal || (silenceDuration > silenceThreshold && uncommittedSeconds > 1.0) || uncommittedSeconds > maxUncommittedDuration

        if rms < 0.005 && !shouldCommit {
            // Just silence, no commit yet. Maybe skip inference to save battery if we haven't spoken much?
            // But we need to keep transcribing to see if user started speaking again or if previous words are finalizing.
            // Actually, if it's pure silence at the END of the buffer, we might want to just wait.
             return
        }
        
        // 🌉 Bridge to AVAudioPCMBuffer
        guard let buffer = AudioBufferBridge.createBuffer(from: segment, sampleRate: Double(audioSampleRate)) else {
            print("❌ DictationEngine: Failed to create audio buffer")
            return
        }
        
        // Get context from accumulator
        let contextTokens = await accumulator.getContext()
        let contextText = await accumulator.getFullText() // For Cloud fallback

        // 🌍 Inject Active Window Context if we are at the beginning (empty accumulator)
        // This helps bias the model correctly.
        var prompt = contextText
        if prompt.isEmpty, let ctx = capturedContext {
            // "GhostType - DictationEngine.swift"
            let title = ctx.windowTitle ?? ""
            let app = ctx.appName
            if !title.isEmpty {
                 prompt = "Context: \(app) - \(title)."
            }
        }

        // Transcribe
        let processingStart = Date()
        
        guard let (text, tokens) = await transcriptionManager.transcribe(buffer: buffer, prompt: prompt, promptTokens: contextTokens) else {
            return
        }
        
        let processingDuration = Date().timeIntervalSince(processingStart)

        // Construct full text for UI
        let committedText = await accumulator.getFullText()
        let fullText = committedText.isEmpty ? text : "\(committedText) \(text)"
        
        // Emit result
        self.callbackQueue.async {
            self.onPartialRawText?(fullText)
            if isFinal {
                self.onFinalText?(fullText)
            }
        }

        // Commit logic
        if shouldCommit {
            print("✅ DictationEngine: Committing chunk (\(String(format: "%.2f", uncommittedSeconds))s). Silence: \(silenceDuration)s")
            if !text.isEmpty {
                await accumulator.append(text: text, tokens: tokens ?? [])
            }
            committedSampleIndex = currentHead
            silenceDuration = 0.0
        }
    }
}
