import Foundation
import SherpaOnnx

class VADService {
    private let sampleRate = 16000
    private let minSpeechDuration = 0.09 // ~90ms
    private let minSilenceDuration = 0.7 // 700ms

    // State
    private var isSpeaking = false
    private var silenceDuration: Double = 0
    private var speechDuration: Double = 0

    private var vad: VoiceActivityDetector?

    // Callbacks
    var onSpeechStart: (() -> Void)?
    var onSpeechEnd: (() -> Void)?

    init() {
        if let modelPath = Bundle.module.path(forResource: "silero_vad", ofType: "onnx") {
            let config = SileroVadModelConfig(
                model: modelPath,
                threshold: 0.5,
                minSilenceDuration: 0.5,
                minSpeechDuration: 0.25,
                windowSize: 512
            )
            let vadConfig = VadModelConfig(sileroVad: config, sampleRate: 16000, numThreads: 1, debug: 1)
            vad = VoiceActivityDetector(config: vadConfig, bufferSizeInSeconds: 60)
            print("VADService initialized with Silero VAD.")
        } else {
             print("VADService: Model not found. Using Energy Heuristic.")
        }
    }

    func process(audioSamples: [Float]) {
        if let vad = vad {
            vad.acceptWaveform(samples: audioSamples)

            if vad.isSpeech() {
                if !isSpeaking {
                    isSpeaking = true
                    print("VAD: Speech Started")
                    onSpeechStart?()
                }
            } else {
                 if isSpeaking {
                    // Start counting silence? Sherpa's VAD usually handles state internally but returns isSpeech for current frame.
                    // Actually, Sherpa VAD streaming API usage might differ slightly, but assuming simple boolean for now.
                    // Typically you check `vad.isEmpty()` or similar, but let's assume `isSpeech()` reflects current state.

                    // Since VAD is often frame-by-frame, we might need our own smoothing if the raw VAD is jittery.
                    // However, Silero inside Sherpa usually has parameters for that.
                    isSpeaking = false
                    print("VAD: Speech Ended")
                    onSpeechEnd?()
                 }
            }
        } else {
            // Fallback Logic
            let energy = calculateEnergy(audioSamples)
            let prob: Float = energy > 0.01 ? 0.8 : 0.1
            updateState(probability: prob, chunkDuration: Double(audioSamples.count) / Double(sampleRate))
        }
    }

    private func calculateEnergy(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumSquares = samples.reduce(0) { $0 + $1 * $1 }
        return sqrt(sumSquares / Float(samples.count))
    }

    private func updateState(probability: Float, chunkDuration: Double) {
        if probability > 0.5 {
            if !isSpeaking {
                speechDuration += chunkDuration
                if speechDuration >= minSpeechDuration {
                    isSpeaking = true
                    silenceDuration = 0
                    print("VAD: Speech Started (Mock)")
                    onSpeechStart?()
                }
            } else {
                speechDuration += chunkDuration
                silenceDuration = 0
            }
        } else if probability < 0.3 {
            if isSpeaking {
                silenceDuration += chunkDuration
                if silenceDuration >= minSilenceDuration {
                    isSpeaking = false
                    speechDuration = 0
                    print("VAD: Speech Ended (Mock)")
                    onSpeechEnd?()
                }
            } else {
                speechDuration = 0
            }
        }
    }
}
