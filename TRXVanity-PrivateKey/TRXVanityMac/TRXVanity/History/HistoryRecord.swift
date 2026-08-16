import Foundation

/// A successfully generated vanity address and the information required to
/// restore it. The private key is deliberately not `Codable`: persistence is
/// handled by `HistoryStore`, which keeps it separate from public metadata.
struct HistoryRecord: Identifiable, Hashable, Sendable, CustomStringConvertible {
    let id: UUID
    let address: String
    let privateKey: String
    let createdAt: Date
    let prefix: String?
    let suffix: String?

    var description: String {
        "HistoryRecord(id: \(id), address: \(address), privateKey: <redacted>)"
    }
}

