import Foundation

/// Service responsible for aligning overlapping transcription segments and determining 
/// which parts of the text are stable enough to "commit" to the final transcript.
actor ConsensusService: ConsensusServiceProtocol {
    
    // MARK: - State
    
    /// The definitive history of committed segments.
    private var committedSegments: [Segment] = []
    
    /// The timestamp of the last committed word end. 
    /// Used to filter out hypothesis segments that are older than our committed history.
    private var lastCommittedTimestamp: TimeInterval = 0.0
    
    /// Cached segments from the last hypothesis, used for flushing the tail.
    private var lastValidSegments: [Segment] = []
    
    // MARK: - Configuration
    
    /// Maximum time difference (seconds) to consider two segments as "matching".
    private let timestampTolerance: TimeInterval = 0.2
    
    /// Number of consecutive matching segments required to trigger a commit.
    /// Higher = more stable but higher latency. Lower = faster but risk of jitter.
    private let stabilityThreshold: Int = 2
    
    // MARK: - Public API
    
    /// Process a new hypothesis from the inference engine.
    /// - Parameter segments: The sequence of word segments returned by Whisper.
    /// - Returns: A tuple of (committed text, volatile hypothesis text).
    func onNewHypothesis(_ segments: [Segment]) -> (committed: String, hypothesis: String) {
        
        // 1. Filter: Ignore segments that are entirely before our last commit.
        // This handles the "overlap" logic naturally.
        let validSegments = segments.filter { $0.endTime > lastCommittedTimestamp }
        self.lastValidSegments = validSegments
        
        // 2. Alignment / Stability Check
        // Ideally we would use previous hypothesis to check for stability over *time*.
        // For V1, we will implement a "Greedy Forward Commit" strategy based on the
        // overlapping window assumption that text *far enough behind the live edge* is stable.
        
        // However, the "Correct" architecture uses Consensus between Previous and Current windows.
        // Since we don't have the *previous* hypothesis stored here yet, let's refine the logic.
        // We will trust the Whisper output's timestamps.
        
        // NOTE: A robust implementation requires diffing against previous frames.
        // For this iteration, we will use a simpler "Age" heuristic combined with the fact
        // that the loop in DictationEngine provides overlapping audio.
        
        // We need to return the FULL text: Committed + New Valid segments.
        // But we want to UPDATE committedSegments if we find "safe" words.
        
        // Heuristic: If we have > N segments, commit the first (Count - N) segments.
        // This assumes that the "tail" is volatile but the "head" of the hypothesis (oldest time)
        // has settled because it's further from the live audio edge.
        
        var newCommitted: [Segment] = []
        var displayHypothesis: [Segment] = []
        
        if validSegments.count > stabilityThreshold {
            // Commit everything except the last N (volatile) segments
            let splitIndex = validSegments.count - stabilityThreshold
            newCommitted = Array(validSegments.prefix(splitIndex))
            displayHypothesis = Array(validSegments.suffix(stabilityThreshold))
            
            // Update state
            for seg in newCommitted {
                // Double check timestamp monotonicity to prevent glitches
                if seg.startTime >= lastCommittedTimestamp {
                    committedSegments.append(seg)
                    lastCommittedTimestamp = seg.endTime
                }
            }
        } else {
            // Not enough segments to verify stability, treat all as hypothesis
            displayHypothesis = validSegments
        }
        
        // 3. Format Output
        let committedString = committedSegments.map { $0.word }.joined(separator: "")
        let hypothesisString = displayHypothesis.map { $0.word }.joined(separator: "")
        
        return (committedString, hypothesisString)
    }
    
    /// Forcefully commits any remaining valid hypothesis segments.
    /// Call this when the session ends to ensure the "tail" is not lost.
    func flush() -> String {
        // Return whatever is in lastValidSegments that hasn't been committed yet.
        // Since we update lastCommittedTimestamp on commit, we can just filter again.
        let tailSegments = lastValidSegments.filter { $0.endTime > lastCommittedTimestamp }
        
        // Combine history + tail
        let fullCommitted = committedSegments + tailSegments
        let fullText = fullCommitted.map { $0.word }.joined(separator: "")
        
        // Clear state after flush
        reset()
        return fullText
    }
    
    func reset() {
        committedSegments = []
        lastValidSegments = []
        lastCommittedTimestamp = 0.0
    }
}
