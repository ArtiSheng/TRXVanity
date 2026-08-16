import SwiftUI

struct PatternConfigurationView: View {
    @ObservedObject var viewModel: VanityViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(alignment: .top) {
                StepHeading(step: "01 / 设置规则", title: "自定义数字")
                Spacer()
                Text("难度·\(viewModel.difficulty)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(difficultyColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(difficultyColor.opacity(0.1), in: Capsule())
            }

            PatternCard(
                title: "前段数字",
                preview: "T?\(viewModel.prefixEnabled ? viewModel.prefix : "")…",
                note: "从地址第 3 位开始匹配；T 是固定网络位，第 2 位受 Base58 编码范围限制。",
                enabled: Binding(
                    get: { viewModel.prefixEnabled },
                    set: { viewModel.prefixEnabled = $0 }
                ),
                selectedLength: viewModel.prefixLength,
                value: Binding(
                    get: { viewModel.prefix },
                    set: viewModel.updatePrefix
                ),
                setLength: viewModel.setPrefixLength,
                isLocked: viewModel.isRunning
            )

            PatternCard(
                title: "尾号数字",
                preview: "…\(viewModel.suffixEnabled ? viewModel.suffix : "")",
                note: "从地址最后一位向前精确匹配。",
                enabled: Binding(
                    get: { viewModel.suffixEnabled },
                    set: { viewModel.suffixEnabled = $0 }
                ),
                selectedLength: viewModel.suffixLength,
                value: Binding(
                    get: { viewModel.suffix },
                    set: viewModel.updateSuffix
                ),
                setLength: viewModel.setSuffixLength,
                isLocked: viewModel.isRunning
            )

            powerPicker
            estimateCard

            if viewModel.activeDigitCount >= 7 {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    VStack(alignment: .leading, spacing: 3) {
                        Text("高难度提醒").fontWeight(.bold)
                        Text(
                            "前后共 \(viewModel.activeDigitCount) 位，理论平均需要 "
                                + "\(viewModel.formattedExpectedAttempts()) 次尝试；每增加 1 位，难度约增加 58 倍。"
                        )
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(AppTheme.warning)
                .padding(12)
                .background(AppTheme.warning.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
            }

            Button {
                viewModel.isRunning ? viewModel.stop() : viewModel.start()
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: viewModel.isRunning ? "stop.fill" : "play.fill")
                    Text(viewModel.isRunning ? "停止生成" : "开始 GPU 生成")
                }
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(viewModel.isRunning ? AppTheme.ink : AppTheme.accent)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)

            Text("极速模式会明显增加 GPU 占用和功耗，运行期间风扇或机身温度可能上升。")
                .font(.system(size: 10))
                .foregroundStyle(AppTheme.muted)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(27)
        .appPanel()
    }

    private var powerPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("GPU 性能档位")
                        .font(.system(size: 13, weight: .bold))
                    Text(viewModel.powerMode.detail)
                        .font(.system(size: 10))
                        .foregroundStyle(AppTheme.muted)
                }
                Spacer()
                Image(systemName: "memorychip")
                    .foregroundStyle(AppTheme.accent)
            }

            HStack(spacing: 6) {
                ForEach(PowerMode.allCases) { mode in
                    Button {
                        viewModel.powerMode = mode
                    } label: {
                        Text(mode.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(viewModel.powerMode == mode ? .white : AppTheme.muted)
                            .frame(maxWidth: .infinity, minHeight: 32)
                            .background(viewModel.powerMode == mode ? AppTheme.ink : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isRunning)
                    .opacity(viewModel.isRunning ? 0.55 : 1)
                }
            }
            .padding(4)
            .background(AppTheme.line.opacity(0.45), in: RoundedRectangle(cornerRadius: 11))
        }
    }

    private var estimateCard: some View {
        HStack(spacing: 0) {
            metric(label: "理论平均尝试", value: viewModel.formattedExpectedAttempts())
            Rectangle().fill(AppTheme.line).frame(width: 1, height: 38)
            metric(label: "按当前实测速度", value: viewModel.formattedRemaining())
        }
        .padding(.vertical, 13)
        .background(AppTheme.panelSecondary, in: RoundedRectangle(cornerRadius: 13))
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .stroke(AppTheme.line, lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private func metric(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 10)).foregroundStyle(AppTheme.muted)
            Text(value).font(.system(size: 13, weight: .bold, design: .rounded))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 13)
    }

    private var difficultyColor: Color {
        viewModel.activeDigitCount >= 5 ? AppTheme.warning : AppTheme.success
    }
}

private struct PatternCard: View {
    let title: String
    let preview: String
    let note: String
    @Binding var enabled: Bool
    let selectedLength: Int
    @Binding var value: String
    let setLength: (Int) -> Void
    let isLocked: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Toggle(title, isOn: $enabled)
                    .toggleStyle(.switch)
                    .tint(AppTheme.accent)
                    .font(.system(size: 13, weight: .bold))
                    .disabled(isLocked)
                Spacer()
                Text(preview)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(AppTheme.accentDark)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(AppTheme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            }

            Text(note)
                .font(.system(size: 10))
                .foregroundStyle(AppTheme.muted)
                .lineSpacing(3)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 5),
                alignment: .leading,
                spacing: 5
            ) {
                ForEach(VanityViewModel.supportedLengths, id: \.self) { length in
                    Button {
                        setLength(length)
                    } label: {
                        Text("\(length)")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(selectedLength == length ? .white : AppTheme.muted)
                            .frame(maxWidth: .infinity, minHeight: 32)
                            .background(selectedLength == length ? AppTheme.accent : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                            .overlay {
                                if selectedLength != length {
                                    RoundedRectangle(cornerRadius: 7)
                                        .stroke(AppTheme.line, lineWidth: 1)
                                        .allowsHitTesting(false)
                                }
                            }
                            .contentShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .disabled(!enabled || isLocked)
                    .opacity(!enabled || isLocked ? 0.5 : 1)
                    .accessibilityIdentifier("\(title)-\(length)")
                }
            }

            HStack {
                TextField("输入 \(selectedLength) 位 1–9", text: $value)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                Text("\(value.count)/\(selectedLength)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(AppTheme.muted)
            }
            .padding(.horizontal, 11)
            .frame(height: 38)
            .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(AppTheme.line, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .disabled(!enabled || isLocked)
        }
        .padding(17)
        .background(AppTheme.panelSecondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(AppTheme.line.opacity(0.7), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }
}
