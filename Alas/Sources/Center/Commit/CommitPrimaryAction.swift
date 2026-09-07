import Foundation
import SwiftUI

enum CommitComposerActionPosition: Sendable {
    case leading
    case trailing
}

enum CommitComposerActionBadgeColor: Equatable, Sendable {
    case systemWhite
    case systemBlack
    case theme(String)
}

struct CommitComposerActionBadgeStyle: Equatable, Sendable {
    let foreground: CommitComposerActionBadgeColor
    let foregroundOpacity: Double
    let background: CommitComposerActionBadgeColor
    let backgroundOpacity: Double
}

enum CommitComposerActionEmphasis: Sendable {
    case preferred
    case subtle

    var badgeStyle: CommitComposerActionBadgeStyle {
        switch self {
        case .preferred:
            .init(
                foreground: .systemWhite,
                foregroundOpacity: 0.85,
                background: .systemBlack,
                backgroundOpacity: 0.25
            )
        case .subtle:
            .init(
                foreground: .theme("fg"),
                foregroundOpacity: 1,
                background: .theme("fg"),
                backgroundOpacity: 0.12
            )
        }
    }
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

    func shortcut(at position: CommitComposerActionPosition) -> ShortcutBinding {
        switch position {
        case .leading: leading
        case .trailing: trailing
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
    let help: String?
    let accessibilityIdentifier: String?
    let handler: () -> Void

    init(
        label: String,
        savedLabel: String? = nil,
        isEnabled: Bool,
        showSavedState: Bool = false,
        keyboardShortcut: KeyboardShortcut? = nil,
        help: String? = nil,
        accessibilityIdentifier: String? = nil,
        handler: @escaping () -> Void
    ) {
        self.label = label
        self.savedLabel = savedLabel
        self.isEnabled = isEnabled
        self.showSavedState = showSavedState
        self.keyboardShortcut = keyboardShortcut
        self.help = help
        self.accessibilityIdentifier = accessibilityIdentifier
        self.handler = handler
    }
}
