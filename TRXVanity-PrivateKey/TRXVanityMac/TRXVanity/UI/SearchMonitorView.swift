import SwiftUI

struct SearchMonitorView: View {
    @ObservedObject var viewModel: VanityViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                StepHeading(step: "02 / 运行状态", title: viewModel.statusTitle)
                Spacer()
                HStack(spacing: 7) {
                    Circle()
                        .fill(viewModel.isRunning ? AppTheme.accent : statusColor)
                        .frame(width: 7, height: 7)
                        .shadow(color: statusColor.opacity(0.3), radius: 3)
                    Text(viewModel.statusDetail)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppTheme.muted)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("最新生成地址")
                    Spacer()
                    Text(viewModel.backendName)
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(AppTheme.muted)

                Text(viewModel.sampleAddress)
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundStyle(viewModel.isRunning ? AppTheme.accentDark : AppTheme.ink.opacity(0.75))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ZStack(alignment: .leading) {
                    Capsule().fill(AppTheme.line.opacity(0.6)).frame(height: 2)
                    if viewModel.isRunning {
                        Capsule().fill(AppTheme.accent)
                            .frame(width: 110, height: 2)
                            .transition(.opacity)
                    }
                }
            }
            .padding(18)
            .background(AppTheme.ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 15))

            HStack(spacing: 10) {
                MetricTile(title: "已尝试", value: viewModel.formattedAttempts(viewModel.attempts), unit: "个地址")
                MetricTile(title: "实时速度", value: viewModel.formattedSpeed(), unit: "地址 / 秒")
                MetricTile(title: "运行时间", value: viewModel.formattedElapsed(), unit: viewModel.powerMode.title + "模式")
            }

            VStack(spacing: 9) {
                HStack {
                    Text("搜索参考进度")
                    Spacer()
                    Text(viewModel.referenceProgress.formatted(.percent.precision(.fractionLength(4))))
                        .fontWeight(.bold)
                }
                .font(.system(size: 11))

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(AppTheme.line.opacity(0.75))
                        Capsule().fill(AppTheme.accent)
                            .frame(width: proxy.size.width * viewModel.referenceProgress)
                    }
                }
                .frame(height: 7)

                Text("随机搜索没有固定完成点；这里是相对于理论平均尝试量的参考。")
                    .font(.system(size: 10))
                    .foregroundStyle(AppTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(27)
        .appPanel()
    }

    private var statusColor: Color {
        switch viewModel.status {
        case .found: return AppTheme.success
        case .failed: return AppTheme.accent
        default: return AppTheme.muted
        }
    }
}

private struct MetricTile: View {
    let title: String
    let value: String
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(AppTheme.muted)
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Text(unit)
                .font(.system(size: 9))
                .foregroundStyle(AppTheme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(AppTheme.panelSecondary, in: RoundedRectangle(cornerRadius: 13))
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .stroke(AppTheme.line.opacity(0.8), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }
}
