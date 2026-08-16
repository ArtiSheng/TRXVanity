import SwiftUI

struct ResultPanelView: View {
    @ObservedObject var viewModel: VanityViewModel

    var body: some View {
        Group {
            if let result = viewModel.result {
                resultContent(result)
            } else {
                emptyContent
            }
        }
        .padding(27)
        .appPanel()
    }

    private func resultContent(_ result: VanitySearchResult) -> some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "checkmark")
                    .font(.system(size: 19, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(AppTheme.success, in: Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text("匹配成功 · CPU 私钥校验通过")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(AppTheme.success)
                    Text("你的 TRON 靓号已生成")
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                    Text("\(viewModel.formattedAttempts(result.attempts)) 次尝试 · \(viewModel.formattedElapsed())")
                        .font(.system(size: 10))
                        .foregroundStyle(AppTheme.muted)
                    backupStatus
                }
            }

            ResultField(title: "TRON 地址", value: result.address) {
                Button("复制", action: viewModel.copyAddress)
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("私钥")
                        .font(.system(size: 10, weight: .bold))
                    Text("64 位 HEX")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(AppTheme.accent)
                    Spacer()
                }

                HStack(spacing: 8) {
                    if viewModel.isPrivateKeyVisible {
                        Text(result.privateKey)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .lineLimit(1)
                            .minimumScaleFactor(0.55)
                            .textSelection(.enabled)
                    } else {
                        Text(String(repeating: "•", count: 40))
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .lineLimit(1)
                            .minimumScaleFactor(0.55)
                            .textSelection(.disabled)
                    }
                    Spacer(minLength: 8)
                    Button {
                        viewModel.isPrivateKeyVisible.toggle()
                    } label: {
                        Image(systemName: viewModel.isPrivateKeyVisible ? "eye.slash" : "eye")
                    }
                    Button("复制", action: viewModel.copyPrivateKey)
                }
                .buttonStyle(.borderless)
                .padding(12)
                .background(AppTheme.panelSecondary, in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(AppTheme.line, lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.shield.fill")
                VStack(alignment: .leading, spacing: 3) {
                    Text("私钥 = 资产控制权").fontWeight(.bold)
                    Text("请在断网环境备份，不要发给任何人，也不要截图上传。")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(AppTheme.accentDark)
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

            HStack {
                Button(action: viewModel.exportResult) {
                    Label("导出 TXT", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.ink)

                Button(action: viewModel.clearResult) {
                    Label("清除当前显示", systemImage: "xmark")
                }
                .buttonStyle(.bordered)
                .help("只清除当前结果面板，不删除本机历史")
            }
        }
    }

    private var backupStatus: some View {
        HStack(spacing: 6) {
            if viewModel.historyBackupStatus == .saving {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: backupStatusIcon)
            }
            Text(viewModel.historyBackupTitle)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(backupStatusColor)
        .padding(.top, 2)
    }

    private var backupStatusIcon: String {
        switch viewModel.historyBackupStatus {
        case .idle: return "key.horizontal"
        case .saving: return "key.horizontal"
        case .saved: return "checkmark.shield.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var backupStatusColor: Color {
        switch viewModel.historyBackupStatus {
        case .idle, .saving: return AppTheme.muted
        case .saved: return AppTheme.success
        case .failed: return AppTheme.accent
        }
    }

    private var emptyContent: some View {
        VStack(spacing: 13) {
            Text("03 / 生成结果")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(1.3)
                .foregroundStyle(AppTheme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "key.horizontal")
                .font(.system(size: 31, weight: .light))
                .foregroundStyle(AppTheme.accent.opacity(0.7))
                .padding(.top, 3)
            Text("匹配后在这里显示私钥")
                .font(.system(size: 18, weight: .bold, design: .rounded))
            Text("匹配成功后会自动保存到本机钥匙串历史，私钥不会上传。")
                .font(.system(size: 11))
                .foregroundStyle(AppTheme.muted)
        }
        .frame(maxWidth: .infinity, minHeight: 170)
    }
}

private struct ResultField<Actions: View>: View {
    let title: String
    let value: String
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 10, weight: .bold))
            HStack(spacing: 8) {
                Text(value)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                actions
            }
            .buttonStyle(.borderless)
            .padding(12)
            .background(AppTheme.panelSecondary, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(AppTheme.line, lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
    }
}
