import Foundation
import WhisperKit
import CoreML

actor WhisperKitService {
    private var whisperKit: WhisperKit?
    private var isModelLoaded = false

    // Dynamic Model Name from UserDefaults
    private var modelName: String {
        return UserDefaults.standard.string(forKey: "selectedModel") ?? "distil-whisper_distil-large-v3"
    }
    
    // 🦄 Unicorn Stack: ANE Enable Flag
    // Re-enabled for Distil-Whisper as it does not trigger the M1 Pro compiler hang
    // ⚠️ UPDATE 2: Still hangs on Distil. Disabling ANE permanently for Large variants on M1 Pro.
    private let useANE = false
    
    init() {
        Task {
            await loadModel()
        }
    }
    
    func loadModel() async {
        let currentModel = self.modelName
        print("🤖 WhisperKitService: Loading model \(currentModel)...")
        print("🧠 WhisperKitService: Compute mode = \(useANE ? "ANE (.all)" : "CPU/GPU (.cpuAndGPU)")")
        
        do {
            // Strategy B: Run in detached task to avoid actor/main-thread blocking during CoreML load
            let pipeline = try await Task.detached(priority: .userInitiated) { [currentModel, useANE] in
                
                // 🦄 Unicorn Stack: ANE compute for lowest latency
                let computeOptions: ModelComputeOptions
                if useANE {
                    computeOptions = ModelComputeOptions(
                        melCompute: .all,
                        audioEncoderCompute: .all,
                        textDecoderCompute: .all,
                        prefillCompute: .all
                    )
                    print("🧠 WhisperKitService (Detached): Configured computeOptions = .all (ANE enabled)")
                } else {
                    computeOptions = ModelComputeOptions(
                        melCompute: .cpuAndGPU,
                        audioEncoderCompute: .cpuAndGPU,
                        textDecoderCompute: .cpuAndGPU,
                        prefillCompute: .cpuOnly
                    )
                    print("🤖 WhisperKitService (Detached): Configured computeOptions = .cpuAndGPU (ANE bypassed)")
                }

                // Initialize WhisperKit with compute options
                // 🦄 Unicorn Stack: Fallback Logic
                let kit: WhisperKit
                do {
                    // Try preferred options first
                    kit = try await WhisperKit(model: currentModel, computeOptions: computeOptions)
                } catch {
                    if useANE {
                        print("⚠️ WhisperKitService: ANE init failed: \(error). Falling back to CPU/GPU.")
                        let fallbackOptions = ModelComputeOptions(
                            melCompute: .cpuAndGPU,
                            audioEncoderCompute: .cpuAndGPU,
                            textDecoderCompute: .cpuAndGPU,
                            prefillCompute: .cpuOnly
                        )
                        kit = try await WhisperKit(model: currentModel, computeOptions: fallbackOptions)
                        print("✅ WhisperKitService: Recovered with CPU/GPU fallback.")
                    } else {
                        // If we weren't trying ANE, it's a real error
                        throw error
                    }
                }
                
                print("🤖 WhisperKitService (Detached): Loading models...")
                try await kit.loadModels()
                
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
            throw TranscriptionError.modelLoadFailed
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
        
        // 🦄 Unicorn Stack: Detailed latency metrics
        let audioDurationSec = Double(audio.count) / 16000.0
        let rtf = duration / audioDurationSec
        let latencyMs = duration * 1000
        
        print("📊 WhisperKitService: Latency Metrics")
        print("   Audio: \(String(format: "%.2f", audioDurationSec))s | E2E: \(String(format: "%.0f", latencyMs))ms | RTF: \(String(format: "%.3f", rtf))x")
        print("   Target: E2E <1000ms, RTF <0.3x | Status: \(latencyMs < 1000 ? "✅ PASS" : "⚠️ ABOVE TARGET")")
        
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
    /// Convert audio samples to Log-Mel Spectrogram using WhisperKit's internal FeatureExtractor.
    /// - Parameter audio: Array of Float samples (16kHz).
    /// - Returns: MLMultiArray of shape [1, 128, 3000] (for Large-v3).
    func audioToMel(_ audio: [Float]) async throws -> MLMultiArray? {
        guard let pipeline = whisperKit, isModelLoaded else {
            print("⚠️ WhisperKitService: Cannot extract features, model not loaded")
            return nil
        }
        
        // 1. Pad/Trim audio to 30s (480,000 samples)
        // FeatureExtractor.windowSamples usually refers to 30s window
        let windowSamples = pipeline.featureExtractor.windowSamples ?? 480_000
        
        // Use AudioProcessor to convert [Float] -> MLMultiArray with padding
        guard let inputAudio = AudioProcessor.padOrTrimAudio(
            fromArray: audio,
            startAt: 0,
            toLength: windowSamples,
            saveSegment: false
        ) else {
            print("❌ WhisperKitService: Failed to pad/trim audio")
            return nil
        }
        
        // 2. Run CoreML FeatureExtractor
        // This returns (1, 128, 3000) for distil-large-v3
        let mel = try await pipeline.featureExtractor.logMelSpectrogram(fromAudio: inputAudio)
        return mel as? MLMultiArray
    }
    
    func convertTokenToId(_ token: String) async -> Int? {
        return whisperKit?.tokenizer?.convertTokenToId(token)
    }
    
    /// Encodes text into token IDs using WhisperKit's tokenizer.
    func encode(text: String) async -> [Int]? {
        guard let tokenizer = whisperKit?.tokenizer else {
            return nil
        }
        return tokenizer.encode(text: text)
    }

    /// Convert token IDs back to text using WhisperKit's tokenizer.
    func detokenize(tokens: [Int]) async -> String {
        guard let tokenizer = whisperKit?.tokenizer else {
            return ""
        }
        return tokenizer.decode(tokens: tokens)
    }
}
