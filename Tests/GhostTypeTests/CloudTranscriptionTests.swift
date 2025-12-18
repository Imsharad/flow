import XCTest
import AVFoundation
@testable import GhostType

final class CloudTranscriptionTests: XCTestCase {
    
    func testGroqTranscriptionEndToEnd() async throws {
        // 1. Get API Key
        let apiKey = ProcessInfo.processInfo.environment["GROQ_API_KEY"] ?? ""
        
        // Skip if no key (don't fail CI, but print warning)
        guard !apiKey.isEmpty else {
            print("⚠️ CloudTranscriptionTests: No GROQ_API_KEY found. Skipping test.")
            return
        }
        
        print("🧪 Testing CloudTranscriptionService with key: \(apiKey.prefix(8))...")
        
        // 2. Setup Service
        let cloudService = CloudTranscriptionService(apiKey: apiKey)
        
        // 3. Generate Synthetic Audio (1 second sine wave @ 440Hz, 16kHz)
        let sampleRate: Double = 16000.0
        let duration: Double = 1.0
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            XCTFail("Failed to create audio buffer")
            return
        }
        
        buffer.frameLength = frameCount
        let channels = buffer.floatChannelData!
        let channel0 = channels[0]
        
        // Generate Sine Wave
        for i in 0..<Int(frameCount) {
            let t = Double(i) / sampleRate
            let amplitude: Float = 0.5
            let frequency: Double = 440.0
            channel0[i] = amplitude * Float(sin(2.0 * .pi * frequency * t))
        }
        
        // 4. Perform Transcription
        do {
            let result = try await cloudService.transcribe(buffer)
            print("✅ Cloud Transcription Result: \"\(result)\"")
            
            // Note: A sine wave might result in hallucinations like "Connect with me..." or "Thank you",
            // or sometimes just silence/empty string depending on the model's VAD.
            // But getting *any* result meant the API roundtrip worked.
            XCTAssertNotNil(result, "Result should not be nil")
        } catch {
            XCTFail("Cloud transcription failed: \(error)")
        }
    }
}
