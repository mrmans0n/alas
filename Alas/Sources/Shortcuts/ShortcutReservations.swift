import Foundation

/// Process-global set of key-combos the app reserves from the terminal pane.
/// The Ghostty surface consults this on every keystroke to decide whether to
/// forward the event to libghostty or let it bubble up to the app's menus.
///
/// `AppState` writes the current effective bindings whenever shortcut
/// overrides change so customizations take effect immediately. All access
/// happens on the main thread (terminal key handling and AppState writes are
/// both main-actor-isolated), which justifies `nonisolated(unsafe)`.
enum ShortcutReservations {
    nonisolated(unsafe) private static var _current: Set<ShortcutBinding>?

    /// The currently effective reserved set. Falls back to `defaultReserved`
    /// when nothing has been published yet (e.g. in tests that exercise the
    /// terminal directly without spinning up an AppState).
    static var current: Set<ShortcutBinding> {
        _current ?? defaultReserved
    }

    /// Reservations derived from the action defaults — used as the seed
    /// before any AppState publishes its effective state. Code-editor and
    /// composer-scoped actions are skipped: they have no responder when the
    /// terminal is focused, so reserving them would just swallow the key.
    static let defaultReserved: Set<ShortcutBinding> = {
        var set = Set<ShortcutBinding>(ShortcutAction.reservedBindings)
        for action in ShortcutAction.allCases where action.appliesInTerminal {
            set.insert(action.defaultBinding)
        }
        return set
    }()

    /// Pure: compute the effective reserved set for a given config snapshot.
    /// An explicit `nil` override drops the action from the set so the
    /// terminal can receive that combo. Code-editor- and composer-scoped
    /// actions are never reserved regardless of override.
    static func snapshot(from config: AppConfig) -> Set<ShortcutBinding> {
        var set = Set<ShortcutBinding>(ShortcutAction.reservedBindings)
        for action in ShortcutAction.allCases where action.appliesInTerminal {
            if let override = config.shortcutOverrides[action.rawValue] {
                if let binding = override { set.insert(binding) }
            } else {
                set.insert(action.defaultBinding)
            }
        }
        return set
    }

    /// Recompute the effective reservations from `config` and publish them.
    static func update(from config: AppConfig) {
        _current = snapshot(from: config)
    }

    /// Reset the published state back to defaults — used by tests that need
    /// a clean baseline regardless of test execution order.
    static func resetToDefaults() {
        _current = nil
    }
}
