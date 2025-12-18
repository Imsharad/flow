import Foundation

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

