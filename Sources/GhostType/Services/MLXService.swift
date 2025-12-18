import Foundation
import MLX
import MLXNN
import MLXRandom
import CoreML

actor MLXService {
    private var isModelLoaded = false
    private var decoder: WhisperDecoder?
    private let whisperKit: WhisperKitService
    
    init(whisperKit: WhisperKitService) {
        self.whisperKit = whisperKit
        Task {
            await loadModel()
        }
    }
    
    func loadModel() async {
        print("🦄 MLXService: Loading model Distil-Large-v3...")
        
        // 1. Define Dimensions for Distil-Large-v3
        // TODO: Load these from config.json
        let dims = ModelDimensions(
            n_mels: 128,       // Distil-Large-v3 uses 128 mels
            n_audio_ctx: 1500,
            n_audio_state: 1280,
            n_audio_head: 20,
            n_audio_layer: 32,
            n_vocab: 51866,    // +1 for extra token? Config says 51866
            n_text_ctx: 448,
            n_text_state: 1280,
            n_text_head: 20,
            n_text_layer: 2    // Distil-Whisper has only 2 decoder layers
        )
        
        let model = WhisperModel(dims: dims)
        // Load weights
        // Load weights
        let resourcesURL = Bundle.main.resourceURL!
        // SwiftPM resources are bundled in GhostType_GhostType.bundle
        let bundleURL = resourcesURL.appendingPathComponent("GhostType_GhostType.bundle")
        let weightsURL = bundleURL
            .appendingPathComponent("mlx-distil-large-v3")
            .appendingPathComponent("weights.safetensors")
            
        print("🦄 DEBUG: Checking weights at: \(weightsURL.path)")
        if FileManager.default.fileExists(atPath: weightsURL.path) {
            do {
                print("🦄 MLXService: Loading weights from \(weightsURL.lastPathComponent)...")
                var weights = try MLX.loadArrays(url: weightsURL)
                
                // Sanitization & Transposition
                var sanitizedWeights: [String: MLXArray] = [:]
                for (key, value) in weights {
                    var newKey = key
                    if key.hasPrefix("model.") {
                        newKey = String(key.dropFirst(6))
                    }
                    
                    // Specific Fix: decoder.positional_embedding
                    if newKey == "decoder.positional_embedding" {
                        newKey = "decoder.positional_embedding.weight"
                    }
                    
                    var tensor = value
                    
                    // TRANSPOSE LOGIC REMOVED
                    // MLX nn.Linear expects weights in [out, in] format, same as PyTorch!
                    // Do NOT transpose.
                    
                    sanitizedWeights[newKey] = tensor
                }
                weights = sanitizedWeights
                
                // Inspect keys for debugging
                if let firstKey = weights.keys.first {
                    print("🦄 Sample Key: \(firstKey)")
                }
                
                // DEBUG: Print ALL keys to identify mismatches
                print("🦄 DEBUG: Weight file contains \(weights.count) keys:")
                let sortedKeys = weights.keys.sorted()
                // Print encoder-specific and embedding keys to find mismatches
                print("🦄 DEBUG: Encoder keys:")
                for key in sortedKeys.filter({ $0.hasPrefix("encoder.") }).prefix(30) {
                    print("🦄   ENCODER: \(key)")
                }
                print("🦄 DEBUG: Decoder/Embedding keys:")
                for key in sortedKeys.filter({ $0.hasPrefix("decoder.") && !$0.contains("blocks") }).prefix(20) {
                    print("🦄   DEC-EMBED: \(key)")
                }
                // Print conv and top-level encoder keys
                print("🦄 DEBUG: Non-block encoder keys (conv, etc):")
                for key in sortedKeys.filter({ $0.hasPrefix("encoder.") && !$0.contains("blocks") }) {
                    print("🦄   ENC-TOP: \(key)")
                }
                if weights.count > 50 {
                    print("🦄   ... and more keys")
                }
                
                // Use unflattened to convert flat dict to NestedDictionary structure
                // Note: ModuleParameters is NestedDictionary<String, MLXArray>
                let parameters = ModuleParameters.unflattened(weights)
                
                try model.update(parameters: parameters, verify: .none)
                print("✅ MLXService: Weights applied successfully.")
            } catch {
                print("❌ MLXService: Failed to load weights: \(error)")
            }
        } else {
            print("❌ MLXService: weights.npz not found at \(weightsURL.path)")
            print("   Please run tools/download_weights.sh and rebuild.")
        }
        
        self.decoder = WhisperDecoder(model: model)
        isModelLoaded = true
        print("🦄 MLXService: Model loaded & Decoder ready.")
        
        // DEBUG: Inspect Weights
        let conv1Weight = model.encoder.conv1.weight
        let mean = conv1Weight.mean().item(Float.self)
        print("🦄 DEBUG: Conv1 Weight Mean: \(mean). Shape: \(conv1Weight.shape)")
        
        // DEBUG: Check Linear Weight Shapes
        // Encoder Block 0 MLP1
        let mlp1Weight = model.encoder.blocks[0].mlp1.weight
        print("🦄 DEBUG: Encoder MLP1 Weight Shape: \(mlp1Weight.shape) (Expect [1280, 5120])")
        
        let qWeight = model.encoder.blocks[0].attn.query.weight
        print("🦄 DEBUG: Encoder Attn Query Weight Shape: \(qWeight.shape)")
        
        // The original `isModelLoaded = true` was already present.
        // The original `print("✅ MLXService: Model loaded & Decoder ready.")` was replaced by the user's provided line.
    }
    
    /// Transcribe a buffer of audio samples using MLX
    /// - Parameter audio: Array of Float samples (16kHz).
    /// - Parameter promptTokens: Optional tokens for context.
    /// - Returns: Tuple of text, tokens, and segments.
    func transcribe(audio: [Float], promptTokens: [Int]? = nil) async throws -> (text: String, tokens: [Int], segments: [Segment]) {
        guard let decoder = decoder, isModelLoaded else {
            print("⚠️ MLXService: Model not loaded yet")
            return ("Loading...", [], [])
        }
        
        let start = Date()
        print("🦄 MLXService: Transcribing \(audio.count) samples...")
        
        // Convert Audio to MLXArray (Spectrogram)
        // Use WhisperKit's FeatureExtractor (CoreML backed) for high-fidelity mels
        // Returns (1, 128, 3000)
        guard let melMultiArray = try await whisperKit.audioToMel(audio) else {
            print("❌ MLXService: Failed to generate Mel Spectrogram")
            return ("Error", [], [])
        }
        
        // Convert MLMultiArray to [Float]
        // SAFE IMPLEMENTATION: Avoids dataPointer crash on non-contiguous arrays
        var melFlat = [Float]()
        melFlat.reserveCapacity(melMultiArray.count)
        
        
        for i in 0..<melMultiArray.count {
            melFlat.append(melMultiArray[i].floatValue)
        }
        
        // DEBUG: Check Mel Statistics
        let minMel = melFlat.min() ?? 0
        let maxMel = melFlat.max() ?? 0
        let meanMel = melFlat.reduce(0, +) / Float(melFlat.count)
        print("🦄 DEBUG: Mel Stats - Min: \(minMel), Max: \(maxMel), Mean: \(meanMel)")
        if minMel < -2.0 || maxMel > 2.0 {
            print("🦄 WARNING: Mel values outside expected range [-1, 1]. Normalization might be missing.")
        }
        
        // Explicitly force Distil-Whisper-Large-v3 shape: [1, 128, 3000]
        let expectedCount = 128 * 3000
        let paddingValue = melFlat.min() ?? -1.0 // Use silence (min value) instead of 0 (noise)
        
        if melFlat.count < expectedCount {
            print("🦄 DEBUG: Padding audio from \(melFlat.count) to \(expectedCount) with \(paddingValue)")
            melFlat.append(contentsOf: repeatElement(paddingValue, count: expectedCount - melFlat.count))
        } else if melFlat.count > expectedCount {
            print("🦄 DEBUG: Truncating audio from \(melFlat.count) to \(expectedCount)")
            melFlat = Array(melFlat.prefix(expectedCount))
        }
        
        let expectedShape = [1, 128, 3000]
        
        var audioFeatures = MLXArray(melFlat).reshaped(expectedShape)
        
        // Transpose: (N, C, L) -> (N, L, C)
        audioFeatures = audioFeatures.transposed(0, 2, 1) 
        
        // DYNAMIC PROMPT GENERATION
        // Use WhisperKit's tokenizer to ensure correct IDs for Distil-Large-v3
        var initialTokens: [Int] = []
        if let tokenizer = whisperKit.tokenizer {
            let sot = tokenizer.convertTokenToId("<|startoftranscript|>") ?? 50258
            let lang = tokenizer.convertTokenToId("<|en|>") ?? 50259
            let task = tokenizer.convertTokenToId("<|transcribe|>") ?? 50359
            let noTimestamps = tokenizer.convertTokenToId("<|notimestamps|>") ?? 50363
            
            initialTokens = [sot, lang, task, noTimestamps]
            // print("🦄 DEBUG: Dynamic Prompt Tokens: \(initialTokens)")
        } else {
            // Fallback
            initialTokens = [50258, 50259, 50359, 50363]
            print("🦄 WARNING: Tokenizer not available, using hardcoded fallback.")
        }
        
        // Pass dynamic tokens to decoder
        let tokens = decoder.decode(audioFeatures: audioFeatures, initialTokens: initialTokens)
        
        let text = await whisperKit.detokenize(tokens: tokens)
        
        // 🦄 Unicorn Stack: Latency Measurement
        let duration = Date().timeIntervalSince(start)
        print("🦄 MLXService: Inference took \(String(format: "%.3f", duration))s")
        print("🦄 MLXService: Text: \"\(text)\"")
        
        // Return dummy segment for now until timestamp estimation is added
        let segment = Segment(word: text, startTime: 0.0, endTime: 1.0, probability: 1.0)
        
        return (text, tokens, [segment])
    }
}
