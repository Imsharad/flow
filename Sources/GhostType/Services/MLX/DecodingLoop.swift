import Foundation
import MLX
import MLXRandom

// MARK: - Decoding Logic (Greedy Search)

/// Decodes audio features into text tokens using the Whisper Model
class WhisperDecoder {
    let model: WhisperModel
    
    init(model: WhisperModel) {
        self.model = model
    }
    
    /// Runs the decoding loop (Greedy)
    func decode(audioFeatures: MLXArray, initialTokens: [Int]) -> [Int] {
        // 1. Run Audio Encoder
        // Shape: [1, n_audio_ctx, n_state]
        let encodedAudio = model.encoder(audioFeatures)
        
        // 2. Initialize Decoder Inputs
        // Use provided initial tokens [SOT, EN, TRANSCRIBE, NO_TIMESTAMPS]
        var tokens = initialTokens
        
        // 3. Decoding Loop
        let maxTokens = 448 // Standard Whisper limit
        
        for _ in 0..<maxTokens {
            let tokenTensor = MLXArray(tokens).expandedDimensions(axis: 0) // [1, seq_len]
            
            // Forward Pass Decoder
            // Note: In optimized impl, we use KV-Cache to avoid re-computing past tokens
            
            // CAUSAL MASKING: Ensure decoder only attends to past tokens
            // Mask shape: [1, 1, seq_len, seq_len]
            // We need a mask for the current sequence length.
            let seqLen = tokens.count
            // MLX MultiHeadAttention adds mask to scores.
            // We want 0 for attended, -inf for masked.
            // Standard causal mask: Upper triangular (excluding diag) is -inf.
            // MLX.TriangleMask makes upper triangular 1s?
            // Let's implement manually for safety:
            // mask[i, j] = 0 if j <= i else -inf
            
            // Create a mask of shape [seqLen, seqLen]
            // Since we are greedy, seqLen grows.
            // We can just create a mask for 'tokens.count'
            
            // Simple explicit mask creation:
            // 1. Create indices
            let indices = MLXArray(0..<seqLen)
            let rowIndices = indices.expandedDimensions(axis: 1) // [L, 1]
            let colIndices = indices.expandedDimensions(axis: 0) // [1, L]
            
            // 2. Compare: mask is where col > row
            let maskBool = MLX.greater(colIndices, rowIndices)
            
            // 3. Convert to float mask: 0 or -1e9
            var attentionMask = MLX.where(maskBool, MLXArray(-1e9), MLXArray(0.0))
            
            // 4. Reshape to [1, 1, L, L] for broadcasting over [B, H, L, S]
            // Use encodedAudio.dtype for compatibility
            attentionMask = attentionMask.reshaped([1, 1, seqLen, seqLen]).asType(encodedAudio.dtype)
            
            let logits = model.decoder(tokenTensor, xa: encodedAudio, mask: attentionMask)
            
            // Get last token logits: [1, seq_len, vocab] -> [1, 1, vocab]
            let lastTokenLogits = logits[-1, axis: 1]
            
            // Greedy: Argmax
            let nextToken = argMax(lastTokenLogits, axis: -1).item(Int.self)
            
            tokens.append(nextToken)
            
            // Check for EOS (50257) or EOT
            if nextToken == 50257 {
                break
            }
        }
        
        return tokens
    }
}

// Helper for argmax on MLXArray to Int
func argMax(_ x: MLXArray, axis: Int = -1) -> MLXArray {
    return MLX.argMax(x, axis: axis) // Use global function
}
