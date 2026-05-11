import Foundation
import Observation

@Observable
@MainActor
final class RightPaneStore {
    private var states: [String: RightPaneState] = [:]

    func state(for worktree: Worktree, baseBranch: String) -> RightPaneState {
        // FIXME: if AppConfig.worktrees.baseBranch changes after a RightPaneState is
        // created, the existing state keeps using the old value. Consider invalidating
        // on config change.
        if let existing = states[worktree.id] { return existing }
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
