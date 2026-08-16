import Foundation

struct GPUUInt256 {
    var d0: UInt32 = 0
    var d1: UInt32 = 0
    var d2: UInt32 = 0
    var d3: UInt32 = 0
    var d4: UInt32 = 0
    var d5: UInt32 = 0
    var d6: UInt32 = 0
    var d7: UInt32 = 0

    init() { }

    init(bigEndian bytes: ArraySlice<UInt8>) {
        precondition(bytes.count == 32)
        let value = Array(bytes)
        func limb(_ index: Int) -> UInt32 {
            let start = (7 - index) * 4
            return (UInt32(value[start]) << 24)
                | (UInt32(value[start + 1]) << 16)
                | (UInt32(value[start + 2]) << 8)
                | UInt32(value[start + 3])
        }
        d0 = limb(0)
        d1 = limb(1)
        d2 = limb(2)
        d3 = limb(3)
        d4 = limb(4)
        d5 = limb(5)
        d6 = limb(6)
        d7 = limb(7)
    }
}

struct GPUAffinePoint {
    var x: GPUUInt256
    var y: GPUUInt256

    init(uncompressedPublicKey publicKey: [UInt8]) {
        precondition(publicKey.count == 65 && publicKey[0] == 0x04)
        x = GPUUInt256(bigEndian: publicKey[1...32])
        y = GPUUInt256(bigEndian: publicKey[33...64])
    }
}

/// Splits one random, fixed-generator scalar walk into large, disjoint per-lane
/// regions.
///
/// Lane `n` starts at `(base + n * laneSpan) * G`. A mutable GPU affine-point
/// buffer then advances within that lane's region across many command buffers,
/// so the CPU never has to rebuild every lane between dispatches.
struct MetalEpochIndexLayout: Sendable, Equatable {
    static let defaultLaneSpan: UInt64 = 1 << 40

    let laneCount: Int
    let laneSpan: UInt64

    init(laneCount: Int, laneSpan: UInt64 = Self.defaultLaneSpan) {
        precondition(laneCount > 0)
        precondition(laneSpan > 0)
        self.laneCount = laneCount
        self.laneSpan = laneSpan
    }

    func laneStartIndex(for lane: UInt32) -> UInt64? {
        guard UInt64(lane) < UInt64(laneCount) else { return nil }
        let result = UInt64(lane).multipliedReportingOverflow(by: laneSpan)
        return result.overflow ? nil : result.partialValue
    }

    /// Converts a GPU-only `(lane, local offset)` hit back to the scalar walk
    /// index. `resultOffset` is one-based because the kernel adds `G` before
    /// hashing the first candidate in each dispatch.
    func candidateIndex(
        lane: UInt32,
        dispatchStart: UInt64,
        resultOffset: UInt32
    ) -> UInt64? {
        guard resultOffset > 0,
              dispatchStart < laneSpan,
              let laneStart = laneStartIndex(for: lane) else {
            return nil
        }
        let local = dispatchStart.addingReportingOverflow(UInt64(resultOffset))
        guard !local.overflow, local.partialValue <= laneSpan else { return nil }
        let global = laneStart.addingReportingOverflow(local.partialValue)
        return global.overflow ? nil : global.partialValue
    }

    func canDispatch(from dispatchStart: UInt64, count: UInt32) -> Bool {
        guard count > 0, dispatchStart < laneSpan else { return false }
        let end = dispatchStart.addingReportingOverflow(UInt64(count))
        return !end.overflow && end.partialValue <= laneSpan
    }
}
