import Foundation
import AppKit

protocol VADDelegate: AnyObject {
    func didDetectSpeechStart()
    func didDetectSpeechEnd()
}

class VADService: AudioInputDelegate {
    weak var delegate: VADDelegate?
    private var isSpeaking = false

    // Placeholder for Silero VAD implementation
    // Since we cannot run the code, we assume the VAD checks the buffer energy or probability

    // Delegate to forward audio to transcriber
    weak var audioDelegate: Transcriber?

    func didCaptureBuffer(_ buffer: [Float]) {
        // Forward buffer to transcriber
        audioDelegate?.processAudio(buffer: buffer)

        // Simple energy-based VAD for now as placeholder for Silero logic
        // In real implementation, we would run the ONNX model here

        let energy = buffer.map { $0 * $0 }.reduce(0, +) / Float(buffer.count)
        let threshold: Float = 0.01 // Arbitrary threshold

        if energy > threshold && !isSpeaking {
            isSpeaking = true
            NSSound(named: "Pop")?.play()
            delegate?.didDetectSpeechStart()
            print("Speech Started")
        } else if energy < threshold && isSpeaking {
            // Need a hangover timer here usually
            isSpeaking = false
            NSSound(named: "Blow")?.play()
            delegate?.didDetectSpeechEnd()
            print("Speech Ended")
        }
    }
}
