import Foundation
import SwiftUI

@MainActor
extension AppState {
    /// Effective binding for an action: override if present (including explicit
    /// nil = unbound), else the default. Nil = no shortcut.
    func binding(for action: ShortcutAction) -> ShortcutBinding? {
        let key = action.rawValue
        if let override = config.shortcutOverrides[key] {
            return override  // may be nil = explicit unbind
        }
        return action.defaultBinding
    }

    /// SwiftUI-ready form. Pass directly into `.keyboardShortcut(_:)`.
    func shortcut(for action: ShortcutAction) -> KeyboardShortcut? {
        guard let binding = binding(for: action) else { return nil }
        return binding.asKeyboardShortcut()
    }

    /// Assign or unbind a shortcut.
    ///
    /// - Pass a non-nil binding to override the default.
    /// - Pass `nil` to *explicitly unbind* the action (suppresses the default —
    ///   the action will have no shortcut).
    /// - Use `resetShortcut(for:)` instead if you want the default restored.
    func setShortcut(_ binding: ShortcutBinding?, for action: ShortcutAction) {
        guard binding?.hasSupportedKey != false else { return }
        config.shortcutOverrides[action.rawValue] = .some(binding)
        _ = saveConfig()
        ShortcutReservations.update(from: config)
    }

    /// Remove the override entirely, returning the action to its default.
    func resetShortcut(for action: ShortcutAction) {
        config.shortcutOverrides.removeValue(forKey: action.rawValue)
        _ = saveConfig()
        ShortcutReservations.update(from: config)
    }

    /// Drop every override.
    func resetAllShortcuts() {
        config.shortcutOverrides.removeAll()
        _ = saveConfig()
        ShortcutReservations.update(from: config)
    }

    /// Find the first other action that currently has `candidate` as its
    /// effective binding. Returns nil when no conflict.
    func conflict(for candidate: ShortcutBinding, excluding action: ShortcutAction) -> ShortcutAction? {
        for a in ShortcutAction.allCases where a != action {
            if binding(for: a) == candidate {
                return a
            }
        }
        return nil
    }
}
