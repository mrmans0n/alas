import Foundation
import SwiftUI

enum CommitComposerActionPosition: Sendable {
    case leading
    case trailing
}

struct CommitComposerActionPair: Equatable, Sendable {
    let leading: ShortcutBinding
    let trailing: ShortcutBinding

    static func shortcuts(
        preferred: CommitComposerActionPosition,
        base: ShortcutBinding
    ) -> Self {
        switch preferred {
        case .leading:
            Self(leading: base, trailing: base.togglingShift())
        case .trailing:
            Self(leading: base.togglingShift(), trailing: base)
        }
    }
}

struct CommitPrimaryAction {
    let label: String
    let savedLabel: String?     // shown when showSavedState is true (and non-nil)
    let isEnabled: Bool
    /// True when the button should show `savedLabel` instead of `label`.
    /// Distinct from `!isEnabled` because some disabled states (e.g. valid edits with empty subject)
    /// should keep showing the primary `label`, not the "Saved" alternative.
    let showSavedState: Bool
    /// Optional keyboard shortcut applied to the primary action button.
    let keyboardShortcut: KeyboardShortcut?
    let handler: () -> Void

    init(
        label: String,
        savedLabel: String? = nil,
        isEnabled: Bool,
        showSavedState: Bool = false,
        keyboardShortcut: KeyboardShortcut? = nil,
        handler: @escaping () -> Void
    ) {
        self.label = label
        self.savedLabel = savedLabel
        self.isEnabled = isEnabled
        self.showSavedState = showSavedState
        self.keyboardShortcut = keyboardShortcut
        self.handler = handler
    }
}
