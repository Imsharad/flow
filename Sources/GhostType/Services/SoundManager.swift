import Cocoa

class SoundManager {
    static let shared = SoundManager()

    private var startSound: NSSound?
    private var stopSound: NSSound?

    private init() {
        if let startPath = Bundle.module.path(forResource: "start", ofType: "wav") {
             startSound = NSSound(contentsOfFile: startPath, byReference: true)
        }
        if let stopPath = Bundle.module.path(forResource: "stop", ofType: "wav") {
            stopSound = NSSound(contentsOfFile: stopPath, byReference: true)
        }
    }

    func playStart() {
        startSound?.play()
    }

    func playStop() {
        stopSound?.play()
    }
}
