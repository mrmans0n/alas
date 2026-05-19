import AppKit
import SwiftUI

enum ShortcutRecorderValidation: Equatable, Sendable {
    case ok
    case needsModifier
    case reserved
}

enum ShortcutRecorder {
    /// Pure validation against rules in the spec:
    /// - must include at least one of ⌘ ⌥ ⌃
    /// - shift alone with a letter is not enough (would shadow typing)
    /// - reserved bindings are rejected outright
    static func validate(_ binding: ShortcutBinding) -> ShortcutRecorderValidation {
        if ShortcutAction.reservedBindings.contains(binding) {
            return .reserved
        }
        let hasStrongModifier = binding.modifiers.contains(.command)
            || binding.modifiers.contains(.option)
            || binding.modifiers.contains(.control)
        guard hasStrongModifier else { return .needsModifier }
        return .ok
    }
}
