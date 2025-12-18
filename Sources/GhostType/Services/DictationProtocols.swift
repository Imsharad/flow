import Foundation
import AVFoundation

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

// Protocol for Transcription Services (Cloud/Local)
protocol TranscriptionProvider: Actor {
    var id: String { get }
    var name: String { get }

    // Core function
    func transcribe(_ buffer: AVAudioPCMBuffer) async throws -> String

    // New function with context
    func transcribeWithTokens(_ buffer: AVAudioPCMBuffer, promptTokens: [Int]?) async throws -> (String, [Int])

    // Lifecycle
    func warmUp() async throws
    func cooldown() async
}

// Default implementation for transcribeWithTokens to avoid breaking changes if not implemented
extension TranscriptionProvider {
    func transcribeWithTokens(_ buffer: AVAudioPCMBuffer, promptTokens: [Int]?) async throws -> (String, [Int]) {
        // Fallback: Just call transcribe and return empty tokens
        let text = try await transcribe(buffer)
        return (text, [])
    }
}

enum TranscriptionError: Error {
    case modelLoadFailed
    case encodingFailed
    case networkError(Error)
    case unknown(Error)
}

enum TranscriptionMode {
    case local
    case cloud
}

enum TranscriptionProviderState {
    case notReady
    case warmingUp
    case ready
    case error(Error)
}
