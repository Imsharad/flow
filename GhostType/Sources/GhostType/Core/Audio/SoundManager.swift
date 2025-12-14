import Cocoa
import AVFoundation

class SoundManager {
    private var player: AVAudioPlayer?

    func playStartSound() {
        playSound(named: "start")
    }

    func playStopSound() {
        playSound(named: "stop")
    }

    private func playSound(named name: String) {
        // In a real app, these files should be in the bundle resources.
        // For scaffold, we check if file exists, otherwise we just print.

        guard let url = Bundle.module.url(forResource: name, withExtension: "wav") else {
            print("[SoundManager] Sound file '\(name).wav' not found.")
            return
        }

        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.play()
        } catch {
            print("[SoundManager] Failed to play sound: \(error)")
        }
    }
}
