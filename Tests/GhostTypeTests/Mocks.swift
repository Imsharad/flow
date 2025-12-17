import Foundation
@testable import GhostType



class MockTranscriber: TranscriberProtocol {
    var onPartialResult: ((String) -> Void)?
    var onFinalResult: ((String) -> Void)?
    
    var startStreamingCallCount = 0
    var stopStreamingCallCount = 0
    var transcribeCallCount = 0
    
    var mockTranscriptionResult = "Mock Transcription"
    
    func startStreaming() throws {
        startStreamingCallCount += 1
    }
    
    func stopStreaming() {
        stopStreamingCallCount += 1
    }
    
    func transcribe(buffer: [Float]) -> String {
        transcribeCallCount += 1
        return mockTranscriptionResult
    }
}

class MockTextCorrector: TextCorrectorProtocol {
    var correctCallCount = 0
    var warmUpCallCount = 0
    
    var mockCorrectionResult = "Mock Corrected Text"
    
    func correct(text: String, context: String?) -> String {
        correctCallCount += 1
        return mockCorrectionResult
    }
    
    func warmUp(completion: (() -> Void)?) {
        warmUpCallCount += 1
        completion?()
    }
}
