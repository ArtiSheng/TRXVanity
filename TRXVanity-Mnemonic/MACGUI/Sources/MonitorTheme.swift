import SwiftUI

enum MonitorTheme {
    static let background = Color(red: 0.949, green: 0.961, blue: 0.976)
    static let surface = Color.white
    static let surfaceRaised = Color(red: 0.910, green: 0.933, blue: 0.965)
    static let surfaceMuted = Color(red: 0.961, green: 0.969, blue: 0.980)
    static let border = Color(red: 0.831, green: 0.871, blue: 0.914)
    static let primaryText = Color(red: 0.090, green: 0.125, blue: 0.200)
    static let secondaryText = Color(red: 0.376, green: 0.439, blue: 0.525)
    static let accent = Color(red: 0.192, green: 0.357, blue: 0.780)
    static let onAccent = Color.white
    static let accentSurface = Color(red: 0.918, green: 0.941, blue: 1.000)
    static let accentBorder = Color(red: 0.725, green: 0.788, blue: 0.961)
    static let online = Color(red: 0.086, green: 0.506, blue: 0.373)
    static let warning = Color(red: 0.624, green: 0.376, blue: 0.000)
    static let danger = Color(red: 0.753, green: 0.239, blue: 0.294)
    static let panelShadow = Color(red: 0.102, green: 0.188, blue: 0.294).opacity(0.08)
}

private struct DashboardPanelModifier: ViewModifier {
    var cornerRadius: CGFloat
    var fill: Color
    var border: Color

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: MonitorTheme.panelShadow, radius: 10, x: 0, y: 4)
    }
}

extension View {
    @ViewBuilder
    func withoutFocusRing() -> some View {
        if #available(macOS 14.0, *) {
            self.focusEffectDisabled(true)
        } else {
            self
        }
    }

    func dashboardPanel(
        cornerRadius: CGFloat = 16,
        fill: Color = MonitorTheme.surface,
        border: Color = MonitorTheme.border
    ) -> some View {
        modifier(DashboardPanelModifier(cornerRadius: cornerRadius, fill: fill, border: border))
    }
}

struct AccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(MonitorTheme.onAccent)
            .padding(.horizontal, 15)
            .frame(height: 38)
            .background(
                MonitorTheme.accent.opacity(configuration.isPressed ? 0.86 : 1),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct NeutralButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(MonitorTheme.primaryText)
            .padding(.horizontal, 15)
            .frame(height: 38)
            .background(
                MonitorTheme.surfaceRaised.opacity(configuration.isPressed ? 0.72 : 1),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(MonitorTheme.border, lineWidth: 1)
            )
    }
}
