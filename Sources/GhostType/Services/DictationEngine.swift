import Foundation

/// Local dictation engine (single-process).
///
/// This mirrors the PRD pipeline boundaries so we can later swap the implementation
/// to an XPC service without changing the UI layer.
final class DictationEngine {
    // Callbacks (invoked on `callbackQueue`).
    var onSpeechStart: (() -> Void)?
    var onSpeechEnd: (() -> Void)?
    var onPartialRawText: ((String) -> Void)?
    var onFinalText: ((String) -> Void)?

    private let callbackQueue: DispatchQueue

    private let audioSampleRate: Int = 16000
    private let ringBuffer: AudioRingBuffer

    // Services
    private let audioManager = AudioInputManager.shared // Changed from AudioSessionManager

    private let whisperKitService: WhisperKitService
    private let mlxService: MLXService // 🦄 Unicorn Stack
    private let accumulator: TranscriptionAccumulator
    private let consensusService: ConsensusServiceProtocol
    
    // State
    private var isRecording = false
    private var slidingWindowTimer: Timer?
    private let windowLoopInterval: TimeInterval = 0.5 // 500ms Tick
    private var sessionStartSampleIndex: Int64 = 0 // Track session start for isolation
    
    // 🦄 Unicorn Stack Configuration
    private let useMLX: Bool = true // Set to false to fallback to WhisperKit


    init(
        callbackQueue: DispatchQueue = .main
    ) {
        self.callbackQueue = callbackQueue
        self.whisperKitService = WhisperKitService()
        self.mlxService = MLXService(whisperKit: self.whisperKitService)
        self.accumulator = TranscriptionAccumulator()
        self.consensusService = ConsensusService()
        self.ringBuffer = AudioRingBuffer(capacitySamples: 16000 * 180) 
    }
    
    // For testing injection
    init( 
         whisperKitService: WhisperKitService, 
         mlxService: MLXService,
         accumulator: TranscriptionAccumulator,
         consensusService: ConsensusServiceProtocol,
         ringBuffer: AudioRingBuffer) {
        self.callbackQueue = .main
        self.whisperKitService = whisperKitService
        self.mlxService = mlxService
        self.accumulator = accumulator
        self.consensusService = consensusService
        self.ringBuffer = ringBuffer
    }

    func pushAudio(samples: [Float]) {
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
        completion?()
    }

    // MARK: - Internals



    private func handleSpeechStart() {
        guard !isRecording else { return }
        
        // Reset state for new session
        ringBuffer.clear()
        sessionStartSampleIndex = ringBuffer.totalSamplesWritten // Mark session start AFTER clear
        
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
        
        // Final drain and flush
        Task { [weak self] in
            guard let self = self else { return }
            
            // 1. Force one final transcription of the complete buffer to ensure we capture everything
            await self.processOnePass()
            
            // 2. Now flush the consensus service
            let finalText = await self.consensusService.flush()
            
            self.callbackQueue.async {
                self.onFinalText?(finalText)
            }
        }
        
        DispatchQueue.main.async { [weak self] in
            self?.onSpeechEnd?()
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
            await self?.processOnePass()
        }
    }
    
    private func processOnePass() async {
        let end = ringBuffer.totalSamplesWritten
        // Look back 30 seconds, but never before session start
        let maxSamples = Int64(30 * audioSampleRate)
        let effectiveStart = max(sessionStartSampleIndex, end - maxSamples)
        
        let segment = ringBuffer.snapshot(from: effectiveStart, to: end)
        
        guard !segment.isEmpty else { return }
        
        // RMS Energy Gate to prevent silence hallucinations
        let rms = sqrt(segment.reduce(0) { $0 + $1 * $1 } / Float(segment.count))
        
        // Debug logging (uncomment for troubleshooting)
        // let prefix = segment.prefix(5).map { String(format: "%.4f", $0) }.joined(separator: ", ")
        // print("🔍 Debug: SegSamples=\(segment.count), Head=\(end), RMS=\(String(format: "%.4f", rms)), First5=[\(prefix)]")
        
        guard rms > 0.005 else {
            // print("🔇 DictationEngine: Silence detected (RMS: \(rms)), skipping inference.")
            return
        }
        
        do {
            // 🦄 Unicorn Stack: Audio Processing Latency Log
            let processingStart = Date()
            
            // Transcribe
            let (_, _, segments): (String, [Int], [Segment])
            
            if self.useMLX {
                 // 🦄 Unicorn Stack: MLX Path
                 segments = try await self.mlxService.transcribe(audio: segment, promptTokens: nil).segments
            } else {
                 // Classic WhisperKit Path
                 segments = try await self.whisperKitService.transcribe(audio: segment, promptTokens: nil).segments
            }
            
            let processingDuration = Date().timeIntervalSince(processingStart)
            print("🎙️ DictationEngine: Audio prep+inference took \(String(format: "%.3f", processingDuration))s")
            
            // Consensus
            let (committed, hypothesis) = await self.consensusService.onNewHypothesis(segments)
            
            let fullText = committed + hypothesis
            
            self.callbackQueue.async {
                self.onPartialRawText?(fullText)
            }
            
        } catch {
            print("❌ DictationEngine: Loop error: \(error)")
        }
    }
}
