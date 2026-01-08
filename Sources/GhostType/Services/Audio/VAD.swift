import Foundation
import Accelerate

/// A state-machine-based Voice Activity Detector (VAD).
/// It analyzes audio energy (RMS) and manages transitions between Silence and Speech states.
class VAD {
    enum State {
        case silence
        case speech
    }

    // Configuration
    private let activationThreshold: Float // RMS > this triggers Speech
    private let deactivationThreshold: Float // RMS < this triggers Silence
    private let minSpeechDuration: TimeInterval // Ignore short bursts
    private let minSilenceDuration: TimeInterval // Ignore short silences (pauses)

    // State
    private(set) var state: State = .silence
    private var stateStartTime: Date = Date()

    // Callbacks
    var onSpeechStart: (() -> Void)?
    var onSpeechEnd: (() -> Void)?

    init(
        activationThreshold: Float = 0.015, // Slightly higher to avoid noise
        deactivationThreshold: Float = 0.01,
        minSpeechDuration: TimeInterval = 0.1,
        minSilenceDuration: TimeInterval = 0.7 // As per plan
    ) {
        self.activationThreshold = activationThreshold
        self.deactivationThreshold = deactivationThreshold
        self.minSpeechDuration = minSpeechDuration
        self.minSilenceDuration = minSilenceDuration
    }

    func process(rms: Float) {
        let now = Date()
        let stateDuration = now.timeIntervalSince(stateStartTime)

        switch state {
        case .silence:
            if rms > activationThreshold {
                // Potential speech start
                // Immediate transition for responsiveness
                transition(to: .speech)
            }

        case .speech:
            if rms < deactivationThreshold {
                // Potential silence (pause or end)
                if stateDuration > minSilenceDuration {
                     // Only transition to silence if we've been "quiet" for enough time?
                     // Wait, this logic is tricky. If we are in speech, and rms drops, we are technically in a "gap".
                     // But we don't change state to silence until the gap persists?
                     // No, typically VAD has a "hangover" or hold time.
                     // A simple way is:
                     // If we are in speech, we stay in speech unless we see consistently low energy for `minSilenceDuration`.
                     // Since `process` is called frequently (e.g. every chunk), we need to track "silence onset".
                }
            } else {
                // Still loud, reset silence tracking if any
                silenceOnsetTime = nil
            }
        }
    }

    private var silenceOnsetTime: Date?

    func process(segment: [Float], sampleRate: Double) {
        // Calculate RMS of the segment
        guard !segment.isEmpty else { return }
        let rms = sqrt(segment.reduce(0) { $0 + $1 * $1 } / Float(segment.count))

        // State Machine
        let now = Date()

        switch state {
        case .silence:
            if rms > activationThreshold {
                // Speech Detected
                transition(to: .speech)
                silenceOnsetTime = nil
            }

        case .speech:
            if rms < deactivationThreshold {
                // Low energy detected. Start tracking silence duration.
                if silenceOnsetTime == nil {
                    silenceOnsetTime = now
                } else if let onset = silenceOnsetTime, now.timeIntervalSince(onset) >= minSilenceDuration {
                    // We have been silent long enough. End speech.
                    transition(to: .silence)
                    silenceOnsetTime = nil
                }
            } else {
                // Speech continues, reset silence timer
                silenceOnsetTime = nil
            }
        }
    }

    private func transition(to newState: State) {
        guard newState != state else { return }

        let now = Date()
        let previousStateDuration = now.timeIntervalSince(stateStartTime)

        if newState == .silence {
            // We are ending speech
            // Check if speech was long enough to count
             if previousStateDuration >= minSpeechDuration {
                 onSpeechEnd?()
             } else {
                 // Speech was too short, maybe just noise?
                 // For now, we fire onSpeechEnd anyway to keep logic simple, or we could ignore it.
                 // But if we ignore it, we need to decide what to do with the audio.
                 // Let's assume the consumer handles "empty" or short results.
                 onSpeechEnd?()
             }
        } else {
            // We are starting speech
            onSpeechStart?()
        }

        state = newState
        stateStartTime = now
    }

    func reset() {
        state = .silence
        stateStartTime = Date()
        silenceOnsetTime = nil
    }
}
