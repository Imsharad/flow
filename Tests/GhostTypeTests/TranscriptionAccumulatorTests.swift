
import XCTest
@testable import GhostType

final class TranscriptionAccumulatorTests: XCTestCase {
    
    func testAccumulationAndStitching() async {
        let accumulator = TranscriptionAccumulator()
        
        await accumulator.append(text: "Hello", tokens: [1, 2])
        await accumulator.append(text: "world", tokens: [3, 4])
        
        let fullText = await accumulator.getFullText()
        XCTAssertEqual(fullText, "Hello world")
        
        let context = await accumulator.getContext()
        XCTAssertEqual(context, [1, 2, 3, 4])
    }
    
    func testContextWindowOptimization() async {
        let accumulator = TranscriptionAccumulator()
        
        // Feed 300 tokens (simulates overflowing 224 max context)
        let largeTokenSet = Array(0..<300)
        await accumulator.append(text: "LargeChunk", tokens: largeTokenSet)
        
        let context = await accumulator.getContext()
        XCTAssertEqual(context.count, 224)
        
        // It should keep the *last* 224 tokens.
        // Input was 0...299.
        // Expecting 76...299.
        XCTAssertEqual(context.first, 76)
        XCTAssertEqual(context.last, 299)
    }
    
    func testReset() async {
        let accumulator = TranscriptionAccumulator()
        await accumulator.append(text: "Test", tokens: [1])
        
        await accumulator.reset()
        
        let text = await accumulator.getFullText()
        XCTAssertEqual(text, "")
        
        let context = await accumulator.getContext()
        XCTAssertTrue(context.isEmpty)
    }
}
