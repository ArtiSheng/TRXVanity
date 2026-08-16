import Foundation

/// Legacy Keccak-256 used by Ethereum/TRON. This is deliberately not SHA3-256:
/// the padding/domain byte is 0x01 rather than FIPS SHA-3's 0x06.
enum Keccak256 {
    private static let roundConstants: [UInt64] = [
        0x0000_0000_0000_0001, 0x0000_0000_0000_8082,
        0x8000_0000_0000_808A, 0x8000_0000_8000_8000,
        0x0000_0000_0000_808B, 0x0000_0000_8000_0001,
        0x8000_0000_8000_8081, 0x8000_0000_0000_8009,
        0x0000_0000_0000_008A, 0x0000_0000_0000_0088,
        0x0000_0000_8000_8009, 0x0000_0000_8000_000A,
        0x0000_0000_8000_808B, 0x8000_0000_0000_008B,
        0x8000_0000_0000_8089, 0x8000_0000_0000_8003,
        0x8000_0000_0000_8002, 0x8000_0000_0000_0080,
        0x0000_0000_0000_800A, 0x8000_0000_8000_000A,
        0x8000_0000_8000_8081, 0x8000_0000_0000_8080,
        0x0000_0000_8000_0001, 0x8000_0000_8000_8008,
    ]

    private static let rotationOffsets: [UInt64] = [
         0,  1, 62, 28, 27,
        36, 44,  6, 55, 20,
         3, 10, 43, 25, 39,
        41, 45, 15, 21,  8,
        18,  2, 61, 56, 14,
    ]

    static func hash(_ input: [UInt8]) -> [UInt8] {
        let rate = 136
        var padded = input
        padded.append(0x01)
        while padded.count % rate != rate - 1 {
            padded.append(0)
        }
        padded.append(0x80)

        var state = [UInt64](repeating: 0, count: 25)
        var blockOffset = 0
        while blockOffset < padded.count {
            for byteIndex in 0..<rate {
                let lane = byteIndex / 8
                let shift = UInt64((byteIndex % 8) * 8)
                state[lane] ^= UInt64(padded[blockOffset + byteIndex]) << shift
            }
            permute(&state)
            blockOffset += rate
        }

        var output = [UInt8]()
        output.reserveCapacity(32)
        for byteIndex in 0..<32 {
            output.append(UInt8(truncatingIfNeeded: state[byteIndex / 8] >> UInt64((byteIndex % 8) * 8)))
        }
        return output
    }

    private static func permute(_ state: inout [UInt64]) {
        for roundConstant in roundConstants {
            var c = [UInt64](repeating: 0, count: 5)
            var d = [UInt64](repeating: 0, count: 5)
            for x in 0..<5 {
                c[x] = state[x] ^ state[x + 5] ^ state[x + 10] ^ state[x + 15] ^ state[x + 20]
            }
            for x in 0..<5 {
                d[x] = c[(x + 4) % 5] ^ rotateLeft(c[(x + 1) % 5], by: 1)
            }
            for y in 0..<5 {
                for x in 0..<5 {
                    state[x + 5 * y] ^= d[x]
                }
            }

            var b = [UInt64](repeating: 0, count: 25)
            for y in 0..<5 {
                for x in 0..<5 {
                    let newX = y
                    let newY = (2 * x + 3 * y) % 5
                    b[newX + 5 * newY] = rotateLeft(
                        state[x + 5 * y],
                        by: rotationOffsets[x + 5 * y]
                    )
                }
            }

            for y in 0..<5 {
                for x in 0..<5 {
                    state[x + 5 * y] = b[x + 5 * y]
                        ^ ((~b[(x + 1) % 5 + 5 * y]) & b[(x + 2) % 5 + 5 * y])
                }
            }
            state[0] ^= roundConstant
        }
    }

    private static func rotateLeft(_ value: UInt64, by count: UInt64) -> UInt64 {
        guard count != 0 else { return value }
        return (value << count) | (value >> (64 - count))
    }
}
