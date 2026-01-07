import Foundation

/// Represents a single word segment with timing information.
struct Segment: Identifiable, Equatable, Sendable {
    let id = UUID()
    let word: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let probability: Float
}

/// Represents the result of a transcription request
struct TranscriptionResult: Sendable {
    let text: String
    let tokens: [Int]
    let segments: [Segment]
}

/// Protocol for the Consensus Service
protocol ConsensusServiceProtocol: AnyObject {
    func onNewHypothesis(_ segments: [Segment]) async -> (committed: String, hypothesis: String)
    func flush() async -> String
    func reset() async
}
