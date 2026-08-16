import CryptoKit
import Foundation
import Security

enum TronCryptoError: LocalizedError {
    case randomGenerationFailed(OSStatus)
    case invalidPrivateKey
    case publicKeyDerivationFailed

    var errorDescription: String? {
        switch self {
        case .randomGenerationFailed(let status):
            return "系统安全随机数生成失败（\(status)）。"
        case .invalidPrivateKey:
            return "私钥不是有效的 secp256k1 标量。"
        case .publicKeyDerivationFailed:
            return "secp256k1 公钥生成失败。"
        }
    }
}

enum TronAddress {
    static func randomPrivateKey() throws -> [UInt8] {
        for _ in 0..<128 {
            var bytes = [UInt8](repeating: 0, count: 32)
            let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            guard status == errSecSuccess else {
                throw TronCryptoError.randomGenerationFailed(status)
            }
            if verify(privateKey: bytes) {
                return bytes
            }
            bytes.withUnsafeMutableBytes { buffer in
                trx_secure_zero(buffer.baseAddress, UInt64(buffer.count))
            }
        }
        throw TronCryptoError.invalidPrivateKey
    }

    static func verify(privateKey: [UInt8]) -> Bool {
        guard privateKey.count == 32 else { return false }
        return privateKey.withUnsafeBytes { pointer in
            trx_secp256k1_verify_secret(pointer.bindMemory(to: UInt8.self).baseAddress) == 1
        }
    }

    static func privateKey(atOffset offset: UInt64, from base: [UInt8]) throws -> [UInt8] {
        guard base.count == 32 else { throw TronCryptoError.invalidPrivateKey }
        var output = [UInt8](repeating: 0, count: 32)
        let success = base.withUnsafeBytes { basePointer in
            output.withUnsafeMutableBytes { outputPointer in
                trx_secp256k1_add_u64(
                    basePointer.bindMemory(to: UInt8.self).baseAddress,
                    offset,
                    outputPointer.bindMemory(to: UInt8.self).baseAddress
                )
            }
        }
        guard success == 1 else { throw TronCryptoError.invalidPrivateKey }
        return output
    }

    static func privateKey(base: [UInt8], step: [UInt8], index: UInt64) throws -> [UInt8] {
        guard base.count == 32, step.count == 32, index > 0 else {
            throw TronCryptoError.invalidPrivateKey
        }
        var output = [UInt8](repeating: 0, count: 32)
        let success = base.withUnsafeBytes { basePointer in
            step.withUnsafeBytes { stepPointer in
                output.withUnsafeMutableBytes { outputPointer in
                    trx_secp256k1_linear_combination(
                        basePointer.bindMemory(to: UInt8.self).baseAddress,
                        stepPointer.bindMemory(to: UInt8.self).baseAddress,
                        index,
                        outputPointer.bindMemory(to: UInt8.self).baseAddress
                    )
                }
            }
        }
        guard success == 1 else { throw TronCryptoError.invalidPrivateKey }
        return output
    }

    static func uncompressedPublicKey(for privateKey: [UInt8]) throws -> [UInt8] {
        guard privateKey.count == 32 else { throw TronCryptoError.invalidPrivateKey }
        var output = [UInt8](repeating: 0, count: 65)
        let success = privateKey.withUnsafeBytes { inputPointer in
            output.withUnsafeMutableBytes { outputPointer in
                trx_secp256k1_public_key(
                    inputPointer.bindMemory(to: UInt8.self).baseAddress,
                    outputPointer.bindMemory(to: UInt8.self).baseAddress
                )
            }
        }
        guard success == 1 else { throw TronCryptoError.publicKeyDerivationFailed }
        return output
    }

    static func address(from privateKey: [UInt8]) throws -> String {
        let publicKey = try uncompressedPublicKey(for: privateKey)
        let hash = Keccak256.hash(Array(publicKey.dropFirst()))
        var payload = [UInt8](arrayLiteral: 0x41)
        payload.append(contentsOf: hash.suffix(20))
        let firstHash = Array(SHA256.hash(data: Data(payload)))
        let secondHash = Array(SHA256.hash(data: Data(firstHash)))
        return Base58.encode(payload + secondHash.prefix(4))
    }

    static func address(fromPrivateKeyHex hex: String) throws -> String {
        guard let privateKey = bytes(fromHex: hex), privateKey.count == 32 else {
            throw TronCryptoError.invalidPrivateKey
        }
        return try address(from: privateKey)
    }

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined()
    }

    static func bytes(fromHex hex: String) -> [UInt8]? {
        let normalized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "0x", with: "", options: [.anchored, .caseInsensitive])
        guard normalized.count.isMultiple(of: 2) else { return nil }
        var output = [UInt8]()
        output.reserveCapacity(normalized.count / 2)
        var cursor = normalized.startIndex
        while cursor < normalized.endIndex {
            let next = normalized.index(cursor, offsetBy: 2)
            guard let value = UInt8(normalized[cursor..<next], radix: 16) else { return nil }
            output.append(value)
            cursor = next
        }
        return output
    }

    static func matches(address: String, prefix: String?, suffix: String?) -> Bool {
        let prefixMatches = prefix.map { address.dropFirst(2).hasPrefix($0) } ?? true
        let suffixMatches = suffix.map { address.hasSuffix($0) } ?? true
        return prefixMatches && suffixMatches
    }
}
