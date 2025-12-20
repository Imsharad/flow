import Foundation

/// Accumulates partial transcriptions from chunks and manages context for semantic coherence.
actor TranscriptionAccumulator {
    private var segments: [String] = []
    private var lastTokens: [Int] = []
    
    // Config for context carryover
    private let maxContextTokens = 224 // Half of 448 (Whisper window)
    
    func append(text: String, tokens: [Int]?) {
        if !text.isEmpty {
            segments.append(text)
        }
        
        // Update context tokens (keep last N)
        if let tokens = tokens, !tokens.isEmpty {
            let combined = lastTokens + tokens
            if combined.count > maxContextTokens {
                lastTokens = Array(combined.suffix(maxContextTokens))
            } else {
                lastTokens = combined
            }
        }
    }
    
    func getContext() -> [Int] {
        return lastTokens
    }
    
    func getFullText() -> String {
        return segments.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    func reset() {
        segments.removeAll()
        lastTokens.removeAll()
    }
}
