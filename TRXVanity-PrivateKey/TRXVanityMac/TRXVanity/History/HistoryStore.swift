import Foundation
import Security

enum HistoryStoreError: LocalizedError, Equatable {
    case invalidRecord
    case keychain(OSStatus)
    case missingPrivateKey(UUID)
    case invalidPrivateKeyEncoding(UUID)
    case unsupportedMetadataVersion(Int)
    case rollbackFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidRecord:
            return "历史记录中的地址或私钥为空。"
        case .keychain(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String?
            return "钥匙串操作失败（\(status)）：\(detail ?? "未知错误")"
        case .missingPrivateKey:
            return "历史记录对应的私钥不存在。"
        case .invalidPrivateKeyEncoding:
            return "历史记录中的私钥编码无效。"
        case .unsupportedMetadataVersion(let version):
            return "不支持的历史记录版本：\(version)。"
        case .rollbackFailed(let detail):
            return "历史存储回滚失败，数据可能需要人工检查：\(detail)"
        }
    }
}

/// Serializes all history mutations and keeps private keys in the injected
/// secret store. The production singleton uses the local macOS Keychain and a
/// sandboxed Application Support file; no network or cloud synchronization is
/// performed.
actor HistoryStore {
    static let shared = HistoryStore()

    private let secretStore: any HistorySecretStoring
    private let metadataStore: any HistoryMetadataStoring

    init(
        secretStore: any HistorySecretStoring = KeychainHistorySecretStore(),
        metadataStore: any HistoryMetadataStoring = FileHistoryMetadataStore()
    ) {
        self.secretStore = secretStore
        self.metadataStore = metadataStore
    }

    func load() throws -> [HistoryRecord] {
        let entries = try metadataStore.load()
        return try entries.map(record(from:)).sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.createdAt > rhs.createdAt
        }
    }

    @discardableResult
    func add(
        address: String,
        privateKey: String,
        createdAt: Date = Date(),
        prefix: String?,
        suffix: String?
    ) throws -> HistoryRecord {
        guard !address.isEmpty, !privateKey.isEmpty else {
            throw HistoryStoreError.invalidRecord
        }

        let id = UUID()
        let account = id.uuidString
        let entry = HistoryMetadataEntry(
            id: id,
            address: address,
            createdAt: createdAt,
            prefix: prefix,
            suffix: suffix,
            secretAccount: account
        )
        let privateKeyData = Data(privateKey.utf8)

        try secretStore.write(privateKeyData, account: account)
        do {
            var entries = try metadataStore.load()
            entries.append(entry)
            try metadataStore.save(entries)
        } catch let saveError {
            // Do not leave an unreferenced private key behind if metadata fails.
            do {
                try secretStore.delete(account: account)
            } catch let rollbackError {
                throw HistoryStoreError.rollbackFailed(
                    "保存元数据失败（\(saveError.localizedDescription)），"
                        + "且清理钥匙串失败（\(rollbackError.localizedDescription)）。"
                )
            }
            throw saveError
        }

        return HistoryRecord(
            id: id,
            address: address,
            privateKey: privateKey,
            createdAt: createdAt,
            prefix: prefix,
            suffix: suffix
        )
    }

    func delete(id: UUID) throws {
        var entries = try metadataStore.load()
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            return
        }

        let removed = entries.remove(at: index)
        try metadataStore.save(entries)
        do {
            try secretStore.delete(account: removed.secretAccount)
        } catch let deleteError {
            // Restore visibility if the private key could not be deleted.
            do {
                try metadataStore.save(entries + [removed])
            } catch let rollbackError {
                throw HistoryStoreError.rollbackFailed(
                    "删除钥匙串项失败（\(deleteError.localizedDescription)），"
                        + "且恢复元数据失败（\(rollbackError.localizedDescription)）。"
                )
            }
            throw deleteError
        }
    }

    func deleteAll() throws {
        let entries = try metadataStore.load()
        guard !entries.isEmpty else { return }

        // Retain temporary rollback copies only for the duration of this call.
        let secrets = try entries.map { entry in
            (entry, try secretStore.read(account: entry.secretAccount))
        }

        try metadataStore.save([])
        do {
            for entry in entries {
                try secretStore.delete(account: entry.secretAccount)
            }
        } catch let deleteError {
            var rollbackErrors: [String] = []
            for (entry, secret) in secrets {
                if let secret {
                    do {
                        try secretStore.write(secret, account: entry.secretAccount)
                    } catch {
                        rollbackErrors.append("恢复钥匙串项失败：\(error.localizedDescription)")
                    }
                }
            }
            do {
                try metadataStore.save(entries)
            } catch {
                rollbackErrors.append("恢复元数据失败：\(error.localizedDescription)")
            }
            if !rollbackErrors.isEmpty {
                throw HistoryStoreError.rollbackFailed(
                    "删除全部历史失败（\(deleteError.localizedDescription)）；"
                        + rollbackErrors.joined(separator: "；")
                )
            }
            throw deleteError
        }
    }

    private func record(from entry: HistoryMetadataEntry) throws -> HistoryRecord {
        guard let data = try secretStore.read(account: entry.secretAccount) else {
            throw HistoryStoreError.missingPrivateKey(entry.id)
        }
        guard let privateKey = String(data: data, encoding: .utf8) else {
            throw HistoryStoreError.invalidPrivateKeyEncoding(entry.id)
        }
        return HistoryRecord(
            id: entry.id,
            address: entry.address,
            privateKey: privateKey,
            createdAt: entry.createdAt,
            prefix: entry.prefix,
            suffix: entry.suffix
        )
    }
}
