import Foundation
import AVFoundation
import Combine

@MainActor
class TranscriptionManager: ObservableObject {
    @Published var currentMode: TranscriptionMode = .local
    @Published var isTranscribing: Bool = false
    @Published var lastError: String?
    @Published var hasStoredKey: Bool = false
    
    // Config
    @Published var selectedModel: String = "distil-whisper_distil-large-v3"
    // Available models hardcoded for now (WhisperKit Optimized)
    let availableModels = [
        "distil-whisper_distil-large-v3",
        "openai_whisper-large-v3-turbo",
        "openai_whisper-base",
        "openai_whisper-tiny"
    ]

    private var cloudService: CloudTranscriptionService
    private let localService: LocalTranscriptionService
    private let keychain: KeychainManager
    
    // Concurrency: Latest Wins pattern
    private var currentTask: Task<(String, [Int])?, Never>?
    
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
    
    func switchModel(_ modelName: String) {
        guard availableModels.contains(modelName) else { return }
        selectedModel = modelName

        Task {
            await localService.switchModel(modelName: modelName)
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
    func transcribe(buffer: AVAudioPCMBuffer, prompt: String? = nil) async -> String? {
        let result = await transcribeWithTokens(buffer: buffer, promptTokens: nil)
        return result?.0
    }

    func transcribeWithTokens(buffer: AVAudioPCMBuffer, promptTokens: [Int]? = nil) async -> (String, [Int])? {
        // 1. Cancel existing work (Latest wins)
        currentTask?.cancel()
        
        isTranscribing = true
        
        let newTask = Task { () -> (String, [Int])? in
            defer { 
                Task { @MainActor in 
                   // Only reset if this is still the current task (avoid clearing flag for newer task)
                   // But since we are cancelling specific tasks, we can just defer.
                   // Actually, checking cancellation is safer.
                }
            }
            
            if Task.isCancelled { return nil }
            
            do {
                let result = try await self.performTranscriptionWithTokens(buffer: buffer, promptTokens: promptTokens)
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
    
    private func performTranscription(buffer: AVAudioPCMBuffer, prompt: String?) async throws -> String {
         let (text, _) = try await performTranscriptionWithTokens(buffer: buffer, promptTokens: nil)
         return text
    }

    private func performTranscriptionWithTokens(buffer: AVAudioPCMBuffer, promptTokens: [Int]?) async throws -> (String, [Int]) {
        // Check cancellation
        try Task.checkCancellation()
        
        // Attempt Primary
        if currentMode == .cloud {
            do {
                // We use the cloud service
                // Note: The service itself handles Retries via ResilienceManager
                // Cloud service might not support tokens yet, so we just pass nil or handle it?
                // For now, CloudTranscriptionService likely only does text.
                // We need to check CloudTranscriptionService implementation.
                let text = try await cloudService.transcribe(buffer) // Assuming no token support for cloud yet
                return (text, [])
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
            return try await localService.transcribeWithTokens(buffer, promptTokens: promptTokens)
        } catch {
            throw error
        }
    }
}
