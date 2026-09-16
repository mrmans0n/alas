import SwiftUI

/// Shared inset card treatment for right-pane content. Callers own interaction
/// state; this modifier only preserves the Agents rail's visual chrome.
struct RightPaneCardChrome: ViewModifier {
    let accent: Color
    let isHovering: Bool

    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .background(
                LinearGradient(
                    colors: [
                        accent.opacity(isHovering ? 0.12 : 0.07),
                        theme.color("bg-1").opacity(isHovering ? 0.82 : 0.66)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 11)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11).strokeBorder(
                    isHovering ? accent.opacity(0.38) : theme.color("line").opacity(0.78),
                    lineWidth: 0.75
                )
            )
            .shadow(color: .black.opacity(isHovering ? 0.18 : 0.10), radius: isHovering ? 5 : 3, y: 2)
            .contentShape(RoundedRectangle(cornerRadius: 11))
    }
}

extension View {
    func rightPaneCardChrome(accent: Color, isHovering: Bool) -> some View {
        modifier(RightPaneCardChrome(accent: accent, isHovering: isHovering))
    }
}
