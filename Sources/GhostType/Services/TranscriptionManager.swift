import Foundation
import AVFoundation
import Combine

@MainActor
class TranscriptionManager: ObservableObject {
    @Published var currentMode: TranscriptionMode = .local
    @Published var isTranscribing: Bool = false
    @Published var lastError: String?
    @Published var hasStoredKey: Bool = false
    
    private var cloudService: CloudTranscriptionService
    private let localService: LocalTranscriptionService
    private let keychain: KeychainManager
    
    // Concurrency: Latest Wins pattern
    private var currentTask: Task<TranscriptionResult?, Never>?
    
    init() {
        self.keychain = KeychainManager()
        
        // Try to load key from Keychain, or fallback to Environment (Dev convenience)
        let key = keychain.retrieveKey() ?? ProcessInfo.processInfo.environment["GROQ_API_KEY"] ?? ""
        
        self.cloudService = CloudTranscriptionService(apiKey: key)
        self.localService = LocalTranscriptionService()
        
        // Track if we have a stored key
        self.hasStoredKey = !key.isEmpty
        
        // Default to local if no key is present at all
        if key.isEmpty {
            self.currentMode = .local
        } else {
            self.currentMode = .cloud // Prefer cloud if key exists
        }
    }
    
    func updateAPIKey(_ key: String) async -> Bool {
        // 1. Create temporary service to validate
        let testService = CloudTranscriptionService(apiKey: key)
        
        print("🔍 TranscriptionManager: Validating new API Key...")
        
        do {
            let isValid = try await testService.validateAPIKey()
            if isValid {
                // 2. Save only if valid
                await MainActor.run {
                    keychain.saveKey(key)
                    self.cloudService = testService // Update the actor
                    self.hasStoredKey = true
                    
                     // Auto-switch to cloud mode
                    self.currentMode = .cloud
                    print("✅ TranscriptionManager: API Key validated and saved. Cloud service ready.")
                }
                return true
            } else {
                print("❌ TranscriptionManager: API Key validation failed.")
                return false
            }
        } catch {
            print("❌ TranscriptionManager: Validation error: \(error)")
            return false
        }
    }
    
    /// Main entry point for transcription.
    /// Uses "Latest Wins" cancellation to prevent race conditions from rapid updates (e.g. sliding window).
    func transcribe(buffer: AVAudioPCMBuffer, promptTokens: [Int]? = nil, textContext: String? = nil) async -> TranscriptionResult? {
        // 1. Cancel existing work (Latest wins)
        currentTask?.cancel()
        
        isTranscribing = true
        
        let newTask = Task { () -> TranscriptionResult? in
            defer { 
                Task { @MainActor in 
                   // Defer logic if needed
                }
            }
            
            if Task.isCancelled { return nil }
            
            do {
                let result = try await self.performTranscription(buffer: buffer, promptTokens: promptTokens, textContext: textContext)
                return result
            } catch is CancellationError {
                return nil
            } catch {
                print("❌ TranscriptionManager: Error: \(error)")
                self.lastError = error.localizedDescription
                return nil
            }
        }
        
        currentTask = newTask
        let result = await newTask.value
        
        isTranscribing = false
        return result
    }
    
    private func performTranscription(buffer: AVAudioPCMBuffer, promptTokens: [Int]?, textContext: String?) async throws -> TranscriptionResult {
        // Check cancellation
        try Task.checkCancellation()
        
        // Attempt Primary
        if currentMode == .cloud {
            do {
                // We use the cloud service
                // Note: The service itself handles Retries via ResilienceManager
                return try await cloudService.transcribe(buffer, promptTokens: promptTokens, textContext: textContext)
            } catch {
                if error is CancellationError { throw error }
                print("⚠️ Cloud transcription failed: \(error). Falling back to Local.")
                // Fallback to local
            }
        }
        
        // Check cancellation before fallback
        try Task.checkCancellation()
        
        // Primary Local OR Fallback Local
        do {
            return try await localService.transcribe(buffer, promptTokens: promptTokens, textContext: textContext)
        } catch {
            throw error
        }
    }
}
