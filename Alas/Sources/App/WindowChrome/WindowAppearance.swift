import AppKit

/// Pushes an `NSAppearance` (`.aqua` or `.darkAqua`) onto the running
/// application and every existing window so all system materials —
/// `NSVisualEffectView`, `Color(.windowBackgroundColor)`, scrollers,
/// focus rings — render in the right mode for the in-app theme.
///
/// New windows opened after this call inherit `NSApp.appearance`
/// automatically. Call again whenever the active theme changes.
enum WindowAppearance {
    @MainActor
    static func apply(darkMode: Bool) {
        guard let app = NSApp else { return }
        let appearance = NSAppearance(named: darkMode ? .darkAqua : .aqua)
        app.appearance = appearance
        for window in app.windows {
            window.appearance = appearance
        }
    }
}
