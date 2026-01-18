import Foundation

/// Accumulates transcription results from chunked streaming.
class TranscriptionAccumulator {
    private var segments: [String] = []
    private var lastTokens: [Int] = []
    
    // Limits the context window for tokens to avoid overflowing the model
    private let maxContextTokens = 224 // Standard Whisper prompt limit
    
    var fullText: String {
        return segments.joined(separator: " ")
    }

    var contextTokens: [Int] {
        return lastTokens
    }

    func commit(text: String, tokens: [Int]?) {
        guard !text.isEmpty else { return }
        segments.append(text)
        
        if let newTokens = tokens {
            // Append and trim
            let combined = lastTokens + newTokens
            if combined.count > maxContextTokens {
                lastTokens = Array(combined.suffix(maxContextTokens))
            } else {
                lastTokens = combined
            }
        }
    }
    
    func clear() {
        segments.removeAll()
        lastTokens.removeAll()
    }
}
