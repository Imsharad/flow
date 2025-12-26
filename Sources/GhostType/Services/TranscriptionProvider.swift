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
    /// - Returns: The transcribed text string.
    func transcribe(_ buffer: AVAudioPCMBuffer) async throws -> String
    
    /// Transcribes the given audio buffer with context prompt.
    /// - Parameter buffer: The raw PCM buffer.
    /// - Parameter prompt: The context prompt (e.g. previous sentence or window context).
    /// - Returns: The transcribed text string.
    func transcribe(_ buffer: AVAudioPCMBuffer, prompt: String?) async throws -> String

    /// Cleans up resources.
    /// For Local: Unloads the model to free system RAM.
    func cooldown() async
}

/// Decodable structure for standard OpenAI-compatible JSON responses.
struct OpenAIResponse: Decodable {
    let text: String
}
