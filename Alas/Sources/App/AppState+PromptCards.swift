import AppKit

extension AppState {
    /// A prompt card's footer button. A target that no longer resolves
    /// (deleted worktree) does nothing.
    func performPromptCardAction(_ action: ACPPromptCard.Action) {
        switch action {
        case .url(let url):
            NSWorkspace.shared.open(url)
        case .reviewSession(let target):
            guard let resolved = projectAndWorktree(withWorktreeId: target.worktreeID) else { return }
            focusGlobalWorktree(id: resolved.worktree.id, projectId: resolved.project.id)
            let store = ReviewSessionStore()
            ReviewSessionLauncher.openOrFocus(
                target: target,
                findActive: { try store.findActive(targetID: $0) },
                save: { try store.save($0) },
                open: { self.tabs.openOrFocusReviewSession(worktreeId: target.worktreeID, record: $0) }
            )
        case .reviewChanges(let worktreeID):
            guard let resolved = projectAndWorktree(withWorktreeId: worktreeID) else { return }
            focusGlobalWorktree(id: resolved.worktree.id, projectId: resolved.project.id)
            openReviewChangesTab(for: resolved.worktree)
        }
    }
}
