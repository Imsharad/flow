import Foundation
import AVFoundation

enum TranscriptionProviderState: Sendable {
    case notReady
    case warmingUp
    case ready
    case failed(String)
}

enum TranscriptionError: Error {
    case modelLoadFailed
    case unknown(Error)
}

protocol TranscriptionProvider: Actor {
    var id: String { get }
    var name: String { get }
    var state: TranscriptionProviderState { get }
    
    /// Transcribe a buffer of audio.
    /// - Parameter buffer: The audio buffer to transcribe.
    /// - Parameter promptTokens: Optional tokens for context carryover.
    func transcribe(_ buffer: AVAudioPCMBuffer, promptTokens: [Int]?) async throws -> (text: String, tokens: [Int]?)
    
    func warmUp() async throws
    func cooldown() async
}

// Default implementation to make promptTokens optional in calls for backward compatibility
extension TranscriptionProvider {
    func transcribe(_ buffer: AVAudioPCMBuffer) async throws -> String {
        let (text, _) = try await transcribe(buffer, promptTokens: nil)
        return text
    }
}
