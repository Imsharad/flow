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
    
    // VAD & Chunking State
    private var currentSegmentStart: Int64 = 0
    private var consecutiveSilenceDuration: TimeInterval = 0
    private var segmentHasSpeech: Bool = false
    private let silenceThresholdSeconds: TimeInterval = 0.7

    // Context
    private var capturedContext: String?


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
        
        // Reset Chunking State
        accumulator.reset()
        currentSegmentStart = sessionStartSampleIndex
        consecutiveSilenceDuration = 0
        segmentHasSpeech = false

        // Capture Context
        // We create a temporary AccessibilityManager here as it's stateless for context capture
        // Ideally this should be injected or held as a service property if it grows complex.
        let ax = AccessibilityManager()
        if let context = ax.getActiveWindowContext() {
            let app = context.appName ?? "Unknown App"
            let title = context.windowTitle ?? "Untitled"
            self.capturedContext = "Context: Writing in \(app) - \(title). "
            print("🔍 DictationEngine: Captured Context: \(self.capturedContext!)")
        } else {
            self.capturedContext = nil
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
        
        // 1. Analyze tail (last window interval) for VAD
        // We look at the most recent audio added since last check (approx windowLoopInterval)
        // But to be safe, we check the last 0.5s
        let tailDuration = windowLoopInterval
        let tailSamplesCount = Int64(tailDuration * Double(audioSampleRate))
        let tailStart = max(sessionStartSampleIndex, end - tailSamplesCount)
        let tailSegment = ringBuffer.snapshot(from: tailStart, to: end)
        
        // Simple RMS VAD
        let isTailSilence = isSilence(tailSegment)
        
        if isTailSilence {
            consecutiveSilenceDuration += tailDuration
        } else {
            consecutiveSilenceDuration = 0
            segmentHasSpeech = true
        }
        
        // 2. Determine Action
        // We commit if:
        // A) We detected a natural pause > threshold AND we have collected some speech
        // B) We are forced to stop (isFinal)
        let shouldCommit = (consecutiveSilenceDuration > silenceThresholdSeconds && segmentHasSpeech) || isFinal
        
        if shouldCommit {
            // Define Speech Segment (exclude trailing silence)
            let silenceSamples = Int64(consecutiveSilenceDuration * Double(audioSampleRate))
            // Ensure we don't cut back before start
            var speechEnd = end - silenceSamples
            if isFinal { speechEnd = end } // On stop, take everything
            if speechEnd < currentSegmentStart { speechEnd = currentSegmentStart } // Safety clamp

            // Transcribe FINAL
            if speechEnd > currentSegmentStart {
                await transcribeSegment(start: currentSegmentStart, end: speechEnd, isFinal: true)
            }

            // Advance Start
            currentSegmentStart = speechEnd
            // If we just committed, the "speech" part is consumed.
            // The remaining buffer (silence) is now the start of the next segment (potentially).
            // But since it's silence, we reset the flag.
            segmentHasSpeech = false
            // Note: We do NOT reset consecutiveSilenceDuration here because we are technically still in silence.
            // But we already advanced currentSegmentStart past the silence?
            // Wait, if we set currentSegmentStart = speechEnd (which is BEFORE silence),
            // then the silence is still ahead of us?
            // Actually, we want to SKIP the silence.
            // So currentSegmentStart should be 'end' (skipping the silence we just detected).
            if !isFinal {
                currentSegmentStart = end
                // We consumed the silence as "spacer".
            }

        } else {
            // Streaming Partial
            if segmentHasSpeech {
                // Transcribe from Start to End (including current silence if any, as it might be a pause)
                // Limit to max 30s to avoid model confusion
                let maxSamples = Int64(30 * audioSampleRate)
                let effectiveStart = max(currentSegmentStart, end - maxSamples)

                await transcribeSegment(start: effectiveStart, end: end, isFinal: false)
            } else {
                // We are just skipping silence
                // Advance start to keep up with head
                currentSegmentStart = end
            }
        }
    }

    private func transcribeSegment(start: Int64, end: Int64, isFinal: Bool) async {
         let segment = ringBuffer.snapshot(from: start, to: end)
         guard !segment.isEmpty else { return }

         // RMS Guard for very short segments (e.g. noise bursts)
         if isSilence(segment) { return }

         // 🌉 Bridge to AVAudioPCMBuffer
         guard let buffer = AudioBufferBridge.createBuffer(from: segment, sampleRate: Double(audioSampleRate)) else {
             print("❌ DictationEngine: Failed to create audio buffer")
             return
         }

         // Context from Accumulator
         // For Cloud: We pass full text prompt
         // For Local: We pass tokens
         let contextText = await accumulator.getFullText()
         let contextTokens = await accumulator.getContext()

         // Static Context (Window Info)
         let staticContext = self.capturedContext

         // Perform Transcription
         let result = await transcriptionManager.transcribe(buffer: buffer, prompt: contextText, promptTokens: contextTokens, staticContext: staticContext)

         if let (text, tokens) = result {
             if isFinal {
                 // Append to accumulator
                 await accumulator.append(text: text, tokens: tokens ?? [])

                 // UI Update: Full Text
                 let fullText = await accumulator.getFullText()

                 self.callbackQueue.async {
                     self.onFinalText?(fullText)
                     self.onPartialRawText?(fullText) // Sync partial view too
                 }
                 print("✅ DictationEngine: Committed chunk: \"\(text)\"")
             } else {
                 // UI Update: Accumulated + Partial
                 let fullText = await accumulator.getFullText()
                 let combined = fullText.isEmpty ? text : "\(fullText) \(text)"

                 self.callbackQueue.async {
                     self.onPartialRawText?(combined)
                 }
             }
         }
    }

    private func isSilence(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return true }
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
        return rms < 0.005
    }
}

