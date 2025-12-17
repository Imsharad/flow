import XCTest
@testable import GhostType

final class GhostTypeTests: XCTestCase {
    func testExample() throws {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct
        // results.
    }
    
/*
    func testMLXModelLoading() async throws {
        print("🧪 Testing MLX Model Loading...")
        let cwd = FileManager.default.currentDirectoryPath
        let modelPath = cwd + "/models/whisper-turbo"
        
        let service = MLXService(modelDir: modelPath)
        
        do {
            try await service.loadModel()
            print("✅ Model loaded successfully in test.")
        } catch {
            XCTFail("Failed to load model: \(error)")
        }
    }
    */
}
