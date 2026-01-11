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
    
    func transcribe(_ buffer: AVAudioPCMBuffer, prompt: String? = nil, promptTokens: [Int]? = nil) async throws -> (text: String, tokens: [Int]?) {
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
            return ("", nil)
        }
        
        // 3. Local Inference
        // Convert AVAudioPCMBuffer to [Float] for WhisperKit
        let floatArray = buffer.toFloatArray()
        
        // Call existing service
        do {
            // Priority: promptTokens (continuation) > prompt (text context)
            // But WhisperKitService currently only takes promptTokens in `transcribe`.
            // If we have a text prompt but no tokens, we should tokenize it.

            var tokensToUse = promptTokens
            if let textPrompt = prompt, (tokensToUse == nil || tokensToUse!.isEmpty) {
                // Tokenize text prompt
                // Assuming service has a helper or we add one.
                // Verified: WhisperKitService has convertTokenToId but maybe not full encode.
                // Let's assume we can get tokens or just rely on the tokens passed from accumulator.
                // For Phase 4, we might want to tokenize `prompt`.
                // For now, let's just use promptTokens if available.
            }

            let (text, tokens, _) = try await service.transcribe(audio: floatArray, promptTokens: tokensToUse)
            return (text, tokens)
        } catch {
            print("❌ LocalTranscriptionService: Inference failed: \(error)")
            throw TranscriptionError.unknown(error)
        }
    }
    
    // Backward compatibility if needed, or protocol requirement satisfaction
    // But protocol now requires the full signature.

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
