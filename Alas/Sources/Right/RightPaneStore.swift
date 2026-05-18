import Foundation
import Observation

@Observable
@MainActor
final class RightPaneStore {
    private var states: [String: RightPaneState] = [:]

    /// Weak back-reference used to close diff tabs after a successful discard.
    /// Set by `AppState` after both objects exist. Weak so the store doesn't
    /// retain the app.
    weak var appState: AppState?

    func state(for worktree: Worktree, baseBranch: String) -> RightPaneState {
        if let existing = states[worktree.id] {
            // Keep the cached state in sync with the currently-configured
            // base branch. If it changed (Settings → Worktrees → Base branch),
            // update the field and trigger a refresh so commitsAhead runs
            // against the new ref. We don't recreate the state because that
            // would discard tab expansion / file-tree open-paths / the
            // sticky activeTab choice.
            if existing.baseBranch != baseBranch {
                existing.baseBranch = baseBranch
                Task { @MainActor in await existing.refresh() }
            }
            return existing
        }
        let new = RightPaneState(worktree: worktree, baseBranch: baseBranch)
        let worktreeId = worktree.id
        new.closeDiffTabs = { [weak self] paths in
            guard let app = self?.appState else { return }
            let pathSet = Set(paths)
            for tab in app.tabs.tabs(forWorktree: worktreeId) {
                if case .diff(let s) = tab, pathSet.contains(s.relativePath) {
                    app.closeTab(worktreeId: worktreeId, tabId: s.id)
                }
            }
        }
        states[worktree.id] = new
        new.start()
        return new
    }

    func releaseUnselected(keep id: String) {
        _ = id
    }
}
