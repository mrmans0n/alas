import SwiftUI

/// Renames the branch a worktree has checked out. The directory stays where it
/// is: worktree identity is its path.
struct RenameBranchDialog: View {
    @Bindable var state: AppState
    let worktree: Worktree
    let onDismiss: () -> Void

    @State private var name: String
    @State private var suggestionTask: Task<Void, Never>?
    @State private var suggestionUnavailable = false
    @State private var isRenaming = false
    @State private var errorMessage: String?

    init(state: AppState, worktree: Worktree, onDismiss: @escaping () -> Void) {
        self.state = state
        self.worktree = worktree
        self.onDismiss = onDismiss
        self._name = State(initialValue: worktree.branch)
    }

    var body: some View {
        DialogContainer(
            title: "Rename branch",
            subtitle: (worktree.path.path as NSString).abbreviatingWithTildeInPath,
            headerAccessory: {
                DialogHeaderIconButton(
                    icon: "sparkle",
                    tooltip: suggestionUnavailable
                        ? "Nothing on this branch to suggest a name from yet"
                        : "Suggest a name from this branch's changes",
                    isHighlighted: suggestionTask != nil,
                    action: suggest
                )
                .disabled(suggestionTask != nil)
            },
            content: {
                DialogField(label: "Branch name") {
                    AlasField(
                        text: $name,
                        monospaced: true,
                        focusOnAppear: true,
                        onSubmit: rename,
                        disablesAutomaticTextSubstitutions: true,
                        inputPolicy: .gitBranchName
                    )
                    .aiBeam(isActive: suggestionTask != nil)
                }
                if let message = errorMessage ?? validationMessage {
                    Text(message).font(.system(size: 11)).foregroundColor(.red)
                }
            },
            cancelTitle: "Cancel",
            confirmTitle: "Rename",
            confirmStyle: .primary,
            onCancel: onDismiss,
            onConfirm: rename,
            confirmEnabled: canRename
        )
        .onChange(of: name) { _, _ in errorMessage = nil }
        .onDisappear { suggestionTask?.cancel() }
    }

    private var validationMessage: String? {
        guard !name.isEmpty, name != worktree.branch,
              case .invalid(let message) = GitNameValidator.validateBranchName(name)
        else { return nil }
        return message
    }

    private var canRename: Bool {
        !name.isEmpty && name != worktree.branch && validationMessage == nil && !isRenaming
    }

    private func suggest() {
        suggestionUnavailable = false
        suggestionTask = Task { @MainActor in
            let suggestion = await state.suggestBranchName(for: worktree)
            guard !Task.isCancelled else { return }
            if let suggestion { name = suggestion } else { suggestionUnavailable = true }
            suggestionTask = nil
        }
    }

    private func rename() {
        guard canRename else { return }
        suggestionTask?.cancel()
        suggestionTask = nil
        isRenaming = true
        Task { @MainActor in
            errorMessage = await state.renameWorktreeBranch(worktree, to: name)
            isRenaming = false
            if errorMessage == nil { onDismiss() }
        }
    }
}
