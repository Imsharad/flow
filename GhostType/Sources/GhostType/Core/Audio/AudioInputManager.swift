import AVFoundation
import Accelerate

class AudioInputManager: ObservableObject {
    private var engine: AVAudioEngine
    private var inputNode: AVAudioInputNode
    private var mixerNode: AVAudioMixerNode
    private let targetSampleRate: Double = 16000.0

    // Callback for delivering audio buffers (pcm, channelCount)
    var onAudioBuffer: (([Float]) -> Void)?

    init() {
        self.engine = AVAudioEngine()
        self.inputNode = engine.inputNode
        self.mixerNode = AVAudioMixerNode()

        setupEngine()
    }

    private func setupEngine() {
        let inputFormat = inputNode.inputFormat(forBus: 0)
        let format16k = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetSampleRate, channels: 1, interleaved: false)!

        engine.attach(mixerNode)

        // Connect input to mixer, converting format if necessary
        engine.connect(inputNode, to: mixerNode, format: inputFormat)

        // Install tap on mixer output to get 16kHz mono
        mixerNode.installTap(onBus: 0, bufferSize: 1024, format: format16k) { [weak self] (buffer, time) in
            self?.processBuffer(buffer)
        }
    }

    private func processBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }

        let channelDataValue = channelData.pointee
        let channelDataPtr = UnsafeBufferPointer(start: channelDataValue, count: Int(buffer.frameLength))
        let samples = Array(channelDataPtr)

        onAudioBuffer?(samples)
    }

    func start() throws {
        if !engine.isRunning {
            try engine.start()
        }
    }

    func stop() {
        if engine.isRunning {
            engine.stop()
        }
    }
}
