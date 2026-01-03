import Foundation
import AVFoundation

/// Defines the operational state of a provider.
enum TranscriptionProviderState: Sendable {
    case notReady       // Model not loaded or no API key
    case warmingUp      // Currently loading model or validating connection
    case ready          // Ready to accept audio
    case error(String)  // Persistent failure state
}

/// Defines the user-selected mode for transcription.
enum TranscriptionMode: String, CaseIterable, Identifiable, Sendable {
    case cloud
    case local
    
    var id: String { rawValue }
}

/// Errors specific to the transcription process.
enum TranscriptionError: Error {
    case authenticationMissing
    case networkError(Error)
    case serverError(code: Int)
    case modelLoadFailed
    case encodingFailed
    case invalidResponse
    case unknown(Error)
}

public struct TranscriptionResult: Sendable {
    public let text: String
    public let tokens: [Int]?
    public let segments: [Segment]?

    public init(text: String, tokens: [Int]? = nil, segments: [Segment]? = nil) {
        self.text = text
        self.tokens = tokens
        self.segments = segments
    }
}

/// A unified interface for transcription services (Cloud or Local).
protocol TranscriptionProvider: Sendable {
    
    /// A stable identifier for the provider (e.g., "cloud.groq", "local.whisperkit").
    var id: String { get }
    
    /// A user-facing display name.
    var name: String { get }
    
    /// The current operational state of the provider.
    /// Implementation note: This should be thread-safe.
    var state: TranscriptionProviderState { get async }
    
    /// Prepares the provider for immediate use.
    /// For Cloud: This might verify the API key availability.
    /// For Local: This loads the neural network weights into memory.
    func warmUp() async throws
    
    /// Transcribes the given audio buffer.
    /// - Parameter buffer: The raw PCM buffer captured from the microphone.
    /// - Parameter prompt: Optional text prompt for context (Cloud).
    /// - Parameter promptTokens: Optional token IDs for context (Local).
    /// - Returns: The transcription result containing text and optional tokens/segments.
    func transcribe(_ buffer: AVAudioPCMBuffer, prompt: String?, promptTokens: [Int]?) async throws -> TranscriptionResult
    
    /// Cleans up resources.
    /// For Local: Unloads the model to free system RAM.
    func cooldown() async
}

/// Decodable structure for standard OpenAI-compatible JSON responses.
struct OpenAIResponse: Decodable {
    let text: String
}
