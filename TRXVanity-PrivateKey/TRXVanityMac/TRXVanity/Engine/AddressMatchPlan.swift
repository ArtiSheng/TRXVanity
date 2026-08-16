import Foundation

enum AddressMatchPlanError: LocalizedError, Sendable {
    case noCondition
    case invalidPattern(String)
    case invalidBase58Range

    var errorDescription: String? {
        switch self {
        case .noCondition:
            return "请至少启用一项匹配条件。"
        case .invalidPattern(let label):
            return "\(label)必须是 1–\(SearchConfiguration.maximumPatternLength) 位数字，并且只能使用 1–9。"
        case .invalidBase58Range:
            return "无法构造 TRON Base58 匹配区间。"
        }
    }
}

struct Base58AddressRange: Sendable, Equatable {
    let minimum: [UInt8]
    let maximum: [UInt8]

    var payloadMinimum: [UInt8] { Array(minimum.prefix(21)) }
    var payloadMaximum: [UInt8] { Array(maximum.prefix(21)) }
}

struct AddressMatchPlan: Sendable {
    let prefix: String?
    let suffix: String?
    let prefixRanges: [Base58AddressRange]
    let suffixModulus: UInt64
    let suffixRemainder: UInt64
    let suffixProbeTarget: UInt32

    init(configuration: SearchConfiguration) throws {
        guard configuration.prefix != nil || configuration.suffix != nil else {
            throw AddressMatchPlanError.noCondition
        }
        if let prefix = configuration.prefix {
            guard Self.isValid(pattern: prefix) else {
                throw AddressMatchPlanError.invalidPattern("前段数字")
            }
            prefixRanges = try Self.makePrefixRanges(prefix)
            guard !prefixRanges.isEmpty else {
                throw AddressMatchPlanError.invalidBase58Range
            }
        } else {
            prefixRanges = []
        }

        if let suffix = configuration.suffix {
            guard Self.isValid(pattern: suffix),
                  let value = Base58.numericValue(of: suffix),
                  let modulus = Self.power58(suffix.count) else {
                throw AddressMatchPlanError.invalidPattern("尾号数字")
            }
            suffixModulus = modulus
            suffixRemainder = value
            suffixProbeTarget = UInt32(value % (58 * 58))
        } else {
            suffixModulus = 1
            suffixRemainder = 0
            suffixProbeTarget = 0
        }

        prefix = configuration.prefix
        suffix = configuration.suffix
    }

    func matches(address: String) -> Bool {
        TronAddress.matches(address: address, prefix: prefix, suffix: suffix)
    }

    var payloadMinimumBytes: [UInt8] {
        prefixRanges.flatMap(\.payloadMinimum)
    }

    var payloadMaximumBytes: [UInt8] {
        prefixRanges.flatMap(\.payloadMaximum)
    }

    var fullMinimumBytes: [UInt8] {
        prefixRanges.flatMap(\.minimum)
    }

    var fullMaximumBytes: [UInt8] {
        prefixRanges.flatMap(\.maximum)
    }

    private static func isValid(pattern: String) -> Bool {
        SearchConfiguration.supportedPatternLengths.contains(pattern.count)
            && pattern.allSatisfy { ("1"..."9").contains(String($0)) }
    }

    /// `58^10 == 430_804_206_899_405_824`, which fits in `UInt64`.
    /// Keep overflow checking here so a future UI limit increase cannot wrap the
    /// Metal suffix modulus silently.
    private static func power58(_ exponent: Int) -> UInt64? {
        guard exponent >= 0 else { return nil }
        var value: UInt64 = 1
        for _ in 0..<exponent {
            let (next, overflow) = value.multipliedReportingOverflow(by: 58)
            guard !overflow else { return nil }
            value = next
        }
        return value
    }

    /// The UI prefix starts at Base58 character 3, so each range is `T?prefix`.
    /// Enumerating the constrained second Base58 character yields a small set of
    /// exact 200-bit intervals and avoids encoding Base58 for every GPU candidate.
    private static func makePrefixRanges(_ prefix: String) throws -> [Base58AddressRange] {
        let tronMinimum = [UInt8](arrayLiteral: 0x41) + [UInt8](repeating: 0x00, count: 24)
        let tronMaximum = [UInt8](arrayLiteral: 0x41) + [UInt8](repeating: 0xff, count: 24)
        var ranges = [Base58AddressRange]()

        for secondByte in Base58.alphabet {
            let known = "T" + String(decoding: [secondByte], as: UTF8.self) + prefix
            let remaining = 34 - known.utf8.count
            guard remaining >= 0,
                  let rawMinimum = Base58.decodeFixed(
                    known + String(repeating: "1", count: remaining),
                    size: 25
                  ),
                  let rawMaximum = Base58.decodeFixed(
                    known + String(repeating: "z", count: remaining),
                    size: 25
                  ) else {
                throw AddressMatchPlanError.invalidBase58Range
            }

            if compare(rawMaximum, tronMinimum) < 0 || compare(rawMinimum, tronMaximum) > 0 {
                continue
            }
            let minimum = compare(rawMinimum, tronMinimum) < 0 ? tronMinimum : rawMinimum
            let maximum = compare(rawMaximum, tronMaximum) > 0 ? tronMaximum : rawMaximum
            ranges.append(Base58AddressRange(minimum: minimum, maximum: maximum))
        }
        return ranges
    }

    private static func compare(_ lhs: [UInt8], _ rhs: [UInt8]) -> Int {
        precondition(lhs.count == rhs.count)
        for (left, right) in zip(lhs, rhs) {
            if left < right { return -1 }
            if left > right { return 1 }
        }
        return 0
    }
}
