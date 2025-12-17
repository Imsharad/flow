import Foundation

/// Protocol for Voice Activity Detection service.


/// Protocol for Speech-to-Text transcription service.
protocol TranscriberProtocol: AnyObject {
    var onPartialResult: ((String) -> Void)? { get set }
    var onFinalResult: ((String) -> Void)? { get set }
    
    func startStreaming() throws
    func stopStreaming()
    func transcribe(buffer: [Float]) -> String
}

/// Protocol for Grammar Correction service.
protocol TextCorrectorProtocol: AnyObject {
    func correct(text: String, context: String?) -> String
    func warmUp(completion: (() -> Void)?)
}

/// Represents a single word segment with timing information.
struct Segment: Identifiable, Equatable, Sendable {
    let id = UUID()
    let word: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let probability: Float
}

/// Protocol for the Consensus Service
protocol ConsensusServiceProtocol: AnyObject {
    func onNewHypothesis(_ segments: [Segment]) async -> (committed: String, hypothesis: String)
    func flush() async -> String
    func reset() async
}

