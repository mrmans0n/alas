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
            // If the global config base branch changed (Settings → Worktrees),
            // honor the new value and clear the user override. If it didn't
            // change, leave the state's baseBranch alone so a user-picked
            // override survives across renders.
            if existing.lastConfigBaseBranch != baseBranch {
                let clearedUserOverride = existing.userOverrodeBaseBranch
                let baseChanged = existing.baseBranch != baseBranch
                existing.lastConfigBaseBranch = baseBranch
                existing.userOverrodeBaseBranch = false
                if baseChanged {
                    existing.baseBranch = baseBranch
                }
                if baseChanged || clearedUserOverride {
                    // Clear the prior probe so the chip doesn't show a stale
                    // count while comparison semantics are changing.
                    existing.behindBase = nil
                    Task { @MainActor in
                        await existing.refresh()
                        await existing.refreshSyncStatus()
                    }
                }
            }
            result = existing
        } else {
            let new = RightPaneState(worktree: worktree, baseBranch: baseBranch)
            new.lastConfigBaseBranch = baseBranch
            new.closeDiffTabs = { [weak self] paths in
                guard let app = self?.appState else { return }
                let pathSet = Set(paths)
                for tab in app.tabs.tabs(forWorktree: id) {
                    if case .diff(let s) = tab, pathSet.contains(s.relativePath) {
                        app.closeTab(worktreeId: id, tabId: s.id)
                    }
                }
            }
            new.openConflict = { [weak self] path in
                guard let app = self?.appState else { return }
                let title = (path as NSString).lastPathComponent
                let tab = app.tabs.openMergeConflict(
                    worktreeId: id,
                    relativePath: path,
                    title: title
                )
                app.tabs.activate(worktreeId: id, tabId: tab.id)
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

    /// Refreshes the cached `RightPaneState` for `worktreeId` if one exists.
    /// No-op when the worktree hasn't been activated yet. Called from the
    /// merge-conflict editor after `Mark resolved` so the Conflicts section
    /// reflects the staged resolution immediately without waiting for the
    /// FSEvents debouncer.
    func refresh(worktreeId: String) async {
        guard let state = states[worktreeId] else { return }
        await state.refresh()
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
