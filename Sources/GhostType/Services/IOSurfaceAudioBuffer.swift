import Foundation

#if canImport(IOSurface)
import IOSurface
import os.lock

/// IOSurface-backed lock-free ring buffer for zero-copy audio transport.
///
/// Architecture (from PRD research):
/// - Single-Producer Single-Consumer (SPSC) design
/// - Cache-line aligned cursors to prevent false sharing
/// - Memory ordering via OSMemoryBarrier for cross-process safety
///
/// Memory Layout (256-byte header + data):
/// ```
/// Offset 0x00-0x07:  WriteCursor (UInt64, atomic)
/// Offset 0x08-0x7F:  Padding (120 bytes, cache line separation)
/// Offset 0x80-0x87:  ReadCursor (UInt64, atomic)
/// Offset 0x88-0xFF:  Padding (120 bytes)
/// Offset 0x100-End:  Audio Data (Float32 samples, circular)
/// ```
final class IOSurfaceAudioBuffer {
    private let surface: IOSurfaceRef
    private let baseAddress: UnsafeMutableRawPointer
    private let capacity: Int  // Number of Float samples
    
    // Header offsets (cache-line aligned for Apple Silicon)
    private static let writeCursorOffset: Int = 0
    private static let readCursorOffset: Int = 128  // Separate cache line
    private static let headerSize: Int = 256
    
    // Typed pointers into shared memory
    private let writeCursorPtr: UnsafeMutablePointer<UInt64>
    private let readCursorPtr: UnsafeMutablePointer<UInt64>
    private let bufferPtr: UnsafeMutablePointer<Float>
    
    /// Initialize with a new IOSurface allocation
    init?(capacitySamples: Int) {
        self.capacity = capacitySamples
        let dataBytes = capacitySamples * MemoryLayout<Float>.size
        let totalBytes = Self.headerSize + dataBytes

        // IOSurface properties for 1D buffer
        let props: [String: Any] = [
            kIOSurfaceWidth as String: totalBytes,
            kIOSurfaceHeight as String: 1,
            kIOSurfaceBytesPerElement as String: 1,
            kIOSurfaceAllocSize as String: totalBytes,
            // Request CPU-cacheable memory for better performance
            kIOSurfaceCacheMode as String: IOSurfaceMemoryMap.writeCombine.rawValue,
        ]

        guard let created = IOSurfaceCreate(props as CFDictionary) else { return nil }
        self.surface = created
        
        // Lock and get base address
        IOSurfaceLock(surface, [], nil)
        let base = IOSurfaceGetBaseAddress(surface)
        self.baseAddress = base
        
        // Bind typed pointers
        self.writeCursorPtr = (base + Self.writeCursorOffset).bindMemory(to: UInt64.self, capacity: 1)
        self.readCursorPtr = (base + Self.readCursorOffset).bindMemory(to: UInt64.self, capacity: 1)
        self.bufferPtr = (base + Self.headerSize).bindMemory(to: Float.self, capacity: capacitySamples)
        
        // Initialize cursors to 0
        writeCursorPtr.pointee = 0
        readCursorPtr.pointee = 0
        
        // Memory barrier to ensure initialization is visible
        OSMemoryBarrier()
    }
    
    /// Initialize from an existing IOSurface ID (for XPC client)
    init?(surfaceID: UInt32, capacitySamples: Int) {
        guard let surface = IOSurfaceLookup(surfaceID) else { return nil }
        self.surface = surface
        self.capacity = capacitySamples
        
        IOSurfaceLock(surface, [], nil)
        let base = IOSurfaceGetBaseAddress(surface)
        self.baseAddress = base
        
        // Bind typed pointers (same layout as creator)
        self.writeCursorPtr = (base + Self.writeCursorOffset).bindMemory(to: UInt64.self, capacity: 1)
        self.readCursorPtr = (base + Self.readCursorOffset).bindMemory(to: UInt64.self, capacity: 1)
        self.bufferPtr = (base + Self.headerSize).bindMemory(to: Float.self, capacity: capacitySamples)
    }
    
    deinit {
        IOSurfaceUnlock(surface, [], nil)
    }

    /// Exportable identifier to send once to the XPC service.
    var surfaceID: UInt32 {
        IOSurfaceGetID(surface)
    }
    
    /// Total capacity in samples
    var capacitySamples: Int { capacity }
    
    // MARK: - Producer API (Main App writes audio)
    
    /// Write samples to the ring buffer.
    /// Returns the number of samples written (may be less than input if buffer full).
    @discardableResult
    func write(_ samples: [Float]) -> Int {
        guard !samples.isEmpty else { return 0 }
        
        // Load current write cursor (we own it, so relaxed is fine)
        let currentWrite = writeCursorPtr.pointee
        
        // Load read cursor with memory barrier to see latest consumer progress
        OSMemoryBarrier()
        let currentRead = readCursorPtr.pointee
        
        // Calculate available space
        let used = currentWrite - currentRead
        let free = UInt64(capacity) - used
        let toWrite = min(Int(free), samples.count)
        
        guard toWrite > 0 else { return 0 }  // Buffer full
        
        // Write samples with wrap-around
        for i in 0..<toWrite {
            let idx = Int((currentWrite + UInt64(i)) % UInt64(capacity))
            bufferPtr[idx] = samples[i]
        }
        
        // Memory barrier: ensure data writes complete before cursor update
        OSMemoryBarrier()
        
        // Update write cursor
        writeCursorPtr.pointee = currentWrite + UInt64(toWrite)
        
        return toWrite
    }
    
    // MARK: - Consumer API (XPC Service reads audio)
    
    /// Read available samples from the ring buffer.
    /// Returns samples and advances the read cursor.
    func read(maxSamples: Int = .max) -> [Float] {
        // Load current read cursor (we own it)
        let currentRead = readCursorPtr.pointee
        
        // Load write cursor with memory barrier to see latest producer progress
        OSMemoryBarrier()
        let currentWrite = writeCursorPtr.pointee
        
        // Calculate available data
        let available = Int(currentWrite - currentRead)
        let toRead = min(available, maxSamples)
        
        guard toRead > 0 else { return [] }
        
        // Read samples with wrap-around
        var output = [Float]()
        output.reserveCapacity(toRead)
        
        for i in 0..<toRead {
            let idx = Int((currentRead + UInt64(i)) % UInt64(capacity))
            output.append(bufferPtr[idx])
        }
        
        // Memory barrier: ensure reads complete before cursor update
        OSMemoryBarrier()
        
        // Update read cursor
        readCursorPtr.pointee = currentRead + UInt64(toRead)
        
        return output
    }
    
    /// Peek at available samples without advancing the cursor
    func peek(maxSamples: Int = .max) -> [Float] {
        let currentRead = readCursorPtr.pointee
        OSMemoryBarrier()
        let currentWrite = writeCursorPtr.pointee
        
        let available = Int(currentWrite - currentRead)
        let toRead = min(available, maxSamples)
        
        guard toRead > 0 else { return [] }
        
        var output = [Float]()
        output.reserveCapacity(toRead)
        
        for i in 0..<toRead {
            let idx = Int((currentRead + UInt64(i)) % UInt64(capacity))
            output.append(bufferPtr[idx])
        }
        
        return output
    }
    
    /// Number of samples available for reading
    var availableSamples: Int {
        let currentRead = readCursorPtr.pointee
        OSMemoryBarrier()
        let currentWrite = writeCursorPtr.pointee
        return Int(currentWrite - currentRead)
    }
    
    /// Number of samples that can be written
    var freeSamples: Int {
        let currentWrite = writeCursorPtr.pointee
        OSMemoryBarrier()
        let currentRead = readCursorPtr.pointee
        return capacity - Int(currentWrite - currentRead)
    }
    
    /// Total samples written since creation (monotonic counter)
    var totalSamplesWritten: Int64 {
        OSMemoryBarrier()
        return Int64(writeCursorPtr.pointee)
    }
    
    /// Reset cursors to initial state (use with caution in multi-process)
    func reset() {
        writeCursorPtr.pointee = 0
        readCursorPtr.pointee = 0
        OSMemoryBarrier()
    }
}

// MARK: - IOSurface Memory Map Constants

private enum IOSurfaceMemoryMap: UInt32 {
    case defaultCache = 0
    case writeCombine = 1
    case copyback = 2
    case writeThrough = 3
}
#endif
