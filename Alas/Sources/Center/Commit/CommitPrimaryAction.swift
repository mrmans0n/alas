import SwiftUI

struct CommitPrimaryAction {
    let label: String
    let savedLabel: String?     // shown when showSavedState is true (and non-nil)
    let isEnabled: Bool
    let showSavedState: Bool
    let handler: () -> Void

    init(
        label: String,
        savedLabel: String? = nil,
        isEnabled: Bool,
        showSavedState: Bool = false,
        handler: @escaping () -> Void
    ) {
        self.label = label
        self.savedLabel = savedLabel
        self.isEnabled = isEnabled
        self.showSavedState = showSavedState
        self.handler = handler
    }
}
