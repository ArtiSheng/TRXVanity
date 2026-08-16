import Metal
import XCTest
@testable import TRX_Vanity

final class MetalEpochTests: XCTestCase {
    func testPersistentLaneIndexRegionsDoNotOverlap() throws {
        let layout = MetalEpochIndexLayout(laneCount: 4, laneSpan: 1_024)

        XCTAssertEqual(layout.laneStartIndex(for: 0), 0)
        XCTAssertEqual(layout.laneStartIndex(for: 1), 1_024)
        XCTAssertEqual(layout.candidateIndex(lane: 0, dispatchStart: 0, resultOffset: 1), 1)
        XCTAssertEqual(
            layout.candidateIndex(lane: 0, dispatchStart: 992, resultOffset: 32),
            1_024
        )
        XCTAssertEqual(
            layout.candidateIndex(lane: 1, dispatchStart: 0, resultOffset: 1),
            1_025
        )
        XCTAssertNil(layout.candidateIndex(lane: 0, dispatchStart: 992, resultOffset: 33))
        XCTAssertNil(layout.candidateIndex(lane: 4, dispatchStart: 0, resultOffset: 1))

        var visited = Set<UInt64>()
        for dispatchStart in stride(from: UInt64(0), to: 96, by: 32) {
            for lane in UInt32(0)..<UInt32(layout.laneCount) {
                for offset in UInt32(1)...UInt32(32) {
                    let index = try XCTUnwrap(layout.candidateIndex(
                        lane: lane,
                        dispatchStart: dispatchStart,
                        resultOffset: offset
                    ))
                    XCTAssertTrue(visited.insert(index).inserted, "duplicate scalar index \(index)")
                }
            }
        }
        XCTAssertEqual(visited.count, 4 * 3 * 32)
    }

    func testMetalSuffixModuloMatchesCPUForLengthsOneThroughTen() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("This test environment cannot access a Metal device.")
        }
        let source = try bundledShaderSource()
        let library = try device.makeLibrary(source: source, options: nil)
        let function = try XCTUnwrap(library.makeFunction(name: "trx_suffix_mod_batch"))
        let pipeline = try device.makeComputePipelineState(function: function)
        let queue = try XCTUnwrap(device.makeCommandQueue())

        let privateKey = [UInt8](repeating: 0, count: 31) + [1]
        let address = try TronAddress.address(from: privateKey)
        let decoded = try XCTUnwrap(Base58.decodeFixed(address, size: 25))
        var addressBatch = [UInt8]()
        var moduli = [UInt64]()
        var modulus: UInt64 = 1
        for _ in 1...10 {
            modulus *= 58
            moduli.append(modulus)
            addressBatch.append(contentsOf: decoded)
        }

        let addressBuffer = try XCTUnwrap(makeBuffer(device: device, array: &addressBatch))
        let moduliBuffer = try XCTUnwrap(makeBuffer(device: device, array: &moduli))
        let resultBuffer = try XCTUnwrap(device.makeBuffer(
            length: MemoryLayout<UInt64>.stride * moduli.count,
            options: .storageModeShared
        ))
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(commandBuffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(addressBuffer, offset: 0, index: 0)
        encoder.setBuffer(moduliBuffer, offset: 0, index: 1)
        encoder.setBuffer(resultBuffer, offset: 0, index: 2)
        encoder.dispatchThreads(
            MTLSize(width: moduli.count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: moduli.count, height: 1, depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(
            commandBuffer.status,
            .completed,
            commandBuffer.error?.localizedDescription ?? "Metal command did not complete."
        )

        let results = resultBuffer.contents().bindMemory(
            to: UInt64.self,
            capacity: moduli.count
        )
        for length in 1...10 {
            let cpuRemainder = safeModulo(decoded, modulus: moduli[length - 1])
            let base58Tail = try XCTUnwrap(Base58.numericValue(of: String(address.suffix(length))))
            XCTAssertEqual(cpuRemainder, base58Tail, "CPU suffix mismatch at length \(length)")
            XCTAssertEqual(results[length - 1], cpuRemainder, "Metal mismatch at length \(length)")
        }
    }

    func testMetalSuffixProbeMatchesCPUForDeterministicBatch() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("This test environment cannot access a Metal device.")
        }
        let source = try bundledShaderSource()
        let library = try device.makeLibrary(source: source, options: nil)
        let function = try XCTUnwrap(library.makeFunction(name: "trx_suffix_probe_batch"))
        let pipeline = try device.makeComputePipelineState(function: function)
        let queue = try XCTUnwrap(device.makeCommandQueue())

        let privateKey = [UInt8](repeating: 0, count: 31) + [1]
        let realAddress = try TronAddress.address(from: privateKey)
        let decodedAddress = try XCTUnwrap(Base58.decodeFixed(realAddress, size: 25))
        var addresses = [decodedAddress]
        for seed in UInt32(0)..<UInt32(256) {
            var state = seed &+ 0x9e37_79b9
            var bytes = [UInt8](repeating: 0, count: 25)
            bytes[0] = 0x41
            for index in 1..<bytes.count {
                state = state &* 1_664_525 &+ 1_013_904_223
                bytes[index] = UInt8(truncatingIfNeeded: state >> 24)
            }
            addresses.append(bytes)
        }

        var addressBatch = addresses.flatMap { $0 }
        let expectedProbes = addresses.map {
            UInt32(safeModulo($0, modulus: 58 * 58))
        }
        let addressBuffer = try XCTUnwrap(makeBuffer(device: device, array: &addressBatch))
        let resultBuffer = try XCTUnwrap(device.makeBuffer(
            length: MemoryLayout<UInt32>.stride * expectedProbes.count,
            options: .storageModeShared
        ))
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(commandBuffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(addressBuffer, offset: 0, index: 0)
        encoder.setBuffer(resultBuffer, offset: 0, index: 1)
        let groupWidth = min(
            expectedProbes.count,
            pipeline.maxTotalThreadsPerThreadgroup,
            max(pipeline.threadExecutionWidth, 1) * 4
        )
        encoder.dispatchThreads(
            MTLSize(width: expectedProbes.count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: groupWidth, height: 1, depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(
            commandBuffer.status,
            .completed,
            commandBuffer.error?.localizedDescription ?? "Metal command did not complete."
        )

        let results = resultBuffer.contents().bindMemory(
            to: UInt32.self,
            capacity: expectedProbes.count
        )
        for index in expectedProbes.indices {
            XCTAssertEqual(results[index], expectedProbes[index], "probe mismatch at \(index)")
            XCTAssertEqual(
                results[index] % 58,
                UInt32(safeModulo(addresses[index], modulus: 58)),
                "one-digit probe mismatch at \(index)"
            )
        }
    }

    private func bundledShaderSource() throws -> String {
        let shaderURL = try XCTUnwrap(
            Bundle.main.url(
                forResource: "VanitySearch.metal",
                withExtension: "txt",
                subdirectory: "Shaders"
            ) ?? Bundle.main.url(
                forResource: "VanitySearch.metal",
                withExtension: "txt"
            )
        )
        return try String(contentsOf: shaderURL, encoding: .utf8)
    }

    private func safeModulo(_ bytes: [UInt8], modulus: UInt64) -> UInt64 {
        var remainder: UInt64 = 0
        for byte in bytes {
            for _ in 0..<8 {
                remainder = addModulo(remainder, remainder, modulus: modulus)
            }
            remainder = addModulo(remainder, UInt64(byte), modulus: modulus)
        }
        return remainder
    }

    private func addModulo(_ lhs: UInt64, _ rhs: UInt64, modulus: UInt64) -> UInt64 {
        let left = lhs % modulus
        let right = rhs % modulus
        return left >= modulus - right
            ? left - (modulus - right)
            : left + right
    }

    private func makeBuffer<T>(device: MTLDevice, array: inout [T]) -> MTLBuffer? {
        array.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return nil }
            return device.makeBuffer(
                bytes: baseAddress,
                length: bytes.count,
                options: .storageModeShared
            )
        }
    }
}
