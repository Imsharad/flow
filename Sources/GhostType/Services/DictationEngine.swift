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

    private let vadService = VADService()
    private let transcriber = Transcriber()
    private let corrector = TextCorrector()

    private var speechStartSampleIndex: Int64?
    private var partialTimer: DispatchSourceTimer?
    private var isPartialTranscriptionInFlight = false

    init(callbackQueue: DispatchQueue = .main) {
        self.callbackQueue = callbackQueue

        vadService.onSpeechStart = { [weak self] in
            self?.handleSpeechStart()
        }
        vadService.onSpeechEnd = { [weak self] in
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

    // MARK: - Internals

    private func handleSpeechStart() {
        let preRollSamples = Int64(Double(audioSampleRate) * 1.5)
        let current = ringBuffer.totalSamplesWritten
        speechStartSampleIndex = max(Int64(0), current - preRollSamples)

        callbackQueue.async { [weak self] in
            self?.onSpeechStart?()
        }

        startPartialTranscriptionTimer()
    }

    private func handleSpeechEnd() {
        stopPartialTranscriptionTimer()

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
        speechStartSampleIndex = nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let rawText = self.transcriber.transcribe(buffer: segment)
            self.callbackQueue.async {
                self.onPartialRawText?(rawText)
            }

            let corrected = self.corrector.correct(text: rawText, context: nil)
            self.callbackQueue.async {
                self.onFinalText?(corrected)
            }
        }
    }

    private func startPartialTranscriptionTimer() {
        stopPartialTranscriptionTimer()

        // Fire on main to avoid data races with callback state; do heavy work on background.
        let timer = DispatchSource.makeTimerSource(queue: callbackQueue)
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
        guard let start = speechStartSampleIndex else { return }

        isPartialTranscriptionInFlight = true
        let end = ringBuffer.totalSamplesWritten
        let segment = ringBuffer.snapshot(from: start, to: end)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let rawText = self.transcriber.transcribe(buffer: segment)
            self.callbackQueue.async {
                self.onPartialRawText?(rawText)
                self.isPartialTranscriptionInFlight = false
            }
        }
    }
}
