import Foundation
import Accelerate

class VoiceActivityDetector {
    // Configuration
    let sampleRate: Double
    let frameDuration: TimeInterval = 0.1 // 100ms analysis window
    let silenceThreshold: Float = 0.01 // Tunable, matches AudioAnalyzer
    let minSpeechDuration: TimeInterval = 0.2 // Minimum speech to trigger start
    let minSilenceDuration: TimeInterval = 0.7 // Silence required to trigger end

    // State
    private var isSpeechActive: Bool = false
    private var speechDuration: TimeInterval = 0
    private var silenceDuration: TimeInterval = 0

    // Callbacks
    var onSpeechStart: (() -> Void)?
    var onSpeechEnd: (() -> Void)?

    // Buffer for accumulation
    private var buffer: [Float] = []

    init(sampleRate: Double = 16000) {
        self.sampleRate = sampleRate
    }

    func process(samples: [Float]) {
        buffer.append(contentsOf: samples)

        let frameSize = Int(sampleRate * frameDuration)

        while buffer.count >= frameSize {
            let frame = Array(buffer.prefix(frameSize))
            buffer.removeFirst(frameSize)
            processFrame(frame)
        }
    }

    private func processFrame(_ frame: [Float]) {
        let rms = calculateRMS(frame)
        let frameTime = Double(frame.count) / sampleRate

        if rms > silenceThreshold {
            // Speech detected
            if !isSpeechActive {
                if speechDuration + frameTime >= minSpeechDuration {
                    isSpeechActive = true
                    onSpeechStart?()
                } else {
                    speechDuration += frameTime
                }
            } else {
                speechDuration += frameTime
            }
            silenceDuration = 0
        } else {
            // Silence detected
            if isSpeechActive {
                if silenceDuration + frameTime >= minSilenceDuration {
                    isSpeechActive = false
                    onSpeechEnd?()
                    speechDuration = 0
                } else {
                    silenceDuration += frameTime
                }
            } else {
                speechDuration = 0 // Reset potential speech accumulation if we hit silence before triggering start
            }
        }
    }

    private func calculateRMS(_ buffer: [Float]) -> Float {
        guard !buffer.isEmpty else { return 0 }
        var rms: Float = 0
        vDSP_rmsqv(buffer, 1, &rms, vDSP_Length(buffer.count))
        return rms
    }

    func reset() {
        buffer.removeAll()
        isSpeechActive = false
        speechDuration = 0
        silenceDuration = 0
    }
}
