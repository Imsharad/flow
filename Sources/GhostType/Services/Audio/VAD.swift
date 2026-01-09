import Foundation
import Accelerate

enum VADState {
    case silence
    case speech
}

final class VAD {
    // Configuration
    let sampleRate: Double
    let frameDuration: Double = 0.03 // 30ms analysis window

    // Thresholds (Tunable)
    // - Activation: How loud to trigger speech
    // - Deactivation: How quiet to trigger silence (hysteresis)
    var activationThreshold: Float = 0.015
    var deactivationThreshold: Float = 0.005

    // Timing Constraints
    var minSpeechDuration: Double = 0.15 // Minimum speech to count as valid
    var minSilenceDuration: Double = 0.6 // Silence duration to trigger "End of Speech"

    // State
    private(set) var state: VADState = .silence
    private var speechDuration: Double = 0
    private var silenceDuration: Double = 0

    // Callbacks
    var onSpeechStart: (() -> Void)?
    var onSpeechEnd: (() -> Void)?

    // Accumulator for partial frames
    private var scratchBuffer: [Float] = []

    init(sampleRate: Double = 16000) {
        self.sampleRate = sampleRate
    }

    func process(buffer: [Float]) {
        scratchBuffer.append(contentsOf: buffer)

        let frameSize = Int(sampleRate * frameDuration)

        while scratchBuffer.count >= frameSize {
            let frame = Array(scratchBuffer.prefix(frameSize))
            scratchBuffer.removeFirst(frameSize)
            processFrame(frame)
        }
    }

    private func processFrame(_ frame: [Float]) {
        let rms = calculateRMS(frame)
        let frameTime = Double(frame.count) / sampleRate

        switch state {
        case .silence:
            if rms > activationThreshold {
                speechDuration += frameTime
                if speechDuration >= minSpeechDuration {
                    transition(to: .speech)
                    // We don't reset silenceDuration here, it's reset on transition
                }
            } else {
                // Reset accumulation if it wasn't enough to trigger speech
                speechDuration = 0
            }

        case .speech:
            if rms < deactivationThreshold {
                silenceDuration += frameTime
                if silenceDuration >= minSilenceDuration {
                    transition(to: .silence)
                }
            } else {
                // Still loud enough, reset silence counter
                silenceDuration = 0
                // We keep tracking speech duration just for stats if needed
                speechDuration += frameTime
            }
        }
    }

    private func transition(to newState: VADState) {
        guard newState != state else { return }

        state = newState

        switch newState {
        case .speech:
            speechDuration = 0
            silenceDuration = 0
            print("🔊 VAD: Speech Start")
            onSpeechStart?()
        case .silence:
            speechDuration = 0
            silenceDuration = 0
            print("🔇 VAD: Speech End")
            onSpeechEnd?()
        }
    }

    private func calculateRMS(_ buffer: [Float]) -> Float {
        var rms: Float = 0
        vDSP_rmsqv(buffer, 1, &rms, vDSP_Length(buffer.count))
        return rms
    }

    /// Reset internal state
    func reset() {
        state = .silence
        speechDuration = 0
        silenceDuration = 0
        scratchBuffer.removeAll()
    }
}
