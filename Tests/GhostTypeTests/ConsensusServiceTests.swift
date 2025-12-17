import XCTest
@testable import GhostType

final class ConsensusServiceTests: XCTestCase {
    
    func testStabilityPromotion() async {
        let service = ConsensusService()
        
        // Window 1: "Ghost type" (Time 0.0 - 1.0)
        // Hyp: [Ghost (0.0-0.5), type (0.5-1.0)]
        let segments1 = [
            Segment(word: "Ghost", startTime: 0.0, endTime: 0.5, probability: 0.9),
            Segment(word: " type", startTime: 0.5, endTime: 1.0, probability: 0.9)
        ]
        
        // Stability Threshold is 2 (defined in ConsensusService).
        // If count > 2, commit prefix.
        // Here count is 2. So all should be hypothesis.
        let result1 = await service.onNewHypothesis(segments1)
        XCTAssertEqual(result1.committed, "")
        XCTAssertEqual(result1.hypothesis, "Ghost type")
        
        // Window 2: "Ghost type app" (Time 0.0 - 1.5)
        // Overlap!
        // Hyp: [Ghost, type, app] (Count 3)
        // Should commit (3 - 2 = 1) -> "Ghost"
        let segments2 = [
            Segment(word: "Ghost", startTime: 0.0, endTime: 0.5, probability: 0.95), // Improved prob
            Segment(word: " type", startTime: 0.5, endTime: 1.0, probability: 0.95),
            Segment(word: " app", startTime: 1.0, endTime: 1.5, probability: 0.8)
        ]
        
        let result2 = await service.onNewHypothesis(segments2)
        XCTAssertEqual(result2.committed, "Ghost")
        XCTAssertEqual(result2.hypothesis, " type app") // Remaining tail
        
        // Window 3: "Ghost type application" (Time 0.0 - 2.0)
        // Hyp: [Ghost, type, application]
        // Filter: "Ghost" is already committed (endTime 0.5).
        // Filtered Input: [type, application]
        // Count 2. Threshold 2. No new commit.
        let segments3 = [
            Segment(word: "Ghost", startTime: 0.0, endTime: 0.5, probability: 0.99),
            Segment(word: " type", startTime: 0.5, endTime: 1.0, probability: 0.99),
            Segment(word: " application", startTime: 1.5, endTime: 2.0, probability: 0.9)
        ]
        
        let result3 = await service.onNewHypothesis(segments3)
        // Committed accumulated: "Ghost"
        // Hypothesis: " type application"
        XCTAssertEqual(result3.committed, "Ghost") // No *new* commit yet
        XCTAssertEqual(result3.hypothesis, " type application")
        
        // Window 4: "Ghost type application today"
        // Filtered Input: [type, application, today] (Count 3)
        // Commit 1 (type).
        let segments4 = [
             Segment(word: "Ghost", startTime: 0.0, endTime: 0.5, probability: 0.99),
             Segment(word: " type", startTime: 0.5, endTime: 1.0, probability: 0.99),
             Segment(word: " application", startTime: 1.5, endTime: 2.0, probability: 0.9),
             Segment(word: " today", startTime: 2.0, endTime: 2.5, probability: 0.7)
        ]
        
        let result4 = await service.onNewHypothesis(segments4)
        XCTAssertEqual(result4.committed, "Ghost type")
        XCTAssertEqual(result4.hypothesis, " application today")
    }
}
