
import XCTest
@testable import GhostType

final class AudioRingBufferTests: XCTestCase {
    
    func testCircularWriting() {
        let capacitySamples = 100
        let buffer = AudioRingBuffer(capacitySamples: capacitySamples)
        
        // write 80 samples (fill 80%)
        let data1 = [Float](repeating: 1.0, count: 80)
        buffer.write(data1)
        
        XCTAssertEqual(buffer.totalSamplesWritten, 80)
        
        // write 40 more samples (overflow wrap-around by 20)
        let data2 = [Float](repeating: 2.0, count: 40)
        buffer.write(data2)
        
        XCTAssertEqual(buffer.totalSamplesWritten, 120)
        
        // Check content
        // Buffer should contain [20..99] from 1st write (1.0) overridden by 2nd write for indices 0..19 (2.0)
        // But let's check via snapshot
        
        // The buffer capacity is 100.
        // We wrote 120.
        // The first 20 samples (index 0-19) were overwritten.
        // The valid range in the buffer is logically [20, 120).
        // Index 20-79 should be 1.0.
        // Index 80-119 should be 2.0.
        
        let dump = buffer.snapshot(from: 20, to: 120)
        XCTAssertEqual(dump.count, 100)
        
        // First 60 samples of snapshot (logical 20 to 79) should be 1.0
        for i in 0..<60 {
            XCTAssertEqual(dump[i], 1.0, "Mismatch at relative index \(i)")
        }
        
        // Last 40 samples (logical 80 to 119) should be 2.0
        for i in 60..<100 {
            XCTAssertEqual(dump[i], 2.0, "Mismatch at relative index \(i)")
        }
    }
    
    func testSeekingAndSnapshot() {
        let buffer = AudioRingBuffer(capacitySamples: 1000)
        let data = (0..<500).map { Float($0) }
        buffer.write(data)
        
        // Snapshot middle 100
        let segment = buffer.snapshot(from: 200, to: 300)
        XCTAssertEqual(segment.count, 100)
        XCTAssertEqual(segment.first, 200.0)
        XCTAssertEqual(segment.last, 299.0)
    }
    
    func testReadLast() {
        let buffer = AudioRingBuffer(capacitySamples: 16000 * 10) // 10s
        let sampleRate = 16000
        
        // Write 5 seconds of 1s
        let chunk1 = [Float](repeating: 1.0, count: 5 * sampleRate)
        buffer.write(chunk1)
        
        // Write 2 seconds of 2s
        let chunk2 = [Float](repeating: 2.0, count: 2 * sampleRate)
        buffer.write(chunk2)
        
        // Total 7s. Read last 3s.
        // Should be 1s of '1.0' and 2s of '2.0'
        let last3 = buffer.readLast(seconds: 3.0)
        XCTAssertEqual(last3.count, 3 * sampleRate)
        
        let firstPart = last3.prefix(sampleRate) // 1s
        let secondPart = last3.suffix(2 * sampleRate) // 2s
        
        XCTAssertEqual(firstPart.first, 1.0)
        XCTAssertEqual(secondPart.first, 2.0)
    }
}
