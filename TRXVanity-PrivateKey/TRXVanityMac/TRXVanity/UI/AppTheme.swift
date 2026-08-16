import SwiftUI

enum AppTheme {
    static let canvas = Color(red: 0.965, green: 0.953, blue: 0.918)
    static let panel = Color(red: 0.998, green: 0.995, blue: 0.976)
    static let panelSecondary = Color(red: 0.984, green: 0.980, blue: 0.957)
    static let ink = Color(red: 0.09, green: 0.095, blue: 0.082)
    static let muted = Color(red: 0.43, green: 0.44, blue: 0.40)
    static let line = Color(red: 0.86, green: 0.84, blue: 0.79)
    static let accent = Color(red: 0.93, green: 0.17, blue: 0.21)
    static let accentDark = Color(red: 0.76, green: 0.09, blue: 0.13)
    static let success = Color(red: 0.08, green: 0.48, blue: 0.33)
    static let warning = Color(red: 0.62, green: 0.37, blue: 0.04)
}

struct PanelModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(AppTheme.panel.opacity(0.97))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(AppTheme.line, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .shadow(color: Color.black.opacity(0.06), radius: 25, x: 0, y: 14)
    }
}

extension View {
    func appPanel() -> some View {
        modifier(PanelModifier())
    }
}

struct StepHeading: View {
    let step: String
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(step.uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(1.3)
                .foregroundStyle(AppTheme.muted)
            Text(title)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.ink)
        }
    }
}

struct SecurityPill: View {
    let title: String
    var isActive = false

    var body: some View {
        HStack(spacing: 7) {
            if isActive {
                Circle()
                    .fill(AppTheme.success)
                    .frame(width: 7, height: 7)
                    .shadow(color: AppTheme.success.opacity(0.25), radius: 3)
            }
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.muted)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(AppTheme.panel.opacity(0.8), in: Capsule())
        .overlay {
            Capsule()
                .stroke(AppTheme.line, lineWidth: 1)
                .allowsHitTesting(false)
        }
    }
}
