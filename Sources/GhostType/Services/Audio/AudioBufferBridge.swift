import AVFoundation
import Accelerate

/// A high-performance utility for bridging Swift native types to Core Audio buffers.
/// This struct is stateless and thread-safe.
struct AudioBufferBridge {

    /// Errors specific to buffer conversion operations.
    enum ConversionError: Error {
        case invalidSampleRate
        case bufferAllocationFailed
        case channelDataInaccessible
    }

    /// Creates an `AVAudioPCMBuffer` from a raw array of Float samples.
    ///
    /// This method performs a deep copy of the audio data. It is optimized for use
    /// in real-time transcription pipelines where `[Float]` data from a RingBuffer
    /// needs to be converted into a Core Audio compatible format.
    ///
    /// - Parameters:
    ///   - samples: The raw audio samples (Mono, Float32).
    ///   - sampleRate: The sample rate of the audio (typically 16000Hz for Whisper).
    /// - Returns: A configured `AVAudioPCMBuffer` containing the copied data.
    /// - Throws: `ConversionError` if allocation fails or formats differ.
    static func createBuffer(from samples: [Float], sampleRate: Double = 16000.0) -> AVAudioPCMBuffer? {
        // 1. Validate inputs
        guard sampleRate > 0 else {
            print("AudioBufferBridge Error: Invalid sample rate: \(sampleRate)")
            return nil
        }
        
        guard !samples.isEmpty else {
            return nil
        }

        // 2. Define the Core Audio format
        // Whisper models typically expect 16kHz, Mono, Float32.
        // We use interleaved: false because mono is effectively non-interleaved,
        // and accessing floatChannelData is simpler.
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            print("AudioBufferBridge Error: Failed to create AVAudioFormat.")
            return nil
        }

        // 3. Allocate the buffer
        // frameCapacity is the maximum number of frames the buffer can hold.
        // We allocate exactly enough for the provided samples.
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            print("AudioBufferBridge Error: Failed to allocate AVAudioPCMBuffer.")
            return nil
        }

        // 4. Update the frameLength
        // This tells the system how many valid frames are actually in the buffer.
        // Failing to set this results in a silent buffer.
        buffer.frameLength = AVAudioFrameCount(samples.count)

        // 5. Perform the memory copy
        // We use `floatChannelData` to get the destination pointer.
        // This is an UnsafePointer<UnsafeMutablePointer<Float>>.
        guard let channelData = buffer.floatChannelData else {
            print("AudioBufferBridge Error: floatChannelData was nil.")
            return nil
        }

        // Access the pointer for the first channel (Channel 0).
        let destinationPointer = channelData.pointee

        // Access the source memory from the Swift array.
        // `withUnsafeBufferPointer` ensures the array's memory is pinned
        // and accessible during the closure execution.
        samples.withUnsafeBufferPointer { sourceBuffer in
            guard let sourceAddress = sourceBuffer.baseAddress else { return }

            // Calculate the number of bytes to copy.
            // Count * SizeOf(Float)
            let byteCount = samples.count * MemoryLayout<Float>.size

            // memcpy(dest, src, bytes)
            // This is the fastest way to copy contiguous memory.
            memcpy(destinationPointer, sourceAddress, byteCount)
        }

        return buffer
    }
}
