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
    // private var currentTask: Task<String?, Never>? // Deprecated
    
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
    func transcribe(buffer: AVAudioPCMBuffer, contextTokens: [Int]? = nil, contextText: String? = nil) async -> (text: String, tokens: [Int])? {
        // 1. Cancel existing work (Latest wins)
        currentTaskTuple?.cancel()
        
        isTranscribing = true
        
        let newTask = Task { () -> (String, [Int])? in
            if Task.isCancelled { return nil }
            
            do {
                let result = try await self.performTranscription(buffer: buffer, contextTokens: contextTokens, contextText: contextText)
                return result
            } catch is CancellationError {
                return nil
            } catch {
                print("❌ TranscriptionManager: Error: \(error)")
                self.lastError = error.localizedDescription
                return nil
            }
        }
        
        currentTaskTuple = newTask
        let result = await newTask.value
        
        isTranscribing = false
        return result
    }

    // New internal method handling the typed task
    private var currentTaskTuple: Task<(String, [Int])?, Never>?
    
    private func performTranscription(buffer: AVAudioPCMBuffer, contextTokens: [Int]?, contextText: String?) async throws -> (text: String, tokens: [Int]) {
        // Check cancellation
        try Task.checkCancellation()
        
        // Attempt Primary
        if currentMode == .cloud {
            do {
                let (text, tokens) = try await cloudService.transcribe(buffer, promptTokens: contextTokens, promptText: contextText)
                return (text, tokens ?? [])
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
            let (text, tokens) = try await localService.transcribe(buffer, promptTokens: contextTokens, promptText: contextText)
            return (text, tokens ?? [])
        } catch {
            throw error
        }
    }
}
