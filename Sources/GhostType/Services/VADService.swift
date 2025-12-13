import Foundation
import SherpaOnnx

class VADService {
    private var vad: SherpaOnnxVoiceActivityDetector?
    private let sampleRate: Int = 16000
    private let config: SherpaOnnxVadModelConfig

    // VAD parameters
    private let threshold: Float = 0.5
    private let minSpeechDuration: Float = 0.09 // 90ms
    private let minSilenceDuration: Float = 0.7 // 700ms

    var onSpeechStart: (() -> Void)?
    var onSpeechEnd: (() -> Void)?

    private var isSpeaking = false
    private var isMockMode = false

    init() {
        let bundle = Bundle.module
        let modelPath = bundle.path(forResource: "silero_vad", ofType: "onnx")

        // Configure Silero VAD
        var sileroConfig = SherpaOnnxSileroVadModelConfig(
            model: modelPath ?? "", // If empty, sherpa-onnx might fail or we handle it
            threshold: threshold,
            minSpeechDuration: minSpeechDuration,
            minSilenceDuration: minSilenceDuration
        )

        self.config = SherpaOnnxVadModelConfig(sileroVad: sileroConfig, sampleRate: sampleRate)

        if modelPath != nil {
             self.vad = SherpaOnnxVoiceActivityDetector(config: config)
        } else {
            print("Warning: VAD model not found. Entering Mock Mode.")
            isMockMode = true
        }
    }

    func process(buffer: [Float]) {
        if isMockMode {
            // Simulate random speech events for testing if needed, or rely on manual triggers
            return
        }

        guard let vad = vad else { return }
        vad.acceptWaveform(buffer)

        if vad.isSpeechDetected() {
            if !isSpeaking {
                isSpeaking = true
                onSpeechStart?()
            }
        } else {
            if isSpeaking {
                isSpeaking = false
                onSpeechEnd?()
            }
        }
    }

    // Helper for manual triggering in debug/mock mode
    func manualTriggerStart() {
        onSpeechStart?()
    }

    func manualTriggerEnd() {
        onSpeechEnd?()
    }
}
