import AVFoundation
import Accelerate

class AudioInputManager {
    static let shared = AudioInputManager()

    private let engine = AVAudioEngine()
    private let targetSampleRate: Double = 16000.0
    private var isRecording = false

    var onAudioBuffer: (([Float]) -> Void)?

    private init() {}

    func requestPermission() async -> Bool {
        return await withCheckedContinuation { continuation in
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                continuation.resume(returning: true)
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            case .denied, .restricted:
                continuation.resume(returning: false)
            @unknown default:
                continuation.resume(returning: false)
            }
        }
    }

    func startRecording() throws {
        guard !isRecording else { return }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)

        // We want 16kHz mono
        guard let desiredFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetSampleRate, channels: 1, interleaved: false) else {
            throw NSError(domain: "AudioInputManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create desired audio format"])
        }

        // Create a converter to resample input to 16kHz
        guard let converter = AVAudioConverter(from: inputFormat, to: desiredFormat) else {
             throw NSError(domain: "AudioInputManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio converter"])
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] (buffer, time) in
            guard let self = self else { return }
            self.processBuffer(buffer, converter: converter, desiredFormat: desiredFormat)
        }

        try engine.start()
        isRecording = true
        print("Audio recording started.")
    }

    func stopRecording() {
        guard isRecording else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        print("Audio recording stopped.")
    }

    private func processBuffer(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, desiredFormat: AVAudioFormat) {
        // Calculate the capacity needed for the converted buffer
        let inputFrameCount = buffer.frameLength
        let ratio = desiredFormat.sampleRate / buffer.format.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(inputFrameCount) * ratio)

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: desiredFormat, frameCapacity: outputFrameCount) else { return }

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

        if let error = error {
            print("Audio conversion error: \(error.localizedDescription)")
            return
        }

        // Extract samples and pass them on
        if let channelData = outputBuffer.floatChannelData {
            let channelPointer = channelData[0] // Mono, so just take the first channel
            let sampleCount = Int(outputBuffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: channelPointer, count: sampleCount))

            self.onAudioBuffer?(samples)
        }
    }
}
