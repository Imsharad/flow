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
    private let ringBuffer = AudioRingBuffer(capacitySamples: 16000 * 30)

    private let vadService: VADServiceProtocol
    private let transcriber: TranscriberProtocol
    private let corrector: TextCorrectorProtocol
    
    // New MLX Service
    private let mlxService: MLXService

    private var speechStartSampleIndex: Int64?
    private var partialTimer: DispatchSourceTimer?
    private var isPartialTranscriptionInFlight = false

    init(
        callbackQueue: DispatchQueue = .main,
        vadService: VADServiceProtocol,
        transcriber: TranscriberProtocol,
        corrector: TextCorrectorProtocol
    ) {
        self.callbackQueue = callbackQueue
        self.vadService = vadService
        self.transcriber = transcriber
        self.corrector = corrector
        self.mlxService = MLXService()
        
        // Wire up Ring Buffer
        Task {
            await self.mlxService.setRingBuffer(self.ringBuffer)
            // Attempt to load model
             try? await self.mlxService.loadModel()
             
             // Setup partial result callback
             await self.mlxService.setPartialResultCallback { [weak self] text in
                 self?.callbackQueue.async {
                     self?.onPartialRawText?(text)
                 }
             }
        }

        self.vadService.onSpeechStart = { [weak self] in
            self?.handleSpeechStart()
        }
        self.vadService.onSpeechEnd = { [weak self] in
            self?.handleSpeechEnd()
        }
    }

    func pushAudio(samples: [Float]) {
        ringBuffer.write(samples)
        vadService.process(buffer: samples)
    }

    func manualTriggerStart() {
        vadService.manualTriggerStart()
    }

    func manualTriggerEnd() {
        vadService.manualTriggerEnd()
    }
    
    /// Warm up models to reduce first-transcription latency
    func warmUp(completion: (() -> Void)? = nil) {
        corrector.warmUp(completion: completion)
    }

    // MARK: - Internals

    private func handleSpeechStart() {
        let preRollSamples = Int64(Double(audioSampleRate) * 1.5)
        let current = ringBuffer.totalSamplesWritten
        speechStartSampleIndex = max(Int64(0), current - preRollSamples)

        callbackQueue.async { [weak self] in
            self?.onSpeechStart?()
        }
        
        // Start MLX Streaming Session
        Task {
            await mlxService.startSession()
        }

        // OLD: startPartialTranscriptionTimer()
    }

    private func handleSpeechEnd() {
        let endToEndStartTime = Date()
        stopPartialTranscriptionTimer()
        
        // Stop MLX Streaming Session
        Task {
            await mlxService.stopSession()
        }

        callbackQueue.async { [weak self] in
            self?.onSpeechEnd?()
        }

        let end = ringBuffer.totalSamplesWritten
        let minFinalizeSamples = Int64(Double(audioSampleRate) * 1.5)
        var start = speechStartSampleIndex ?? max(Int64(0), end - minFinalizeSamples)

        if end - start < minFinalizeSamples {
            start = max(Int64(0), end - minFinalizeSamples)
        }

        let segment = ringBuffer.snapshot(from: start, to: end)
        let segmentDuration = Double(segment.count) / Double(audioSampleRate)
        print("⏱️  DictationEngine: Processing \(String(format: "%.2f", segmentDuration))s audio segment (\(segment.count) samples)")
        speechStartSampleIndex = nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let transcriptionStart = Date()
            
            // For Alpha 2: We rely on the last partial result from MLX as the "Final" text, 
            // OR we can trigger one last fetch. 
            // Since Transcriber is the "Old" way, let's keep it for a moment as a fallback 
            // if MLX isn't producing final text yet.
            // BUT, if we want to test MLX, we should try to get result from MLX.
            // However, MLXService.transcribe is async actor call.
            
            // Let's use the old transcriber for the "Final" block for safety in this step,
            // while the streaming updates come from MLX.
            // TODO: Switch final pass to MLX as well.
            
            let rawText = self.transcriber.transcribe(buffer: segment)
            let transcriptionLatency = Date().timeIntervalSince(transcriptionStart) * 1000
            print("⏱️  DictationEngine: Transcription took \(String(format: "%.0f", transcriptionLatency))ms")

            self.callbackQueue.async {
                self.onPartialRawText?(rawText)
            }

            // DISABLED: T5 grammar correction (was adding 5-7 seconds latency)
            // TODO: Remove T5 models and corrector code entirely in future cleanup
            // let correctionStart = Date()
            // let corrected = self.corrector.correct(text: rawText, context: nil)
            // let correctionLatency = Date().timeIntervalSince(correctionStart) * 1000
            // print("⏱️  DictationEngine: Correction took \(String(format: "%.0f", correctionLatency))ms")

            let totalLatency = Date().timeIntervalSince(endToEndStartTime) * 1000
            print("⏱️  🎯 TOTAL END-TO-END LATENCY: \(String(format: "%.0f", totalLatency))ms")

            self.callbackQueue.async {
                self.onFinalText?(rawText)  // Using raw text directly (no T5 correction)
            }
        }
    }

    private func startPartialTranscriptionTimer() {
        // Disabled for MLX migration
    }

    private func stopPartialTranscriptionTimer() {
        partialTimer?.cancel()
        partialTimer = nil
        isPartialTranscriptionInFlight = false
    }

    private func emitPartialTranscription() {
       // Disabled for MLX migration
    }
}
