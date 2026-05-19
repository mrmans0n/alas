import SwiftUI

/// Wraps sidebar content with a theme where the foreground tokens have
/// been blended toward maximum contrast by the active per-theme
/// `textContrast` override. Has no effect when the override is zero.
struct SidebarChromeTheme: ViewModifier {
    @Environment(\.theme) private var baseTheme
    let textContrast: Double

    func body(content: Content) -> some View {
        let derived = baseTheme.applyingSidebarTextContrast(textContrast)
        return content.environment(\.theme, derived)
    }
}

extension View {
    /// Apply the sidebar text-contrast derivation to a subtree. Pass the
    /// resolved `textContrast` (already looked up from `AppConfig`).
    func sidebarChromeTheme(textContrast: Double) -> some View {
        modifier(SidebarChromeTheme(textContrast: textContrast))
    }
}
