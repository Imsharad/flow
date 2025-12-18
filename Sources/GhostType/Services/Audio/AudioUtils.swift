import AVFoundation
import Accelerate

enum AudioEncodingError: Error {
    case conversionFailed
    case emptyBuffer
}

final class WAVAudioEncoder {
    
    /// Converts a standard AVAudioPCMBuffer (Float32) to a WAV-formatted Data object (Int16, 16kHz).
    static func encodeToWAV(buffer: AVAudioPCMBuffer) throws -> Data {
        // 1. Define the Target Format: 16kHz, 1 channel, 16-bit Integer PCM
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                               sampleRate: 16000,
                                               channels: 1,
                                               interleaved: true) else {
            throw AudioEncodingError.conversionFailed
        }
        
        // 2. Setup the Converter
        guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat) else {
            throw AudioEncodingError.conversionFailed
        }
        
        // Calculate output frame count based on sample rate ratio
        let ratio = 16000 / buffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else {
            throw AudioEncodingError.conversionFailed
        }
        
        // 3. Perform Conversion
        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        
        let status = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
        
        if status == .error || error != nil {
            throw AudioEncodingError.conversionFailed
        }
        
        // 4. Synthesize WAV Header + Data
        return createWAVData(from: outputBuffer)
    }
    
    private static func createWAVData(from buffer: AVAudioPCMBuffer) -> Data {
        guard let channelData = buffer.int16ChannelData else { return Data() }
        
        let frameLength = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let sampleRate = Int(buffer.format.sampleRate)
        
        // Total bytes of audio data
        let dataSize = frameLength * channels * 2 // 2 bytes per sample (Int16)
        
        var header = Data()
        
        // RIFF chunk descriptor
        header.append("RIFF".data(using: .ascii)!)
        header.append(UInt32(36 + dataSize).littleEndian.data) // File size - 8
        header.append("WAVE".data(using: .ascii)!)
        
        // fmt sub-chunk
        header.append("fmt ".data(using: .ascii)!)
        header.append(UInt32(16).littleEndian.data) // Subchunk1Size (16 for PCM)
        header.append(UInt16(1).littleEndian.data)  // AudioFormat (1 for PCM)
        header.append(UInt16(channels).littleEndian.data)
        header.append(UInt32(sampleRate).littleEndian.data)
        
        // ByteRate = SampleRate * NumChannels * BitsPerSample/8
        let byteRate = sampleRate * channels * 2
        header.append(UInt32(byteRate).littleEndian.data)
        
        // BlockAlign = NumChannels * BitsPerSample/8
        header.append(UInt16(channels * 2).littleEndian.data)
        header.append(UInt16(16).littleEndian.data) // BitsPerSample
        
        // data sub-chunk
        header.append("data".data(using: .ascii)!)
        header.append(UInt32(dataSize).littleEndian.data)
        
        // Append actual PCM data
        let pcmData = Data(bytes: channelData.pointee, count: dataSize)
        header.append(pcmData)
        
        return header
    }
}

// Helper extension for Little Endian conversion
extension Numeric {
    var data: Data {
        var source = self
        return Data(bytes: &source, count: MemoryLayout<Self>.size)
    }
}

struct AudioAnalyzer {
    /// Threshold for silence. 0.01 is roughly -40dB. Adjust based on testing.
    static let silenceThreshold: Float = 0.01
    
    static func isSilence(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard let channelData = buffer.floatChannelData else { return true }
        let frameLength = vDSP_Length(buffer.frameLength)
        
        var rms: Float = 0.0
        // Calculate RMS of the vector (channel 0)
        vDSP_rmsqv(channelData.pointee, 1, &rms, frameLength)
        
        return rms < silenceThreshold
    }
}

extension AVAudioPCMBuffer {
    /// Converts the buffer content to a simple Float array (Mono).
    /// Used for compatibility with WhisperKit.
    func toFloatArray() -> [Float] {
        guard let channelData = self.floatChannelData else { return [] }
        let channelPointer = channelData.pointee
        let frameCount = Int(self.frameLength)
        return Array(UnsafeBufferPointer(start: channelPointer, count: frameCount))
    }
}
