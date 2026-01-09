import AVFoundation
import Accelerate

protocol AudioInputDelegate: AnyObject {
    func didCaptureBuffer(_ buffer: [Float])
}

class AudioInputManager {
    weak var delegate: AudioInputDelegate?
    private let engine = AVAudioEngine()
    private let desiredSampleRate: Double = 16000.0

    func start() throws {
        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)

        let format16k = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: desiredSampleRate, channels: 1, interleaved: false)!

        guard let converter = AVAudioConverter(from: inputFormat, to: format16k) else {
            throw NSError(domain: "AudioInputManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create audio converter"])
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] (buffer, time) in
            guard let self = self else { return }

            let capacity = AVAudioFrameCount(Double(buffer.frameLength) / inputFormat.sampleRate * self.desiredSampleRate)
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: format16k, frameCapacity: capacity) else { return }

            var error: NSError?
            let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

            if let error = error {
                print("Conversion error: \(error)")
                return
            }

            if let floatChannelData = outputBuffer.floatChannelData {
                let channelData = floatChannelData.pointee
                let frameLength = Int(outputBuffer.frameLength)
                let samples = Array(UnsafeBufferPointer(start: channelData, count: frameLength))

                self.delegate?.didCaptureBuffer(samples)
            }
        }

        try engine.start()
    }

    func stop() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
    }
}
