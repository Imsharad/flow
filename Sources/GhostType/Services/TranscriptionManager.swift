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
    // We store a reference to the task so we can cancel it.
    // We use Any to type-erase the specific Task<T, E> return type.
    private var currentTask: Any?
    
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
    func transcribe(buffer: AVAudioPCMBuffer, promptTokens: [Int]? = nil) async -> (text: String, tokens: [Int])? {
        // 1. Cancel existing work (Latest wins)
        if let task = currentTask as? Task<(String, [Int])?, Never> {
            task.cancel()
        }
        
        isTranscribing = true
        
        // Create the task
        let task = Task { [weak self] () -> (String, [Int])? in
            guard let self = self else { return nil }
            
            // Check cancellation early
            if Task.isCancelled { return nil }
            
            do {
                let result = try await self.performTranscription(buffer: buffer, promptTokens: promptTokens)
                return result
            } catch is CancellationError {
                return nil
            } catch {
                print("❌ TranscriptionManager: Error: \(error)")
                self.lastError = error.localizedDescription
                return nil
            }
        }
        
        // Store as void task just for cancellation handle
        currentTask = Task {
            _ = await newTask.value
        }

        let result = await newTask.value
        
        // Only clear flag if we are still the current task (or just clear it, simple implementation)
        // If another task started, it would have cancelled us or overwritten currentTask.
        // But since we await properly, we can just clear if not cancelled?
        // Actually, if a new task started, `isTranscribing` should stay true.
        // So we should only set to false if we are not cancelled.
        if !Task.isCancelled {
            isTranscribing = false
        }

        return result
    }
    
    // Legacy overload for simple string return (keeping it for compatibility if needed, but upgrading internals)
    func transcribe(buffer: AVAudioPCMBuffer, prompt: String? = nil) async -> String? {
         // This seems to be used by old tests or cloud logic?
         // We can keep it but it won't support tokens.
         return await transcribe(buffer: buffer, promptTokens: nil)?.text
    }

    private func performTranscription(buffer: AVAudioPCMBuffer, promptTokens: [Int]?) async throws -> (String, [Int]) {
        // Check cancellation
        try Task.checkCancellation()
        
        // Attempt Primary
        if currentMode == .cloud {
            do {
                // Cloud doesn't support tokens yet, returns empty tokens
                return try await cloudService.transcribe(buffer, promptTokens: promptTokens)
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
            return try await localService.transcribe(buffer, promptTokens: promptTokens)
        } catch {
            throw error
        }
    }

    // Helper to tokenize text using the local model (if available)
    func tokenize(_ text: String) async -> [Int]? {
        // Only works if we have a local service active or can access it
        // Cloud service doesn't expose tokenizer yet.
        // We'll ask local service.
        return await localService.tokenize(text)
    }
}
