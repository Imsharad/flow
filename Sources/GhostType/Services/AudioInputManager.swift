import AVFoundation
import Accelerate

class AudioInputManager: ObservableObject {
    private var engine: AVAudioEngine
    private var inputNode: AVAudioInputNode
    private var mixerNode: AVAudioMixerNode
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?

    init() {
        engine = AVAudioEngine()
        inputNode = engine.inputNode
        mixerNode = AVAudioMixerNode()

        setupAudioEngine()
    }

    private func setupAudioEngine() {
        engine.attach(mixerNode)

        let inputFormat = inputNode.inputFormat(forBus: 0)
        engine.connect(inputNode, to: mixerNode, format: inputFormat)

        // Mute the mixer to prevent feedback loop
        mixerNode.outputVolume = 0

        // Downsample to 16kHz
        engine.connect(mixerNode, to: engine.mainMixerNode, format: outputFormat)

        mixerNode.installTap(onBus: 0, bufferSize: 1024, format: outputFormat) { [weak self] (buffer, time) in
            self?.onAudioBuffer?(buffer)
        }
    }

    func start() throws {
        // Ensure the engine is not running before starting
        if engine.isRunning { return }
        try engine.start()
    }

    func stop() {
        engine.stop()
    }
}
