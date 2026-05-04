import Foundation
import Observation

@Observable
final class ThemeStore {
    private(set) var current: Theme

    init(initialId: String = "cool-slate") throws {
        self.current = try Theme.loadBundled(id: initialId)
    }

    func activate(id: String) throws {
        var next = try Theme.loadBundled(id: id)
        // Preserve any user-set accent override across theme switches.
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
}
