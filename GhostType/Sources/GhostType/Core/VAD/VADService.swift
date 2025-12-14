import Foundation

class VADService {
    // Mocking VAD for now as we don't have the ONNX models loaded yet.
    // In a real implementation, this would use SherpaOnnx's VAD or Silero VAD.

    private var isSpeechDetected = false
    private var consecutiveSpeechFrames = 0
    private var consecutiveSilenceFrames = 0

    // Thresholds (Simulated)
    private let startThreshold = 3 // Frames to trigger start
    private let endThreshold = 20  // Frames to trigger end

    var onSpeechStart: (() -> Void)?
    var onSpeechEnd: (() -> Void)?

    func process(samples: [Float]) {
        // Simple energy-based VAD for simulation
        let energy = calculateEnergy(samples)
        let threshold: Float = 0.01

        if energy > threshold {
            consecutiveSpeechFrames += 1
            consecutiveSilenceFrames = 0

            if !isSpeechDetected && consecutiveSpeechFrames > startThreshold {
                isSpeechDetected = true
                onSpeechStart?()
                print("[VAD] Speech Started")
            }
        } else {
            consecutiveSilenceFrames += 1
            consecutiveSpeechFrames = 0

            if isSpeechDetected && consecutiveSilenceFrames > endThreshold {
                isSpeechDetected = false
                onSpeechEnd?()
                print("[VAD] Speech Ended")
            }
        }
    }

    private func calculateEnergy(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumSquares = samples.reduce(0) { $0 + $1 * $1 }
        return sqrt(sumSquares / Float(samples.count))
    }
}
