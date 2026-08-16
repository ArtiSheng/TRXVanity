import Darwin
import Foundation

struct HistoryMetadataEntry: Codable, Equatable, Sendable {
    let id: UUID
    let address: String
    let createdAt: Date
    let prefix: String?
    let suffix: String?
    let secretAccount: String
}

protocol HistoryMetadataStoring: Sendable {
    func load() throws -> [HistoryMetadataEntry]
    func save(_ entries: [HistoryMetadataEntry]) throws
}

struct FileHistoryMetadataStore: HistoryMetadataStoring {
    private struct Document: Codable {
        let version: Int
        let records: [HistoryMetadataEntry]
    }

    static let defaultFileURL: URL = {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)

        return applicationSupport
            .appendingPathComponent("TRXVanity", isDirectory: true)
            .appendingPathComponent("History", isDirectory: true)
            .appendingPathComponent("history.json", isDirectory: false)
    }()

    private let fileURL: URL

    init(fileURL: URL = Self.defaultFileURL) {
        self.fileURL = fileURL
    }

    func load() throws -> [HistoryMetadataEntry] {
        do {
            let data = try Data(contentsOf: fileURL)
            let document = try JSONDecoder().decode(Document.self, from: data)
            guard document.version == 1 else {
                throw HistoryStoreError.unsupportedMetadataVersion(document.version)
            }
            return document.records
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
    }

    func save(_ entries: [HistoryMetadataEntry]) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Document(version: 1, records: entries))
        let stagingURL = directoryURL.appendingPathComponent(
            ".history-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        defer { try? FileManager.default.removeItem(at: stagingURL) }
        try data.write(to: stagingURL, options: [.withoutOverwriting])

        // Metadata contains no private key, but it still identifies generated
        // wallets. Restrict the staging file before it becomes visible as the
        // live document, so a permissions error cannot commit half a save.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: stagingURL.path
        )

        let attributes = try FileManager.default.attributesOfItem(atPath: stagingURL.path)
        guard let mode = attributes[.posixPermissions] as? NSNumber,
              mode.intValue & 0o777 == 0o600 else {
            throw CocoaError(.fileWriteNoPermission)
        }

        // Both paths are in the same directory. POSIX rename atomically
        // replaces the previous document and is the final fallible step.
        let renameStatus = stagingURL.path.withCString { source in
            fileURL.path.withCString { destination in
                Darwin.rename(source, destination)
            }
        }
        guard renameStatus == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
