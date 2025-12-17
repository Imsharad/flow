import Foundation
import CoreML

/// T5-Small grammar correction using CoreML.
///
/// Architecture notes (from PRD):
/// - Uses T5Small.mlpackage for text-to-text grammar correction
/// - Prepends "grammar: " prefix to input text per T5 convention
/// - Greedy decoding with max 128 output tokens
/// - Target <50ms latency for short sentences on Neural Engine
final class TextCorrector: TextCorrectorProtocol {
    private var model: MLModel?
    private let formatter = TextFormatter()
    private var isMockMode = false
    private let bundle: Bundle
    
    // Tokenizer state (loaded from t5_vocab.json)
    private var vocab: [String: Int] = [:]
    private var idToToken: [Int: String] = [:]
    private var padTokenId: Int = 0
    private var eosTokenId: Int = 1
    private var unkTokenId: Int = 2
    private var decoderStartTokenId: Int = 0
    
    // Generation config
    private let maxOutputTokens = 128
    private let grammarPrefix = "grammar: "
    
    // Warm-up state
    private var isWarmedUp = false
    
    init(resourceBundle: Bundle) {
        self.bundle = resourceBundle
        // Re-enable T5 model
        // TEMPORARY: Disable T5 model due to segfault on macOS 26.2
        // TODO: Investigate and fix CoreML crash
        // print("TextCorrector: T5 model disabled (using TextFormatter fallback)")
        // isMockMode = true
        // return

        // Load tokenizer vocabulary
        loadVocabulary(bundle: bundle)

        // Load CoreML model
        guard let modelURL = Self.resolveModelURL(bundle: bundle) else {
            print("Warning: T5 CoreML model not found. Falling back to TextFormatter.")
            isMockMode = true
            return
        }

        do {
            // Configure for Neural Engine (ANE) execution
            let config = MLModelConfiguration()
            config.computeUnits = .all  // Allow ANE, GPU, CPU

            self.model = try MLModel(contentsOf: modelURL, configuration: config)
            print("T5Small CoreML model loaded successfully")
        } catch {
            print("Warning: Failed to load T5 CoreML model: \(error). Falling back to TextFormatter.")
            isMockMode = true
        }
    }
    
    // MARK: - Warm-up API
    
    /// Perform a warm-up inference to reduce first-run latency.
    /// Call this at app launch in background thread.
    func warmUp(completion: (() -> Void)? = nil) {
        guard !isMockMode, !isWarmedUp else {
            completion?()
            return
        }
        
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self = self else { return }
            
            let startTime = CFAbsoluteTimeGetCurrent()
            
            // Run a minimal inference to warm up the model pipeline
            // This compiles shaders, allocates buffers, etc.
            let _ = self.correct(text: "hello", context: nil)
            
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            self.isWarmedUp = true
            
            print("T5 model warmed up in \(String(format: "%.2f", elapsed * 1000))ms")
            
            DispatchQueue.main.async {
                completion?()
            }
        }
    }
    
    // MARK: - Main API
    
    /// Correct grammar in the given text using T5 model
    /// - Parameters:
    ///   - text: Raw transcription text to correct
    ///   - context: Optional context (currently unused, reserved for future)
    /// - Returns: Grammar-corrected text
    func correct(text: String, context: String?) -> String {
        // Skip empty or very short input
        guard !text.isEmpty else { return text }
        
        // Fall back to simple formatting if model not available
        guard !isMockMode, model != nil else {
            return formatter.format(text: text, context: context)
        }
        
        // Prepare input with grammar prefix
        let inputText = grammarPrefix + text
        
        // Tokenize input
        let inputIds = tokenize(inputText)
        guard !inputIds.isEmpty else {
            return formatter.format(text: text, context: context)
        }
        
        // Run greedy decoding
        let outputIds = generateGreedy(inputIds: inputIds)
        
        // Decode output tokens to text
        let correctedText = detokenize(outputIds)
        
        // Return corrected text, or fallback if generation failed
        return correctedText.isEmpty ? formatter.format(text: text, context: context) : correctedText
    }
    
    // MARK: - Tokenization (SentencePiece-style)
    
    private func loadVocabulary(bundle: Bundle) {
        guard let vocabURL = bundle.url(forResource: "t5_vocab", withExtension: "json") else {
            print("Warning: t5_vocab.json not found")
            return
        }
        
        do {
            let data = try Data(contentsOf: vocabURL)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                print("Warning: Invalid t5_vocab.json format")
                return
            }
            
            // Load vocab: token -> id
            if let vocabDict = json["vocab"] as? [String: Int] {
                self.vocab = vocabDict
            }
            
            // Load id_to_token: id -> token (stored as string keys in JSON)
            if let idToTokenDict = json["id_to_token"] as? [String: String] {
                for (idStr, token) in idToTokenDict {
                    if let id = Int(idStr) {
                        self.idToToken[id] = token
                    }
                }
            }
            
            // Load special tokens
            if let specialTokens = json["special_tokens"] as? [String: Int] {
                self.padTokenId = specialTokens["pad_token_id"] ?? 0
                self.eosTokenId = specialTokens["eos_token_id"] ?? 1
                self.unkTokenId = specialTokens["unk_token_id"] ?? 2
                self.decoderStartTokenId = specialTokens["decoder_start_token_id"] ?? 0
            }
            
            print("T5 vocabulary loaded: \(vocab.count) tokens")
        } catch {
            print("Warning: Failed to load t5_vocab.json: \(error)")
        }
    }
    
    /// Simple SentencePiece-style tokenization
    /// Note: This is a simplified greedy tokenizer. For production, consider
    /// using a proper SentencePiece implementation.
    private func tokenize(_ text: String) -> [Int] {
        guard !vocab.isEmpty else { return [] }
        
        var tokens: [Int] = []
        var remaining = text
        
        while !remaining.isEmpty {
            var matched = false
            
            // Try to match the longest token from vocab
            // SentencePiece uses "▁" (U+2581) to mark word boundaries
            for length in stride(from: min(remaining.count, 20), through: 1, by: -1) {
                let prefix = String(remaining.prefix(length))
                
                // Try with word boundary marker for word starts
                let withMarker = "▁" + prefix
                if let tokenId = vocab[withMarker], tokens.isEmpty || remaining.first?.isWhitespace == true {
                    tokens.append(tokenId)
                    remaining = String(remaining.dropFirst(length))
                    // Also skip leading whitespace
                    while remaining.first?.isWhitespace == true {
                        remaining = String(remaining.dropFirst())
                    }
                    matched = true
                    break
                }
                
                // Try exact match
                if let tokenId = vocab[prefix] {
                    tokens.append(tokenId)
                    remaining = String(remaining.dropFirst(length))
                    matched = true
                    break
                }
            }
            
            // If no match, use UNK token and skip character
            if !matched {
                tokens.append(unkTokenId)
                remaining = String(remaining.dropFirst())
            }
        }
        
        return tokens
    }
    
    /// Detokenize: convert token IDs back to text
    private func detokenize(_ tokenIds: [Int]) -> String {
        guard !idToToken.isEmpty else { return "" }
        
        var text = ""
        for tokenId in tokenIds {
            // Skip special tokens
            if tokenId == padTokenId || tokenId == eosTokenId {
                continue
            }
            
            if let token = idToToken[tokenId] {
                // Replace SentencePiece word boundary marker with space
                let decoded = token.replacingOccurrences(of: "▁", with: " ")
                text += decoded
            }
        }
        
        return text.trimmingCharacters(in: .whitespaces)
    }
    
    // MARK: - CoreML Inference
    
    /// Greedy decoding: generate tokens one at a time, always picking argmax
    private func generateGreedy(inputIds: [Int]) -> [Int] {
        guard let model = model else { return [] }
        
        // Convert input to MLMultiArray
        guard let inputArray = createMLArray(from: inputIds, dtype: .int32) else {
            return []
        }
        
        // Start with decoder start token
        var generatedIds: [Int] = [decoderStartTokenId]
        
        // Autoregressive generation loop
        for _ in 0..<maxOutputTokens {
            // Create decoder input array
            guard let decoderArray = createMLArray(from: generatedIds, dtype: .int32) else {
                break
            }
            
            // Run model inference
            do {
                let input = T5SmallInput(input_ids: inputArray, decoder_input_ids: decoderArray)
                let output = try model.prediction(from: input)
                
                // Get logits from output
                guard let logitsArray = output.featureValue(for: "logits")?.multiArrayValue else {
                    break
                }
                
                // Get argmax of last position logits
                let nextTokenId = argmax(logitsArray, position: generatedIds.count - 1)
                
                // Check for EOS
                if nextTokenId == eosTokenId {
                    break
                }
                
                generatedIds.append(nextTokenId)
            } catch {
                print("T5 inference error: \(error)")
                break
            }
        }
        
        return generatedIds
    }
    
    /// Create MLMultiArray from Int array
    private func createMLArray(from values: [Int], dtype: MLMultiArrayDataType) -> MLMultiArray? {
        do {
            let array = try MLMultiArray(shape: [1, NSNumber(value: values.count)], dataType: dtype)
            for (i, value) in values.enumerated() {
                array[[0, i] as [NSNumber]] = NSNumber(value: value)
            }
            return array
        } catch {
            print("Failed to create MLMultiArray: \(error)")
            return nil
        }
    }
    
    /// Get argmax from logits at a specific position
    private func argmax(_ logits: MLMultiArray, position: Int) -> Int {
        // logits shape: [1, seq_len, vocab_size]
        let vocabSize = logits.shape[2].intValue
        
        var maxValue: Float = -.infinity
        var maxIndex = 0
        
        for i in 0..<vocabSize {
            let value = logits[[0, position, i] as [NSNumber]].floatValue
            if value > maxValue {
                maxValue = value
                maxIndex = i
            }
        }
        
        return maxIndex
    }
    
    // MARK: - Model Loading
    
    private static func resolveModelURL(bundle: Bundle) -> URL? {
        // Preferred: precompiled model
        if let url = bundle.url(forResource: "T5Small", withExtension: "mlmodelc") {
            return url
        }
        
        // Fallback: compile .mlpackage on first run
        if let packageURL = bundle.url(forResource: "T5Small", withExtension: "mlpackage") {
            do {
                let compiledURL = try MLModel.compileModel(at: packageURL)
                return compiledURL
            } catch {
                print("Failed to compile T5Small.mlpackage: \(error)")
                return nil
            }
        }
        
        return nil
    }
}

// MARK: - CoreML Input Provider

/// Input provider for T5Small model
private class T5SmallInput: MLFeatureProvider {
    let input_ids: MLMultiArray
    let decoder_input_ids: MLMultiArray
    
    var featureNames: Set<String> {
        return ["input_ids", "decoder_input_ids"]
    }
    
    init(input_ids: MLMultiArray, decoder_input_ids: MLMultiArray) {
        self.input_ids = input_ids
        self.decoder_input_ids = decoder_input_ids
    }
    
    func featureValue(for featureName: String) -> MLFeatureValue? {
        switch featureName {
        case "input_ids":
            return MLFeatureValue(multiArray: input_ids)
        case "decoder_input_ids":
            return MLFeatureValue(multiArray: decoder_input_ids)
        default:
            return nil
        }
    }
}
