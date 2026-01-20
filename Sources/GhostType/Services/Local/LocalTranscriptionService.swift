import Foundation
import AVFoundation
import WhisperKit

actor LocalTranscriptionService: TranscriptionProvider {
    let id = "local.whisperkit"
    let name = "Local (M-Series)"
    
    // Wrapped existing service
    private var whisperKitService: WhisperKitService?
    
    // State
    private(set) var state: TranscriptionProviderState = .notReady
    
    // Memory Management
    private var lastAccessTime: Date?
    private var cooldownTimer: Task<Void, Never>?
    private let cooldownDuration: TimeInterval = 300 // 5 minutes
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    

    
    deinit {
        memoryPressureSource?.cancel()
        cooldownTimer?.cancel()
    }
    
    // MARK: - TranscriptionProvider Protocol
    
    func warmUp() async throws {
        guard whisperKitService == nil else { return }
        
        state = .warmingUp
        print("⚡️ LocalTranscriptionService: Warming up WhisperKit...")
        
        // Initialize the existing service (which loads the model internally)
        let service = WhisperKitService()
        
        // Wait for it to be ready (simplified check, usually we'd await a ready state)
        // Since WhisperKitService loads in a detached task, we might need to wait a bit or trust it handles calls.
        
        self.whisperKitService = service
        self.state = .ready
        
        setupMemoryPressureMonitor()
        resetCooldownTimer()
    }
    
    func transcribe(_ buffer: AVAudioPCMBuffer, promptTokens: [Int]?) async throws -> (text: String, tokens: [Int]) {
        lastAccessTime = Date()
        resetCooldownTimer()
        
        // 1. Auto-warmup if needed
        if whisperKitService == nil {
            try await warmUp()
        }
        
        guard let service = whisperKitService else {
            throw TranscriptionError.modelLoadFailed
        }
        
        // 2. VAD Gating (Crucial for preventing hallucinations on silence)
        if AudioAnalyzer.isSilence(buffer) {
            // print("🔇 LocalTranscriptionService: Silence detected, skipping inference.")
            return ("", [])
        }
        
        // 3. Local Inference
        // Convert AVAudioPCMBuffer to [Float] for WhisperKit
        let floatArray = buffer.toFloatArray()
        
        // Call existing service
        do {
            let (text, tokens, _) = try await service.transcribe(audio: floatArray, promptTokens: promptTokens)
            return (text, tokens)
        } catch {
            print("❌ LocalTranscriptionService: Inference failed: \(error)")
            throw TranscriptionError.unknown(error)
        }
    }
    
    func cooldown() async {
        print("❄️ LocalTranscriptionService: Cooling down. Unloading model.")
        whisperKitService = nil
        state = .notReady
        cooldownTimer?.cancel()
        cooldownTimer = nil
    }
    
    // MARK: - Memory Management
    
    private func resetCooldownTimer() {
        cooldownTimer?.cancel()
        cooldownTimer = Task {
            try? await Task.sleep(nanoseconds: UInt64(cooldownDuration * 1_000_000_000))
            if !Task.isCancelled {
                print("💤 LocalTranscriptionService: Inactivity timeout. Unloading.")
                await cooldown()
            }
        }
    }
    
    init() {}
    
    private func setupMemoryPressureMonitor() {
        guard memoryPressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global())
        source.setEventHandler { [weak self] in
            Task { [weak self] in
                print("⚠️ LocalTranscriptionService: Memory Pressure Detected! Purging model.")
                await self?.cooldown()
            }
        }
        source.activate()
        self.memoryPressureSource = source
    }

    /// Tokenize text using the underlying WhisperKit service.
    func tokenize(text: String) async -> [Int]? {
        // Auto-warmup if needed (or just fail if we don't want to load just for this?)
        // Let's safe load.
        if whisperKitService == nil {
             try? await warmUp()
        }

        guard let service = whisperKitService else { return nil }
        return await service.encode(text: text)
    }
}
