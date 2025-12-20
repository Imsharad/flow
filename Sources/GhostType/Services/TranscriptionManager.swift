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
    // Lock for final commits
    private var isProcessingFinal: Bool = false
    
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
    
    /// Partial transcription (cancellable, lower priority).
    /// Will be skipped if a Final transcription is in progress.
    func transcribe(buffer: AVAudioPCMBuffer, prompt: String? = nil, promptTokens: [Int]? = nil) async -> TranscriptionResult? {
        if isProcessingFinal {
            // print("⚠️ TranscriptionManager: Skipping partial update (Final in progress)")
            return nil
        }

        // 1. Cancel existing partial work (Latest wins)
        currentTask?.cancel()
        
        isTranscribing = true
        
        let newTask = Task { () -> TranscriptionResult? in
            if Task.isCancelled { return nil }
            
            do {
                let result = try await self.performTranscription(buffer: buffer, prompt: prompt, promptTokens: promptTokens)
                return result
            } catch is CancellationError {
                return nil
            } catch {
                // print("❌ TranscriptionManager: Partial Error: \(error)")
                return nil
            }
        }
        
        currentTask = newTask
        let result = await newTask.value
        
        isTranscribing = false
        return result
    }
    
    /// Final transcription (Atomic, High Priority).
    /// Cancels any running partial task and blocks new partials until done.
    func transcribeFinal(buffer: AVAudioPCMBuffer, prompt: String? = nil, promptTokens: [Int]? = nil) async throws -> TranscriptionResult {
        // 1. Cancel any partial task
        currentTask?.cancel()
        currentTask = nil

        isProcessingFinal = true
        isTranscribing = true
        defer {
            isProcessingFinal = false
            isTranscribing = false
        }

        // 2. Run immediately (no Task wrapper needed as we want to await it directly)
        return try await performTranscription(buffer: buffer, prompt: prompt, promptTokens: promptTokens)
    }

    private func performTranscription(buffer: AVAudioPCMBuffer, prompt: String?, promptTokens: [Int]?) async throws -> TranscriptionResult {
        // Check cancellation (mostly for partials)
        try Task.checkCancellation()
        
        // Attempt Primary
        if currentMode == .cloud {
            do {
                return try await cloudService.transcribeWithContext(buffer, prompt: prompt, promptTokens: promptTokens)
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
            return try await localService.transcribeWithContext(buffer, prompt: prompt, promptTokens: promptTokens)
        } catch {
            throw error
        }
    }
}
