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
        binding(for: action)?.asKeyboardShortcut()
    }

    /// Assign a binding (nil = explicit unbind, removes default too).
    func setShortcut(_ binding: ShortcutBinding?, for action: ShortcutAction) {
        config.shortcutOverrides[action.rawValue] = .some(binding)
        _ = saveConfig()
    }

    /// Remove the override entirely, returning the action to its default.
    func resetShortcut(for action: ShortcutAction) {
        config.shortcutOverrides.removeValue(forKey: action.rawValue)
        _ = saveConfig()
    }

    /// Drop every override.
    func resetAllShortcuts() {
        config.shortcutOverrides.removeAll()
        _ = saveConfig()
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
