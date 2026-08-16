import Foundation

struct MachineRecord: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var user: String
    var host: String
    var port: Int
    var password: String?
    var privateKey: String?
    var localForward: String?

    var sshCommand: String {
        let base = "ssh -p \(port) \(user)@\(host)"
        guard let localForward, !localForward.isEmpty else { return base }
        return "\(base) -L \(localForward)"
    }

    /// Safe for UI display only. Connection code must keep using the raw fields above.
    var maskedEndpoint: String {
        "\(Self.maskNumericRuns(in: user))@\(Self.maskHost(host)):\(Self.maskPort(port))"
    }

    private static func maskHost(_ host: String) -> String {
        let components = host.split(separator: ".", omittingEmptySubsequences: false)
        let isIPv4 = components.count == 4 && components.allSatisfy { component in
            guard !component.isEmpty,
                  component.allSatisfy({ $0.isNumber }),
                  let value = Int(component)
            else { return false }
            return (0...255).contains(value)
        }
        if isIPv4 {
            return "\(components[0]).•••.•••.\(components[3])"
        }
        return maskNumericRuns(in: host)
    }

    private static func maskPort(_ port: Int) -> String {
        let digits = Array(String(port))
        switch digits.count {
        case 0:
            return "—"
        case 1...3:
            return String(digits)
        default:
            return String(digits.prefix(2))
                + String(repeating: "•", count: digits.count - 3)
                + String(digits.last!)
        }
    }

    private static func maskNumericRuns(in value: String) -> String {
        var result = ""
        var numericRun: [Character] = []

        func appendNumericRun() {
            guard !numericRun.isEmpty else { return }
            if numericRun.count >= 4 {
                result.append(contentsOf: numericRun.prefix(2))
                result.append(String(repeating: "•", count: numericRun.count - 3))
                result.append(numericRun.last!)
            } else {
                result.append(contentsOf: numericRun)
            }
            numericRun.removeAll(keepingCapacity: true)
        }

        for character in value {
            if character.isNumber {
                numericRun.append(character)
            } else {
                appendNumericRun()
                result.append(character)
            }
        }
        appendNumericRun()
        return result
    }
}

enum SSHLoginParserError: LocalizedError, Equatable {
    case missingCredential
    case invalidCommand
    case invalidPort
    case invalidForward
    case invalidCredential
    case invalidPrivateKey

    var errorDescription: String? {
        switch self {
        case .missingCredential:
            return "请粘贴 SSH 命令，并在下方粘贴密码或完整私钥。"
        case .invalidCommand:
            return "SSH 命令格式应为：ssh -p 端口 用户@主机，可选加 -L 本地端口:目标主机:目标端口。"
        case .invalidPort:
            return "SSH 端口必须在 1 到 65535 之间。"
        case .invalidForward:
            return "-L 转发格式无效，例如：-L 8080:localhost:8080。"
        case .invalidCredential:
            return "密码应为单独一行，或粘贴完整的 OpenSSH 私钥。"
        case .invalidPrivateKey:
            return "私钥格式不完整，请从 BEGIN 行粘贴到 END 行。"
        }
    }
}

/// The outcome of parsing a paste that may describe any number of machines.
struct SSHLoginBatch: Equatable, Sendable {
    struct Failure: Equatable, Sendable {
        var lineNumber: Int
        var command: String
        var message: String
    }

    var records: [MachineRecord] = []
    var failures: [Failure] = []
    /// Entries that repeated an earlier user@host:port in the same paste; the last one won.
    var mergedDuplicates = 0

    var isEmpty: Bool { records.isEmpty && failures.isEmpty }
}

enum SSHLoginParser {
    /// Splits a paste into one block per `ssh` command line and parses each independently, so a
    /// single malformed entry reports its own line number instead of failing the whole paste.
    static func parseBatch(_ input: String) -> SSHLoginBatch {
        let lines = input
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var blocks: [(lineNumber: Int, lines: [String])] = []
        var strayLineNumber: Int?
        for (offset, line) in lines.enumerated() {
            if isCommandLine(line) {
                blocks.append((offset + 1, [line]))
            } else if blocks.isEmpty {
                if strayLineNumber == nil, !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    strayLineNumber = offset + 1
                }
            } else {
                blocks[blocks.count - 1].lines.append(line)
            }
        }

        var batch = SSHLoginBatch()
        if let strayLineNumber {
            batch.failures.append(
                SSHLoginBatch.Failure(
                    lineNumber: strayLineNumber,
                    command: summarize(lines[strayLineNumber - 1]),
                    message: SSHLoginParserError.invalidCommand.errorDescription ?? ""
                )
            )
        }

        var indexByEndpoint: [String: Int] = [:]
        for block in blocks {
            do {
                let record = try parse(block.lines.joined(separator: "\n"))
                let endpoint = "\(record.user)\u{0}\(record.host)\u{0}\(record.port)"
                if let existing = indexByEndpoint[endpoint] {
                    batch.records[existing] = record
                    batch.mergedDuplicates += 1
                } else {
                    indexByEndpoint[endpoint] = batch.records.count
                    batch.records.append(record)
                }
            } catch {
                batch.failures.append(
                    SSHLoginBatch.Failure(
                        lineNumber: block.lineNumber,
                        command: summarize(block.lines[0]),
                        message: error.localizedDescription
                    )
                )
            }
        }
        return batch
    }

    private static func isCommandLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("ssh") else { return false }
        return trimmed.dropFirst(3).first?.isWhitespace == true
    }

    private static func summarize(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > 44 else { return trimmed }
        return String(trimmed.prefix(44)) + "…"
    }

    static func parse(_ input: String) throws -> MachineRecord {
        let normalized = input
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = normalized.firstIndex(of: "\n") else {
            throw SSHLoginParserError.missingCredential
        }
        let command = String(normalized[..<separator]).trimmingCharacters(in: .whitespaces)
        let credential = String(normalized[normalized.index(after: separator)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, !credential.isEmpty else {
            throw SSHLoginParserError.missingCredential
        }

        let range = NSRange(command.startIndex..<command.endIndex, in: command)
        guard let match = commandRegex.firstMatch(in: command, range: range),
              match.numberOfRanges == 7,
              let portRange = Range(match.range(at: 1), in: command),
              let userRange = Range(match.range(at: 2), in: command),
              let hostRange = Range(match.range(at: 3), in: command)
        else { throw SSHLoginParserError.invalidCommand }

        guard let port = Int(command[portRange]), (1...65_535).contains(port) else {
            throw SSHLoginParserError.invalidPort
        }
        var localForward: String?
        if match.range(at: 4).location != NSNotFound,
           let localPortRange = Range(match.range(at: 4), in: command),
           let forwardHostRange = Range(match.range(at: 5), in: command),
           let remotePortRange = Range(match.range(at: 6), in: command),
           let localPort = Int(command[localPortRange]),
           let remotePort = Int(command[remotePortRange]),
           (1...65_535).contains(localPort),
           (1...65_535).contains(remotePort) {
            localForward = "\(localPort):\(command[forwardHostRange]):\(remotePort)"
        } else if match.range(at: 4).location != NSNotFound {
            throw SSHLoginParserError.invalidForward
        }
        let credentialLines = credential
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var password: String?
        var privateKey: String?
        if credential.hasPrefix("-----BEGIN ") {
            guard let header = credentialLines.first,
                  let footer = credentialLines.last,
                  credentialLines.count >= 3,
                  supportedPrivateKeyHeaders.contains(header),
                  footer == header.replacingOccurrences(of: "-----BEGIN ", with: "-----END ")
            else { throw SSHLoginParserError.invalidPrivateKey }
            privateKey = credentialLines.joined(separator: "\n") + "\n"
        } else {
            guard credentialLines.count == 1 else { throw SSHLoginParserError.invalidCredential }
            password = credentialLines[0]
        }
        return MachineRecord(
            id: UUID(),
            user: String(command[userRange]),
            host: String(command[hostRange]),
            port: port,
            password: password,
            privateKey: privateKey,
            localForward: localForward
        )
    }

    /// Batch parsing re-runs on every keystroke, so the pattern is compiled once. It is a literal,
    /// and `testParsesTwoLineSSHLogin` would fail immediately if it ever stopped compiling.
    private static let commandRegex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"^ssh\s+-p\s+([0-9]{1,5})\s+([A-Za-z0-9._-]+)@([A-Za-z0-9.-]+)(?:\s+-L\s+([0-9]{1,5}):([A-Za-z0-9._-]+):([0-9]{1,5}))?$"#
        )
    }()

    private static let supportedPrivateKeyHeaders: Set<String> = [
        "-----BEGIN OPENSSH PRIVATE KEY-----",
        "-----BEGIN PRIVATE KEY-----",
        "-----BEGIN RSA PRIVATE KEY-----",
        "-----BEGIN EC PRIVATE KEY-----"
    ]
}

struct MonitorStatus: Codable, Equatable, Sendable {
    var state: String?
    var suffix: String?
    var attempts: UInt64?
    var speed: Double?
    var elapsedSeconds: Double?
    var engineDevice: String?
    var engineProfile: String?
    var engineCPUWorkers: Int?
    var engineCPUBudget: Int?
    var engineCPUBudgetSource: String?
    var engineBatchSize: UInt64?
    var engineBatchCapacity: UInt64?
    var engineCUDAMasterBlockSize: Int?
    var engineCUDAAddressBlockSize: Int?
    var engineKernelMode: String?
    var heartbeatOK: Bool?
    var heartbeatAt: String?
    var updatedAt: String?
    var detail: String?

    enum CodingKeys: String, CodingKey {
        case state, suffix, attempts, speed, detail
        case elapsedSeconds = "elapsed_seconds"
        case engineDevice = "engine_device"
        case engineProfile = "engine_profile"
        case engineCPUWorkers = "engine_cpu_workers"
        case engineCPUBudget = "engine_cpu_budget"
        case engineCPUBudgetSource = "engine_cpu_budget_source"
        case engineBatchSize = "engine_batch_size"
        case engineBatchCapacity = "engine_batch_capacity"
        case engineCUDAMasterBlockSize = "engine_cuda_master_block_size"
        case engineCUDAAddressBlockSize = "engine_cuda_address_block_size"
        case engineKernelMode = "engine_kernel_mode"
        case heartbeatOK = "heartbeat_ok"
        case heartbeatAt = "heartbeat_at"
        case updatedAt = "updated_at"
    }
}

struct RemoteTelemetry: Equatable, Sendable {
    var cpuPercent: Double?
    var gpuPercent: Double?
    var gpuMemoryPercent: Double?
    var gpuMemoryUsedMiB: Double?
    var gpuMemoryTotalMiB: Double?
}

struct MachineSnapshot: Equatable, Sendable {
    var status: MonitorStatus
    var telemetry: RemoteTelemetry
}

enum MachinePhase: Equatable, Sendable {
    case saved
    case connecting
    case checking
    case starting
    case searching
    case missingFiles([String])
    case secretMissing
    case offline(String)

    var label: String {
        switch self {
        case .saved: return "等待连接"
        case .connecting: return "连接中"
        case .checking: return "检查运行文件"
        case .starting: return "启动搜索"
        case .searching: return "搜索中"
        case .missingFiles: return "缺少运行文件"
        case .secretMissing: return "缺少内存密钥"
        case .offline: return "连接失败"
        }
    }
}

struct RuntimeUploadProgress: Equatable, Sendable {
    var bytesSent: Int64
    var totalBytes: Int64

    var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(bytesSent) / Double(totalBytes)))
    }
}

struct MachineViewState: Identifiable, Equatable, Sendable {
    var record: MachineRecord
    var phase: MachinePhase = .saved
    var snapshot: MachineSnapshot?
    var isUploading = false
    var uploadProgress: RuntimeUploadProgress?
    var uploadError: String?

    var id: UUID { record.id }
}

/// TRON Base58 suffix shared by the Mac monitor, `formal-suffix`, and the remote controller.
enum FormalSearch {
    static let defaultSuffix = "8888888"
    static let defaultsKey = "trxvanity.monitor.target-suffix.v1"
    static let base58AlphabetSize = 58
    static let minLength = 1
    static let maxLength = 10
    static let base58Characters = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

    static func filterInput(_ raw: String) -> String {
        String(raw.filter { base58Characters.contains($0) }.prefix(maxLength))
    }

    static func normalize(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(
            of: "^[1-9A-HJ-NP-Za-km-z]{\(minLength),\(maxLength)}$",
            options: .regularExpression
        ) != nil else {
            throw FormalSearchError.invalidSuffix
        }
        return value
    }

    static func isValid(_ raw: String) -> Bool {
        (try? normalize(raw)) != nil
    }

    static func searchSpace(for suffix: String) -> Double {
        guard isValid(suffix) else { return 0 }
        return pow(Double(base58AlphabetSize), Double(suffix.count))
    }

    static var persistedSuffix: String {
        get {
            guard let stored = UserDefaults.standard.string(forKey: defaultsKey) else {
                return defaultSuffix
            }
            let filtered = filterInput(stored)
            return filtered.isEmpty ? defaultSuffix : filtered
        }
        set {
            UserDefaults.standard.set(filterInput(newValue), forKey: defaultsKey)
        }
    }
}

enum FormalSearchError: LocalizedError, Equatable {
    case invalidSuffix

    var errorDescription: String? {
        "尾号必须是 1 到 10 位 TRON Base58 字符，不能包含 0、O、I、l。"
    }
}

struct FleetForecast: Equatable, Sendable {
    var attempts: Double
    var speed: Double
    var suffix: String

    var searchSpace: Double { FormalSearch.searchSpace(for: suffix) }

    var workProgress: Double {
        let space = searchSpace
        guard space > 0 else { return 0 }
        return attempts / space
    }

    var cumulativeProbability: Double {
        let space = searchSpace
        guard space > 1 else { return 0 }
        let missLog = log1p(-1.0 / space)
        return min(1, max(0, -expm1(attempts * missLog)))
    }

    var until50Seconds: Double? { remainingSeconds(to: 0.5) }
    var until100Seconds: Double? { remainingSeconds(to: 1.0) }

    private func remainingSeconds(to ratio: Double) -> Double? {
        guard speed > 0, searchSpace > 0 else { return nil }
        return max(0, searchSpace * ratio - attempts) / speed
    }
}

enum DisplayFormat {
    private static let chineseNumber: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    private static let iso8601WithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601WithoutFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let beijingDateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_CN_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy年MM月dd日 HH:mm:ss"
        return formatter
    }()

    static func compact(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "—" }
        if value >= 1e12 { return "\(number(value / 1e12)) 万亿" }
        if value >= 1e8 { return "\(number(value / 1e8)) 亿" }
        if value >= 1e4 { return "\(number(value / 1e4)) 万" }
        return number(value)
    }

    static func number(_ value: Double) -> String {
        chineseNumber.string(from: NSNumber(value: value)) ?? "—"
    }

    static func bytes(_ value: Int64) -> String {
        guard value >= 0 else { return "—" }
        let units = ["B", "KB", "MB", "GB"]
        var scaled = Double(value)
        var unitIndex = 0
        while scaled >= 1024, unitIndex < units.count - 1 {
            scaled /= 1024
            unitIndex += 1
        }
        return String(format: unitIndex == 0 ? "%.0f %@" : "%.1f %@", scaled, units[unitIndex])
    }

    static func percent(_ value: Double?, unclamped: Bool = false) -> String {
        guard let value, value.isFinite else { return "—" }
        let ratio = unclamped ? max(0, value) : min(1, max(0, value))
        let result = ratio * 100
        if result > 0, result < 0.00000001 { return "< 0.00000001%" }
        return String(format: result >= 1 ? "%.4f%%" : "%.8f%%", result)
    }

    static func utilization(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.0f%%", min(100, max(0, value)))
    }

    static func beijingDateTime(_ value: String?) -> String {
        guard let value else { return "—" }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              let date = iso8601WithFractionalSeconds.date(from: normalized)
                ?? iso8601WithoutFractionalSeconds.date(from: normalized)
        else { return "—" }
        return beijingDateTimeFormatter.string(from: date)
    }

    static func duration(_ rawSeconds: Double?) -> String {
        guard let rawSeconds, rawSeconds.isFinite, rawSeconds >= 0 else { return "—" }
        var seconds = Int(rawSeconds)
        let units = [(31_557_600, "年"), (86_400, "天"), (3_600, "时"), (60, "分"), (1, "秒")]
        var parts: [String] = []
        for (size, label) in units {
            let count = seconds / size
            if count > 0 || !parts.isEmpty {
                parts.append("\(count)\(label)")
                seconds %= size
            }
            if parts.count == 2 { break }
        }
        return parts.isEmpty ? "0秒" : parts.joined(separator: " ")
    }
}
