import AVFoundation
import Accelerate
import SwiftUI
import Combine

class AudioInputManager: NSObject, ObservableObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let captureSession = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.ghosttype.audioInput")
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    // User Settings - Observed via UserDefaults
    private var cachedMicSensitivity: Double = 1.0
    private var cancellables = Set<AnyCancellable>()

    var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?

    static let shared = AudioInputManager()
    
    private override init() {
        super.init()
        setupCaptureSession()
        setupSettingsObserver()
    }

    private func setupSettingsObserver() {
        // Initialize cache
        self.cachedMicSensitivity = UserDefaults.standard.double(forKey: "micSensitivity")
        if self.cachedMicSensitivity == 0 { self.cachedMicSensitivity = 1.0 } // Default if missing

        // Observe changes
        UserDefaults.standard.publisher(for: \.micSensitivity) // requires extension or string key KVO
            .sink { [weak self] _ in
                // This might not work easily with standard UserDefaults without KVO compliance on specific keys or wrapper
            }

        // Simpler: Just poll or rely on NotificationCenter if AppStorage posts it? No.
        // Let's use KVO on UserDefaults standard.
        UserDefaults.standard.addObserver(self, forKeyPath: "micSensitivity", options: [.new], context: nil)
    }

    deinit {
        UserDefaults.standard.removeObserver(self, forKeyPath: "micSensitivity")
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "micSensitivity" {
            if let newVal = change?[.newKey] as? Double {
                self.cachedMicSensitivity = newVal
                // print("AudioInputManager: Updated sensitivity to \(newVal)")
            }
        } else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }
    
    private func setupCaptureSession() {
        captureSession.beginConfiguration()
        
        // 1. Select Built-in Microphone explicitly
        // This bypasses "CADefaultDeviceAggregate" or other virtual virtual devices that might be silent
        guard let microphone = AVCaptureDevice.default(.builtInMicrophone, for: .audio, position: .unspecified) else {
            print("AudioInputManager: ❌ ERROR - No built-in microphone found!")
            captureSession.commitConfiguration()
            return
        }
        
        print("AudioInputManager: 🎤 FOUND DEVICE: [\(microphone.localizedName)] ID: \(microphone.uniqueID)")
        
        do {
            let input = try AVCaptureDeviceInput(device: microphone)
            if captureSession.canAddInput(input) {
                captureSession.addInput(input)
            } else {
                print("AudioInputManager: ❌ ERROR - Could not add mic input to session")
            }
        } catch {
            print("AudioInputManager: ❌ ERROR - Failed to create device input: \(error)")
        }
        
        // 2. Configure Output
        let output = AVCaptureAudioDataOutput()
        if captureSession.canAddOutput(output) {
            captureSession.addOutput(output)
            output.setSampleBufferDelegate(self, queue: queue)
        } else {
            print("AudioInputManager: ❌ ERROR - Could not add audio output to session")
        }
        
        captureSession.commitConfiguration()
    }

    func start() throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status != .authorized {
            throw NSError(domain: "AudioInputManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone permission not authorized"])
        }
        
        if !captureSession.isRunning {
            // Start on background thread to avoid blocking UI
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.captureSession.startRunning()
                print("AudioInputManager: Capture session started")
            }
        }
    }

    func stop() {
        if captureSession.isRunning {
            captureSession.stopRunning()
            print("AudioInputManager: Capture session stopped")
        }
    }
    
    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let onAudioBuffer = onAudioBuffer else { return }
        
        // 1. Create AVAudioPCMBuffer from CMSampleBuffer
        // This is a bit verbose but necessary to get it into the AVAudioConverter pipeline
        
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamBasicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description) else {
            return
        }
        
        let sourceFormat = AVAudioFormat(streamDescription: streamBasicDescription)!
        
        // Initialize converter if format changed or first run
        if converter == nil || converter?.inputFormat != sourceFormat {
            print("AudioInputManager: Initializing converter \(sourceFormat) -> \(targetFormat)")
            converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        }
        
        guard let converter = converter else { return }
        
        // Create input buffer wrapper
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        
        // We need to get the AudioBufferList from the CMSampleBuffer
        // This is safe because we are just reading, not modifying
        var audioBufferList = AudioBufferList()
        var blockBuffer: CMBlockBuffer?
        
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        
        guard status == noErr else {
            print("AudioInputManager: Failed to extract buffer list from sample buffer")
            return
        }
        
        // Create the input PCM buffer from the AudioBufferList
        // Note: We have to trust that sourceFormat matches the buffer list structure
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else { return }
        inputBuffer.frameLength = frameCount
        
        // Copy data into inputBuffer (AVAudioPCMBuffer takes ownership/copy usually, or we can just unsafe reference it)
        // For simplicity and safety, let's copy using the AudioConverter input block pattern which is standard
        
        let bytesPerFrame = Int(sourceFormat.streamDescription.pointee.mBytesPerFrame)
        let byteSize = Int(frameCount) * bytesPerFrame
        
        if let srcPtr = audioBufferList.mBuffers.mData, let dstPtr = inputBuffer.audioBufferList.pointee.mBuffers.mData {
            dstPtr.copyMemory(from: srcPtr, byteCount: byteSize)
        } else {
            print("AudioInputManager: ❌ Failed to get pointers for copy")
        }
        
        // Prepare output buffer
        // 16kHz conversion ratio depends on source.
        // E.g. 48k -> 16k = 1/3 size.
        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let targetFrameCapacity = AVAudioFrameCount(Double(frameCount) * ratio) + 100 // +padding
        
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: targetFrameCapacity) else { return }
        
        var error: NSError? = nil
        let inputBlock: AVAudioConverterInputBlock = { inPacketCount, outStatus in
            outStatus.pointee = .haveData
            return inputBuffer
        }
        
        converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
        
        if let error = error {
            print("AudioInputManager: Conversion error: \(error)")
            return
        }
        
        // Apply Mic Sensitivity Gain using cached value
        if let channelData = outputBuffer.floatChannelData?[0] {
             let count = Int(outputBuffer.frameLength)
             let gain = Float(cachedMicSensitivity)
             // Only apply if gain is different from 1.0
             if abs(gain - 1.0) > 0.01 {
                 vDSP_vsmul(channelData, 1, [gain], channelData, 1, vDSP_Length(count))
             }
        }

        onAudioBuffer(outputBuffer)
    }
}
