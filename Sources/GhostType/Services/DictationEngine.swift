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
    private let accessibilityManager = AccessibilityManager()
    // private let consensusService: ConsensusServiceProtocol // Temporarily unused in Hybrid Mode v1
    
    // State
    private var capturedContext: (appName: String, windowTitle: String, bundleID: String)?
    private var isRecording = false
    private var slidingWindowTimer: Timer?
    private let windowLoopInterval: TimeInterval = 0.5 // 500ms Tick
    private var sessionStartSampleIndex: Int64 = 0 // Track session start for isolation
    
    // VAD & Chunking State
    private var lastSpeechTime: Date = Date()
    private var currentSegmentStartSample: Int64 = 0
    private var isSpeechActive = false
    private let silenceThresholdSeconds: TimeInterval = 1.2


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
        
        // Reset VAD state
        currentSegmentStartSample = sessionStartSampleIndex
        lastSpeechTime = Date()
        isSpeechActive = false
        Task { await accumulator.reset() }

        // Capture Context
        // We do this on MainActor (Accessibility APIs often prefer main thread/UI thread)
        // Since DictationEngine is @MainActor, this is safe.
        self.capturedContext = accessibilityManager.getActiveWindowContext()
        print("🪟 DictationEngine: Context Captured - App: \(capturedContext?.appName ?? "N/A"), Title: \(capturedContext?.windowTitle ?? "N/A")")

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
        
        // We now process from `currentSegmentStartSample` instead of a fixed 30s window sliding from `end`.
        // However, we still want to limit the maximum chunk size to avoid memory issues or hallucinations.
        // Let's enforce a soft cap of 30s for a segment.

        let effectiveStart = max(currentSegmentStartSample, sessionStartSampleIndex)
        var segmentLength = end - effectiveStart

        // Safety cap: if segment > 60s, force a chunk? For now, let's rely on VAD.

        // Snapshot current pending segment
        let segment = ringBuffer.snapshot(from: effectiveStart, to: end)
        
        guard !segment.isEmpty else { return }
        
        // VAD Logic
        // Calculate RMS of the *recent* portion (last 500ms) to detect current speech activity
        let recentSamples = Int(0.5 * Double(audioSampleRate))
        let recentSegment = segment.suffix(recentSamples)
        let rms = sqrt(recentSegment.reduce(0) { $0 + $1 * $1 } / Float(max(1, recentSegment.count)))

        let isSilence = rms < 0.005
        
        if !isSilence {
            lastSpeechTime = Date()
            isSpeechActive = true
        } else if !isSpeechActive && !isFinal {
            // Optimization: If we are silent and not in an active speech segment, skip transcription.
            return
        }
        
        // Determine if we should finalize this chunk
        // 1. Explicitly requested (isFinal)
        // 2. Silence duration exceeded AND we have some speech content
        let timeSinceLastSpeech = Date().timeIntervalSince(lastSpeechTime)
        let shouldFinalize = isFinal || (isSpeechActive && timeSinceLastSpeech > silenceThresholdSeconds)

        // Prepare context
        var previousContext = await accumulator.getFullText()

        // Inject App Context if accumulator is empty (Start of dictation)
        // This helps condition Whisper style (e.g. Code vs Prose)
        if previousContext.isEmpty, let ctx = capturedContext {
            // Heuristic: If we are in a code editor, maybe prompt with "Coding."?
            // For now, simpler: "Dictating in [App]."
            // Note: Too much text might hallucinate.
            // Let's try: "I am dictating in [App]."
            // previousContext = "I am dictating in \(ctx.appName)."

            // Actually, let's keep it safe. Just empty for now unless we are sure.
            // But the task is "Active Window Context".
            // Let's print it for now to verify we have it, and maybe add a subtle prompt.
            // "Context: [App Name]"
            // Whisper prompt is best as natural text.
             previousContext = "Context: \(ctx.appName). \(ctx.windowTitle)."
        }

        // 🌉 Bridge to AVAudioPCMBuffer
        guard let buffer = AudioBufferBridge.createBuffer(from: segment, sampleRate: Double(audioSampleRate)) else {
            return
        }
        
        // Transcribe
        // Pass accumulated context as prompt
        // Use prompt only if we have context
        let prompt = previousContext.isEmpty ? nil : previousContext
        
        guard let text = await transcriptionManager.transcribe(buffer: buffer, prompt: prompt) else {
            return
        }
        
        // Logic for output
        if shouldFinalize {
            print("🧱 DictationEngine: Finalizing chunk. Text: \(text.prefix(20))...")

            // 1. Commit this text to accumulator
            // Note: We don't have tokens here because TM returns string.
            // Ideally we'd get tokens. For now, we trust text accumulation.
            await accumulator.append(text: text, tokens: [])

            // 2. Emit combined text (Previous + Current Chunk)
            let fullText = await accumulator.getFullText()

            self.callbackQueue.async {
                self.onPartialRawText?(fullText)
            }

            // 3. Advance the window
            // The next segment starts where this one ended
            currentSegmentStartSample = end
            isSpeechActive = false

            if isFinal {
                self.onFinalText?(fullText)
            }

        } else {
            // Partial Update
            // Combine confirmed history + current unstable text
            let fullText = (previousContext + " " + text).trimmingCharacters(in: .whitespacesAndNewlines)

            self.callbackQueue.async {
                self.onPartialRawText?(fullText)
            }
        }
    }
}

