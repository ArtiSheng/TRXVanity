import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: VanityViewModel

    var body: some View {
        ZStack(alignment: .top) {
            AppTheme.canvas.ignoresSafeArea()
            backgroundDecoration

            ScrollView {
                VStack(spacing: 0) {
                    header
                    hero
                    workspace
                    HistoryPanelView(viewModel: viewModel)
                        .padding(.top, 18)
                    footer
                }
                .frame(maxWidth: 1_260)
                .padding(.horizontal, 30)
                .padding(.bottom, 36)
            }

            if viewModel.errorMessage != nil || viewModel.noticeMessage != nil {
                toast
                    .padding(.top, 18)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .foregroundStyle(AppTheme.ink)
        .animation(.easeOut(duration: 0.18), value: viewModel.errorMessage)
        .animation(.easeOut(duration: 0.18), value: viewModel.noticeMessage)
        .task {
            await viewModel.loadHistory()
        }
    }

    private var header: some View {
        HStack(spacing: 20) {
            HStack(spacing: 12) {
                Text("T")
                    .font(.system(size: 22, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 43, height: 43)
                    .background(AppTheme.accent, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .rotationEffect(.degrees(-3))
                    .shadow(color: AppTheme.accent.opacity(0.25), radius: 10, y: 5)

                VStack(alignment: .leading, spacing: 2) {
                    Text("TRX Vanity")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                    Text("原生 Metal 工具")
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.muted)
                }
            }

            Spacer(minLength: 20)

            HStack(spacing: 8) {
                SecurityPill(title: "100% 本地计算", isActive: true)
                SecurityPill(title: "Metal GPU")
                SecurityPill(title: "私钥不上传")
            }
        }
        .frame(minHeight: 84)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppTheme.ink.opacity(0.13))
                .frame(height: 1)
                .allowsHitTesting(false)
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(spacing: 9) {
                Rectangle().fill(AppTheme.accent).frame(width: 28, height: 2)
                Text("TRON MAINNET ADDRESS LAB")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.3)
                    .foregroundStyle(AppTheme.muted)
            }

            (Text("把你喜欢的数字，") +
             Text("留在链上地址里。").foregroundColor(AppTheme.accent))
                .font(.system(size: 48, weight: .heavy, design: .rounded))
                .tracking(-2.6)

            Text("调用 Mac 的 Metal GPU 本地并行搜索，匹配成功后当场给出 TRON 地址和对应的 64 位十六进制私钥。")
                .font(.system(size: 15))
                .foregroundStyle(AppTheme.muted)
                .lineSpacing(6)
                .frame(maxWidth: 780, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 48)
    }

    private var workspace: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 18) {
                PatternConfigurationView(viewModel: viewModel)
                    .frame(width: 410)
                monitorColumn
                    .frame(maxWidth: .infinity)
            }
            VStack(spacing: 18) {
                PatternConfigurationView(viewModel: viewModel)
                monitorColumn
            }
        }
    }

    private var monitorColumn: some View {
        VStack(spacing: 18) {
            SearchMonitorView(viewModel: viewModel)
            ResultPanelView(viewModel: viewModel)
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            Text("离线安全原则：生成前可断开网络；大额资产请优先使用经审计的硬件钱包。")
                .fontWeight(.semibold)
            Text("算法：secp256k1 → Keccak-256 → 0x41 网络前缀 → Base58Check")
            Text("匹配成功后会自动保存到本机历史；私钥仅存入 macOS 钥匙串，不会上传。")
        }
        .font(.system(size: 11))
        .foregroundStyle(AppTheme.muted)
        .frame(maxWidth: .infinity)
        .padding(.top, 27)
    }

    private var toast: some View {
        HStack(spacing: 11) {
            Image(systemName: viewModel.errorMessage == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(viewModel.errorMessage == nil ? AppTheme.success : AppTheme.accent)
            Text(viewModel.errorMessage ?? viewModel.noticeMessage ?? "")
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
            Button {
                viewModel.dismissMessage()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.muted)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(AppTheme.line, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(color: Color.black.opacity(0.13), radius: 17, y: 7)
    }

    private var backgroundDecoration: some View {
        GeometryReader { proxy in
            Circle()
                .fill(AppTheme.accent.opacity(0.07))
                .frame(width: 460, height: 460)
                .blur(radius: 55)
                .position(x: proxy.size.width - 60, y: 30)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
