import Foundation
import AppKit
import Observation

@Observable
final class ThemeStore {
    private(set) var current: Theme

    /// User's last manual theme selection (the picker) — restored when
    /// matchSystem is turned OFF.
    private var userPickedId: String

    /// When true, `current` is auto-driven by NSApp.effectiveAppearance
    /// (light vs dark) and ignores `userPickedId` until turned off.
    private var matchSystem: Bool = false

    /// Theme used when matchSystem is on and the system is light.
    private static let systemLightThemeId = "light"
    /// Theme used when matchSystem is on and the system is dark.
    /// Picks the user's last manual dark theme if they had one, else
    /// `cool-slate` as a sensible default.
    private var systemDarkThemeId: String {
        userPickedId == "light" ? "cool-slate" : userPickedId
    }

    init(initialId: String = "cool-slate") throws {
        self.userPickedId = initialId
        self.current = try Theme.loadBundled(id: initialId)
        // Listen for system-appearance changes so we can swap themes
        // automatically when `matchSystem` is on.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(systemAppearanceDidChange),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func activate(id: String) throws {
        userPickedId = id
        // Manual selection turns off match-system implicitly so the user's
        // pick actually shows up.
        matchSystem = false
        var next = try Theme.loadBundled(id: id)
        next.accentOverrideHex = current.accentOverrideHex
        self.current = next
    }

    /// Apply an accent preset (one of the keys in `Theme.accentHexById`).
    /// Pass nil (or an unknown id) to clear the override and fall back to
    /// the theme's own accent token.
    func setAccent(_ accentId: String?) {
        var next = current
        next.accentOverrideHex = accentId.flatMap { Theme.accentHexById[$0] }
        current = next
    }

    /// Toggle the "Match system" mode. When on, current theme follows the
    /// system's effective appearance (light → systemLightThemeId, dark →
    /// last picked dark theme). When off, the user's manual pick is restored.
    func setMatchSystem(_ on: Bool) {
        matchSystem = on
        applyForCurrentMode()
    }

    @objc private func systemAppearanceDidChange() {
        if matchSystem {
            DispatchQueue.main.async { [weak self] in
                self?.applyForCurrentMode()
            }
        }
    }

    /// Pick the right theme based on `matchSystem` + the current system
    /// appearance.
    private func applyForCurrentMode() {
        let targetId: String
        if matchSystem {
            targetId = systemIsDark() ? systemDarkThemeId : Self.systemLightThemeId
        } else {
            targetId = userPickedId
        }
        guard let next = try? Theme.loadBundled(id: targetId) else { return }
        var withAccent = next
        withAccent.accentOverrideHex = current.accentOverrideHex
        current = withAccent
    }

    private func systemIsDark() -> Bool {
        let name = NSApp.effectiveAppearance.bestMatch(
            from: [.aqua, .darkAqua, .vibrantDark, .vibrantLight]
        )
        switch name {
        case .darkAqua?, .vibrantDark?:
            return true
        default:
            return false
        }
    }
}
