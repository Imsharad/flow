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
    private let vad: VoiceActivityDetector // VAD instance
    
    // Orchestration
    let transcriptionManager: TranscriptionManager
    private let accumulator: TranscriptionAccumulator
    // private let consensusService: ConsensusServiceProtocol // Temporarily unused in Hybrid Mode v1
    
    // State
    private var isRecording = false
    private var slidingWindowTimer: Timer?
    private let windowLoopInterval: TimeInterval = 0.5 // 500ms Tick
    private var sessionStartSampleIndex: Int64 = 0 // Track session start for isolation
    private var currentSegmentStartIndex: Int64 = 0 // Track where current VAD segment started
    private var capturedContext: ActiveContext? // Context at start of session

    init(
        callbackQueue: DispatchQueue = .main
    ) {
        self.callbackQueue = callbackQueue
        // Initialize Manager (Shared instance logic should ideally be lifted to App)
        self.transcriptionManager = TranscriptionManager() 
        self.accumulator = TranscriptionAccumulator()
        self.ringBuffer = AudioRingBuffer(capacitySamples: 16000 * 180)
        self.vad = VoiceActivityDetector(sampleRate: 16000)

        setupVAD()
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
        self.vad = VoiceActivityDetector(sampleRate: 16000)

        setupVAD()
    }

    private func setupVAD() {
        vad.onSpeechStart = { [weak self] in
            guard let self = self else { return }
            // Capture session start index at this moment?
            // Actually, we use ringBuffer current position as approximation of start
            // But VAD detects start slightly in past.
            // For now, we rely on the main update loop to just pick up from currentSegmentStartIndex.
            // But if we want to reset currentSegmentStartIndex on speech start?
            // Usually we assume contiguous stream.
            // If we are strictly chunking:
            // Silence -> Speech Start.
            // Maybe we should update currentSegmentStartIndex here?
            // But we might cut off the start of the word.
            // Better to let currentSegmentStartIndex stay where it was (end of last segment).
            // So we capture silence + speech.
            // Or we can advance it if silence was too long?

            // For simplicity in Phase 1: Just logging
             print("🎤 DictationEngine: VAD Speech Started")
        }

        vad.onSpeechEnd = { [weak self] in
             print("🎤 DictationEngine: VAD Speech Ended")
             // Trigger chunk finalization
             Task { @MainActor [weak self] in
                 await self?.processOnePass(isFinal: true)
             }
        }
    }

    nonisolated func pushAudio(samples: [Float]) {
        vad.process(samples: samples)
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
        vad.reset()
        Task { @MainActor in
            await accumulator.reset()
            // Capture Context
            self.capturedContext = await ContextManager.shared.getCurrentContext()
            if let ctx = self.capturedContext {
                print("🧠 DictationEngine: Captured Context: \(ctx.promptDescription)")
            }
        }

        sessionStartSampleIndex = ringBuffer.totalSamplesWritten // Mark session start AFTER clear
        currentSegmentStartIndex = sessionStartSampleIndex
        
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

        // Determine start of this segment.
        // If finalizing, we take everything since last segment start.
        // If partial, we also take everything since last segment start (but don't advance start index).
        // BUT we must cap at max 30s because Whisper/Model limit.
        // If current segment > 30s, we might need to force split?
        // For now, assuming VAD splits < 30s. If not, we just take last 30s for partial.

        let segmentStart = currentSegmentStartIndex
        let maxSamples = Int64(30 * audioSampleRate)

        // If segment is too long, we might be in trouble for context coherence if we just take last 30s.
        // But for partial feedback, last 30s relative to end is fine.
        // For finalization, we want the whole chunk if possible, or we rely on the fact that VAD triggered.

        let effectiveStart = max(segmentStart, end - maxSamples)
        
        let segment = ringBuffer.snapshot(from: effectiveStart, to: end)
        
        guard !segment.isEmpty else { return }
        
        // RMS Energy Gate to prevent silence hallucinations
        // VAD already handles this logically, but double check doesn't hurt for very quiet segments
        // However, if VAD triggered "End", we definitely want to process it even if low energy tail.
        // So we might skip this check if isFinal? Or keep it low.
        let rms = sqrt(segment.reduce(0) { $0 + $1 * $1 } / Float(segment.count))
        
        guard rms > 0.005 else {
             if isFinal {
                 // If finalizing silence, just advance index and return
                 currentSegmentStartIndex = end
             }
             return
        }
        
        // 🌉 Bridge to AVAudioPCMBuffer
        guard let buffer = AudioBufferBridge.createBuffer(from: segment, sampleRate: Double(audioSampleRate)) else {
            print("❌ DictationEngine: Failed to create audio buffer")
            return
        }
        
        // Get context prompt from accumulator (only previous segments)
        let accumulatedText = await accumulator.getFullText()

        // Construct Prompt:
        // 1. Static Context (App/Window)
        // 2. Accumulated Text (Previous segments)

        var promptString = ""
        if let ctx = capturedContext {
            promptString += ctx.promptDescription + " "
        }

        // Add last 500 chars of accumulated text to context
        let previousText = accumulatedText.suffix(500)
        promptString += previousText

        // 🦄 Unicorn Stack: Hybrid Transcription
        let processingStart = Date()
        
        guard let text = await transcriptionManager.transcribe(buffer: buffer, prompt: promptString) else {
            // Processing cancelled or failed
            return
        }
        
        let processingDuration = Date().timeIntervalSince(processingStart)
        // print("🎙️ DictationEngine: Transcribed \"\(text.prefix(20))...\" in \(String(format: "%.3f", processingDuration))s")
        
        if isFinal {
            await accumulator.append(text: text, tokens: []) // We don't have tokens from TranscriptionManager yet easily, passing empty for now.
            // Update start index for next segment
            currentSegmentStartIndex = end

            let fullText = await accumulator.getFullText()

            self.callbackQueue.async {
                self.onPartialRawText?(fullText) // Clear partial, show full
                // self.onFinalText?(fullText) // Only called on Session Stop usually?
            }
        } else {
             let fullText = accumulatedText.isEmpty ? text : accumulatedText + " " + text
             self.callbackQueue.async {
                 self.onPartialRawText?(fullText)
             }
        }
    }
}

