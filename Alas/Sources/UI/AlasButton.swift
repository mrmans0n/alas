import SwiftUI

enum AlasButtonStyle { case primary, normal, subtle }

struct AlasButton: View {
    let title: String
    var icon: String? = nil
    var style: AlasButtonStyle = .normal
    /// Replaces the accent a primary button fills with, or the text color of the others.
    var tint: Color? = nil
    /// Stretches the button to the width its container offers.
    var fillsWidth = false
    /// 24 pt tall instead of 28, for toolbars and status bars.
    var compact = false
    let action: () -> Void
    @Environment(\.theme) var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Icon(name: icon, size: 11, color: foreground) }
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, compact ? 10 : 12)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .frame(height: compact ? 24 : 28)
            .background(background)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(theme.color("line"), lineWidth: 0.5)
                    .opacity(style == .subtle ? 0 : 1)
            )
            .foregroundColor(foreground)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private var background: Color {
        switch style {
        case .primary: return tint ?? theme.color("accent")
        case .normal:  return theme.color("bg-3")
        case .subtle:  return .clear
        }
    }
    private var foreground: Color {
        switch style {
        case .primary: return theme.color("bg-0")
        case .normal:  return tint ?? theme.color("fg")
        case .subtle:  return tint ?? theme.color("fg-muted")
        }
    }
}
