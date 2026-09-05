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
        registerAppearanceObserver()
    }

    /// Non-throwing factory for startup paths. Resolves the requested id,
    /// then any bundled id, then a guaranteed in-code fallback theme — a
    /// missing or unloadable bundle resource must never trap the app at
    /// launch (see AppState.init).
    static func creating(
        initialId: String,
        loader: (String) throws -> Theme = Theme.loadBundled(id:)
    ) -> ThemeStore {
        if let theme = try? loader(initialId) {
            return ThemeStore(resolvedTheme: theme, initialId: initialId)
        }
        for id in Theme.bundledIds {
            if let theme = try? loader(id) {
                return ThemeStore(resolvedTheme: theme, initialId: id)
            }
        }
        return ThemeStore(fallbackWithCurrent: .fallback)
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    private init(resolvedTheme: Theme, initialId: String) {
        self.userPickedId = initialId
        self.current = resolvedTheme
        registerAppearanceObserver()
    }

    private init(fallbackWithCurrent theme: Theme) {
        self.userPickedId = theme.id
        self.current = theme
    }

    /// `AppleInterfaceThemeChangedNotification` is delivered on the
    /// *distributed* notification center (macOS broadcasts it across
    /// process boundaries). Observing the in-process default center
    /// would silently never fire.
    private func registerAppearanceObserver() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(systemAppearanceDidChange),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
    }

    func activate(id: String) throws {
        var next = try Theme.loadBundled(id: id)
        next.accentOverrideHex = current.accentOverrideHex
        userPickedId = id
        // Manual selection turns off match-system implicitly so the user's
        // pick actually shows up.
        matchSystem = false
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
        // Read the OS preference directly. We can't use
        // `NSApp.effectiveAppearance` here: `WindowAppearance.apply`
        // forces `NSApp.appearance` to match the in-app theme, which
        // poisons `effectiveAppearance` so it would echo our override
        // instead of the real OS setting. `AppleInterfaceStyle` is the
        // canonical global default — `"Dark"` when dark, missing when
        // light — and is unaffected by per-app overrides.
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }
}
