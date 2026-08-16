import Foundation

enum Base58 {
    static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".utf8)

    static func encode(_ bytes: [UInt8]) -> String {
        guard !bytes.isEmpty else { return "" }
        let zeroCount = bytes.prefix(while: { $0 == 0 }).count
        var input = bytes
        var encoded = [UInt8]()
        var start = zeroCount

        while start < input.count {
            var remainder = 0
            for index in start..<input.count {
                let accumulator = remainder * 256 + Int(input[index])
                input[index] = UInt8(accumulator / 58)
                remainder = accumulator % 58
            }
            encoded.append(alphabet[remainder])
            while start < input.count, input[start] == 0 {
                start += 1
            }
        }
        encoded.append(contentsOf: repeatElement(alphabet[0], count: zeroCount))
        return String(decoding: encoded.reversed(), as: UTF8.self)
    }

    /// Decodes a Base58 number into exactly `size` big-endian bytes.
    static func decodeFixed(_ string: String, size: Int) -> [UInt8]? {
        guard size > 0 else { return nil }
        var output = [UInt8](repeating: 0, count: size)
        for character in string.utf8 {
            guard let digit = alphabet.firstIndex(of: character) else { return nil }
            var carry = digit
            for index in stride(from: size - 1, through: 0, by: -1) {
                let value = Int(output[index]) * 58 + carry
                output[index] = UInt8(value & 0xff)
                carry = value >> 8
            }
            if carry != 0 { return nil }
        }
        return output
    }

    static func numericValue(of suffix: String) -> UInt64? {
        var result: UInt64 = 0
        for character in suffix.utf8 {
            guard let digit = alphabet.firstIndex(of: character) else { return nil }
            let (multiplied, overflowA) = result.multipliedReportingOverflow(by: 58)
            let (added, overflowB) = multiplied.addingReportingOverflow(UInt64(digit))
            guard !overflowA, !overflowB else { return nil }
            result = added
        }
        return result
    }
}
