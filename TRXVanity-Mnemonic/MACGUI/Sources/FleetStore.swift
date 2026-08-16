import AppKit
import Foundation

struct FleetAddOutcome: Equatable, Sendable {
    var added = 0
    var updated = 0

    var total: Int { added + updated }
}

@MainActor
final class FleetStore: ObservableObject {
    @Published private(set) var machines: [MachineViewState] = []
    @Published private(set) var targetSuffix: String
    @Published var isAddSheetPresented = false

    private let defaultsKey = "trxvanity.monitor.machines.plaintext.v1"
    private var sessions: [UUID: any SSHSession] = [:]
    private let sessionFactory: @Sendable (MachineRecord) -> any SSHSession
    private let persistsRecords: Bool
    private var refreshTask: Task<Void, Never>?
    private var connectingIDs: Set<UUID> = []
    private var retryAfter: [UUID: Date] = [:]
    private let retryDelay: TimeInterval = 2
    private var didStart = false

    init() {
        targetSuffix = FormalSearch.persistedSuffix
        sessionFactory = { SSHConnection(record: $0, suffix: FormalSearch.persistedSuffix) }
        persistsRecords = true
        loadRecords()
        observeApplicationTermination()
    }

    init(
        records: [MachineRecord],
        sessionFactory: @escaping @Sendable (MachineRecord) -> any SSHSession
    ) {
        targetSuffix = FormalSearch.defaultSuffix
        self.sessionFactory = sessionFactory
        persistsRecords = false
        machines = records.map { MachineViewState(record: $0) }
    }

    func updateTargetSuffix(_ raw: String) {
        let filtered = FormalSearch.filterInput(raw)
        guard filtered != targetSuffix else { return }
        targetSuffix = filtered
        if persistsRecords {
            FormalSearch.persistedSuffix = filtered
        }
    }

    private func observeApplicationTermination() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.stopAll() }
        }
    }

    var runningMachines: [MachineViewState] {
        machines.filter { $0.snapshot?.status.state == "searching" }
    }

    var onlineCount: Int {
        machines.filter { $0.snapshot != nil }.count
    }

    var offlineCount: Int {
        max(0, machines.count - onlineCount)
    }

    var totalSpeed: Double {
        runningMachines.reduce(0) { $0 + max(0, $1.snapshot?.status.speed ?? 0) }
    }

    var totalAttempts: Double {
        machines.reduce(0) { $0 + Double($1.snapshot?.status.attempts ?? 0) }
    }

    var longestElapsed: Double {
        runningMachines.map { $0.snapshot?.status.elapsedSeconds ?? 0 }.max() ?? 0
    }

    var runningSuffixes: [String] {
        runningMachines.compactMap { machine in
            guard let suffix = machine.snapshot?.status.suffix, FormalSearch.isValid(suffix) else {
                return nil
            }
            return suffix
        }
    }

    var forecastSuffix: String {
        let unique = Set(runningSuffixes)
        if unique.count == 1, let suffix = unique.first {
            return suffix
        }
        return FormalSearch.isValid(targetSuffix) ? targetSuffix : FormalSearch.defaultSuffix
    }

    var suffixSummary: String {
        let unique = Set(runningSuffixes)
        if unique.count > 1 {
            return "多台尾号不同"
        }
        if unique.count == 1, let suffix = unique.first {
            return suffix == targetSuffix ? "目标尾号 \(suffix)" : "正在搜 \(suffix)"
        }
        return FormalSearch.isValid(targetSuffix) ? "目标尾号 \(targetSuffix)" : "未设置尾号"
    }

    var forecast: FleetForecast {
        FleetForecast(attempts: totalAttempts, speed: totalSpeed, suffix: forecastSuffix)
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        Task {
            for machine in machines { await connect(machine.id) }
            await refreshAll()
        }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                await self.refreshAll()
            }
        }
    }

    @discardableResult
    func add(records: [MachineRecord]) -> FleetAddOutcome {
        var outcome = FleetAddOutcome()
        var pendingIDs: [UUID] = []
        for var record in records {
            if let existing = machines.first(where: {
                $0.record.user == record.user
                    && $0.record.host == record.host
                    && $0.record.port == record.port
            }) {
                record.id = existing.id
                update(record.id) {
                    $0.record.password = record.password
                    $0.record.privateKey = record.privateKey
                    $0.record.localForward = record.localForward
                    $0.phase = .saved
                }
                outcome.updated += 1
            } else {
                machines.append(MachineViewState(record: record))
                outcome.added += 1
            }
            pendingIDs.append(record.id)
        }
        guard !pendingIDs.isEmpty else { return outcome }

        saveRecords()
        isAddSheetPresented = false
        // Connect in parallel; a batch of twenty would otherwise wait out one handshake at a time.
        for id in pendingIDs {
            Task { [weak self] in await self?.connect(id) }
        }
        return outcome
    }

    func connect(_ id: UUID) async {
        await connect(id, allowWhileUploading: false)
    }

    private func connect(_ id: UUID, allowWhileUploading: Bool) async {
        guard !connectingIDs.contains(id) else { return }
        guard let machine = machines.first(where: { $0.id == id }),
              allowWhileUploading || !machine.isUploading
        else { return }
        let record = machine.record
        connectingIDs.insert(id)
        retryAfter[id] = nil
        defer { connectingIDs.remove(id) }
        update(id) { $0.phase = .connecting; $0.snapshot = nil; $0.uploadError = nil }
        if let old = sessions[id] { await old.disconnect() }
        guard machineExists(id) else { return }
        let session = sessionFactory(record)
        sessions[id] = session
        do {
            update(id) { $0.phase = .checking }
            let preparation = try await session.prepareAndStart()
            guard machineExists(id) else {
                sessions[id] = nil
                await session.disconnect()
                return
            }
            switch preparation {
            case .missingFiles(let files):
                clearRetry(for: id)
                update(id) { $0.phase = .missingFiles(files) }
                return
            case .secretMissing:
                clearRetry(for: id)
                update(id) { $0.phase = .secretMissing }
                return
            case .running:
                break
            case .started:
                update(id) { $0.phase = .starting }
            }
            try await session.startTunnel()
            guard machineExists(id) else {
                sessions[id] = nil
                await session.disconnect()
                return
            }
            let snapshot = try await session.fetchSnapshot()
            guard machineExists(id) else {
                sessions[id] = nil
                await session.disconnect()
                return
            }
            clearRetry(for: id)
            update(id) { $0.snapshot = snapshot; $0.phase = .searching }
        } catch {
            if !machineExists(id) {
                sessions[id] = nil
                await session.disconnect()
                return
            }
            scheduleReconnect(for: id, message: error.localizedDescription)
        }
    }

    func uploadRuntime(for id: UUID) async {
        guard let machine = machines.first(where: { $0.id == id }),
              !machine.isUploading,
              case .missingFiles = machine.phase
        else { return }

        update(id) { $0.isUploading = true; $0.uploadProgress = nil; $0.uploadError = nil }
        if sessions[id] == nil {
            await connect(id, allowWhileUploading: true)
        }

        guard machineExists(id),
              let current = machines.first(where: { $0.id == id }),
              case .missingFiles = current.phase,
              let session = sessions[id]
        else {
            update(id) { $0.isUploading = false; $0.uploadProgress = nil }
            return
        }

        do {
            try await session.uploadBundledRuntime { [weak self] progress in
                Task { @MainActor in
                    self?.update(id) { $0.uploadProgress = progress }
                }
            }
            update(id) { $0.isUploading = false; $0.uploadProgress = nil; $0.uploadError = nil; $0.phase = .checking }
            await connect(id)
        } catch {
            let files: [String]
            if case .missingFiles(let current) = machines.first(where: { $0.id == id })?.phase {
                files = current
            } else {
                files = ["运行包"]
            }
            update(id) {
                $0.isUploading = false
                $0.uploadProgress = nil
                $0.uploadError = error.localizedDescription
                $0.phase = .missingFiles(files)
            }
        }
    }

    func remove(_ id: UUID) {
        remove(ids: Set([id]))
    }

    func remove(ids: Set<UUID>) {
        let validIDs = Set(ids.filter { id in
            machines.contains { $0.id == id }
        })
        guard !validIDs.isEmpty else { return }

        let sessionsToDisconnect = validIDs.compactMap { sessions.removeValue(forKey: $0) }
        for id in validIDs {
            retryAfter[id] = nil
        }
        machines.removeAll { validIDs.contains($0.id) }
        saveRecords()
        for session in sessionsToDisconnect {
            Task { await session.disconnect() }
        }
    }

    func refreshAll() async {
        let states = machines.map { ($0.id, $0.phase) }
        let now = Date()
        var reconnectIDs: [UUID] = []
        for (id, phase) in states {
            switch phase {
            case .searching:
                guard let session = sessions[id] else {
                    scheduleReconnect(for: id, message: "SSH 监控会话不存在。")
                    continue
                }
                do {
                    let snapshot = try await session.fetchSnapshot()
                    clearRetry(for: id)
                    update(id) { $0.snapshot = snapshot; $0.phase = .searching }
                } catch {
                    scheduleReconnect(for: id, message: error.localizedDescription)
                }
            case .offline:
                let due = retryAfter[id] ?? .distantPast
                if due <= now, !connectingIDs.contains(id) {
                    reconnectIDs.append(id)
                }
            default:
                continue
            }
        }
        for id in reconnectIDs {
            Task { [weak self] in await self?.connect(id) }
        }
    }

    func stopAll() async {
        refreshTask?.cancel()
        refreshTask = nil
        let active = Array(sessions.values)
        sessions.removeAll()
        connectingIDs.removeAll()
        retryAfter.removeAll()
        for session in active { await session.disconnect() }
    }

    private func clearRetry(for id: UUID) {
        retryAfter[id] = nil
    }

    private func machineExists(_ id: UUID) -> Bool {
        machines.contains { $0.id == id }
    }

    private func scheduleReconnect(for id: UUID, message: String) {
        guard machines.contains(where: { $0.id == id }) else { return }
        retryAfter[id] = Date().addingTimeInterval(retryDelay)
        let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
        update(id) {
            $0.snapshot = nil
            $0.phase = .offline("\(detail.isEmpty ? "SSH 或监控连接失败。" : detail)\n\(Int(retryDelay)) 秒后自动重试。")
        }
    }

    private func update(_ id: UUID, change: (inout MachineViewState) -> Void) {
        guard let index = machines.firstIndex(where: { $0.id == id }) else { return }
        change(&machines[index])
    }

    private func loadRecords() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let records = try? JSONDecoder().decode([MachineRecord].self, from: data)
        else { return }
        machines = records.map { MachineViewState(record: $0) }
    }

    private func saveRecords() {
        guard persistsRecords else { return }
        let records = machines.map(\.record)
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
