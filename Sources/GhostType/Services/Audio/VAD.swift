import Foundation
import Accelerate

/// A simple state-machine VAD based on RMS energy.
class VAD {
    enum State {
        case silence
        case speech
    }

    // Configuration
    private let sampleRate: Double
    private let activationThreshold: Float // RMS > this to trigger speech
    private let deactivationThreshold: Float // RMS < this to trigger silence
    private let minSpeechDuration: TimeInterval // Minimum speech duration to be valid
    private let minSilenceDuration: TimeInterval // Silence required to end a segment

    // State
    private var state: State = .silence
    private var speechStartTime: TimeInterval?
    private var silenceStartTime: TimeInterval?

    // Callbacks
    var onSpeechStart: (() -> Void)?
    var onSpeechEnd: (() -> Void)?

    init(sampleRate: Double = 16000,
         activationThreshold: Float = 0.01, // -40dB
         deactivationThreshold: Float = 0.005, // -46dB
         minSpeechDuration: TimeInterval = 0.1,
         minSilenceDuration: TimeInterval = 0.7) {
        self.sampleRate = sampleRate
        self.activationThreshold = activationThreshold
        self.deactivationThreshold = deactivationThreshold
        self.minSpeechDuration = minSpeechDuration
        self.minSilenceDuration = minSilenceDuration
    }

    func process(buffer: [Float], currentTime: TimeInterval) {
        let rms = calculateRMS(buffer)

        switch state {
        case .silence:
            if rms > activationThreshold {
                state = .speech
                speechStartTime = currentTime
                silenceStartTime = nil
                onSpeechStart?()
            }
        case .speech:
            if rms < deactivationThreshold {
                if silenceStartTime == nil {
                    silenceStartTime = currentTime
                }

                if let silenceStart = silenceStartTime, (currentTime - silenceStart) >= minSilenceDuration {
                    // Confirmed silence
                    state = .silence
                    onSpeechEnd?()
                    silenceStartTime = nil
                    speechStartTime = nil
                }
            } else {
                // Still speaking, reset silence timer
                silenceStartTime = nil
            }
        }
    }

    private func calculateRMS(_ buffer: [Float]) -> Float {
        guard !buffer.isEmpty else { return 0.0 }
        var rms: Float = 0.0
        vDSP_rmsqv(buffer, 1, &rms, vDSP_Length(buffer.count))
        return rms
    }

    func reset() {
        state = .silence
        speechStartTime = nil
        silenceStartTime = nil
    }
}
