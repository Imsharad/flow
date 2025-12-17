import AVFoundation
import AppKit

/// Sound feedback manager for dictation events.
///
/// Uses system sounds as fallback when custom audio files aren't bundled.
/// System sounds are reliable and provide consistent UX.
class SoundManager {
    private var startSound: AVAudioPlayer?
    private var stopSound: AVAudioPlayer?
    private var useSystemSounds = false
    
    // System sound IDs for fallback
    // These are standard macOS system sounds
    private let systemStartSound: NSSound.Name = NSSound.Name("Tink")  // Light "start" sound
    private let systemStopSound: NSSound.Name = NSSound.Name("Pop")   // Distinct "stop" sound

    private let bundle: Bundle
    init(resourceBundle: Bundle) {
        self.bundle = resourceBundle

        // Try to load custom sounds first
        if let startUrl = Bundle.main.url(forResource: "start", withExtension: "wav") {
            startSound = try? AVAudioPlayer(contentsOf: startUrl)
            startSound?.prepareToPlay()
        }

        if let stopUrl = Bundle.main.url(forResource: "stop", withExtension: "wav") {
            stopSound = try? AVAudioPlayer(contentsOf: stopUrl)
            stopSound?.prepareToPlay()
        }
        
        // Use system sounds if custom sounds not available
        if startSound == nil || stopSound == nil {
            useSystemSounds = true
            print("Info: Using system sounds for audio feedback")
        }
    }

    func playStart() {
        if useSystemSounds {
            NSSound(named: systemStartSound)?.play()
        } else {
            startSound?.currentTime = 0
            startSound?.play()
        }
    }

    func playStop() {
        if useSystemSounds {
            NSSound(named: systemStopSound)?.play()
        } else {
            stopSound?.currentTime = 0
            stopSound?.play()
        }
    }
    
    /// Play a subtle error/warning sound
    func playError() {
        NSSound(named: NSSound.Name("Basso"))?.play()
    }
}
