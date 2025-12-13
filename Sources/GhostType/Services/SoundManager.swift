import AVFoundation

class SoundManager {
    private var startSound: AVAudioPlayer?
    private var stopSound: AVAudioPlayer?

    init() {
        if let startUrl = Bundle.module.url(forResource: "start", withExtension: "wav") {
            startSound = try? AVAudioPlayer(contentsOf: startUrl)
        } else {
             print("Warning: start.wav not found. Sound effects disabled.")
        }

        if let stopUrl = Bundle.module.url(forResource: "stop", withExtension: "wav") {
            stopSound = try? AVAudioPlayer(contentsOf: stopUrl)
        } else {
             print("Warning: stop.wav not found. Sound effects disabled.")
        }
    }

    func playStart() {
        startSound?.play()
    }

    func playStop() {
        stopSound?.play()
    }
}
