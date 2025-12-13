import Foundation
import Accelerate

class VADService {
    private let sampleRate: Int = 16000

    // PRD-aligned timing parameters (we use an energy-based placeholder for now).
    private let minSpeechDurationSeconds: Float = 0.09 // 90ms
    private let minSilenceDurationSeconds: Float = 0.7 // 700ms

    var onSpeechStart: (() -> Void)?
    var onSpeechEnd: (() -> Void)?

    private var isSpeaking = false

    // Simple energy VAD state (placeholder until CoreML Silero is wired).
    private var speechRunSamples: Int = 0
    private var silenceRunSamples: Int = 0
    private let energyThreshold: Float = 0.01 // tune later

    init() {
        // TODO(PRD): Replace with Silero VAD v5 CoreML model in the XPC service.
    }

    func process(buffer: [Float]) {
        guard !buffer.isEmpty else { return }

        // Compute RMS energy.
        var rms: Float = 0
        vDSP_rmsqv(buffer, 1, &rms, vDSP_Length(buffer.count))
        let isSpeechFrame = rms >= energyThreshold

        if isSpeechFrame {
            speechRunSamples += buffer.count
            silenceRunSamples = 0
        } else {
            silenceRunSamples += buffer.count
            speechRunSamples = 0
        }

        let minSpeechSamples = Int(Float(sampleRate) * minSpeechDurationSeconds)
        let minSilenceSamples = Int(Float(sampleRate) * minSilenceDurationSeconds)

        if !isSpeaking {
            if speechRunSamples >= minSpeechSamples {
                isSpeaking = true
                onSpeechStart?()
            }
        } else {
            if silenceRunSamples >= minSilenceSamples {
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
