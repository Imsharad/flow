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
    
    func transcribe(_ buffer: AVAudioPCMBuffer) async throws -> String {
        return try await transcribe(buffer, prompt: nil)
    }

    func transcribe(_ buffer: AVAudioPCMBuffer, prompt: String?) async throws -> String {
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
            return ""
        }
        
        // 3. Local Inference
        // Convert AVAudioPCMBuffer to [Float] for WhisperKit
        let floatArray = buffer.toFloatArray()
        
        // Convert prompt text to tokens if provided
        var promptTokens: [Int]? = nil
        if let promptText = prompt {
            promptTokens = await service.convertTokenToId(promptText)
        }

        // Call existing service
        do {
            let (text, newTokens, _) = try await service.transcribe(audio: floatArray, promptTokens: promptTokens)

            // Note: We might want to pass these tokens back up for accumulation,
            // but the current interface returns String.
            // The Accumulator currently re-tokenizes or just stores text?
            // Actually `DictationEngine` has access to `accumulator`.
            // But `TranscriptionManager` returns `String`.
            // We need `TranscriptionManager` to return `(text, tokens)` ideally.
            // For now, we return text. The caller (DictationEngine) might need to re-tokenize
            // if it wants to maintain token-based context, OR we just trust the text accumulator.

            // To properly support context passing, we should probably update the return type
            // or let the service handle accumulation? No, DictationEngine should orchestrate.

            return text
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
}
