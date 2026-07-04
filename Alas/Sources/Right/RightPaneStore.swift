import Foundation
import Observation
import os

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

    private let git: GitService

    init(git: GitService = GitService()) {
        self.git = git
    }

    /// Returns the branch name the Commits section should compare HEAD against
    /// when no user override has been set. If the worktree is checked out on the
    /// configured base branch itself, prefer `origin/<baseBranch>` so the
    /// comparison is meaningful instead of `branch..branch`.
    static func effectiveBaseBranch(worktree: Worktree, baseBranch: String) -> String {
        guard !baseBranch.isEmpty else { return baseBranch }
        guard worktree.branch == baseBranch else { return baseBranch }
        return "origin/\(baseBranch)"
    }

    /// Verifies whether `origin/<baseBranch>` resolves in the worktree. If it
    /// does not, returns the original `baseBranch`. Errors are swallowed and
    /// logged so the UI never crashes on a bad git probe.
    private func resolveEffectiveBaseBranch(
        worktreePath: URL,
        baseBranch: String
    ) async -> String {
        guard !baseBranch.isEmpty else { return baseBranch }
        do {
            if let resolved = try await git.resolveBaseRef(
                worktreePath: worktreePath,
                baseBranch: baseBranch,
                preferLocal: false
            ) {
                return resolved.baseRef
            }
        } catch {
            logger.error("Failed to resolve effective base branch for \(worktreePath.path): \(error.localizedDescription)")
        }
        return baseBranch
    }

    private let logger = Logger(subsystem: "io.nlopez.alas", category: "right-pane-store")

    func state(for worktree: Worktree, baseBranch: String, trackUpstreamForCommits: Bool) -> RightPaneState {
        let id = worktree.id
        let result: RightPaneState
        if let existing = states[id] {
            let effectiveDefault = Self.effectiveBaseBranch(worktree: worktree, baseBranch: baseBranch)
            let trackUpstreamChanged = existing.trackUpstreamForCommits != trackUpstreamForCommits
            if existing.lastConfigBaseBranch != effectiveDefault {
                let clearedUserOverride = existing.userOverrodeBaseBranch
                let baseChanged = existing.baseBranch != effectiveDefault
                existing.lastConfigBaseBranch = effectiveDefault
                existing.userOverrodeBaseBranch = false
                if baseChanged {
                    existing.baseBranch = effectiveDefault
                    existing.reviewLoop.updateBaseBranch(effectiveDefault)
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
            let effectiveDefault = Self.effectiveBaseBranch(worktree: worktree, baseBranch: baseBranch)
            let new = RightPaneState(worktree: worktree, baseBranch: effectiveDefault)
            new.lastConfigBaseBranch = effectiveDefault
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

            if effectiveDefault != baseBranch {
                Task { @MainActor [weak new] in
                    guard let state = new else { return }
                    let confirmed = await self.resolveEffectiveBaseBranch(
                        worktreePath: worktree.path,
                        baseBranch: baseBranch
                    )
                    guard confirmed != state.baseBranch,
                          !state.userOverrodeBaseBranch,
                          state.lastConfigBaseBranch == effectiveDefault else { return }
                    state.baseBranch = confirmed
                    state.lastConfigBaseBranch = confirmed
                    state.reviewLoop.updateBaseBranch(confirmed)
                    state.behindBase = nil
                    await state.refresh()
                    await state.refreshSyncStatus()
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
}
