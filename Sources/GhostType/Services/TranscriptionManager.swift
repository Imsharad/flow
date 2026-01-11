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
    
    // Concurrency: Latest Wins pattern with Priority
    // If a .high priority task is running, .low priority tasks are ignored/queued (here ignored).
    // If a .low priority task is running, a .high priority task cancels it.
    private var currentTask: Task<(String, [Int]?)?, Never>?
    private var currentTaskPriority: TranscriptionPriority = .low

    enum TranscriptionPriority: Comparable {
        case low // Partial/Preview
        case high // Final/Commit
    }
    
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
    /// - priority: .low for partial previews (can be cancelled), .high for final commits (cannot be cancelled by low).
    func transcribe(buffer: AVAudioPCMBuffer, prompt: String? = nil, promptTokens: [Int]? = nil, priority: TranscriptionPriority = .low) async -> (text: String, tokens: [Int]?)? {

        // Priority Logic:
        // If a HIGH priority task is already running, REJECT this new LOW priority request.
        if isTranscribing && currentTaskPriority == .high && priority == .low {
            print("⚠️ TranscriptionManager: Skipping Low Priority request (High Priority running).")
            return nil
        }

        // If we proceed, we cancel the existing task (Latest Wins or Priority Override)
        // If existing is Low, High cancels it.
        // If existing is High, High cancels it (user might have clicked stop/start rapidly? or just replacement).
        currentTask?.cancel()
        
        isTranscribing = true
        currentTaskPriority = priority
        
        let newTask = Task { () -> (String, [Int]?)? in
            defer { 
                 // Cleanup handled by outer scope monitoring or just resetting flags if needed.
                 // We don't need to do much here.
            }
            
            if Task.isCancelled { return nil }
            
            do {
                let result = try await self.performTranscription(buffer: buffer, prompt: prompt, promptTokens: promptTokens)
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
        
        // Only reset flags if *this* was the task that finished (avoid clearing for newer task)
        // Check if currentTask is still newTask.
        // But since we cancelled previous one, and subsequent ones cancel this one...
        // We can just check if we are not cancelled?
        // Actually, just checking if currentTask === newTask is enough (but Task is struct/value? No class reference identity).
        // Using simple bool for now.

        if !Task.isCancelled {
            isTranscribing = false
            currentTaskPriority = .low // Reset priority
        }

        return result
    }
    
    private func performTranscription(buffer: AVAudioPCMBuffer, prompt: String?, promptTokens: [Int]?) async throws -> (String, [Int]?) {
        // Check cancellation
        try Task.checkCancellation()
        
        // Attempt Primary
        if currentMode == .cloud {
            do {
                // We use the cloud service
                // Note: The service itself handles Retries via ResilienceManager
                return try await cloudService.transcribe(buffer, prompt: prompt, promptTokens: promptTokens)
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
            return try await localService.transcribe(buffer, prompt: prompt, promptTokens: promptTokens)
        } catch {
            throw error
        }
    }
}
