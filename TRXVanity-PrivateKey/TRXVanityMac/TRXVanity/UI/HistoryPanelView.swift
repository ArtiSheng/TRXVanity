import SwiftUI

struct HistoryPanelView: View {
    @ObservedObject var viewModel: VanityViewModel

    @State private var deletionTarget: HistoryDeletionTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            content
        }
        .padding(27)
        .appPanel()
        .alert(item: $deletionTarget, content: deletionAlert)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                StepHeading(step: "04 / 本地备份", title: "历史记录")
                Text("私钥保存在 macOS 钥匙串；地址、时间和匹配条件仅保存在本机应用容器。")
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.muted)
            }

            Spacer(minLength: 16)

            HStack(spacing: 9) {
                Text("\(viewModel.historyRecords.count) 条")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.muted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(AppTheme.line.opacity(0.42), in: Capsule())

                Button {
                    viewModel.exportAllHistory()
                } label: {
                    Label("导出全部", systemImage: "square.and.arrow.down.on.square")
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.historyRecords.isEmpty)

                Button(role: .destructive) {
                    deletionTarget = .all
                } label: {
                    Label("全部删除", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.historyRecords.isEmpty)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isHistoryLoading {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("正在读取本机历史…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.muted)
            }
            .frame(maxWidth: .infinity, minHeight: 124)
        } else if viewModel.historyRecords.isEmpty {
            VStack(spacing: 11) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 27, weight: .light))
                    .foregroundStyle(AppTheme.accent.opacity(0.7))
                Text("还没有历史记录")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                Text("下一个通过 CPU 校验的地址会自动保存在这里。")
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.muted)
            }
            .frame(maxWidth: .infinity, minHeight: 124)
        } else {
            LazyVStack(spacing: 12) {
                ForEach(viewModel.historyRecords) { record in
                    HistoryRecordRow(
                        record: record,
                        formattedDate: viewModel.formattedHistoryDate(record.createdAt),
                        patternDescription: viewModel.historyPatternDescription(record),
                        copyAddress: { viewModel.copyHistoryAddress(record) },
                        copyPrivateKey: { viewModel.copyHistoryPrivateKey(record) },
                        export: { viewModel.exportHistoryRecord(record) },
                        requestDeletion: { deletionTarget = .record(record) }
                    )
                }
            }
        }
    }

    private func deletionAlert(for target: HistoryDeletionTarget) -> Alert {
        switch target {
        case .record(let record):
            return Alert(
                title: Text("删除这条历史？"),
                message: Text("将从本机历史和钥匙串删除 \(record.address) 的私钥。已导出的 TXT 文件不受影响。"),
                primaryButton: .destructive(Text("删除")) {
                    viewModel.deleteHistoryRecord(record)
                },
                secondaryButton: .cancel(Text("取消"))
            )
        case .all:
            return Alert(
                title: Text("删除全部历史？"),
                message: Text("将从本机历史和钥匙串删除全部地址与私钥。已导出的 TXT 文件不受影响。"),
                primaryButton: .destructive(Text("全部删除")) {
                    viewModel.deleteAllHistory()
                },
                secondaryButton: .cancel(Text("取消"))
            )
        }
    }
}

private struct HistoryRecordRow: View {
    let record: HistoryRecord
    let formattedDate: String
    let patternDescription: String
    let copyAddress: () -> Void
    let copyPrivateKey: () -> Void
    let export: () -> Void
    let requestDeletion: () -> Void

    @State private var isPrivateKeyVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "key.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.success)
                    .frame(width: 31, height: 31)
                    .background(AppTheme.success.opacity(0.1), in: Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text(patternDescription)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                    Text(formattedDate)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(AppTheme.muted)
                }

                Spacer(minLength: 12)

                Button(action: export) {
                    Label("导出 TXT", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)

                Button(role: .destructive, action: requestDeletion) {
                    Label("删除", systemImage: "trash")
                }
                .buttonStyle(.bordered)
            }

            historyField(title: "TRON 地址") {
                Text(record.address)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .textSelection(.enabled)
                    .layoutPriority(1)

                Spacer(minLength: 8)

                Button("复制", action: copyAddress)
                    .buttonStyle(.borderless)
            }

            historyField(title: "私钥 · 64 位 HEX") {
                Group {
                    if isPrivateKeyVisible {
                        Text(record.privateKey)
                            .textSelection(.enabled)
                            .privacySensitive()
                            .accessibilityLabel("私钥 \(record.privateKey)")
                    } else {
                        Text(String(repeating: "•", count: 40))
                            .textSelection(.disabled)
                            .accessibilityLabel("私钥已隐藏")
                    }
                }
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.52)
                .layoutPriority(1)

                Spacer(minLength: 8)

                Button {
                    isPrivateKeyVisible.toggle()
                } label: {
                    Image(systemName: isPrivateKeyVisible ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(isPrivateKeyVisible ? "隐藏私钥" : "显示私钥")
                .help(isPrivateKeyVisible ? "隐藏私钥" : "显示私钥")

                Button("复制", action: copyPrivateKey)
                    .buttonStyle(.borderless)
                    .help("复制后 30 秒自动清除剪贴板")
            }
        }
        .padding(16)
        .background(AppTheme.panelSecondary, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(AppTheme.line.opacity(0.75), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .contextMenu {
            Button("复制地址", action: copyAddress)
            Button("复制私钥", action: copyPrivateKey)
            Divider()
            Button("导出 TXT", action: export)
            Button("删除", role: .destructive, action: requestDeletion)
        }
        .onDisappear {
            isPrivateKeyVisible = false
        }
    }

    private func historyField<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(AppTheme.muted)
            HStack(spacing: 8, content: content)
                .padding(.horizontal, 12)
                .frame(minHeight: 39)
                .background(AppTheme.panel, in: RoundedRectangle(cornerRadius: 9))
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(AppTheme.line, lineWidth: 1)
                        .allowsHitTesting(false)
                }
        }
    }
}

private enum HistoryDeletionTarget: Identifiable {
    case record(HistoryRecord)
    case all

    var id: String {
        switch self {
        case .record(let record): return record.id.uuidString
        case .all: return "all"
        }
    }
}
