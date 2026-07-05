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

    func state(for worktree: Worktree, baseBranch: String, trackUpstreamForCommits: Bool) -> RightPaneState {
        let id = worktree.id
        let result: RightPaneState
        if let existing = states[id] {
            let trackUpstreamChanged = existing.trackUpstreamForCommits != trackUpstreamForCommits
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
            if trackUpstreamChanged {
                existing.trackUpstreamForCommits = trackUpstreamForCommits
                Task { @MainActor in await existing.refresh() }
            }
            result = existing
        } else {
            let new = RightPaneState(worktree: worktree, baseBranch: baseBranch)
            new.lastConfigBaseBranch = baseBranch
            new.trackUpstreamForCommits = trackUpstreamForCommits
            new.closeDiffTabs = { [weak self] paths in
                guard let app = self?.appState else { return }
                app.tabs.closeDiffTabs(worktreeId: id, relativePaths: paths)
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

    func invalidateSnapshot(worktreeId: String) {
        states[worktreeId]?.markSnapshotUnknown()
    }

    func commitEditorComparisonRef(worktreeId: String) -> String? {
        guard let state = states[worktreeId] else { return nil }
        return state.comparisonRef
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

    /// The cached `RightPaneState` for `worktreeId`, if one exists.
    /// Does NOT create a new state — returns nil if the worktree isn't active.
    /// Used by `DraftCommitTabView` to observe staged-set changes.
    func activeState(worktreeId: String) -> RightPaneState? {
        states[worktreeId]
    }

    /// The first cached state currently reporting a merge failure, if any.
    /// Merge errors are surfaced app-wide (see RootView) independent of the
    /// selected worktree: the async merge can fail after the user has switched
    /// away from the worktree that initiated it, so the alert must observe the
    /// originating state rather than the current selection.
    func stateReportingMergeError() -> RightPaneState? {
        states.values.first { $0.mergeError != nil }
    }
}
