import Foundation
// import sherpa_onnx // Commented out until dependency is fully resolved/downloaded in a real env

class Transcriber {
    // Mocking Transcription for now.
    // Real implementation would initialize SherpaOnnxRecognizer.

    var onTranscriptionResult: ((String) -> Void)?

    init() {
        print("Transcriber initialized (Mock Mode)")
    }

    func transcribe(buffer: [Float]) async -> String {
        // In a real app, this would feed the buffer to the recognizer.
        // For now, we simulate a delay and return a dummy string if buffer has content.

        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms simulation

        if !buffer.isEmpty {
            return "Testing 1 2 3"
        }
        return ""
    }

    func processAudioBatch(_ buffer: [Float]) {
        Task {
            let result = await transcribe(buffer: buffer)
            if !result.isEmpty {
                onTranscriptionResult?(result)
            }
        }
    }
}
