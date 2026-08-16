import AppKit
import Foundation
import UniformTypeIdentifiers

// MARK: - Search engine contract

/// The prefix, when present, starts at character index 2 of the Base58 TRON address.
/// In other words, the fixed leading `T` and the constrained second character are skipped.
public struct SearchConfiguration: Sendable, Equatable {
    public static let minimumPatternLength = 1
    public static let maximumPatternLength = 10
    public static let supportedPatternLengths = minimumPatternLength...maximumPatternLength

    public let prefix: String?
    public let suffix: String?
    public let powerMode: PowerMode

    public init(prefix: String?, suffix: String?, powerMode: PowerMode) {
        self.prefix = prefix
        self.suffix = suffix
        self.powerMode = powerMode
    }
}

public enum PowerMode: String, CaseIterable, Identifiable, Sendable {
    case eco
    case balanced
    case turbo

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .eco: return "节能"
        case .balanced: return "平衡"
        case .turbo: return "极速"
        }
    }

    public var detail: String {
        switch self {
        case .eco: return "降低 GPU 占用"
        case .balanced: return "速度与流畅度兼顾"
        case .turbo: return "最大批量计算"
        }
    }
}

public struct SearchProgress: Sendable, Equatable {
    public let attempts: UInt64
    public let speed: Double
    public let elapsed: TimeInterval
    public let sampleAddress: String
    public let backendName: String

    public init(
        attempts: UInt64,
        speed: Double,
        elapsed: TimeInterval,
        sampleAddress: String,
        backendName: String
    ) {
        self.attempts = attempts
        self.speed = speed
        self.elapsed = elapsed
        self.sampleAddress = sampleAddress
        self.backendName = backendName
    }
}

public struct VanitySearchResult: Sendable, Equatable {
    public let address: String
    public let privateKey: String
    public let attempts: UInt64
    public let elapsed: TimeInterval

    public init(address: String, privateKey: String, attempts: UInt64, elapsed: TimeInterval) {
        self.address = address
        self.privateKey = privateKey
        self.attempts = attempts
        self.elapsed = elapsed
    }
}

public protocol VanitySearching: Sendable {
    func search(
        configuration: SearchConfiguration,
        progress: @escaping @Sendable (SearchProgress) -> Void
    ) async throws -> VanitySearchResult

    func cancel() async
}

public enum SearchBackendError: LocalizedError, Sendable {
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Metal 搜索核心尚未加载。"
        }
    }
}

/// Keeps previews and the UI target buildable until the Metal engine is injected.
public actor UnavailableVanitySearcher: VanitySearching {
    public init() { }

    public func search(
        configuration: SearchConfiguration,
        progress: @escaping @Sendable (SearchProgress) -> Void
    ) async throws -> VanitySearchResult {
        throw SearchBackendError.unavailable
    }

    public func cancel() async { }
}

// MARK: - View state

enum SearchStatus: Equatable {
    case idle
    case running
    case stopped
    case found
    case failed
}

enum HistoryBackupStatus: Equatable {
    case idle
    case saving
    case saved
    case failed
}

@MainActor
final class VanityViewModel: ObservableObject {
    static let supportedLengths = Array(SearchConfiguration.supportedPatternLengths)

    @Published var prefixEnabled = true
    @Published var suffixEnabled = true
    @Published var prefixLength = 1
    @Published var suffixLength = 1
    @Published var prefix = "8"
    @Published var suffix = "8"
    @Published var powerMode: PowerMode = .turbo

    @Published private(set) var status: SearchStatus = .idle
    @Published private(set) var attempts: UInt64 = 0
    @Published private(set) var speed: Double = 0
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var sampleAddress = "T—————————————————"
    @Published private(set) var backendName = "Apple Metal GPU"
    @Published private(set) var result: VanitySearchResult?
    @Published private(set) var historyRecords: [HistoryRecord] = []
    @Published private(set) var isHistoryLoading = false
    @Published private(set) var historyBackupStatus: HistoryBackupStatus = .idle
    @Published var isPrivateKeyVisible = false
    @Published var errorMessage: String?
    @Published var noticeMessage: String?

    private let searcher: any VanitySearching
    private let historyStore: HistoryStore
    private var searchTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var clipboardClearTask: Task<Void, Never>?
    private var activeSearchID: UUID?
    private var didLoadHistory = false

    init(
        searcher: any VanitySearching = UnavailableVanitySearcher(),
        historyStore: HistoryStore = .shared
    ) {
        self.searcher = searcher
        self.historyStore = historyStore
    }

    var isRunning: Bool { status == .running }

    var activeDigitCount: Int {
        (prefixEnabled ? prefixLength : 0) + (suffixEnabled ? suffixLength : 0)
    }

    var expectedAttempts: Double {
        guard activeDigitCount > 0 else { return 0 }
        return pow(58, Double(activeDigitCount))
    }

    var referenceProgress: Double {
        guard expectedAttempts > 0 else { return 0 }
        return min(1, Double(attempts) / expectedAttempts)
    }

    var estimatedRemaining: TimeInterval? {
        guard speed > 0 else { return nil }
        return max(expectedAttempts - Double(attempts), 0) / speed
    }

    var difficulty: String {
        switch activeDigitCount {
        case ...2: return "快速"
        case 3...4: return "中等"
        case 5...6: return "耗时"
        case 7...10: return "极难"
        default: return "近乎不可行"
        }
    }

    var statusTitle: String {
        switch status {
        case .idle: return "等待开始"
        case .running: return "正在穷举地址"
        case .stopped: return "已停止"
        case .found: return "已找到匹配"
        case .failed: return "生成中断"
        }
    }

    var statusDetail: String {
        switch status {
        case .idle: return "未占用 GPU"
        case .running: return "\(powerMode.title)模式运行中"
        case .stopped: return "已释放 GPU"
        case .found: return "CPU 二次校验通过"
        case .failed: return "请检查错误提示"
        }
    }

    var historyBackupTitle: String {
        switch historyBackupStatus {
        case .idle: return "等待备份"
        case .saving: return "正在保存到本机钥匙串"
        case .saved: return "已自动备份到本机钥匙串"
        case .failed: return "自动备份失败，请立即导出"
        }
    }

    func setPrefixLength(_ length: Int) {
        prefixLength = clampedLength(length)
        prefix = String(prefix.prefix(prefixLength))
    }

    func setSuffixLength(_ length: Int) {
        suffixLength = clampedLength(length)
        suffix = String(suffix.prefix(suffixLength))
    }

    func updatePrefix(_ value: String) {
        prefix = sanitizedDigits(value, maximumLength: prefixLength)
    }

    func updateSuffix(_ value: String) {
        suffix = sanitizedDigits(value, maximumLength: suffixLength)
    }

    func start() {
        guard !isRunning else { return }

        if let validationError = validationError() {
            errorMessage = validationError
            return
        }

        let configuration = SearchConfiguration(
            prefix: prefixEnabled ? prefix : nil,
            suffix: suffixEnabled ? suffix : nil,
            powerMode: powerMode
        )
        let searchID = UUID()
        activeSearchID = searchID
        searchTask?.cancel()
        result = nil
        isPrivateKeyVisible = false
        historyBackupStatus = .idle
        attempts = 0
        speed = 0
        elapsed = 0
        sampleAddress = "T—————————————————"
        errorMessage = nil
        noticeMessage = nil
        status = .running
        let progressTarget = WeakVanityViewModel(self)

        searchTask = Task { [weak self, searcher] in
            do {
                let searchResult = try await searcher.search(
                    configuration: configuration,
                    progress: { progress in
                        Task { @MainActor in
                            progressTarget.value?.consume(progress, searchID: searchID)
                        }
                    }
                )

                guard let self, self.activeSearchID == searchID else { return }
                try self.validate(searchResult, configuration: configuration)
                self.attempts = searchResult.attempts
                self.elapsed = searchResult.elapsed
                self.speed = Double(searchResult.attempts) / max(searchResult.elapsed, 0.001)
                self.sampleAddress = searchResult.address
                self.result = searchResult
                self.status = .found
                self.activeSearchID = nil
                self.searchTask = nil
                self.historyBackupStatus = .saving

                do {
                    let record = try await self.historyStore.add(
                        address: searchResult.address,
                        privateKey: searchResult.privateKey,
                        prefix: configuration.prefix,
                        suffix: configuration.suffix
                    )
                    self.upsertHistory(record)
                    self.historyBackupStatus = .saved
                    self.showNotice("已自动备份到本机钥匙串。")
                } catch {
                    self.historyBackupStatus = .failed
                    self.errorMessage = "地址已生成，但自动备份失败：\(error.localizedDescription)。请立即导出当前结果。"
                }
            } catch is CancellationError {
                guard let self, self.activeSearchID == searchID else { return }
                self.status = .stopped
                self.activeSearchID = nil
                self.searchTask = nil
            } catch {
                guard let self, self.activeSearchID == searchID else { return }
                self.status = .failed
                self.errorMessage = error.localizedDescription
                self.activeSearchID = nil
                self.searchTask = nil
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        activeSearchID = nil
        searchTask?.cancel()
        searchTask = nil
        status = .stopped
        showNotice("搜索已停止，当前进度不会保存。")

        Task { [searcher] in
            await searcher.cancel()
        }
    }

    func stopIfRunning() {
        if isRunning { stop() }
    }

    func clearResult() {
        guard !isRunning else { return }
        result = nil
        isPrivateKeyVisible = false
        historyBackupStatus = .idle
        status = .idle
        sampleAddress = "T—————————————————"
        showNotice("当前显示已清除，本机历史备份仍保留。")
    }

    func loadHistory() async {
        guard !didLoadHistory, !isHistoryLoading else { return }
        isHistoryLoading = true
        defer {
            isHistoryLoading = false
            didLoadHistory = true
        }

        do {
            let loaded = try await historyStore.load()
            mergeHistory(loaded)
        } catch {
            errorMessage = "读取本机历史失败：\(error.localizedDescription)"
        }
    }

    func copyAddress() {
        guard let result else { return }
        copy(result.address, label: "地址")
    }

    func copyPrivateKey() {
        guard let result else { return }
        copy(result.privateKey, label: "私钥", clearAfter: 30)
    }

    func copyHistoryAddress(_ record: HistoryRecord) {
        copy(record.address, label: "历史地址")
    }

    func copyHistoryPrivateKey(_ record: HistoryRecord) {
        copy(record.privateKey, label: "历史私钥", clearAfter: 30)
    }

    func exportResult() {
        guard let result else { return }

        let panel = NSSavePanel()
        panel.title = "导出 TRON 地址和私钥"
        panel.prompt = "导出"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "TRX-\(result.address).txt"

        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let contents = [
            "TRON (TRX) 靓号地址",
            "地址: \(result.address)",
            "私钥: \(result.privateKey)",
            "",
            "警告：获得此私钥的人可以控制该地址中的全部资产。请离线加密保管。",
        ].joined(separator: "\n")

        do {
            try writeSecureExport(contents, to: destination)
            showNotice("已导出密钥文件，请将它移到安全的离线位置。")
        } catch {
            errorMessage = "导出失败：\(error.localizedDescription)"
        }
    }

    func exportHistoryRecord(_ record: HistoryRecord) {
        let panel = NSSavePanel()
        panel.title = "导出历史 TRON 地址和私钥"
        panel.prompt = "导出"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "TRX-\(record.address).txt"

        guard panel.runModal() == .OK, let destination = panel.url else { return }

        do {
            try writeSecureExport(historyExportContents(for: record), to: destination)
            showNotice("已导出这条历史，文件权限为 0600。")
        } catch {
            errorMessage = "导出失败：\(error.localizedDescription)"
        }
    }

    func exportAllHistory() {
        guard !historyRecords.isEmpty else { return }

        let panel = NSSavePanel()
        panel.title = "导出全部 TRON 历史备份"
        panel.prompt = "导出全部"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "TRX-Vanity-全部备份.txt"

        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let contents = historyRecords
            .map(historyExportContents)
            .joined(separator: "\n\n========================================\n\n")

        do {
            try writeSecureExport(contents, to: destination)
            showNotice("已导出全部历史，请离线加密保管。")
        } catch {
            errorMessage = "导出全部历史失败：\(error.localizedDescription)"
        }
    }

    func deleteHistoryRecord(_ record: HistoryRecord) {
        Task { [weak self, historyStore] in
            do {
                try await historyStore.delete(id: record.id)
                guard let self else { return }
                self.historyRecords.removeAll { $0.id == record.id }
                self.showNotice("已删除这条本机历史。")
            } catch {
                self?.errorMessage = "删除历史失败：\(error.localizedDescription)"
            }
        }
    }

    func deleteAllHistory() {
        Task { [weak self, historyStore] in
            do {
                try await historyStore.deleteAll()
                guard let self else { return }
                self.historyRecords.removeAll()
                self.showNotice("已删除全部本机历史，已导出的文件不受影响。")
            } catch {
                self?.errorMessage = "删除全部历史失败：\(error.localizedDescription)"
            }
        }
    }

    func formattedHistoryDate(_ date: Date) -> String {
        date.formatted(
            .dateTime
                .year()
                .month(.twoDigits)
                .day(.twoDigits)
                .hour(.twoDigits(amPM: .omitted))
                .minute(.twoDigits)
                .second(.twoDigits)
        )
    }

    func historyPatternDescription(_ record: HistoryRecord) -> String {
        var parts: [String] = []
        if let prefix = record.prefix { parts.append("前段 \(prefix)") }
        if let suffix = record.suffix { parts.append("尾号 \(suffix)") }
        return parts.isEmpty ? "未记录匹配条件" : parts.joined(separator: "  ·  ")
    }

    func dismissMessage() {
        errorMessage = nil
        noticeMessage = nil
    }

    func formattedAttempts(_ value: UInt64) -> String {
        formattedNumber(Double(value))
    }

    func formattedExpectedAttempts() -> String {
        formattedNumber(expectedAttempts)
    }

    func formattedSpeed() -> String {
        guard speed > 0 else { return "—" }
        return formattedNumber(speed)
    }

    func formattedElapsed() -> String {
        let totalSeconds = max(0, Int(elapsed.rounded(.down)))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    func formattedRemaining() -> String {
        guard let seconds = estimatedRemaining else { return "等待实测" }
        if seconds < 1 { return "少于 1 秒" }
        if seconds < 60 { return "约 \(Int(ceil(seconds))) 秒" }
        if seconds < 3_600 { return "约 \(Int(ceil(seconds / 60))) 分钟" }
        if seconds < 86_400 { return String(format: "约 %.1f 小时", seconds / 3_600) }
        if seconds < 31_536_000 { return String(format: "约 %.1f 天", seconds / 86_400) }
        return String(format: "约 %.2e 年", seconds / 31_536_000)
    }

    private func consume(_ progress: SearchProgress, searchID: UUID) {
        guard activeSearchID == searchID, status == .running else { return }
        attempts = progress.attempts
        speed = progress.speed
        elapsed = progress.elapsed
        if !progress.sampleAddress.isEmpty {
            sampleAddress = progress.sampleAddress
        }
        if !progress.backendName.isEmpty {
            backendName = progress.backendName
        }
    }

    private func upsertHistory(_ record: HistoryRecord) {
        historyRecords.removeAll { $0.id == record.id }
        historyRecords.append(record)
        historyRecords.sort { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.createdAt > rhs.createdAt
        }
    }

    private func mergeHistory(_ loaded: [HistoryRecord]) {
        var recordsByID = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
        for record in historyRecords {
            recordsByID[record.id] = record
        }
        historyRecords = recordsByID.values.sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.createdAt > rhs.createdAt
        }
    }

    private func historyExportContents(for record: HistoryRecord) -> String {
        [
            "TRON (TRX) 靓号历史备份",
            "生成时间: \(formattedHistoryDate(record.createdAt))",
            "匹配条件: \(historyPatternDescription(record))",
            "地址: \(record.address)",
            "私钥: \(record.privateKey)",
            "",
            "警告：获得此私钥的人可以控制该地址中的全部资产。请离线加密保管。",
        ].joined(separator: "\n")
    }

    private func writeSecureExport(_ contents: String, to destination: URL) throws {
        guard let data = contents.data(using: .utf8) else {
            throw ExportError.encodingFailed
        }

        let fileManager = FileManager.default
        let permissions: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.setAttributes(permissions, ofItemAtPath: destination.path)
        } else if !fileManager.createFile(
            atPath: destination.path,
            contents: nil,
            attributes: permissions
        ) {
            throw ExportError.createFailed
        }

        let handle = try FileHandle(forWritingTo: destination)
        do {
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }

        // Apply and verify the permission after writing as well. A pre-existing
        // user-selected file may have had broader permissions before export.
        try fileManager.setAttributes(permissions, ofItemAtPath: destination.path)
        let attributes = try fileManager.attributesOfItem(atPath: destination.path)
        guard let mode = attributes[.posixPermissions] as? NSNumber,
              mode.intValue & 0o777 == 0o600 else {
            throw ExportError.insecurePermissions
        }
    }

    private func validationError() -> String? {
        guard prefixEnabled || suffixEnabled else {
            return "请至少开启一项匹配条件。"
        }
        if prefixEnabled {
            if prefix.count != prefixLength {
                return "前段数字需要填写 \(prefixLength) 位。"
            }
            if !isValidDigits(prefix) {
                return "前段数字只能使用 1–9；TRON Base58 地址不包含数字 0。"
            }
        }
        if suffixEnabled {
            if suffix.count != suffixLength {
                return "尾号数字需要填写 \(suffixLength) 位。"
            }
            if !isValidDigits(suffix) {
                return "尾号数字只能使用 1–9；TRON Base58 地址不包含数字 0。"
            }
        }
        return nil
    }

    private func validate(
        _ searchResult: VanitySearchResult,
        configuration: SearchConfiguration
    ) throws {
        let address = searchResult.address
        let prefixRegion = String(address.dropFirst(2))
        let prefixMatches = configuration.prefix.map(prefixRegion.hasPrefix) ?? true
        let suffixMatches = configuration.suffix.map(address.hasSuffix) ?? true
        let keyIsHex = searchResult.privateKey.count == 64
            && searchResult.privateKey.allSatisfy(\.isHexDigit)
        let derivedAddress = try? TronAddress.address(
            fromPrivateKeyHex: searchResult.privateKey
        )

        guard address.first == "T",
              prefixMatches,
              suffixMatches,
              keyIsHex,
              derivedAddress == address else {
            throw ResultValidationError.invalidResult
        }
    }

    private func copy(_ value: String, label: String, clearAfter seconds: UInt64? = nil) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.setString(value, forType: .string) {
            if let seconds {
                let changeCount = pasteboard.changeCount
                clipboardClearTask?.cancel()
                clipboardClearTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                    guard !Task.isCancelled,
                          NSPasteboard.general.changeCount == changeCount else { return }
                    NSPasteboard.general.clearContents()
                    self?.showNotice("剪贴板中的私钥已自动清除。")
                }
                showNotice("\(label)已复制，\(seconds) 秒后将自动清除剪贴板。")
            } else {
                showNotice("\(label)已复制到剪贴板。")
            }
        } else {
            errorMessage = "复制失败，请检查系统剪贴板权限。"
        }
    }

    private func showNotice(_ message: String) {
        noticeTask?.cancel()
        noticeMessage = message
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            guard !Task.isCancelled else { return }
            self?.noticeMessage = nil
        }
    }

    private func sanitizedDigits(_ value: String, maximumLength: Int) -> String {
        String(value.filter { ("1"..."9").contains(String($0)) }.prefix(maximumLength))
    }

    private func isValidDigits(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { ("1"..."9").contains(String($0)) }
    }

    private func clampedLength(_ length: Int) -> Int {
        min(
            max(length, SearchConfiguration.minimumPatternLength),
            SearchConfiguration.maximumPatternLength
        )
    }

    private func formattedNumber(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        if value < 1_000_000 {
            return value.formatted(.number.precision(.fractionLength(0)))
        }
        if value < 1_000_000_000 {
            return String(format: "%.2f 百万", value / 1_000_000)
        }
        if value < 1_000_000_000_000 {
            return String(format: "%.2f 十亿", value / 1_000_000_000)
        }
        return String(format: "%.2e", value)
    }
}

private enum ResultValidationError: LocalizedError {
    case invalidResult

    var errorDescription: String? {
        "生成结果未通过界面层校验，已停止搜索。"
    }
}

private enum ExportError: LocalizedError {
    case encodingFailed
    case createFailed
    case insecurePermissions

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "无法编码密钥文件。"
        case .createFailed:
            return "无法创建密钥文件。"
        case .insecurePermissions:
            return "无法将密钥文件权限限制为 0600。"
        }
    }
}

private final class WeakVanityViewModel: @unchecked Sendable {
    weak var value: VanityViewModel?

    init(_ value: VanityViewModel) {
        self.value = value
    }
}
