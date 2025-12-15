import Foundation
import MLX
import MLXNN
import MLXRandom

public struct WhisperConfig: Codable {
    public let nMels: Int
    public let nAudioCtx: Int
    public let nAudioState: Int
    public let nAudioHead: Int
    public let nAudioLayer: Int
    public let nVocab: Int
    public let nTextCtx: Int
    public let nTextState: Int
    public let nTextHead: Int
    public let nTextLayer: Int // 4 for Turbo
    
    enum CodingKeys: String, CodingKey {
        case nMels = "n_mels"
        case nAudioCtx = "n_audio_ctx"
        case nAudioState = "n_audio_state"
        case nAudioHead = "n_audio_head"
        case nAudioLayer = "n_audio_layer"
        case nVocab = "n_vocab"
        case nTextCtx = "n_text_ctx"
        case nTextState = "n_text_state"
        case nTextHead = "n_text_head"
        case nTextLayer = "n_text_layer"
    }
}

class MultiHeadAttention: Module {
    let query: Linear
    let key: Linear
    let value: Linear
    let out: Linear
    let nHead: Int
    let headDim: Int

    init(_ nState: Int, _ nHead: Int) {
        self.nHead = nHead
        self.headDim = nState / nHead
        self.query = Linear(nState, nState, bias: true)
        self.key = Linear(nState, nState, bias: false)
        self.value = Linear(nState, nState, bias: true)
        self.out = Linear(nState, nState, bias: true)
        super.init()
    }

    func callAsFunction(_ x: MLXArray, xa: MLXArray? = nil, mask: MLXArray? = nil, cache: [MLXArray]? = nil) -> MLXArray {
        let q = query(x)
        let k = key(xa ?? x)
        let v = value(xa ?? x)
        
        let shapeX = x.shape
        let B = shapeX[0]
        let L = shapeX[1]
        
        let shapeK = k.shape
        let S = shapeK[1]
        
        // Reshape for attention
        // [B, L, D] -> [B, L, H, d] -> [B, H, L, d]
        let qs = q.reshaped([B, L, nHead, headDim]).transposed(0, 2, 1, 3)
        let ks = k.reshaped([B, S, nHead, headDim]).transposed(0, 2, 1, 3)
        let vs = v.reshaped([B, S, nHead, headDim]).transposed(0, 2, 1, 3)

        // TODO: KV Cache handling for streaming would go here
        
        // Scaled Dot Product Attention
        var score = matmul(qs, ks.transposed(0, 1, 3, 2)) / sqrt(Float(headDim))
        
        if let mask = mask {
            score = score + mask
        }
        
        let attn = softmax(score, axis: -1)
        let z = matmul(attn, vs)
        
        // [B, H, L, d] -> [B, L, H, d] -> [B, L, D]
        let output = z.transposed(0, 2, 1, 3).reshaped([B, L, nHead * headDim])
        
        return out(output)
    }
}

class ResidualAttentionBlock: Module {
    let attn: MultiHeadAttention
    let ln1: LayerNorm
    let mlp: Sequential
    let ln2: LayerNorm
    let crossAttn: MultiHeadAttention?
    let lnCross: LayerNorm?

    init(_ nState: Int, _ nHead: Int, crossAttention: Bool = false) {
        self.attn = MultiHeadAttention(nState, nHead)
        self.ln1 = LayerNorm(dimensions: nState)
        
        self.mlp = Sequential(layers: [
            Linear(nState, nState * 4),
            GELU(),
            Linear(nState * 4, nState)
        ])
        self.ln2 = LayerNorm(dimensions: nState)
        
        if crossAttention {
            self.crossAttn = MultiHeadAttention(nState, nHead)
            self.lnCross = LayerNorm(dimensions: nState)
        } else {
            self.crossAttn = nil
            self.lnCross = nil
        }
        super.init()
    }

    func callAsFunction(_ x: MLXArray, xa: MLXArray? = nil, mask: MLXArray? = nil) -> MLXArray {
        var x = x + attn(ln1(x), mask: mask)
        
        if let crossAttn = crossAttn, let lnCross = lnCross, let xa = xa {
            x = x + crossAttn(lnCross(x), xa: xa)
        }
        
        x = x + mlp(ln2(x))
        return x
    }
}

class AudioEncoder: Module {
    let conv1: Conv1d
    let conv2: Conv1d
    let blocks: [ResidualAttentionBlock]
    let lnPost: LayerNorm
    let embeddingDim: Int
    
    // Positional embedding is a parameter (learned or sinusoidal loaded from weights)
    let positionEmbedding: MLXArray 

    init(_ config: WhisperConfig) {
        self.embeddingDim = config.nAudioState
        self.conv1 = Conv1d(inputChannels: config.nMels, outputChannels: config.nAudioState, kernelSize: 3, padding: 1)
        self.conv2 = Conv1d(inputChannels: config.nAudioState, outputChannels: config.nAudioState, kernelSize: 3, stride: 2, padding: 1)
        
        var blocks: [ResidualAttentionBlock] = []
        for _ in 0..<config.nAudioLayer {
            blocks.append(ResidualAttentionBlock(config.nAudioState, config.nAudioHead))
        }
        self.blocks = blocks
        self.lnPost = LayerNorm(dimensions: config.nAudioState)
        
        // Placeholder, will be replaced by loaded weights
        self.positionEmbedding = MLXArray.zeros([config.nAudioCtx, config.nAudioState])
        
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var x = gelu(conv1(x))
        x = gelu(conv2(x))
        
        // Add positional embedding (sliced to length)
        let L = x.shape[1]
        x = x + positionEmbedding[0..<L]
        
        for block in blocks {
            x = block(x)
        }
        
        return lnPost(x)
    }
}

class TextDecoder: Module {
    let tokenEmbedding: Embedding
    let positionEmbedding: MLXArray // Loaded parameter
    let blocks: [ResidualAttentionBlock]
    let ln: LayerNorm
    
    init(_ config: WhisperConfig) {
        self.tokenEmbedding = Embedding(embeddingCount: config.nVocab, dimensions: config.nTextState)
        self.positionEmbedding = MLXArray.zeros([config.nTextCtx, config.nTextState])
        
        var blocks: [ResidualAttentionBlock] = []
        for _ in 0..<config.nTextLayer {
            blocks.append(ResidualAttentionBlock(config.nTextState, config.nTextHead, crossAttention: true))
        }
        self.blocks = blocks
        self.ln = LayerNorm(dimensions: config.nTextState)
        super.init()
    }

    func callAsFunction(_ x: MLXArray, xa: MLXArray) -> MLXArray {
        let shape = x.shape
        let B = shape[0]
        let L = shape[1]
        
        var x = tokenEmbedding(x) + positionEmbedding[0..<L]
        
        // Causal Mask (Simplification: using a causal mask if L > 1)
        // Creating a causal mask: Upper triangle is -inf
        // TODO: Implement proper causal mask builder using MLX primitives
        // For Alpha loading test, passing nil is fine if we don't validate output correctness yet
        let mask: MLXArray? = nil 
        
        for block in blocks {
            x = block(x, xa: xa, mask: mask)
        }
        
        return ln(x)
    }
}

public class Whisper: Module {
    let encoder: AudioEncoder
    let decoder: TextDecoder
    let config: WhisperConfig
    
    public init(config: WhisperConfig) {
        self.config = config
        self.encoder = AudioEncoder(config)
        self.decoder = TextDecoder(config)
        super.init()
    }

    public func callAsFunction(audio: MLXArray, tokens: MLXArray) -> MLXArray {
        let enc = encoder(audio)
        let dec = decoder(tokens, xa: enc)
        // Project to vocab - share embedding weights
        let logits = matmul(dec, decoder.tokenEmbedding.weight.T)
        return logits
    }
}
