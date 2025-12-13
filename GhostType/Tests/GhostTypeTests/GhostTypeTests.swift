import XCTest
@testable import GhostType

final class GhostTypeTests: XCTestCase {
    func testUtilsFormatting() throws {
        let text = "hello world"
        let formatted = Utils.formatText(text)
        XCTAssertEqual(formatted, "Hello world.")
    }

    func testVADLogic() throws {
        let vad = VADService()
        // Mock buffer with high energy
        let highEnergyBuffer = [Float](repeating: 1.0, count: 1024)
        // vad.didCaptureBuffer(highEnergyBuffer)
        // Assert state logic if accessible
    }
}
