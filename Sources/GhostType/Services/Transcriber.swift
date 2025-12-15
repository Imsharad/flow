import Foundation
import SherpaOnnx

class Transcriber {
    private var recognizer: OfflineRecognizer?

    var onTranscriptionUpdate: ((String) -> Void)?
    var onTranscriptionFinal: ((String) -> Void)?

    private var accumulatedSamples: [Float] = []
    private var isRunning = false
    private let queue = DispatchQueue(label: "com.ghosttype.transcriber")
    private var lastTranscriptionTime: Date = .distantPast

    init() {
        // Attempt to load models from Bundle
        if let encoderPath = Bundle.module.path(forResource: "moonshine-tiny-encoder.int8", ofType: "onnx"),
           let uncachedDecoderPath = Bundle.module.path(forResource: "moonshine-tiny-decoder.int8", ofType: "onnx"),
           let cachedDecoderPath = Bundle.module.path(forResource: "moonshine-tiny-decoder.int8", ofType: "onnx"),
           let preprocessorPath = Bundle.module.path(forResource: "moonshine-tiny-preprocessor", ofType: "onnx"),
           let tokensPath = Bundle.module.path(forResource: "tokens", ofType: "txt") {

            let featConfig = OfflineFeatureExtractorConfig(
                sampleRate: 16000,
                featureDim: 80
            )

            var modelConfig = OfflineMoonshineModelConfig(
                preprocessor: preprocessorPath,
                encoder: encoderPath,
                uncachedDecoder: uncachedDecoderPath,
                cachedDecoder: cachedDecoderPath
            )

            let config = OfflineRecognizerConfig(
                featConfig: featConfig,
                modelConfig: OfflineModelConfig(moonshine: modelConfig, tokens: tokensPath, numThreads: 1, debug: 1)
            )

            recognizer = OfflineRecognizer(config: config)
            print("Transcriber initialized with Moonshine model.")
        } else {
            print("Transcriber: Model files not found. Running in Mock Mode.")
        }
    }

    func start() {
        queue.async {
            self.isRunning = true
            self.accumulatedSamples.removeAll()
        }
    }

    func stop() {
        queue.async {
            self.isRunning = false
            let samples = self.accumulatedSamples
            self.accumulatedSamples.removeAll()

            // Finalize
            let text = self.transcribe(samples: samples)
            DispatchQueue.main.async {
                self.onTranscriptionFinal?(text)
            }
        }
    }

    func processAudio(samples: [Float]) {
        queue.async {
            guard self.isRunning else { return }
            self.accumulatedSamples.append(contentsOf: samples)

            // Throttle: Only partial transcribe every 500ms
            let now = Date()
            if now.timeIntervalSince(self.lastTranscriptionTime) > 0.5 {
                self.lastTranscriptionTime = now
                let currentSnapshot = self.accumulatedSamples

                Task {
                    let text = self.transcribe(samples: currentSnapshot)
                    if !text.isEmpty {
                        await MainActor.run {
                            self.onTranscriptionUpdate?(text)
                        }
                    }
                }
            }
        }
    }

    private func transcribe(samples: [Float]) -> String {
        // Create a local copy to be safe if this was called from outside the queue,
        // but since we control calls, we are mostly fine.
        // Note: Task {} block in processAudio captures 'self', so 'transcribe' runs on that background thread.
        // It reads 'recognizer' which is read-only after init effectively (thread-safety of Sherpa recognizer needs confirmation,
        // but usually decoding is stateless per stream or we create a new stream).

        if let recognizer = recognizer {
            let stream = recognizer.createStream()
            stream.acceptWaveform(sampleRate: 16000, samples: samples)
            recognizer.decode(stream: stream)
            return stream.result.text
        }

        // Mock Mode Fallback
        if samples.count > 16000 * 2 {
            return "Testing 1 2 3 (Mock)"
        }
        return "Testing... (Mock)"
    }
}
