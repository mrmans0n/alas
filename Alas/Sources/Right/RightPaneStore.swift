import Foundation
import Observation

@Observable
@MainActor
final class RightPaneStore {
    private var states: [String: RightPaneState] = [:]

    /// Id of the state currently being surfaced in the UI. Only that state
    /// runs its background sync timer + watcher; others sit cached but
    /// quiescent until they're requested again.
    private var activeId: String? = nil

    /// Weak back-reference used to close diff tabs after a successful discard.
    /// Set by `AppState` after both objects exist. Weak so the store doesn't
    /// retain the app.
    weak var appState: AppState?

    func state(for worktree: Worktree, baseBranch: String) -> RightPaneState {
        let id = worktree.id
        let result: RightPaneState
        if let existing = states[id] {
            // Keep the cached state in sync with the currently-configured
            // base branch. If it changed (Settings → Worktrees → Base branch),
            // update the field and trigger a refresh so commitsAhead runs
            // against the new ref. We don't recreate the state because that
            // would discard tab expansion / file-tree open-paths / the
            // sticky activeTab choice.
            if existing.baseBranch != baseBranch {
                existing.baseBranch = baseBranch
                // Clear the prior probe so the chip doesn't show a stale
                // count against the OLD base while the new probe runs.
                existing.behindBase = nil
                Task { @MainActor in
                    await existing.refresh()
                    await existing.refreshSyncStatus()
                }
            }
            result = existing
        } else {
            let new = RightPaneState(worktree: worktree, baseBranch: baseBranch)
            new.closeDiffTabs = { [weak self] paths in
                guard let app = self?.appState else { return }
                let pathSet = Set(paths)
                for tab in app.tabs.tabs(forWorktree: id) {
                    if case .diff(let s) = tab, pathSet.contains(s.relativePath) {
                        app.closeTab(worktreeId: id, tabId: s.id)
                    }
                }
            }
            states[id] = new
            result = new
        }
        activate(id, on: result)
        return result
    }

    /// Marks `id` as the currently-displayed worktree. Stops the previously
    /// active state's filesystem watcher and sync timer so background work
    /// doesn't leak across every worktree the user has ever opened.
    private func activate(_ id: String, on state: RightPaneState) {
        guard activeId != id else { return }
        if let prev = activeId, let prevState = states[prev] {
            prevState.stop()
        }
        state.start()
        activeId = id
    }

    /// Stops the currently-active state's background work. Call when the
    /// right pane is hidden or no worktree is selected, so the FSEvents
    /// watcher and the 5-min sync timer don't keep running with no
    /// consumer.
    func deactivate() {
        if let prev = activeId, let prevState = states[prev] {
            prevState.stop()
        }
        activeId = nil
    }
}
