import Foundation
import XCTest
@testable import TRX_Vanity

final class HistoryStoreTests: XCTestCase {
    @MainActor
    func testSuccessfulViewModelHitIsAutomaticallyBackedUpExactlyOnce() async throws {
        let fixture = try deterministicVanityResult()
        let searcher = ImmediateVanitySearcher(result: fixture)
        let secrets = MemoryHistorySecretStore()
        let metadata = MemoryHistoryMetadataStore()
        let store = HistoryStore(secretStore: secrets, metadataStore: metadata)
        let viewModel = VanityViewModel(searcher: searcher, historyStore: store)
        configureForFixture(viewModel)

        viewModel.start()
        try await waitUntil { viewModel.historyBackupStatus == .saved }
        // Give any accidentally duplicated completion work a chance to run.
        try await Task.sleep(nanoseconds: 50_000_000)

        let records = try await store.load()
        let searchCount = await searcher.searchCount
        XCTAssertEqual(searchCount, 1)
        XCTAssertEqual(secrets.writeCallCount, 1)
        XCTAssertEqual(metadata.saveCallCount, 1)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(viewModel.historyRecords.count, 1)
        XCTAssertEqual(viewModel.status, .found)
        XCTAssertEqual(viewModel.result, fixture)
        XCTAssertEqual(records.first?.address, fixture.address)
        XCTAssertEqual(records.first?.privateKey, fixture.privateKey)
        XCTAssertNil(records.first?.prefix)
        XCTAssertEqual(records.first?.suffix, "3")
    }

    @MainActor
    func testBackupFailureKeepsFoundResultAndReportsFailure() async throws {
        let fixture = try deterministicVanityResult()
        let searcher = ImmediateVanitySearcher(result: fixture)
        let secrets = MemoryHistorySecretStore(writeFailure: .injectedWriteFailure)
        let metadata = MemoryHistoryMetadataStore()
        let store = HistoryStore(secretStore: secrets, metadataStore: metadata)
        let viewModel = VanityViewModel(searcher: searcher, historyStore: store)
        configureForFixture(viewModel)

        viewModel.start()
        try await waitUntil { viewModel.historyBackupStatus == .failed }

        let records = try await store.load()
        XCTAssertEqual(viewModel.status, .found)
        XCTAssertEqual(viewModel.result, fixture)
        XCTAssertEqual(viewModel.sampleAddress, fixture.address)
        XCTAssertEqual(viewModel.attempts, fixture.attempts)
        XCTAssertEqual(viewModel.historyBackupStatus, .failed)
        XCTAssertTrue(viewModel.historyRecords.isEmpty)
        XCTAssertTrue(records.isEmpty)
        XCTAssertEqual(secrets.writeCallCount, 1)
        XCTAssertEqual(metadata.saveCallCount, 0)
        XCTAssertTrue(viewModel.errorMessage?.contains("地址已生成，但自动备份失败") == true)
        XCTAssertTrue(viewModel.errorMessage?.contains("请立即导出当前结果") == true)
    }

    @MainActor
    func testMismatchedAddressAndPrivateKeyAreRejectedBeforeBackup() async throws {
        let fixture = try deterministicVanityResult()
        let mismatched = VanitySearchResult(
            address: fixture.address,
            privateKey: String(repeating: "0", count: 63) + "1",
            attempts: fixture.attempts,
            elapsed: fixture.elapsed
        )
        XCTAssertNotEqual(
            try TronAddress.address(fromPrivateKeyHex: mismatched.privateKey),
            mismatched.address
        )

        let searcher = ImmediateVanitySearcher(result: mismatched)
        let secrets = MemoryHistorySecretStore()
        let metadata = MemoryHistoryMetadataStore()
        let store = HistoryStore(secretStore: secrets, metadataStore: metadata)
        let viewModel = VanityViewModel(searcher: searcher, historyStore: store)
        configureForFixture(viewModel)

        viewModel.start()
        try await waitUntil { viewModel.status == .failed }
        let storedRecords = try await store.load()

        XCTAssertNil(viewModel.result)
        XCTAssertEqual(viewModel.historyBackupStatus, .idle)
        XCTAssertTrue(viewModel.historyRecords.isEmpty)
        XCTAssertTrue(storedRecords.isEmpty)
        XCTAssertEqual(secrets.writeCallCount, 0)
        XCTAssertEqual(metadata.saveCallCount, 0)
        XCTAssertTrue(viewModel.errorMessage?.contains("未通过界面层校验") == true)
    }

    func testAddAndLoadPreserveFieldsWithoutPuttingSecretInMetadata() async throws {
        let secrets = MemoryHistorySecretStore()
        let metadata = MemoryHistoryMetadataStore()
        let store = HistoryStore(secretStore: secrets, metadataStore: metadata)
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)

        let added = try await store.add(
            address: "TMVQGm1qAQYVdetCeGRRkTWYYrLXuHK2HC",
            privateKey: String(repeating: "0", count: 63) + "1",
            createdAt: createdAt,
            prefix: "12",
            suffix: "89"
        )
        let loaded = try await store.load()

        XCTAssertEqual(loaded, [added])
        XCTAssertEqual(loaded.first?.createdAt, createdAt)
        XCTAssertEqual(loaded.first?.prefix, "12")
        XCTAssertEqual(loaded.first?.suffix, "89")
        XCTAssertEqual(metadata.snapshot().first?.address, added.address)
        XCTAssertEqual(secrets.snapshot()[added.id.uuidString], Data(added.privateKey.utf8))
    }

    func testLoadReturnsNewestFirst() async throws {
        let store = HistoryStore(
            secretStore: MemoryHistorySecretStore(),
            metadataStore: MemoryHistoryMetadataStore()
        )
        let older = try await store.add(
            address: "older",
            privateKey: "key-1",
            createdAt: Date(timeIntervalSince1970: 10),
            prefix: nil,
            suffix: "1"
        )
        let newer = try await store.add(
            address: "newer",
            privateKey: "key-2",
            createdAt: Date(timeIntervalSince1970: 20),
            prefix: "2",
            suffix: nil
        )

        let loadedIDs = try await store.load().map(\.id)
        XCTAssertEqual(loadedIDs, [newer.id, older.id])
    }

    func testDeleteRemovesOnlySelectedRecordAndSecret() async throws {
        let secrets = MemoryHistorySecretStore()
        let store = HistoryStore(
            secretStore: secrets,
            metadataStore: MemoryHistoryMetadataStore()
        )
        let first = try await store.add(
            address: "first",
            privateKey: "first-key",
            prefix: nil,
            suffix: nil
        )
        let second = try await store.add(
            address: "second",
            privateKey: "second-key",
            prefix: "3",
            suffix: "4"
        )

        try await store.delete(id: first.id)

        let loadedIDs = try await store.load().map(\.id)
        XCTAssertEqual(loadedIDs, [second.id])
        XCTAssertNil(secrets.snapshot()[first.id.uuidString])
        XCTAssertNotNil(secrets.snapshot()[second.id.uuidString])
    }

    func testDeleteAllRemovesMetadataAndSecrets() async throws {
        let secrets = MemoryHistorySecretStore()
        let metadata = MemoryHistoryMetadataStore()
        let store = HistoryStore(secretStore: secrets, metadataStore: metadata)

        _ = try await store.add(
            address: "first",
            privateKey: "first-key",
            prefix: nil,
            suffix: nil
        )
        _ = try await store.add(
            address: "second",
            privateKey: "second-key",
            prefix: nil,
            suffix: nil
        )
        try await store.deleteAll()

        let loaded = try await store.load()
        XCTAssertTrue(loaded.isEmpty)
        XCTAssertTrue(metadata.snapshot().isEmpty)
        XCTAssertTrue(secrets.snapshot().isEmpty)
    }

    func testInvalidEmptyRecordIsRejected() async {
        let store = HistoryStore(
            secretStore: MemoryHistorySecretStore(),
            metadataStore: MemoryHistoryMetadataStore()
        )

        do {
            _ = try await store.add(
                address: "",
                privateKey: "secret",
                prefix: nil,
                suffix: nil
            )
            XCTFail("Expected invalid record error")
        } catch {
            XCTAssertEqual(error as? HistoryStoreError, .invalidRecord)
        }
    }

    func testFileMetadataContainsNoPrivateKeyAndUsesRestrictedPermissions() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TRXVanity-HistoryTests-(UUID().uuidString)", isDirectory: true)
        let fileURL = rootURL.appendingPathComponent("history.json", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let privateKey = String(repeating: "a", count: 64)
        let store = HistoryStore(
            secretStore: MemoryHistorySecretStore(),
            metadataStore: FileHistoryMetadataStore(fileURL: fileURL)
        )
        _ = try await store.add(
            address: "TKTX96CBxr5kvhjsDHcqoiPWZageGxoTW3",
            privateKey: privateKey,
            prefix: nil,
            suffix: "3"
        )

        let metadata = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(metadata.contains(privateKey))

        let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: rootURL.path)
        let fileMode = try XCTUnwrap(fileAttributes[.posixPermissions] as? NSNumber)
        let directoryMode = try XCTUnwrap(directoryAttributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(fileMode.intValue & 0o777, 0o600)
        XCTAssertEqual(directoryMode.intValue & 0o777, 0o700)
    }

    func testMetadataFailureRemovesNewlyWrittenSecret() async throws {
        let secrets = MemoryHistorySecretStore()
        let metadata = MemoryHistoryMetadataStore(failingSaveCalls: [1])
        let store = HistoryStore(secretStore: secrets, metadataStore: metadata)

        do {
            _ = try await store.add(
                address: "TKTX96CBxr5kvhjsDHcqoiPWZageGxoTW3",
                privateKey: String(repeating: "0", count: 63) + "3",
                prefix: nil,
                suffix: "3"
            )
            XCTFail("Expected metadata save failure")
        } catch {
            XCTAssertEqual(error as? ViewModelTestError, .injectedMetadataFailure)
        }

        XCTAssertTrue(secrets.snapshot().isEmpty)
        XCTAssertTrue(metadata.snapshot().isEmpty)
    }

    func testSecretDeleteFailureRestoresMetadata() async throws {
        let secrets = MemoryHistorySecretStore(deleteFailure: .injectedDeleteFailure)
        let metadata = MemoryHistoryMetadataStore()
        let store = HistoryStore(secretStore: secrets, metadataStore: metadata)
        let record = try await store.add(
            address: "TKTX96CBxr5kvhjsDHcqoiPWZageGxoTW3",
            privateKey: String(repeating: "0", count: 63) + "3",
            prefix: nil,
            suffix: "3"
        )

        do {
            try await store.delete(id: record.id)
            XCTFail("Expected secret delete failure")
        } catch {
            XCTAssertEqual(error as? ViewModelTestError, .injectedDeleteFailure)
        }

        let restoredRecords = try await store.load()
        XCTAssertEqual(restoredRecords, [record])
        XCTAssertNotNil(secrets.snapshot()[record.id.uuidString])
        XCTAssertEqual(metadata.saveCallCount, 3)
    }

    func testRollbackFailureIsReportedExplicitly() async throws {
        let secrets = MemoryHistorySecretStore(deleteFailure: .injectedDeleteFailure)
        let metadata = MemoryHistoryMetadataStore(failingSaveCalls: [3])
        let store = HistoryStore(secretStore: secrets, metadataStore: metadata)
        let record = try await store.add(
            address: "TKTX96CBxr5kvhjsDHcqoiPWZageGxoTW3",
            privateKey: String(repeating: "0", count: 63) + "3",
            prefix: nil,
            suffix: "3"
        )

        do {
            try await store.delete(id: record.id)
            XCTFail("Expected explicit rollback failure")
        } catch let error as HistoryStoreError {
            guard case .rollbackFailed(let detail) = error else {
                return XCTFail("Expected rollbackFailed, received \(error)")
            }
            XCTAssertTrue(detail.contains("恢复元数据失败"))
        }
    }

    private func deterministicVanityResult() throws -> VanitySearchResult {
        let result = VanitySearchResult(
            address: "TKTX96CBxr5kvhjsDHcqoiPWZageGxoTW3",
            privateKey: String(repeating: "0", count: 63) + "3",
            attempts: 12_345,
            elapsed: 0.25
        )
        XCTAssertEqual(
            try TronAddress.address(fromPrivateKeyHex: result.privateKey),
            result.address,
            "The ViewModel fixture must remain a real private-key/address pair."
        )
        return result
    }

    @MainActor
    private func configureForFixture(_ viewModel: VanityViewModel) {
        viewModel.prefixEnabled = false
        viewModel.suffixEnabled = true
        viewModel.setSuffixLength(1)
        viewModel.updateSuffix("3")
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        if !condition() {
            throw ViewModelTestError.timedOut
        }
    }
}

private actor ImmediateVanitySearcher: VanitySearching {
    private let result: VanitySearchResult
    private(set) var searchCount = 0

    init(result: VanitySearchResult) {
        self.result = result
    }

    func search(
        configuration: SearchConfiguration,
        progress: @escaping @Sendable (SearchProgress) -> Void
    ) async throws -> VanitySearchResult {
        searchCount += 1
        progress(SearchProgress(
            attempts: result.attempts,
            speed: Double(result.attempts) / result.elapsed,
            elapsed: result.elapsed,
            sampleAddress: result.address,
            backendName: "Deterministic test searcher"
        ))
        return result
    }

    func cancel() async { }
}

private enum ViewModelTestError: LocalizedError, Sendable {
    case injectedWriteFailure
    case injectedDeleteFailure
    case injectedMetadataFailure
    case timedOut

    var errorDescription: String? {
        switch self {
        case .injectedWriteFailure:
            return "Injected history write failure"
        case .injectedDeleteFailure:
            return "Injected history delete failure"
        case .injectedMetadataFailure:
            return "Injected history metadata failure"
        case .timedOut:
            return "Timed out waiting for ViewModel state"
        }
    }
}

private final class MemoryHistorySecretStore: HistorySecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private let writeFailure: ViewModelTestError?
    private let deleteFailure: ViewModelTestError?
    private var writes = 0

    init(
        writeFailure: ViewModelTestError? = nil,
        deleteFailure: ViewModelTestError? = nil
    ) {
        self.writeFailure = writeFailure
        self.deleteFailure = deleteFailure
    }

    func read(account: String) -> Data? {
        lock.withLock { values[account] }
    }

    func write(_ data: Data, account: String) throws {
        try lock.withLock {
            writes += 1
            if let writeFailure { throw writeFailure }
            values[account] = data
        }
    }

    func delete(account: String) throws {
        try lock.withLock {
            if let deleteFailure { throw deleteFailure }
            _ = values.removeValue(forKey: account)
        }
    }

    func snapshot() -> [String: Data] {
        lock.withLock { values }
    }

    var writeCallCount: Int {
        lock.withLock { writes }
    }
}

private final class MemoryHistoryMetadataStore: HistoryMetadataStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [HistoryMetadataEntry] = []
    private var saves = 0
    private let failingSaveCalls: Set<Int>

    init(failingSaveCalls: Set<Int> = []) {
        self.failingSaveCalls = failingSaveCalls
    }

    func load() -> [HistoryMetadataEntry] {
        lock.withLock { entries }
    }

    func save(_ entries: [HistoryMetadataEntry]) throws {
        try lock.withLock {
            saves += 1
            if failingSaveCalls.contains(saves) {
                throw ViewModelTestError.injectedMetadataFailure
            }
            self.entries = entries
        }
    }

    func snapshot() -> [HistoryMetadataEntry] {
        lock.withLock { entries }
    }

    var saveCallCount: Int {
        lock.withLock { saves }
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
