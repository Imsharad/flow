import Foundation
import WhisperKit

actor WhisperKitService {
    private var whisperKit: WhisperKit?
    private var isModelLoaded = false
    private let modelName = "distil-whisper_distil-large-v3" // Balanced Speed/Accuracy
    
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
    /// - Parameter promptTokens: Optional tokens from previous segment to provide context.
    /// - Returns: A tuple containing the transcribed text and the token IDs.
    func transcribe(audio: [Float], promptTokens: [Int]? = nil) async throws -> (text: String, tokens: [Int], segments: [Segment]) {
        guard let pipeline = whisperKit, isModelLoaded else {
            print("⚠️ WhisperKitService: Model not loaded yet")
            return ("Loading Model...", [], [])
        }
        
        print("🤖 WhisperKitService: Transcribing \(audio.count) samples (Prompt: \(promptTokens?.count ?? 0) tokens)...")
        let start = Date()
        
        // Tuning: Suppress hallucinations and timestamps for cleaner text
        let decodingOptions = DecodingOptions(
            verbose: true,
            task: .transcribe,
            language: "en", // Force English for now to avoid auto-detect errors on short clips
            temperature: 0.0, // Greedy decoding for stability
            temperatureFallbackCount: 0, // Fail fast on Turbo
            skipSpecialTokens: true,
            withoutTimestamps: false, // OFF: We need timestamps for Consensus
            wordTimestamps: true, // ON: We need word-level precision
            promptTokens: promptTokens, // Context carryover
            compressionRatioThreshold: 2.4, // Default
            logProbThreshold: -1.0, // Default
            noSpeechThreshold: 0.4 // Aggressive silence detection
        )
        
        let result = try await pipeline.transcribe(audioArray: audio, decodeOptions: decodingOptions)
        
        let duration = Date().timeIntervalSince(start)
        print("✅ WhisperKitService: Transcription complete in \(String(format: "%.2f", duration))s")
        
        // Combine segments and clean up artifacts
        let text = result.map { $0.text }.joined(separator: " ").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        
        // Collect all tokens from all segments
        let tokens = result.flatMap { $0.segments }.flatMap { $0.tokens }
        
        // Map to internal Segment struct
        let segments = result.flatMap { $0.segments }.flatMap { segment in
            let words = segment.words ?? []
            return words.map { word in
                Segment(
                    word: word.word,
                    startTime: TimeInterval(word.start),
                    endTime: TimeInterval(word.end),
                    probability: word.probability
                )
            }
        }
        
        return (text, tokens, segments)
    }
}
