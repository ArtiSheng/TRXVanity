import SwiftUI

struct ContentView: View {
    @ObservedObject var store: FleetStore
    @State private var isSelectionMode = false
    @State private var selectedMachineIDs: Set<UUID> = []
    @State private var pendingBatchIDs: Set<UUID> = []
    @State private var isBatchDeleteConfirmationPresented = false

    var body: some View {
        ZStack {
            MonitorTheme.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 18) {
                    header
                    summary
                    forecast
                    machines
                }
                .padding(.horizontal, 28)
                .padding(.top, 22)
                .padding(.bottom, 30)
            }
            .scrollIndicators(.hidden)
        }
        .foregroundStyle(MonitorTheme.primaryText)
        .tint(MonitorTheme.accent)
        .preferredColorScheme(.light)
        .sheet(isPresented: $store.isAddSheetPresented) {
            AddMachineView(store: store)
                .preferredColorScheme(.light)
                .withoutFocusRing()
        }
        .confirmationDialog("删除选中的机器？", isPresented: $isBatchDeleteConfirmationPresented) {
            Button("删除 \(pendingBatchIDs.count) 台", role: .destructive) {
                deletePendingMachines()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只删除 App 内的连接配置，不会停止远程搜索。")
        }
    }

    private var machineIDs: Set<UUID> {
        Set(store.machines.map(\.id))
    }

    private var validSelectedMachineIDs: Set<UUID> {
        selectedMachineIDs.intersection(machineIDs)
    }

    private var allMachinesSelected: Bool {
        !store.machines.isEmpty && validSelectedMachineIDs.count == store.machines.count
    }

    private func beginSelectionMode() {
        isSelectionMode = true
        selectedMachineIDs.removeAll()
    }

    private func endSelectionMode() {
        isSelectionMode = false
        selectedMachineIDs.removeAll()
        pendingBatchIDs.removeAll()
    }

    private func toggleMachineSelection(_ id: UUID) {
        guard isSelectionMode else { return }
        if selectedMachineIDs.contains(id) {
            selectedMachineIDs.remove(id)
        } else if machineIDs.contains(id) {
            selectedMachineIDs.insert(id)
        }
    }

    private func selectAllMachines() {
        selectedMachineIDs = allMachinesSelected ? [] : machineIDs
    }

    private func requestBatchDelete() {
        let ids = validSelectedMachineIDs
        guard !ids.isEmpty else { return }
        pendingBatchIDs = ids
        isBatchDeleteConfirmationPresented = true
    }

    private func deletePendingMachines() {
        let ids = pendingBatchIDs.intersection(machineIDs)
        guard !ids.isEmpty else {
            endSelectionMode()
            return
        }
        store.remove(ids: ids)
        endSelectionMode()
    }

    private func removeMachine(_ id: UUID) {
        selectedMachineIDs.remove(id)
        store.remove(id)
    }

    private var forecastFooter: String {
        let suffix = store.forecastSuffix
        let mixed = Set(store.runningSuffixes).count > 1
        let base = "100% 代表完成一份 \(suffix.isEmpty ? "当前尾号" : "尾号 \(suffix)") 的平均搜索工作量，对应累计命中概率约 63.21%，不代表保证命中。"
        if mixed {
            return "多台机器正在搜不同尾号，进度按 \(suffix) 估算，仅供参考。" + base
        }
        return base
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image("BrandMark")
                .resizable()
                .interpolation(.high)
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text("TRX VANITY MONITOR")
                    .font(.caption.weight(.semibold))
                    .tracking(1.7)
                    .foregroundStyle(MonitorTheme.secondaryText)
                Text("算力集群")
                    .font(.system(size: 26, weight: .semibold))
            }

            Spacer()

            StatusPill(
                text: "监控在线 \(store.onlineCount) / \(store.machines.count)",
                color: store.onlineCount > 0 ? MonitorTheme.online : MonitorTheme.secondaryText
            )

            SuffixEditor(text: Binding(
                get: { store.targetSuffix },
                set: { store.updateTargetSuffix($0) }
            ))

            Button {
                store.isAddSheetPresented = true
            } label: {
                Label("添加机器", systemImage: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(MonitorTheme.accent)
                    .padding(.horizontal, 8)
                    .frame(height: 38)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var summary: some View {
        HStack(spacing: 12) {
            SummaryCard(
                eyebrow: "总算力",
                value: DisplayFormat.compact(store.totalSpeed),
                detail: "次 / 秒",
                systemImage: "bolt.fill",
                isProminent: true
            )
            SummaryCard(
                eyebrow: "正在搜索",
                value: "\(store.runningMachines.count) / \(store.machines.count)",
                detail: store.suffixSummary,
                systemImage: "server.rack",
                isProminent: true
            )
            SummaryCard(
                eyebrow: "累计搜索",
                value: DisplayFormat.compact(store.totalAttempts),
                detail: "独立随机区间合计",
                systemImage: "number",
                isProminent: true
            )
        }
    }

    private var forecast: some View {
        let data = store.forecast
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("SEARCH FORECAST")
                        .font(.caption2.weight(.semibold))
                        .tracking(1.5)
                        .foregroundStyle(MonitorTheme.secondaryText)
                    Text("搜索进度与命中概率")
                        .font(.title3.weight(.semibold))
                }
                Spacer()
                Text("平均工作量 ≠ 保证命中")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(MonitorTheme.secondaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(MonitorTheme.surfaceRaised, in: Capsule())
            }

            HStack(alignment: .lastTextBaseline, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("当前搜索百分比")
                        .font(.caption)
                        .foregroundStyle(MonitorTheme.secondaryText)
                    Text(DisplayFormat.percent(data.workProgress, unclamped: true))
                        .font(.system(size: 38, weight: .semibold).monospacedDigit())
                        .foregroundStyle(MonitorTheme.accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text("累计命中概率")
                        .font(.caption)
                        .foregroundStyle(MonitorTheme.secondaryText)
                    Text(DisplayFormat.percent(data.cumulativeProbability))
                        .font(.system(size: 27, weight: .semibold).monospacedDigit())
                        .foregroundStyle(MonitorTheme.accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }

            FlatProgressBar(value: data.workProgress, color: MonitorTheme.accent)

            HStack(spacing: 10) {
                ForecastMetric(
                    title: "已搜索时间",
                    value: DisplayFormat.duration(store.longestElapsed)
                )
                ForecastMetric(
                    title: "预计到 50%",
                    value: DisplayFormat.duration(data.until50Seconds)
                )
                ForecastMetric(
                    title: "预计平均工作量",
                    value: DisplayFormat.duration(data.until100Seconds)
                )
            }

            Text(forecastFooter)
                .font(.caption)
                .foregroundStyle(MonitorTheme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .dashboardPanel(fill: MonitorTheme.accentSurface, border: MonitorTheme.accentBorder)
    }

    @ViewBuilder
    private var machines: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("机器")
                    .font(.system(size: 30, weight: .semibold))
                StatusLegend(text: "在线 \(store.onlineCount) 台", color: MonitorTheme.online)
                StatusLegend(
                    text: "离线 \(store.offlineCount) 台",
                    color: store.offlineCount > 0 ? MonitorTheme.danger : MonitorTheme.secondaryText
                )
                Spacer()
                if !isSelectionMode && !store.machines.isEmpty {
                    Button {
                        beginSelectionMode()
                    } label: {
                        Label("多选", systemImage: "checklist")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(MonitorTheme.accent)
                    }
                    .buttonStyle(.plain)
                }
                Text("每 2 秒刷新")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(MonitorTheme.secondaryText)
            }

            if isSelectionMode {
                selectionToolbar
            }

            if store.machines.isEmpty {
                EmptyMachinesView { store.isAddSheetPresented = true }
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 5),
                    spacing: 12
                ) {
                    ForEach(store.machines) { machine in
                        MachineCard(
                            machine: machine,
                            isSelectionMode: isSelectionMode,
                            isSelected: validSelectedMachineIDs.contains(machine.id),
                            toggleSelection: { toggleMachineSelection(machine.id) },
                            retry: { Task { await store.connect(machine.id) } },
                            upload: { Task { await store.uploadRuntime(for: machine.id) } },
                            remove: { removeMachine(machine.id) }
                        )
                    }
                }
            }
        }
    }

    private var selectionToolbar: some View {
        HStack(spacing: 12) {
            Text("已选 \(validSelectedMachineIDs.count) 台")
                .font(.caption.weight(.semibold))
                .foregroundStyle(MonitorTheme.primaryText)

            Spacer()

            Button(allMachinesSelected ? "取消全选" : "全选") {
                selectAllMachines()
            }
            .buttonStyle(.plain)
            .foregroundStyle(MonitorTheme.accent)

            Button {
                requestBatchDelete()
            } label: {
                Label("删除 \(validSelectedMachineIDs.count)", systemImage: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(MonitorTheme.danger)
            .disabled(validSelectedMachineIDs.isEmpty)
            .opacity(validSelectedMachineIDs.isEmpty ? 0.45 : 1)

            Button("取消") {
                endSelectionMode()
            }
            .buttonStyle(.plain)
            .foregroundStyle(MonitorTheme.secondaryText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(MonitorTheme.surfaceMuted, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(MonitorTheme.border, lineWidth: 1)
        )
    }
}

private struct SuffixEditor: View {
    @Binding var text: String

    private var isValid: Bool { FormalSearch.isValid(text) }
    private var isShort: Bool { isValid && text.count <= 3 }

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            HStack(spacing: 7) {
                Text("尾号")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MonitorTheme.secondaryText)
                TextField(FormalSearch.defaultSuffix, text: $text)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .textFieldStyle(.plain)
                    .disableAutocorrection(true)
                    .withoutFocusRing()
                    .frame(width: 112)
                    .onChange(of: text) { newValue in
                        let filtered = FormalSearch.filterInput(newValue)
                        if filtered != newValue {
                            text = filtered
                        }
                    }
            }
            .padding(.horizontal, 11)
            .frame(height: 34)
            .background(MonitorTheme.surface, in: Capsule())
            .overlay(
                Capsule().stroke(
                    isValid ? MonitorTheme.border : MonitorTheme.danger,
                    lineWidth: 1
                )
            )
            if !isValid {
                Text("1–10 位 Base58，不含 0OIl")
                    .font(.caption2)
                    .foregroundStyle(MonitorTheme.danger)
            } else if isShort {
                Text("3 位及以下请确认")
                    .font(.caption2)
                    .foregroundStyle(MonitorTheme.warning)
            }
        }
    }
}

private struct StatusPill: View {
    var text: String
    var color: Color

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(MonitorTheme.primaryText)
        }
        .padding(.horizontal, 11)
        .frame(height: 34)
        .background(MonitorTheme.surface, in: Capsule())
        .overlay(Capsule().stroke(MonitorTheme.border, lineWidth: 1))
    }
}

private struct StatusLegend: View {
    var text: String
    var color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text)
                .font(.system(size: 16, weight: .semibold))
                .monospacedDigit()
        }
    }
}

private struct SummaryCard: View {
    var eyebrow: String
    var value: String
    var detail: String
    var systemImage: String
    var isProminent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text(eyebrow)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(MonitorTheme.secondaryText)
                Spacer()
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isProminent ? MonitorTheme.accent : MonitorTheme.secondaryText)
            }

            Text(value)
                .font(.system(size: isProminent ? 38 : 30, weight: .semibold).monospacedDigit())
                .foregroundStyle(isProminent ? MonitorTheme.accent : MonitorTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.65)

            Text(detail)
                .font(.caption)
                .foregroundStyle(MonitorTheme.secondaryText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .dashboardPanel(
            fill: isProminent ? MonitorTheme.accentSurface : MonitorTheme.surface,
            border: isProminent ? MonitorTheme.accentBorder : MonitorTheme.border
        )
    }
}

private struct FlatProgressBar: View {
    var value: Double
    var color: Color

    private var normalizedValue: Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(MonitorTheme.surfaceRaised)
                Capsule()
                    .fill(color)
                    .frame(width: geometry.size.width * normalizedValue)
            }
        }
        .frame(height: 6)
        .accessibilityValue(DisplayFormat.percent(value, unclamped: true))
    }
}

private struct ForecastMetric: View {
    var title: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(MonitorTheme.secondaryText)
            Text(value)
                .font(.headline.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(MonitorTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct EmptyMachinesView: View {
    var add: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "server.rack")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(MonitorTheme.secondaryText)
            Text("还没有机器")
                .font(.headline)
            Text("添加 SSH 连接后，这里会显示算力、显卡状态和搜索预测。")
                .font(.callout)
                .foregroundStyle(MonitorTheme.secondaryText)
            Button("添加机器", action: add)
                .buttonStyle(AccentButtonStyle())
        }
        .frame(maxWidth: .infinity, minHeight: 230)
        .dashboardPanel()
    }
}

private struct MachineCard: View {
    var machine: MachineViewState
    var isSelectionMode: Bool
    var isSelected: Bool
    var toggleSelection: () -> Void
    var retry: () -> Void
    var upload: () -> Void
    var remove: () -> Void

    @State private var confirmUpload = false
    @State private var confirmRemove = false

    private var status: MonitorStatus? { machine.snapshot?.status }
    private var telemetry: RemoteTelemetry? { machine.snapshot?.telemetry }

    private var rawDeviceName: String {
        let value = status?.engineDevice?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "等待显卡信息" : value
    }

    private var deviceTitle: String {
        let title: String
        if let detailStart = rawDeviceName.firstIndex(of: "(") {
            title = rawDeviceName[..<detailStart].trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            title = rawDeviceName
        }
        guard !title.isEmpty else { return rawDeviceName }
        return title.replacingOccurrences(
            of: "NVIDIA GeForce ",
            with: "",
            options: [.anchored, .caseInsensitive]
        )
    }

    private var deviceDetail: String? {
        guard let detailStart = rawDeviceName.firstIndex(of: "("),
              let detailEnd = rawDeviceName.lastIndex(of: ")"),
              detailStart < detailEnd else { return nil }
        let value = rawDeviceName[rawDeviceName.index(after: detailStart)..<detailEnd]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private var remoteErrorDetail: String {
        let value = status?.detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "远程控制器返回错误状态。" : value
    }

    @ViewBuilder
    private var primaryContent: some View {
        if case .missingFiles(let files) = machine.phase {
            MissingFilesView(
                files: files,
                isUploading: machine.isUploading,
                progress: machine.isUploading ? machine.uploadProgress : nil,
                errorMessage: machine.isUploading ? nil : machine.uploadError
            ) {
                confirmUpload = true
            }
        } else if case .secretMissing = machine.phase {
            NoticeView(
                icon: "key.slash",
                title: "内存密钥恢复失败",
                detail: "确认本机钥匙串项可读后点击重新连接。",
                color: MonitorTheme.warning
            )
        } else if case .offline(let message) = machine.phase {
            NoticeView(
                icon: "wifi.exclamationmark",
                title: "SSH 或监控连接失败",
                detail: message,
                color: MonitorTheme.danger
            )
        } else if status?.state?.lowercased() == "error" {
            NoticeView(
                icon: "exclamationmark.triangle",
                title: "远程搜索运行错误",
                detail: remoteErrorDetail,
                color: MonitorTheme.danger
            )
        } else {
            speedContent
        }
    }

    private var speedContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("实时速度")
                .font(.caption)
                .foregroundStyle(MonitorTheme.secondaryText)
            Text(DisplayFormat.compact(status?.speed ?? 0))
                .font(.system(size: 30, weight: .semibold).monospacedDigit())
                .foregroundStyle(MonitorTheme.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.58)
            Text("次 / 秒")
                .font(.caption2)
                .foregroundStyle(MonitorTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
    }

    private var cardHeader: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if isSelectionMode {
                    Button(action: toggleSelection) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(isSelected ? MonitorTheme.accent : MonitorTheme.secondaryText)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isSelected ? "取消选择机器" : "选择机器")
                }

                Text(deviceTitle)
                    .font(.system(size: 20, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Menu {
                    Button("重新连接", action: retry)
                        .disabled(machine.isUploading)
                    Divider()
                    Button("移除机器", role: .destructive) { confirmRemove = true }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(MonitorTheme.secondaryText)
                        .frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            HStack(spacing: 6) {
                MachineStateBadge(phase: machine.phase, remoteState: status?.state)
                if let suffix = status?.suffix, FormalSearch.isValid(suffix) {
                    Text(suffix)
                        .font(.caption2.weight(.semibold).monospaced())
                        .foregroundStyle(MonitorTheme.secondaryText)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(MonitorTheme.surfaceRaised, in: Capsule())
                        .overlay(Capsule().stroke(MonitorTheme.border, lineWidth: 1))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let deviceDetail {
                Text(deviceDetail)
                    .font(.caption2)
                    .foregroundStyle(MonitorTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            cardHeader
            primaryContent
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)

            VStack(alignment: .leading, spacing: 6) {
                UtilizationBar(
                    title: "CPU",
                    value: telemetry?.cpuPercent,
                    color: MonitorTheme.primaryText.opacity(0.72)
                )
                UtilizationBar(
                    title: "GPU",
                    value: telemetry?.gpuPercent,
                    color: MonitorTheme.accent
                )
                UtilizationBar(
                    title: "显存",
                    value: telemetry?.gpuMemoryPercent,
                    color: MonitorTheme.secondaryText
                )
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 6),
                    GridItem(.flexible(), spacing: 6)
                ],
                spacing: 6
            ) {
                MiniMetric(title: "累计尝试", value: DisplayFormat.compact(Double(status?.attempts ?? 0)))
                MiniMetric(title: "搜索时间", value: DisplayFormat.duration(status?.elapsedSeconds))
                MiniMetric(title: "CPU 线程", value: status?.engineCPUWorkers.map(String.init) ?? "—")
                MiniMetric(title: "备份心跳", value: status?.heartbeatOK == true ? "正常" : "未确认")
            }

            Rectangle()
                .fill(MonitorTheme.border)
                .frame(height: 1)

            DetailsGrid(status: status, telemetry: telemetry)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 500, alignment: .top)
        .dashboardPanel()
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(MonitorTheme.accent, lineWidth: 2)
            }
            if status?.state?.lowercased() == "searching" {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(MonitorTheme.accentBorder, lineWidth: 1.5)
            }
        }
        .confirmationDialog("上传内置生产运行包？", isPresented: $confirmUpload) {
            Button("上传到 /root/autodl-fs") { upload() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("App 将上传编译引擎和必要运行脚本，不上传 C++/CUDA 源码；上传后会核对 SHA-256。")
        }
        .alert("移除这台机器？", isPresented: $confirmRemove) {
            Button("移除", role: .destructive) { remove() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只删除 App 内的连接配置，不会停止远程搜索。")
        }
    }
}

private struct MachineStateBadge: View {
    var phase: MachinePhase
    var remoteState: String?

    private var presentation: (label: String, color: Color) {
        switch phase {
        case .offline:
            return ("连接失败", MonitorTheme.danger)
        case .missingFiles:
            return ("缺少运行文件", MonitorTheme.warning)
        case .secretMissing:
            return ("缺少内存密钥", MonitorTheme.warning)
        case .saved:
            return ("等待连接", MonitorTheme.secondaryText)
        case .connecting:
            return ("SSH 连接中", MonitorTheme.secondaryText)
        case .checking:
            return ("检查运行文件", MonitorTheme.secondaryText)
        case .starting:
            return ("启动搜索", MonitorTheme.secondaryText)
        case .searching:
            return remotePresentation
        }
    }

    private var remotePresentation: (label: String, color: Color) {
        guard let state = remoteState?.lowercased(), !state.isEmpty else {
            return ("监控已连接", MonitorTheme.secondaryText)
        }
        switch state {
        case "starting": return ("正在初始化", MonitorTheme.secondaryText)
        case "ready": return ("引擎就绪", MonitorTheme.secondaryText)
        case "searching": return ("搜索中", MonitorTheme.online)
        case "verifying": return ("已命中 · 验证中", MonitorTheme.warning)
        case "result": return ("结果已验证", MonitorTheme.online)
        case "cleanup_launching": return ("安全清理启动中", MonitorTheme.warning)
        case "stopping": return ("正在停止", MonitorTheme.warning)
        case "closing": return ("正在关闭", MonitorTheme.secondaryText)
        case "error": return ("运行错误", MonitorTheme.danger)
        default: return ("未知状态 · \(state)", MonitorTheme.secondaryText)
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(presentation.color)
                .frame(width: 6, height: 6)
            Text(presentation.label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(MonitorTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(MonitorTheme.surfaceRaised, in: Capsule())
        .overlay(Capsule().stroke(MonitorTheme.border, lineWidth: 1))
    }
}

private struct UtilizationBar: View {
    var title: String
    var value: Double?
    var color: Color

    private var normalizedValue: Double {
        guard let value, value.isFinite else { return 0 }
        return min(1, max(0, value / 100))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 2) {
                Text(title)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 1)
                Text(DisplayFormat.utilization(value))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(MonitorTheme.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(MonitorTheme.surfaceRaised)
                    Capsule()
                        .fill(color)
                        .frame(width: geometry.size.width * normalizedValue)
                }
            }
            .frame(height: 4)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct MiniMetric: View {
    var title: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(MonitorTheme.secondaryText)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
            Text(value)
                .font(.caption2.weight(.semibold).monospacedDigit())
                .lineLimit(2)
                .minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .background(MonitorTheme.surfaceMuted, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct DetailsGrid: View {
    var status: MonitorStatus?
    var telemetry: RemoteTelemetry?

    var body: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8)
            ],
            alignment: .leading,
            spacing: 8
        ) {
            detail("计算方案", status?.engineProfile ?? "—")
            detail("CUDA 批次", status?.engineBatchSize.map { DisplayFormat.number(Double($0)) } ?? "—")
            detail("CUDA 线程块", blocks)
            detail("GPU 显存", memory)
            detail("CPU 配额", cpuBudget)
            detail("状态更新", DisplayFormat.beijingDateTime(status?.updatedAt))
        }
    }

    private var blocks: String {
        guard let master = status?.engineCUDAMasterBlockSize,
              let address = status?.engineCUDAAddressBlockSize else { return "—" }
        return "\(master) / \(address)"
    }

    private var memory: String {
        guard let used = telemetry?.gpuMemoryUsedMiB,
              let total = telemetry?.gpuMemoryTotalMiB else { return "—" }
        return String(format: "%.0f / %.0f MiB", used, total)
    }

    private var cpuBudget: String {
        guard let budget = status?.engineCPUBudget else { return "—" }
        return "\(budget) 核\(status?.engineCPUBudgetSource.map { "（\($0)）" } ?? "")"
    }

    private func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(MonitorTheme.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Text(value)
                .font(.caption2.weight(.medium).monospacedDigit())
                .foregroundStyle(MonitorTheme.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .minimumScaleFactor(0.55)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MissingFilesView: View {
    var files: [String]
    var isUploading: Bool
    var progress: RuntimeUploadProgress?
    var errorMessage: String?
    var upload: () -> Void

    private var progressLabel: String {
        guard let progress else { return "正在准备上传…" }
        return "已发送 \(DisplayFormat.bytes(progress.bytesSent)) / \(DisplayFormat.bytes(progress.totalBytes))"
    }

    @ViewBuilder
    private var uploadControl: some View {
        if isUploading {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: progress?.fraction ?? 0)
                    .progressViewStyle(.linear)
                    .tint(MonitorTheme.accent)
                HStack(spacing: 6) {
                    Text(progressLabel)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Spacer(minLength: 0)
                    Text(DisplayFormat.utilization((progress?.fraction ?? 0) * 100))
                        .monospacedDigit()
                }
                .font(.caption2)
                .foregroundStyle(MonitorTheme.secondaryText)
            }
            .frame(maxWidth: .infinity)
        } else {
            Button(action: upload) {
                Label("上传", systemImage: "arrow.up.circle")
            }
            .buttonStyle(NeutralButtonStyle())
            .frame(maxWidth: .infinity)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(MonitorTheme.warning)
                Text("硬盘缺少运行所需文件")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(files.joined(separator: "、"))
                    .font(.caption.monospaced())
                    .foregroundStyle(MonitorTheme.secondaryText)
                    .lineLimit(1)
                    .help(files.joined(separator: "、"))
                    .textSelection(.enabled)
            }
            if let errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(MonitorTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            uploadControl
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MonitorTheme.surfaceMuted, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(MonitorTheme.warning.opacity(0.45), lineWidth: 1)
        )
    }
}

private struct NoticeView: View {
    var icon: String
    var title: String
    var detail: String
    var color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(MonitorTheme.secondaryText)
                .lineLimit(3)
                .truncationMode(.middle)
                .help(detail)
                .textSelection(.enabled)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MonitorTheme.surfaceMuted, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(color.opacity(0.45), lineWidth: 1)
        )
    }
}

private struct AddMachineView: View {
    @ObservedObject var store: FleetStore
    @State private var loginText = ""

    private static let placeholder = """
    ssh -p 22 root@203.0.113.10
    第一台的密码

    ssh -p 22 root@host.example.com
    第二台的密码

    ssh -p 22 root@10.0.0.9 -L 8080:localhost:8080
    -----BEGIN OPENSSH PRIVATE KEY-----
    ...
    -----END OPENSSH PRIVATE KEY-----
    """

    private static func summaryText(for batch: SSHLoginBatch) -> String {
        guard !batch.records.isEmpty else { return "" }
        var text = "识别到 \(batch.records.count) 台机器"
        if batch.mergedDuplicates > 0 {
            text += "，已合并 \(batch.mergedDuplicates) 条重复"
        }
        return text
    }

    /// Adding only the valid half of a paste would hide the typo, so every entry must parse first.
    private static func canConfirm(_ batch: SSHLoginBatch, suffix: String) -> Bool {
        !batch.records.isEmpty && batch.failures.isEmpty && FormalSearch.isValid(suffix)
    }

    private static func confirmTitle(for batch: SSHLoginBatch, suffix: String) -> String {
        guard FormalSearch.isValid(suffix) else { return "请先填写有效尾号" }
        guard batch.failures.isEmpty else { return "请先修正上面的错误" }
        return batch.records.count > 1 ? "添加并连接 \(batch.records.count) 台" : "添加并连接"
    }

    @ViewBuilder
    private func parseReport(for batch: SSHLoginBatch) -> some View {
        let summary = Self.summaryText(for: batch)
        VStack(alignment: .leading, spacing: 6) {
            if !summary.isEmpty {
                Label(summary, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(MonitorTheme.accent)
            }
            ForEach(batch.failures.prefix(4), id: \.lineNumber) { failure in
                Text("第 \(failure.lineNumber) 行 · \(failure.command)\n\(failure.message)")
                    .font(.caption)
                    .foregroundStyle(MonitorTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if batch.failures.count > 4 {
                Text("还有 \(batch.failures.count - 4) 处需要修正。")
                    .font(.caption)
                    .foregroundStyle(MonitorTheme.danger)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        let batch = SSHLoginParser.parseBatch(loginText)
        return ZStack {
            MonitorTheme.background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("批量添加 SSH 机器")
                            .font(.title2.weight(.semibold))
                        Text("先确认尾号，再粘贴 SSH。每台一段：第一行是 SSH 命令，紧接着是密码或完整私钥。可一次粘贴多台，段之间的空行可有可无。")
                            .font(.callout)
                            .foregroundStyle(MonitorTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("取消") { store.isAddSheetPresented = false }
                        .buttonStyle(NeutralButtonStyle())
                }

                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("搜索尾号")
                        .font(.callout.weight(.semibold))
                    SuffixEditor(text: Binding(
                        get: { store.targetSuffix },
                        set: { store.updateTargetSuffix($0) }
                    ))
                    Text("未在搜的机器会按这个尾号写入 formal-suffix 并启动。")
                        .font(.caption)
                        .foregroundStyle(MonitorTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                TextEditor(text: $loginText)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(MonitorTheme.primaryText)
                    .scrollContentBackground(.hidden)
                    .padding(11)
                    .background(MonitorTheme.surfaceMuted)
                    .frame(height: 280)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(MonitorTheme.border, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        if loginText.isEmpty {
                            Text(Self.placeholder)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(MonitorTheme.secondaryText.opacity(0.82))
                                .padding(16)
                                .allowsHitTesting(false)
                        }
                    }

                Label("机器、密码或私钥会以明文保存；App 重启后会自动重连。", systemImage: "exclamationmark.shield")
                    .font(.caption)
                    .foregroundStyle(MonitorTheme.warning)

                parseReport(for: batch)

                HStack {
                    Spacer()
                    Button(Self.confirmTitle(for: batch, suffix: store.targetSuffix)) {
                        store.add(records: batch.records)
                    }
                        .buttonStyle(AccentButtonStyle())
                        .disabled(!Self.canConfirm(batch, suffix: store.targetSuffix))
                        .opacity(Self.canConfirm(batch, suffix: store.targetSuffix) ? 1 : 0.45)
                }
            }
            .padding(24)
        }
        .frame(width: 620)
        .foregroundStyle(MonitorTheme.primaryText)
        .tint(MonitorTheme.accent)
        .withoutFocusRing()
    }
}
