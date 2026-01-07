import Foundation
import Accelerate

enum VADState {
    case silence
    case speech
}

enum VADEvent {
    case none
    case speechStart
    case speechEnd
}

class VAD {
    // Configuration
    var activationThreshold: Float = 0.015 // -36dB approx
    var deactivationThreshold: Float = 0.01 // -40dB approx
    var minSpeechDuration: TimeInterval = 0.1 // 100ms
    var minSilenceDuration: TimeInterval = 0.7 // 700ms (Hangover)

    // State
    private(set) var state: VADState = .silence
    private var silenceDuration: TimeInterval = 0
    private var speechDuration: TimeInterval = 0

    // Debug
    var debug = false

    func reset() {
        state = .silence
        silenceDuration = 0
        speechDuration = 0
    }

    func process(buffer: [Float], sampleRate: Double) -> VADEvent {
        let frameDuration = Double(buffer.count) / sampleRate

        // Calculate RMS
        var rms: Float = 0.0
        vDSP_rmsqv(buffer, 1, &rms, vDSP_Length(buffer.count))

        if debug && rms > 0.001 {
             print("VAD RMS: \(String(format: "%.4f", rms)) | State: \(state)")
        }

        switch state {
        case .silence:
            if rms > activationThreshold {
                speechDuration += frameDuration
                if speechDuration >= minSpeechDuration {
                    state = .speech
                    silenceDuration = 0
                    return .speechStart
                }
            } else {
                speechDuration = 0
            }

        case .speech:
            speechDuration += frameDuration

            if rms < deactivationThreshold {
                silenceDuration += frameDuration
                if silenceDuration >= minSilenceDuration {
                    state = .silence
                    speechDuration = 0
                    return .speechEnd
                }
            } else {
                silenceDuration = 0
            }
        }

        return .none
    }
}
