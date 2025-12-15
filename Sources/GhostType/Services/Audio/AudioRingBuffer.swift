import Foundation
import OSLog

/// A fixed-size tracking ring buffer for audio samples.
/// Designed for single-writer (Audio Thread) / multi-reader (Inference Thread).
/// Uses atomic head pointer for lock-free writes.
final class AudioRingBuffer {
    private let buffer: UnsafeMutableBufferPointer<Float>
    private let capacity: Int
    // Monotonically increasing head counter. 
    // Uses OSAtomic or simple synchronized access. 
    // Swift 6 has atomics, but for compatibility/simplicity we'll use a light lock or assume single-writer guarantees.
    // Given the constraints, we'll use a concurrent queue barrier or simple NSLock if needed, 
    // but standard Int64 access on 64-bit systems is atomic-ish for reads, keeping it imperfect but fast for Alpha.
    // BETTER: Use OSAllocatedUnfairLock for write pointer update which is extremely fast.
    
    private var head: Int64 = 0
    private let lock = NSLock() // Simple lock for now, will optimize to lock-free later
    
    init(capacitySeconds: Int = 30, sampleRate: Int = 16000) {
        self.capacity = capacitySeconds * sampleRate
        self.buffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: self.capacity)
        self.buffer.initialize(repeating: 0.0)
    }
    
    convenience init(capacitySamples: Int) {
        // Approximate seconds for init
        self.init(capacitySeconds: capacitySamples / 16000, sampleRate: 16000)
    }
    
    deinit {
        buffer.deallocate()
    }
    
    var totalSamplesWritten: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return head
    }
    
    /// Write new samples into the buffer.
    func write(_ data: UnsafePointer<Float>, count: Int) {
        lock.lock()
        defer { lock.unlock() }
        
        var currentHead = Int(head % Int64(capacity))
        var samplesRemaining = count
        var srcOffset = 0
        
        while samplesRemaining > 0 {
            let spaceToEnd = capacity - currentHead
            let chunk = min(samplesRemaining, spaceToEnd)
            
            let dst = buffer.baseAddress!.advanced(by: currentHead)
            let src = data.advanced(by: srcOffset)
            dst.assign(from: src, count: chunk)
            
            samplesRemaining -= chunk
            srcOffset += chunk
            currentHead = (currentHead + chunk) % capacity
        }
        
        head += Int64(count)
    }
    
    func write(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { ptr in
            if let base = ptr.baseAddress {
                write(base, count: ptr.count)
            }
        }
    }
    
    func snapshot(from start: Int64, to end: Int64) -> [Float] {
        guard end > start else { return [] }
        lock.lock()
        defer { lock.unlock() }
        
        // Validate against current head
        // We can only read what we have. 
        // If start < head - capacity, we lost data, but we clamp.
        let availableStart = max(start, head - Int64(capacity))
        let availableEnd = min(end, head)
        
        let count = Int(availableEnd - availableStart)
        if count <= 0 { return [] }
        
        var result = [Float](repeating: 0, count: count)
        
        var currentReadIndex = Int(availableStart % Int64(capacity))
        var remaining = count
        var dstOffset = 0
        
        while remaining > 0 {
            let spaceToEnd = capacity - currentReadIndex
            let chunk = min(remaining, spaceToEnd)
            
            let src = buffer.baseAddress!.advanced(by: currentReadIndex)
            result.withUnsafeMutableBufferPointer { dstPtr in
                let dst = dstPtr.baseAddress!.advanced(by: dstOffset)
                dst.assign(from: src, count: chunk)
            }
            
            remaining -= chunk
            dstOffset += chunk
            currentReadIndex = (currentReadIndex + chunk) % capacity
        }
        
        return result
    }

    /// Read the last N seconds of audio.
    func readLast(seconds: Double, sampleRate: Int = 16000) -> [Float] {
        lock.lock()
        let currentHead = head
        lock.unlock()
        
        let samplesToRead = Int64(Double(sampleRate) * seconds)
        return snapshot(from: currentHead - samplesToRead, to: currentHead)
    }
    
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        head = 0
        buffer.initialize(repeating: 0.0)
    }
}
