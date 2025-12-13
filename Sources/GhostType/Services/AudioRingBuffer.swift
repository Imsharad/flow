import Foundation

/// A simple thread-safe circular buffer for 16kHz mono Float PCM.
///
/// This is a stepping stone toward the PRD's IOSurface-backed shared buffer.
final class AudioRingBuffer {
    private let capacitySamples: Int
    private var storage: [Float]
    private var writeIndex: Int = 0
    private var totalWritten: Int64 = 0
    private let lock = NSLock()

    init(capacitySamples: Int) {
        self.capacitySamples = max(1, capacitySamples)
        self.storage = Array(repeating: 0, count: self.capacitySamples)
    }

    var totalSamplesWritten: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return totalWritten
    }

    /// Writes samples into the ring, overwriting oldest data when full.
    func write(_ samples: [Float]) {
        guard !samples.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        storage.withUnsafeMutableBufferPointer { dest in
            samples.withUnsafeBufferPointer { src in
                guard let destBase = dest.baseAddress, let srcBase = src.baseAddress else { return }
                var offset = 0

                while offset < samples.count {
                    let spaceToEnd = capacitySamples - writeIndex
                    let chunk = min(spaceToEnd, samples.count - offset)

                    destBase.advanced(by: writeIndex).assign(from: srcBase.advanced(by: offset), count: chunk)
                    writeIndex = (writeIndex + chunk) % capacitySamples
                    totalWritten += Int64(chunk)
                    offset += chunk
                }
            }
        }
    }

    /// Returns a copy of samples in the half-open interval [start, end), where indices are absolute sample indices.
    ///
    /// If the requested range is older than the buffer capacity, it clamps to the oldest available sample.
    func snapshot(from start: Int64, to end: Int64) -> [Float] {
        lock.lock()
        defer { lock.unlock() }

        let availableStart = max(Int64(0), totalWritten - Int64(capacitySamples))
        let clampedStart = max(start, availableStart)
        let clampedEnd = min(end, totalWritten)

        guard clampedEnd > clampedStart else { return [] }

        let length = Int(clampedEnd - clampedStart)
        var out = Array(repeating: Float(0), count: length)

        let startIndex = indexForAbsoluteSample(clampedStart)

        out.withUnsafeMutableBufferPointer { outBuf in
            storage.withUnsafeBufferPointer { storageBuf in
                guard let outBase = outBuf.baseAddress, let storageBase = storageBuf.baseAddress else { return }

                var remaining = length
                var outOffset = 0
                var srcIndex = startIndex

                while remaining > 0 {
                    let chunk = min(remaining, capacitySamples - srcIndex)
                    outBase.advanced(by: outOffset).assign(from: storageBase.advanced(by: srcIndex), count: chunk)

                    remaining -= chunk
                    outOffset += chunk
                    srcIndex = (srcIndex + chunk) % capacitySamples
                }
            }
        }

        return out
    }

    private func indexForAbsoluteSample(_ absolute: Int64) -> Int {
        // `totalWritten` corresponds to `writeIndex` (the next write position).
        // Map absolute sample index -> ring index.
        let distanceFromEnd = Int(totalWritten - absolute) // absolute is <= totalWritten
        var idx = writeIndex - distanceFromEnd
        idx %= capacitySamples
        if idx < 0 { idx += capacitySamples }
        return idx
    }
}
