import Foundation
import Accelerate

enum VADEvent {
    case speechStarted
    case speechEnded
}

class VAD {
    // Configuration
    var activationThreshold: Float = 0.015
    var deactivationThreshold: Float = 0.005
    var minSpeechDuration: TimeInterval = 0.1
    var minSilenceDuration: TimeInterval = 0.5

    // State
    private(set) var isSpeaking = false
    private var speechDuration: TimeInterval = 0
    private var silenceDuration: TimeInterval = 0

    // Internal counters
    private var consecutiveSpeechFrames = 0
    private var consecutiveSilenceFrames = 0

    func process(buffer: [Float], sampleRate: Double = 16000.0) -> VADEvent? {
        let frameDuration = Double(buffer.count) / sampleRate
        let rms = calculateRMS(buffer)

        // Hysteresis Logic
        if isSpeaking {
            if rms < deactivationThreshold {
                silenceDuration += frameDuration
                if silenceDuration >= minSilenceDuration {
                    isSpeaking = false
                    silenceDuration = 0
                    speechDuration = 0
                    return .speechEnded
                }
            } else {
                silenceDuration = 0 // Reset silence counter if energy spikes
                speechDuration += frameDuration
            }
        } else {
            if rms > activationThreshold {
                speechDuration += frameDuration
                if speechDuration >= minSpeechDuration {
                    isSpeaking = true
                    speechDuration = 0
                    silenceDuration = 0
                    return .speechStarted
                }
            } else {
                speechDuration = 0 // Reset speech counter if energy drops
            }
        }

        return nil
    }

    private func calculateRMS(_ buffer: [Float]) -> Float {
        guard !buffer.isEmpty else { return 0.0 }

        var rms: Float = 0.0
        vDSP_rmsqv(buffer, 1, &rms, vDSP_Length(buffer.count))

        return rms
    }

    func reset() {
        isSpeaking = false
        speechDuration = 0
        silenceDuration = 0
    }
}
