import Foundation
import Observation

@Observable
@MainActor
final class RightPaneStore {
    private var states: [String: RightPaneState] = [:]

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
        states[worktree.id] = new
        new.start()
        return new
    }

    func releaseUnselected(keep id: String) {
        // No-op for v1; states are cheap to keep.
        // Stop watchers for backgrounded worktrees if memory becomes an issue.
        _ = id
    }
}
