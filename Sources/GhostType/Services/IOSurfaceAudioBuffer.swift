import Foundation

#if canImport(IOSurface)
import IOSurface

/// IOSurface-backed audio buffer (PRD transport layer).
///
/// This is a scaffold; the cross-process synchronization protocol (header layout
/// + atomics) will be finalized when the XPC service target is added.
final class IOSurfaceAudioBuffer {
    private let surface: IOSurfaceRef

    init?(capacitySamples: Int) {
        let bytesPerElement = MemoryLayout<Float>.size
        let totalBytes = max(1, capacitySamples) * bytesPerElement

        // IOSurface requires width/height; we treat it as a 1D byte buffer.
        let props: [String: Any] = [
            kIOSurfaceWidth as String: totalBytes,
            kIOSurfaceHeight as String: 1,
            kIOSurfaceBytesPerElement as String: 1,
            kIOSurfaceAllocSize as String: totalBytes,
        ]

        guard let created = IOSurfaceCreate(props as CFDictionary) else { return nil }
        self.surface = created
    }

    /// Exportable identifier to send once to the XPC service.
    var surfaceID: UInt32 {
        IOSurfaceGetID(surface)
    }

    /// Maps the IOSurface base address.
    func withUnsafeMutableBytes<T>(_ body: (UnsafeMutableRawPointer, Int) throws -> T) rethrows -> T {
        IOSurfaceLock(surface, [], nil)
        defer { IOSurfaceUnlock(surface, [], nil) }

        let base = IOSurfaceGetBaseAddress(surface)
        let size = IOSurfaceGetAllocSize(surface)
        return try body(base, size)
    }
}
#endif
