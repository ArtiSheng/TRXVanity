import Foundation
import Metal
import XCTest
@testable import TRX_Vanity

final class MetalIntegrationTests: XCTestCase {
    func testRuntimeShaderCompiles() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("This test environment cannot access a Metal device.")
        }
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
        let source = try String(contentsOf: shaderURL, encoding: .utf8)
        let library = try device.makeLibrary(source: source, options: nil)
        XCTAssertNotNil(library.makeFunction(name: "trx_vanity_search"))
        XCTAssertNotNil(library.makeFunction(name: "trx_suffix_mod_batch"))
        XCTAssertNotNil(library.makeFunction(name: "trx_suffix_probe_batch"))
    }

    func testMetalResultPassesCPUVerification() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("This test environment cannot access a Metal device.")
        }
        let searcher = MetalVanitySearcher()
        let configuration = SearchConfiguration(
            prefix: "8",
            suffix: nil,
            powerMode: .eco
        )

        let result = try await withThrowingTaskGroup(of: VanitySearchResult.self) { group in
            group.addTask {
                try await searcher.search(configuration: configuration) { _ in }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 30_000_000_000)
                await searcher.cancel()
                throw TimeoutError()
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }

        XCTAssertTrue(result.address.dropFirst(2).hasPrefix("8"))
        XCTAssertEqual(
            try TronAddress.address(fromPrivateKeyHex: result.privateKey),
            result.address
        )
    }

    func testMetalSuffixResultPassesCPUVerification() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("This test environment cannot access a Metal device.")
        }
        let searcher = MetalVanitySearcher()
        let configuration = SearchConfiguration(
            prefix: nil,
            suffix: "8",
            powerMode: .eco
        )

        let result = try await withThrowingTaskGroup(of: VanitySearchResult.self) { group in
            group.addTask {
                try await searcher.search(configuration: configuration) { _ in }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 30_000_000_000)
                await searcher.cancel()
                throw TimeoutError()
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }

        XCTAssertTrue(result.address.hasSuffix("8"))
        XCTAssertEqual(
            try TronAddress.address(fromPrivateKeyHex: result.privateKey),
            result.address
        )
    }

    func testMetalCombinedPrefixAndSuffix() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("This test environment cannot access a Metal device.")
        }
        let searcher = MetalVanitySearcher()
        let configuration = SearchConfiguration(
            prefix: "8",
            suffix: "8",
            powerMode: .eco
        )

        let result = try await withThrowingTaskGroup(of: VanitySearchResult.self) { group in
            group.addTask {
                try await searcher.search(configuration: configuration) { _ in }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 30_000_000_000)
                await searcher.cancel()
                throw TimeoutError()
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }

        XCTAssertTrue(result.address.dropFirst(2).hasPrefix("8"))
        XCTAssertTrue(result.address.hasSuffix("8"))
        XCTAssertEqual(
            try TronAddress.address(fromPrivateKeyHex: result.privateKey),
            result.address
        )
    }

    func testReleaseSustainedThroughputWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["TRX_VANITY_BENCHMARK"] == "1" else {
            throw XCTSkip("Set TRX_VANITY_BENCHMARK=1 to run the sustained GPU benchmark.")
        }
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("This test environment cannot access a Metal device.")
        }

        let cases = [
            (
                "prefix",
                SearchConfiguration(prefix: "12345678", suffix: nil, powerMode: .turbo)
            ),
            (
                "suffix",
                SearchConfiguration(prefix: nil, suffix: "12345678", powerMode: .turbo)
            ),
            (
                "combined",
                SearchConfiguration(prefix: "1234", suffix: "1234", powerMode: .turbo)
            ),
        ]

        for (name, configuration) in cases {
            let searcher = MetalVanitySearcher()
            let recorder = LockedProgressRecorder()
            let wallStart = ContinuousClock.now
            let task = Task {
                try await searcher.search(configuration: configuration) { value in
                    recorder.record(value)
                }
            }

            try await Task.sleep(nanoseconds: 3_200_000_000)
            await searcher.cancel()
            let outcome = await task.result
            switch outcome {
            case .success(let unexpected):
                XCTFail("Unexpected benchmark hit: \(unexpected.address)")
            case .failure(let error):
                XCTAssertTrue(error is CancellationError, "Unexpected benchmark error: \(error)")
            }

            let wallSeconds = wallStart.duration(to: .now).testSeconds
            let snapshot = try XCTUnwrap(recorder.snapshot())
            let measuredSpeed = Double(snapshot.attempts) / snapshot.elapsed
            print(
                "TRX_VANITY_BENCHMARK mode=\(name) attempts=\(snapshot.attempts) "
                    + "measured_seconds=\(String(format: "%.3f", snapshot.elapsed)) "
                    + "wall_seconds=\(String(format: "%.3f", wallSeconds)) "
                    + "addresses_per_second=\(String(format: "%.0f", measuredSpeed))"
            )
            XCTAssertGreaterThan(snapshot.elapsed, 2.0)
            XCTAssertGreaterThan(snapshot.attempts, 0)
        }
    }
}

private struct TimeoutError: LocalizedError {
    var errorDescription: String? { "Metal integration search timed out." }
}

private final class LockedProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: SearchProgress?

    func record(_ progress: SearchProgress) {
        lock.lock()
        latest = progress
        lock.unlock()
    }

    func snapshot() -> SearchProgress? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }
}

private extension Duration {
    var testSeconds: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds)
            + TimeInterval(parts.attoseconds) / 1_000_000_000_000_000_000
    }
}
