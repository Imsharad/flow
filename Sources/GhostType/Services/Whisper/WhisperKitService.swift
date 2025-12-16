import Foundation
import WhisperKit

actor WhisperKitService {
    private var whisperKit: WhisperKit?
    private var isModelLoaded = false
    private let modelName = "openai_whisper-large-v3-v20240930_turbo" // Explicit version to match HF repo
    
    init() {
        Task {
            await loadModel()
        }
    }
    
    func loadModel() async {
        print("🤖 WhisperKitService: Loading model \(modelName)...")
        do {
            // Strategy B: Run in detached task to avoid actor/main-thread blocking during CoreML load
            let pipeline = try await Task.detached(priority: .userInitiated) { [modelName] in
                // Strategy A: Compute Unit Pinning (The "Golden Fix")
                // Bypass ANE entirely for large-v3-turbo on M1 Pro
                let computeOptions = ModelComputeOptions(
                    melCompute: .cpuAndGPU,
                    audioEncoderCompute: .cpuAndGPU,
                    textDecoderCompute: .cpuAndGPU,
                    prefillCompute: .cpuOnly
                )
                
                print("🤖 WhisperKitService (Detached): Configured computeOptions = .cpuAndGPU")

                // Initialize WhisperKit with compute options
                // Note: prewarm: true is handled by calling prewarmModels() manually or via init if supported
                let kit = try await WhisperKit(model: modelName, computeOptions: computeOptions)
                
                print("🤖 WhisperKitService (Detached): Prewarming model...")
                try await kit.prewarmModels()
                
                return kit
            }.value
            
            self.whisperKit = pipeline
            self.isModelLoaded = true
            print("✅ WhisperKitService: Model loaded & prewarmed (Detached).")
        } catch {
            print("❌ WhisperKitService: Failed to load model: \(error)")
        }
    }
    
    /// Transcribe a buffer of audio samples.
    /// - Parameter audio: Array of Float samples (16kHz).
    func transcribe(audio: [Float]) async throws -> String {
        guard let pipeline = whisperKit, isModelLoaded else {
            print("⚠️ WhisperKitService: Model not loaded yet")
            return "Loading Model..."
        }
        
        print("🤖 WhisperKitService: Transcribing \(audio.count) samples...")
        let start = Date()
        
        let result = try await pipeline.transcribe(audioArray: audio)
        
        let duration = Date().timeIntervalSince(start)
        print("✅ WhisperKitService: Transcription complete in \(String(format: "%.2f", duration))s")
        
        // Combine segments
        let text = result.map { $0.text }.joined(separator: " ")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
