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
    private var lastChunkEndSampleIndex: Int64 = 0 // Track last committed chunk end
    


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
        lastChunkEndSampleIndex = sessionStartSampleIndex

        Task {
            await accumulator.reset()
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
        // Calculate where the current active segment starts (from last finalized chunk)
        // Ensure we don't exceed buffer capacity or max recording length logic if any
        let effectiveStart = max(sessionStartSampleIndex, lastChunkEndSampleIndex)

        // Limit processing window to 30s for Whisper
        // If current uncommitted audio > 30s, we might have issues, but VAD should have triggered commit.
        // If not, we clip start.
        let maxSamples = Int64(30 * audioSampleRate)
        let clippedStart = max(effectiveStart, end - maxSamples)
        
        let segment = ringBuffer.snapshot(from: clippedStart, to: end)
        
        guard !segment.isEmpty else { return }
        
        // RMS Energy Gate
        let rms = sqrt(segment.reduce(0) { $0 + $1 * $1 } / Float(segment.count))
        guard rms > 0.005 else { return }
        
        // Check for VAD Silence to commit chunk
        // Simple logic: if last 0.7s is silent, commit everything before silence
        let silenceThreshold: Float = 0.005
        let silenceDurationSamples = Int(0.7 * Double(audioSampleRate))

        var shouldCommit = isFinal
        var commitEndIndex = end

        if !isFinal && segment.count > silenceDurationSamples {
            let tail = segment.suffix(silenceDurationSamples)
            let tailRms = sqrt(tail.reduce(0) { $0 + $1 * $1 } / Float(tail.count))
            if tailRms < silenceThreshold {
                shouldCommit = true
                // Commit up to the start of the silence? Or include it?
                // Including it acts as padding.
                commitEndIndex = end
            }
        }
        
        // 🌉 Bridge to AVAudioPCMBuffer
        guard let buffer = AudioBufferBridge.createBuffer(from: segment, sampleRate: Double(audioSampleRate)) else {
            print("❌ DictationEngine: Failed to create audio buffer")
            return
        }
        
        // 🦄 Unicorn Stack: Hybrid Transcription
        let contextTokens = await accumulator.getContext()
        
        // Context Injection from Active Window
        // We only fetch this once per session ideally, or periodically?
        // For now, let's fetch it if we are at the start or just use it.
        // `transcribe` takes `prompt`. We can inject it there.
        var prompt = ""
        if sessionStartSampleIndex == lastChunkEndSampleIndex {
            // First chunk of the session?
             if let context = accessibilityManager.getActiveWindowContext() {
                prompt = "Dictating in \(context.appName) - \(context.windowTitle). "
                // print("Context: \(prompt)")
            }
        }
        
        guard let result = await transcriptionManager.transcribe(buffer: buffer, prompt: prompt.isEmpty ? nil : prompt, promptTokens: contextTokens) else {
            return
        }
        let (text, tokens) = result
        
        if shouldCommit {
            // Commit to accumulator
            await accumulator.append(text: text, tokens: tokens ?? [])
            lastChunkEndSampleIndex = commitEndIndex

            // Get full text
            let fullText = await accumulator.getFullText()

            self.callbackQueue.async {
                // If finalized, we might want to send distinct signal or just update text
                self.onPartialRawText?(fullText)
                if isFinal {
                    self.onFinalText?(fullText)
                }
            }
        } else {
            // Just a partial preview
            // Combine with accumulated text
            let previousText = await accumulator.getFullText()
            let combinedText = previousText.isEmpty ? text : previousText + " " + text

            self.callbackQueue.async {
                self.onPartialRawText?(combinedText)
            }
        }
    }
}

