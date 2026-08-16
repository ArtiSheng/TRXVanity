import XCTest
@testable import TRX_Vanity

final class CPUFallbackTests: XCTestCase {
    func testCPUFallbackFindsAndVerifiesAddress() async throws {
        let searcher = CPUVanitySearcher()
        let configuration = SearchConfiguration(
            prefix: nil,
            suffix: "8",
            powerMode: .eco
        )
        let result = try await searcher.search(configuration: configuration) { _ in }
        XCTAssertTrue(result.address.hasSuffix("8"))
        XCTAssertEqual(
            try TronAddress.address(fromPrivateKeyHex: result.privateKey),
            result.address
        )
    }
}
