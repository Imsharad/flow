import Foundation
import SherpaOnnx

class Transcriber {
    private var recognizer: SherpaOnnxOfflineRecognizer?
    private let sampleRate: Int = 16000
    private var isMockMode = false

    init() {
        // Configure Moonshine Tiny model
        let bundle = Bundle.module
        let preprocessor = bundle.path(forResource: "moonshine-tiny-preprocess", ofType: "onnx") ?? ""
        let encoder = bundle.path(forResource: "moonshine-tiny-encoder", ofType: "onnx") ?? ""
        let uncachedDecoder = bundle.path(forResource: "moonshine-tiny-decoder", ofType: "onnx") ?? ""
        let cachedDecoder = bundle.path(forResource: "moonshine-tiny-cached-decoder", ofType: "onnx") ?? ""
        let tokens = bundle.path(forResource: "tokens", ofType: "txt") ?? ""

        if preprocessor.isEmpty || encoder.isEmpty || uncachedDecoder.isEmpty || cachedDecoder.isEmpty || tokens.isEmpty {
             print("Warning: Moonshine models not found. Entering Mock Mode.")
             isMockMode = true
             return
        }

        let config = SherpaOnnxOfflineRecognizerConfig(
            featConfig: SherpaOnnxFeatureConfig(sampleRate: sampleRate, featureDim: 80),
            modelConfig: SherpaOnnxOfflineModelConfig(
                moonshine: SherpaOnnxOfflineMoonshineModelConfig(
                    preprocessor: preprocessor,
                    encoder: encoder,
                    uncachedDecoder: uncachedDecoder,
                    cachedDecoder: cachedDecoder
                ),
                tokens: tokens
            )
        )

        self.recognizer = SherpaOnnxOfflineRecognizer(config: config)
    }

    func transcribe(buffer: [Float]) -> String {
        if isMockMode {
            return "Mock transcription: Hello world"
        }

        guard let recognizer = recognizer else { return "" }
        let stream = recognizer.createStream()
        stream.acceptWaveform(sampleRate: sampleRate, samples: buffer)
        recognizer.decode(stream)
        return stream.result.text
    }
}
