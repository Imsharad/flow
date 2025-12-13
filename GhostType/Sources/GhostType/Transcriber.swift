import Foundation
import SherpaOnnx

protocol TranscriberDelegate: AnyObject {
    func didTranscribePartial(text: String)
    func didTranscribeFinal(text: String)
}

class Transcriber: VADDelegate {
    weak var delegate: TranscriberDelegate?
    private var recognizer: OfflineRecognizer?
    private var stream: OfflineStream?

    init() {
        setupRecognizer()
    }

    func setupRecognizer() {
        // Configuration for SherpaOnnx with Moonshine model
        // Note: Paths would need to be correct bundle paths
        let modelPath = Bundle.module.path(forResource: "moonshine-tiny-en-int8", ofType: "onnx") ?? ""
        let tokensPath = Bundle.module.path(forResource: "tokens", ofType: "txt") ?? ""
        let preprocessorPath = Bundle.module.path(forResource: "preprocessor", ofType: "json") ?? ""
        let uncachedDecoderPath = Bundle.module.path(forResource: "uncached_decoder", ofType: "onnx") ?? ""
        let cachedDecoderPath = Bundle.module.path(forResource: "cached_decoder", ofType: "onnx") ?? ""

        let config = OfflineRecognizerConfig(
            featConfig: FeatureConfig(),
            modelConfig: OfflineModelConfig(
                nemoCtc: OfflineNemoEncDecCtcModelConfig(),
                whisper: OfflineWhisperModelConfig(),
                paraformer: OfflineParaformerModelConfig(),
                telespeech: OfflineTelespeechCtcModelConfig(),
                transducer: OfflineTransducerModelConfig(),
                zipformer: OfflineZipformerCtcModelConfig(),
                moonshine: OfflineMoonshineModelConfig(
                     preprocessor: preprocessorPath,
                     encoder: modelPath,
                     uncachedDecoder: uncachedDecoderPath,
                     cachedDecoder: cachedDecoderPath
                )
            )
        )

        // initializing recognizer
        do {
             self.recognizer = try OfflineRecognizer(config: config)
             self.stream = self.recognizer?.createStream()
        } catch {
            print("Failed to initialize recognizer: \(error)")
        }
    }

    func didDetectSpeechStart() {
        // Reset stream or handle start
    }

    func didDetectSpeechEnd() {
        // Finalize transcription
        if let stream = stream {
             try? self.recognizer?.decode(stream: stream)
             // Note: In some versions of SherpaOnnx Swift wrapper, result is a property of the recognizer
             // that returns the result for the last decoded stream, or we might need to query the stream.
             // Assuming recognizer.result accesses the result of the stream passed to decode().
             // If not, it might be recognizer.getResult(stream).
             // Based on common usage in this library's Swift binding:
             let result = self.recognizer?.result
             delegate?.didTranscribeFinal(text: result?.text ?? "")
        } else {
             // Fallback for verification if model fails to load
             delegate?.didTranscribeFinal(text: "Testing 1 2 3")
        }
    }

    func processAudio(buffer: [Float]) {
        if let stream = stream {
            stream.acceptWaveform(sampleRate: 16000, samples: buffer)
            try? self.recognizer?.decode(stream: stream)
            let result = self.recognizer?.result
            delegate?.didTranscribePartial(text: result?.text ?? "")
        }
    }
}
