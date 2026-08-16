import CryptoKit
import XCTest
@testable import TRX_Vanity

final class CryptoTests: XCTestCase {
    func testKeccakEmptyVector() {
        XCTAssertEqual(
            TronAddress.hex(Keccak256.hash([])),
            "C5D2460186F7233C927E7DB2DCC703C0E500B653CA82273B7BFAD8045D85A470"
        )
    }

    func testPrivateKeyOneOfficialAddressVector() throws {
        let privateKey = [UInt8](repeating: 0, count: 31) + [1]
        XCTAssertTrue(TronAddress.verify(privateKey: privateKey))
        XCTAssertEqual(
            TronAddress.hex(try TronAddress.uncompressedPublicKey(for: privateKey)),
            "0479BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798"
                + "483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8"
        )
        XCTAssertEqual(
            try TronAddress.address(from: privateKey),
            "TMVQGm1qAQYVdetCeGRRkTWYYrLXuHK2HC"
        )
    }

    func testInvalidZeroPrivateKeyIsRejected() {
        XCTAssertFalse(TronAddress.verify(privateKey: [UInt8](repeating: 0, count: 32)))
    }

    func testLinearScalarRecovery() throws {
        let one = [UInt8](repeating: 0, count: 31) + [1]
        let result = try TronAddress.privateKey(base: one, step: one, index: 7)
        XCTAssertEqual(result, [UInt8](repeating: 0, count: 31) + [8])
    }

    func testBase58FixedDecodeRoundTrip() {
        let bytes = [UInt8](arrayLiteral: 0x41) + Array(0..<24).map(UInt8.init)
        let encoded = Base58.encode(bytes)
        XCTAssertEqual(Base58.decodeFixed(encoded, size: 25), bytes)
    }

    func testAddressMatchPlanPrefixStartsAtThirdCharacter() throws {
        let fixture = try deterministicAddressWithNumericThirdCharacter()
        let character = String(fixture.address.dropFirst(2).first!)
        let configuration = SearchConfiguration(
            prefix: character,
            suffix: nil,
            powerMode: .eco
        )
        let plan = try AddressMatchPlan(configuration: configuration)
        XCTAssertTrue(plan.matches(address: fixture.address))

        let decoded = try XCTUnwrap(Base58.decodeFixed(fixture.address, size: 25))
        XCTAssertTrue(plan.prefixRanges.contains { range in
            Self.compare(decoded, range.minimum) >= 0
                && Self.compare(decoded, range.maximum) <= 0
        })
    }

    func testSuffixModuloMatchesBase58Tail() throws {
        let fixture = try deterministicAddressWithNumericSuffix()
        let suffix = String(fixture.address.suffix(1))
        let configuration = SearchConfiguration(
            prefix: nil,
            suffix: suffix,
            powerMode: .eco
        )
        let plan = try AddressMatchPlan(configuration: configuration)
        let decoded = try XCTUnwrap(Base58.decodeFixed(fixture.address, size: 25))
        var remainder: UInt64 = 0
        for byte in decoded {
            remainder = (remainder * 256 + UInt64(byte)) % plan.suffixModulus
        }
        XCTAssertEqual(remainder, plan.suffixRemainder)
        XCTAssertEqual(plan.suffixProbeTarget, UInt32(plan.suffixRemainder % (58 * 58)))
        XCTAssertTrue(plan.matches(address: fixture.address))
    }

    func testTenDigitPatternsFitUInt64SuffixArithmetic() throws {
        let pattern = "1234567891"
        let configuration = SearchConfiguration(
            prefix: pattern,
            suffix: pattern,
            powerMode: .eco
        )
        let plan = try AddressMatchPlan(configuration: configuration)

        XCTAssertFalse(plan.prefixRanges.isEmpty)
        XCTAssertEqual(plan.suffixModulus, 430_804_206_899_405_824)
        XCTAssertEqual(plan.suffixRemainder, Base58.numericValue(of: pattern))
        XCTAssertEqual(plan.suffixProbeTarget, UInt32(plan.suffixRemainder % (58 * 58)))
        XCTAssertLessThan(plan.suffixModulus, UInt64.max)
    }

    func testElevenDigitPatternsAreRejected() {
        let configuration = SearchConfiguration(
            prefix: nil,
            suffix: "12345678912",
            powerMode: .eco
        )

        XCTAssertThrowsError(try AddressMatchPlan(configuration: configuration)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "尾号数字必须是 1–10 位数字，并且只能使用 1–9。"
            )
        }
    }

    @MainActor
    func testViewModelSupportsTenDigitsAndShowsCombinedDifficulty() {
        let viewModel = VanityViewModel()
        XCTAssertEqual(VanityViewModel.supportedLengths, Array(1...10))
        XCTAssertEqual(viewModel.powerMode, .turbo)

        viewModel.setPrefixLength(10)
        viewModel.setSuffixLength(10)
        viewModel.updatePrefix("1234567891")
        viewModel.updateSuffix("9876543219")

        XCTAssertEqual(viewModel.prefix, "1234567891")
        XCTAssertEqual(viewModel.suffix, "9876543219")
        XCTAssertEqual(viewModel.activeDigitCount, 20)
        XCTAssertEqual(viewModel.expectedAttempts, pow(58, 20), accuracy: pow(58, 20) * 1e-12)
        XCTAssertEqual(viewModel.difficulty, "近乎不可行")
    }

    private func deterministicAddressWithNumericThirdCharacter() throws -> (address: String, key: [UInt8]) {
        try deterministicAddress { address in
            guard address.count > 2 else { return false }
            return ("1"..."9").contains(String(address.dropFirst(2).first!))
        }
    }

    private func deterministicAddressWithNumericSuffix() throws -> (address: String, key: [UInt8]) {
        try deterministicAddress { address in
            guard let last = address.last else { return false }
            return ("1"..."9").contains(String(last))
        }
    }

    private func deterministicAddress(
        matching predicate: (String) -> Bool
    ) throws -> (address: String, key: [UInt8]) {
        let one = [UInt8](repeating: 0, count: 31) + [1]
        for offset in 0..<512 {
            let privateKey = try TronAddress.privateKey(atOffset: UInt64(offset), from: one)
            let address = try TronAddress.address(from: privateKey)
            if predicate(address) { return (address, privateKey) }
        }
        XCTFail("Unable to find deterministic numeric fixture")
        return (try TronAddress.address(from: one), one)
    }

    private static func compare(_ lhs: [UInt8], _ rhs: [UInt8]) -> Int {
        for (left, right) in zip(lhs, rhs) {
            if left < right { return -1 }
            if left > right { return 1 }
        }
        return 0
    }
}
