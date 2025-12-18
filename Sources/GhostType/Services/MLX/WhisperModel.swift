import Foundation
import MLX
import MLXNN

// MARK: - Whisper Model Architecture (Distil-Large-v3 Config)

/// Main Whisper Model Container
class WhisperModel: Module {
    let encoder: AudioEncoder
    let decoder: TextDecoder
    
    init(dims: ModelDimensions) {
        self.encoder = AudioEncoder(dims: dims)
        self.decoder = TextDecoder(dims: dims)
        super.init()
    }
    
    /// Forward pass (Note: Whisper usually runs encoder once, then decoder in loop)
    func notify(_ x: MLXArray) -> MLXArray {
        // Placeholder for full forward
        return x
    }
}

struct ModelDimensions: Codable {
    var n_mels: Int
    var n_audio_ctx: Int
    var n_audio_state: Int
    var n_audio_head: Int
    var n_audio_layer: Int
    var n_vocab: Int
    var n_text_ctx: Int
    var n_text_state: Int
    var n_text_head: Int
    var n_text_layer: Int
}

class AudioEncoder: Module {
    let conv1: Conv1d
    let conv2: Conv1d
    let blocks: [EncoderBlock]
    let ln_post: LayerNorm
    
    init(dims: ModelDimensions) {
        self.conv1 = Conv1d(inputChannels: dims.n_mels, outputChannels: dims.n_audio_state, kernelSize: 3, padding: 1)
        self.conv2 = Conv1d(inputChannels: dims.n_audio_state, outputChannels: dims.n_audio_state, kernelSize: 3, stride: 2, padding: 1)
        self.blocks = (0..<dims.n_audio_layer).map { _ in EncoderBlock(dims: dims) }
        self.ln_post = LayerNorm(dimensions: dims.n_audio_state)
        super.init()
    }
    
    
    func callAsFunction(_ x: MLXArray) -> MLXArray {
        print("🦄 DEBUG: AudioEncoder Start input: \(x.shape)")
        var x = gelu(conv1(x))
        print("🦄 DEBUG: AudioEncoder conv1 done: \(x.shape)")
        x = gelu(conv2(x))
        print("🦄 DEBUG: AudioEncoder conv2 done: \(x.shape)")
        
        // Add positional embedding (sinusoidal)
        // Whisper Encoder uses fixed sinusoidal embeddings
        if x.shape[1] > 0 {
             let posEmb = sinusoidal_positional_encoding(length: x.shape[1], dim: x.shape[2])
             print("🦄 DEBUG: PosEmb shape: \(posEmb.shape), dtype: \(posEmb.dtype)")
             print("🦄 DEBUG: x shape: \(x.shape), dtype: \(x.dtype)")
             
             // Ensure broadcast and type match
             // Explicitly expand to [1, L, D] and cast to x.dtype
             let posEmbBroadcast = posEmb.expandedDimensions(axis: 0).asType(x.dtype)
             x = x + posEmbBroadcast
        }
        
        for (i, block) in blocks.enumerated() {
            x = block(x)
            if i == 0 { print("🦄 DEBUG: EncoderBlock 0 done: \(x.shape)") }
        }
        
        return ln_post(x)
    }
}

class EncoderBlock: Module {
    let attn: MultiHeadAttention
    let mlp1: Linear
    let mlp2: Linear
    let attn_ln: LayerNorm
    let mlp_ln: LayerNorm
    
    init(dims: ModelDimensions) {
        self.attn = MultiHeadAttention(dims: dims, n_head: dims.n_audio_head)
        self.mlp1 = Linear(dims.n_audio_state, dims.n_audio_state * 4)
        self.mlp2 = Linear(dims.n_audio_state * 4, dims.n_audio_state)
        self.attn_ln = LayerNorm(dimensions: dims.n_audio_state)
        self.mlp_ln = LayerNorm(dimensions: dims.n_audio_state)
        super.init()
    }
    
    func callAsFunction(_ x: MLXArray, mask: MLXArray? = nil) -> MLXArray {
        var r = x
        r = attn_ln(r)
        r = attn(r, mask: mask)
        var x = x + r
        
        r = x
        r = mlp_ln(r)
        
        let m1 = mlp1(r)
        r = mlp2(gelu(m1))
        
        x = x + r
        return x
    }
}

class TextDecoder: Module {
    let token_embedding: Embedding
    let positional_embedding: Embedding
    let blocks: [DecoderBlock]
    let ln: LayerNorm
    
    init(dims: ModelDimensions) {
        self.token_embedding = Embedding(embeddingCount: dims.n_vocab, dimensions: dims.n_text_state)
        // Learned positional embeddings for Decoder
        self.positional_embedding = Embedding(embeddingCount: dims.n_text_ctx, dimensions: dims.n_text_state)
        
        self.blocks = (0..<dims.n_text_layer).map { _ in DecoderBlock(dims: dims) }
        self.ln = LayerNorm(dimensions: dims.n_text_state)
        super.init()
    }
    
    func callAsFunction(_ x: MLXArray, xa: MLXArray, mask: MLXArray? = nil) -> MLXArray {
        var x = token_embedding(x)
        // Add positional embedding
        let positions = MLXArray(stride(from: 0, to: x.shape[1], by: 1).map { Int($0) })
        x = x + positional_embedding(positions)
        
        for block in blocks {
            x = block(x, xa: xa, mask: mask)
        }
        
        x = ln(x)
        
        // Output Projection (Weight Tying)
        // [Batch, Len, Dim] @ [Dim, Vocab] -> [Batch, Len, Vocab]
        // Use token_embedding.weight transposed
        return matmul(x, token_embedding.weight.transposed())
    }
}

class DecoderBlock: Module {
    let attn: MultiHeadAttention
    let cross_attn: MultiHeadAttention
    let mlp1: Linear
    let mlp2: Linear
    let attn_ln: LayerNorm
    let cross_attn_ln: LayerNorm
    let mlp_ln: LayerNorm
    
    init(dims: ModelDimensions) {
        self.attn = MultiHeadAttention(dims: dims, n_head: dims.n_text_head)
        self.cross_attn = MultiHeadAttention(dims: dims, n_head: dims.n_text_head)
        self.mlp1 = Linear(dims.n_text_state, dims.n_text_state * 4)
        self.mlp2 = Linear(dims.n_text_state * 4, dims.n_text_state)
        
        self.attn_ln = LayerNorm(dimensions: dims.n_text_state)
        self.cross_attn_ln = LayerNorm(dimensions: dims.n_text_state)
        self.mlp_ln = LayerNorm(dimensions: dims.n_text_state)
        super.init()
    }
    
    func callAsFunction(_ x: MLXArray, xa: MLXArray, mask: MLXArray? = nil) -> MLXArray {
        var r = x
        r = attn_ln(r)
        r = attn(r, mask: mask) // Self Attention
        var x = x + r
        
        r = x
        r = cross_attn_ln(r)
        r = cross_attn(query: r, key: xa, value: xa, mask: nil) // Cross Attention
        x = x + r
        
        r = x
        r = mlp_ln(r)
        r = mlp2(gelu(mlp1(r)))
        x = x + r
        
        return x
    }
}

class MultiHeadAttention: Module {
    let n_head: Int
    let query: Linear
    let key: Linear
    let value: Linear
    let out: Linear
    
    init(dims: ModelDimensions, n_head: Int) {
        self.n_head = n_head
        let n_state = dims.n_audio_state // Assuming symmetric for now
        self.query = Linear(n_state, n_state)
        self.key = Linear(n_state, n_state, bias: false)
        self.value = Linear(n_state, n_state)
        self.out = Linear(n_state, n_state)
        super.init()
    }
    
    func callAsFunction(_ x: MLXArray, mask: MLXArray? = nil) -> MLXArray {
        return callAsFunction(query: x, key: x, value: x, mask: mask)
    }
    
    func callAsFunction(query q: MLXArray, key k: MLXArray, value v: MLXArray, mask: MLXArray? = nil) -> MLXArray {
        let q = query(q)
        let k = key(k)
        let v = value(v)

        let B = q.shape[0]
        let L = q.shape[1]
        let dim = q.shape[2]
        let headDim = dim / n_head

        // Flash Attention (Scaled Dot Product)
        // Split heads: (B, L, D) -> (B, L, H, headDim) -> (B, H, L, headDim)
        let q_heads = q.reshaped([B, L, n_head, headDim]).transposed(0, 2, 1, 3)
        let k_heads = k.reshaped([B, k.shape[1], n_head, headDim]).transposed(0, 2, 1, 3)
        let v_heads = v.reshaped([B, v.shape[1], n_head, headDim]).transposed(0, 2, 1, 3)

        // (B, H, L, headDim) @ (B, H, headDim, S) -> (B, H, L, S)
        // Scale by 1/sqrt(headDim)
        let scale = MLXArray(Float(1.0 / sqrt(Double(headDim))))
        var scores = matmul(q_heads, k_heads.transposed(0, 1, 3, 2)) * scale

        if let mask = mask {
            scores = scores + mask
        }

        let weights = softmax(scores, axis: -1)
        let attention = matmul(weights, v_heads)

        // Merge heads: (B, H, L, headDim) -> (B, L, H, headDim) -> (B, L, D)
        let output = attention.transposed(0, 2, 1, 3).reshaped([B, L, dim])
        
        return out(output)
    }
}

class MLP: Module {
    let fc1: Linear
    let fc2: Linear
    
    init(dims: Int, mult: Int = 4) {
        self.fc1 = Linear(dims, dims * mult)
        self.fc2 = Linear(dims * mult, dims)
        super.init()
    }
    
    func callAsFunction(_ x: MLXArray) -> MLXArray {
        return fc2(gelu(fc1(x)))
    }
}

// MARK: - Helpers

func gelu(_ x: MLXArray) -> MLXArray {
    return 0.5 * x * (1 + tanh(sqrt(2 / .pi) * (x + 0.044715 * pow(x, 3))))
}

func sinusoidal_positional_encoding(length: Int, dim: Int) -> MLXArray {
    let halfDim = dim / 2
    let logTimescaleIncrement = log(10000.0) / Double(halfDim - 1)
    let invTimescales = exp(MLXArray(stride(from: 0, to: halfDim, by: 1).map { Float(Double($0) * -logTimescaleIncrement) }))
    
    let arange = MLXArray(stride(from: 0, to: length, by: 1).map { Float($0) })
    // [length, 1] * [1, half_dim] -> [length, half_dim]
    let scaledTime = arange.reshaped([length, 1]) * invTimescales.reshaped([1, halfDim])
    
    let sinEnc = sin(scaledTime)
    let cosEnc = cos(scaledTime)
    
    // Interleave sin and cos: [sin[0], cos[0], sin[1], cos[1]...]
    // Stack along last axis -> [length, half_dim, 2]
    let s = sinEnc.expandedDimensions(axis: -1)
    let c = cosEnc.expandedDimensions(axis: -1)
    let stacked = concatenated([s, c], axis: -1)
    
    // Flatten last two dims -> [length, dim]
    return stacked.reshaped([length, dim])
}
