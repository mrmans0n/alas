import SwiftUI

/// Renames the branch a worktree has checked out. The directory stays where it
/// is: worktree identity is its path.
struct RenameBranchDialog: View {
    let branch: String
    let subtitle: String
    /// Nil hides the suggestion button.
    let suggest: (@MainActor () async -> String?)?
    /// The error message to show, nil once renamed.
    let rename: @MainActor (String) async -> String?
    let onDismiss: () -> Void

    @State private var name: String
    @State private var suggestionTask: Task<Void, Never>?
    @State private var suggestionUnavailable = false
    @State private var isRenaming = false
    @State private var errorMessage: String?

    init(
        branch: String, subtitle: String,
        suggest: (@MainActor () async -> String?)?,
        rename: @escaping @MainActor (String) async -> String?,
        onDismiss: @escaping () -> Void
    ) {
        self.branch = branch
        self.subtitle = subtitle
        self.suggest = suggest
        self.rename = rename
        self.onDismiss = onDismiss
        self._name = State(initialValue: branch)
    }

    init(state: AppState, worktree: Worktree, onDismiss: @escaping () -> Void) {
        self.init(
            branch: worktree.branch,
            subtitle: (worktree.path.path as NSString).abbreviatingWithTildeInPath,
            suggest: { await state.suggestBranchName(for: worktree) },
            rename: { await state.renameWorktreeBranch(worktree, to: $0) },
            onDismiss: onDismiss
        )
    }

    var body: some View {
        DialogContainer(
            title: "Rename branch",
            subtitle: subtitle,
            headerAccessory: {
                if suggest != nil {
                    DialogHeaderIconButton(
                        icon: "sparkle",
                        tooltip: suggestionUnavailable
                            ? "Nothing on this branch to suggest a name from yet"
                            : "Suggest a name from this branch's changes",
                        isHighlighted: suggestionTask != nil,
                        action: suggestName
                    )
                    .disabled(suggestionTask != nil)
                }
            },
            content: {
                DialogField(label: "Branch name") {
                    AlasField(
                        text: $name,
                        monospaced: true,
                        focusOnAppear: true,
                        onSubmit: renameBranch,
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
            onConfirm: renameBranch,
            confirmEnabled: canRename
        )
        .onChange(of: name) { _, _ in errorMessage = nil }
        .onDisappear { suggestionTask?.cancel() }
    }

    private var validationMessage: String? {
        guard !name.isEmpty, name != branch,
              case .invalid(let message) = GitNameValidator.validateBranchName(name)
        else { return nil }
        return message
    }

    private var canRename: Bool {
        !name.isEmpty && name != branch && validationMessage == nil && !isRenaming
    }

    private func suggestName() {
        guard let suggest else { return }
        suggestionUnavailable = false
        suggestionTask = Task { @MainActor in
            let suggestion = await suggest()
            guard !Task.isCancelled else { return }
            if let suggestion { name = suggestion } else { suggestionUnavailable = true }
            suggestionTask = nil
        }
    }

    private func renameBranch() {
        guard canRename else { return }
        suggestionTask?.cancel()
        suggestionTask = nil
        isRenaming = true
        Task { @MainActor in
            errorMessage = await rename(name)
            isRenaming = false
            if errorMessage == nil { onDismiss() }
        }
    }
}
