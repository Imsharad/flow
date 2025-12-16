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
    
    // New WhisperKit Service
    private let whisperKitService: WhisperKitService

    private var speechStartSampleIndex: Int64?
    private var partialTimer: DispatchSourceTimer?
    private var isPartialTranscriptionInFlight = false

    private var isManualRecording = false

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
        self.whisperKitService = WhisperKitService()
        
        self.vadService.onSpeechStart = { [weak self] in
            // Always handle speech start (detection)
            self?.handleSpeechStart()
        }
        self.vadService.onSpeechEnd = { [weak self] in
            // Only handle speech end if we are NOT in manual recording mode
            // (i.e. if we are relying on VAD to stop)
            guard let self = self, !self.isManualRecording else { return }
            self.handleSpeechEnd()
        }
    }

    func pushAudio(samples: [Float]) {
        ringBuffer.write(samples)
        vadService.process(buffer: samples)
    }

    func manualTriggerStart() {
        isManualRecording = true
        vadService.manualTriggerStart()
    }

    func manualTriggerEnd() {
        // Debounce: Keep isManualRecording true for a moment to ignore trailing VAD events
        // that might fire immediately after release
        let oldState = isManualRecording
        
        // Trigger finalization explicitly now
        handleSpeechEnd()
        
        // Reset state after a short delay to bridge VAD silence detection
        // if user stopped talking exactly when releasing key
        if oldState {
            callbackQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.isManualRecording = false
            }
        } else {
             isManualRecording = false
        }
        
        // Force wrap up the session
        vadService.manualTriggerEnd()
    }
    
    /// Warm up models to reduce first-transcription latency
    func warmUp(completion: (() -> Void)? = nil) {
        corrector.warmUp(completion: completion)
    }

    // MARK: - Internals

    // Track where the last session ended to prevent overlapping pre-roll
    private var lastSpeechEndIndex: Int64 = 0

    // MARK: - Internals

    private func handleSpeechStart() {
        guard speechStartSampleIndex == nil else { return } // Prevent restarting if already started
        
        let preRollSamples = Int64(Double(audioSampleRate) * 0.5) // Reduced pre-roll to 0.5s to minimize bleed risk
        let current = ringBuffer.totalSamplesWritten
        
        // Calculate start, but CLAMP it to not include audio from the previous session
        var start = max(Int64(0), current - preRollSamples)
        if start < lastSpeechEndIndex {
            print("⚠️ DictationEngine: Clamping start index to avoid previous session overlap")
            start = lastSpeechEndIndex
        }
        
        speechStartSampleIndex = start

        callbackQueue.async { [weak self] in
            self?.onSpeechStart?()
        }
        
        // Start polling for transcription
        startPartialTranscriptionTimer()
    }

    private func handleSpeechEnd() {
        // Prevent double handling: if no start index, we already processed this segment
        guard let startIdx = speechStartSampleIndex else { 
            print("⚠️ DictationEngine: handleSpeechEnd ignored (no active speech segment)")
            return 
        }
        
        let endToEndStartTime = Date()
        stopPartialTranscriptionTimer()
        
        // Final transcription pass handled below
        
        callbackQueue.async { [weak self] in
            self?.onSpeechEnd?()
        }

        let end = ringBuffer.totalSamplesWritten
        let minFinalizeSamples = Int64(Double(audioSampleRate) * 0.5) // Reduced min duration
        var start = startIdx // Use local copy confirmed not nil

        if end - start < minFinalizeSamples {
            // Ensure minimum duration? Actually, if it's too short (trailing silence), maybe ignore?
            // "books" hallucination comes from 1.5s of silence/noise.
            // If manual trigger was very short, user might have just tapped.
            // But if VAD triggered this, and it's tiny, we should perhaps drop it.
            // However, let's just stick to the ringbuffer logic.
             start = max(lastSpeechEndIndex, end - minFinalizeSamples)
        }
        
        // Mark where this session ended
        lastSpeechEndIndex = end
        
        // Reset state IMMEDIATELY to prevent re-entry
        speechStartSampleIndex = nil

        let segment = ringBuffer.snapshot(from: start, to: end)
        let segmentDuration = Double(segment.count) / Double(audioSampleRate)
        print("⏱️  DictationEngine: Processing \(String(format: "%.2f", segmentDuration))s audio segment (\(segment.count) samples)")
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let transcriptionStart = Date()
            
            // Generate final transcription using WhisperKit
            Task {
                do {
                    let text = try await self.whisperKitService.transcribe(audio: segment)
                    
                    let transcriptionLatency = Date().timeIntervalSince(transcriptionStart) * 1000
                    print("⏱️  DictationEngine: Transcription took \(String(format: "%.0f", transcriptionLatency))ms")
                    
                    let totalLatency = Date().timeIntervalSince(endToEndStartTime) * 1000
                    print("⏱️  🎯 TOTAL END-TO-END LATENCY: \(String(format: "%.0f", totalLatency))ms")

                    self.callbackQueue.async {
                        self.onFinalText?(text)
                    }
                } catch {
                     print("❌ DictationEngine: Final transcription failed: \(error)")
                }
            }
        }
    }

    private func startPartialTranscriptionTimer() {
        partialTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            self?.emitPartialTranscription()
        }
        timer.resume()
        partialTimer = timer
    }

    private func stopPartialTranscriptionTimer() {
        partialTimer?.cancel()
        partialTimer = nil
        isPartialTranscriptionInFlight = false
    }

    private func emitPartialTranscription() {
        guard !isPartialTranscriptionInFlight else { return }
        isPartialTranscriptionInFlight = true
        
        // Read from speechStart to now
        guard let start = speechStartSampleIndex else { 
            isPartialTranscriptionInFlight = false
            return 
        }
        let end = ringBuffer.totalSamplesWritten
        let samples = ringBuffer.snapshot(from: start, to: end)
        
        Task {
            do {
                let text = try await whisperKitService.transcribe(audio: samples)
                self.callbackQueue.async {
                    self.onPartialRawText?(text)
                }
            } catch {
                print("❌ DictationEngine: Transcription failed: \(error)")
            }
            self.isPartialTranscriptionInFlight = false
        }
    }
}
