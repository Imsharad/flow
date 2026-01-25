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
    private var lastCommittedSampleIndex: Int64 = 0
    


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

        // Reset accumulator
        Task { await accumulator.reset() }

        // Inject Context
        Task {
            if let contextString = AccessibilityManager().getActiveWindowContext() {
                print("Context: \(contextString)")
                // Note: We currently just log it. Future improvement: seed accumulator tokens.
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

        // Chunking Logic: Process from lastCommitted to end
        let start = lastCommittedSampleIndex
        let available = end - start

        guard available > 0 else { return }

        // Limit to 30s max for Whisper (internal window)
        // If we exceed 30s, we process the first 30s of pending audio
        let maxSamples = Int64(30 * audioSampleRate)
        let chunkSamples = min(available, maxSamples)

        let effectiveStart = start
        let effectiveEnd = start + chunkSamples
        
        let segment = ringBuffer.snapshot(from: effectiveStart, to: effectiveEnd)
        
        guard !segment.isEmpty else { return }
        
        // RMS Energy Gate
        let rms = sqrt(segment.reduce(0) { $0 + $1 * $1 } / Float(segment.count))
        
        // Determine Commit Strategy
        let duration = Double(segment.count) / Double(audioSampleRate)

        // Check silence at tail (last 0.5s)
        var isSilentTail = false
        if duration > 0.5 {
             let tailSamples = Int(0.5 * Double(audioSampleRate))
             let tailSegment = segment.suffix(tailSamples)
             let tailRms = sqrt(tailSegment.reduce(0) { $0 + $1 * $1 } / Float(tailSegment.count))
             isSilentTail = tailRms < 0.005
        }

        var shouldCommit = false
        if isFinal {
            shouldCommit = true
        } else if duration > 25.0 {
            shouldCommit = true
            print("⚠️ DictationEngine: Forced commit due to length (>25s)")
        } else if isSilentTail && duration > 1.0 {
            shouldCommit = true
        }
        
        // Silence Skip Logic
        if rms < 0.005 {
            if shouldCommit {
                // Just advance pointer without transcription
                lastCommittedSampleIndex = effectiveEnd
                return
            } else {
                return
            }
        }

        // Prepare Context
        let contextTokens = await accumulator.getContext()
        let contextText = await accumulator.getFullText()

        // 🌉 Bridge to AVAudioPCMBuffer
        guard let buffer = AudioBufferBridge.createBuffer(from: segment, sampleRate: Double(audioSampleRate)) else {
            print("❌ DictationEngine: Failed to create audio buffer")
            return
        }
        
        // 🦄 Unicorn Stack: Hybrid Transcription
        // Pass context to manager
        guard let text = await transcriptionManager.transcribe(buffer: buffer, prompt: contextText, promptTokens: contextTokens) else {
            return
        }
        
        if shouldCommit {
            // Commit to accumulator
            // Encode tokens if possible (for Local)
            if let tokens = await transcriptionManager.encode(text: text) {
                await accumulator.append(text: text, tokens: tokens)
            } else {
                await accumulator.append(text: text, tokens: [])
            }

            lastCommittedSampleIndex = effectiveEnd

            let fullText = await accumulator.getFullText()

            // Emit Final Result for this chunk
            self.callbackQueue.async {
                self.onPartialRawText?(fullText)
                if isFinal {
                    self.onFinalText?(fullText)
                }
            }
        } else {
            // Partial
            let fullText = contextText + (contextText.isEmpty ? "" : " ") + text

            self.callbackQueue.async {
                self.onPartialRawText?(fullText)
            }
        }
    }
}

