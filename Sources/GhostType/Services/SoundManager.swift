import AVFoundation

class SoundManager {
    private var startSound: AVAudioPlayer?
    private var stopSound: AVAudioPlayer?

    init() {
        if let startUrl = Bundle.module.url(forResource: "start", withExtension: "wav") {
            startSound = try? AVAudioPlayer(contentsOf: startUrl)
        }
        if let stopUrl = Bundle.module.url(forResource: "stop", withExtension: "wav") {
            stopSound = try? AVAudioPlayer(contentsOf: stopUrl)
        }
    }

    func playStart() {
        startSound?.play()
    }

    func playStop() {
        stopSound?.play()
    }
}
