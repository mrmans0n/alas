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
    ///
    /// This probe specifically checks the remote-tracking ref
    /// `refs/remotes/origin/<baseBranch>` rather than delegating to the generic
    /// `resolveBaseRef` helper, so slash-named branches such as `release/1.0`
    /// do not accidentally resolve to the local branch of the same name.
    private func resolveEffectiveBaseBranch(
        worktreePath: URL,
        baseBranch: String
    ) async -> String {
        guard !baseBranch.isEmpty else { return baseBranch }
        do {
            let result = try await git.resolveRevision(
                at: worktreePath,
                ref: "refs/remotes/origin/\(baseBranch)"
            )
            guard !result.isEmpty else { return baseBranch }
            return "origin/\(baseBranch)"
        } catch {
            logger.error("Failed to resolve effective base branch for \(worktreePath.path): \(error.localizedDescription)")
        }
        return baseBranch
    }

    private let logger = Logger(subsystem: "io.nlopez.alas", category: "right-pane-store")

    func state(for worktree: Worktree, baseBranch: String, trackUpstreamForCommits: Bool) -> RightPaneState {
        let id = worktree.id
        let result: RightPaneState
        let rawDefault = Self.effectiveBaseBranch(worktree: worktree, baseBranch: baseBranch)
        if let existing = states[id] {
            let trackUpstreamChanged = existing.trackUpstreamForCommits != trackUpstreamForCommits

            // Settings change: the configured base branch changed. Reset to the
            // new default unless the user picked a branch themselves.
            if existing.lastConfigBaseBranch != rawDefault {
                let wasOverridden = existing.userOverrodeBaseBranch
                existing.lastConfigBaseBranch = rawDefault
                existing.userOverrodeBaseBranch = false
                let baseChanged = existing.baseBranch != rawDefault
                if baseChanged {
                    existing.baseBranch = rawDefault
                    existing.reviewLoop.updateBaseBranch(rawDefault)
                }
                if baseChanged || wasOverridden {
                    // Clear the prior probe so the chip doesn't show a stale
                    // count while comparison semantics are changing.
                    existing.behindBase = nil
                    Task { @MainActor in
                        await existing.refresh()
                        await existing.refreshSyncStatus()
                    }
                }

                // If the new default points to a guessed origin ref, verify it
                // asynchronously and fall back to the configured base branch
                // if the remote ref does not exist.
                if rawDefault != baseBranch {
                    Task { @MainActor [weak existing] in
                        guard let state = existing else { return }
                        let confirmed = await self.resolveEffectiveBaseBranch(
                            worktreePath: worktree.path,
                            baseBranch: baseBranch
                        )
                        guard confirmed != state.baseBranch,
                              !state.userOverrodeBaseBranch,
                              state.lastConfigBaseBranch == rawDefault else { return }
                        state.baseBranch = confirmed
                        state.lastConfigBaseBranch = confirmed
                        state.reviewLoop.updateBaseBranch(confirmed)
                        state.behindBase = nil
                        await state.refresh()
                        await state.refreshSyncStatus()
                    }
                }
            }
            if trackUpstreamChanged {
                existing.trackUpstreamForCommits = trackUpstreamForCommits
                Task { @MainActor in await existing.refresh() }
            }
            result = existing
        } else {
            let new = RightPaneState(worktree: worktree, baseBranch: rawDefault)
            new.lastConfigBaseBranch = rawDefault
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

            if rawDefault != baseBranch {
                Task { @MainActor [weak new] in
                    guard let state = new else { return }
                    let confirmed = await self.resolveEffectiveBaseBranch(
                        worktreePath: worktree.path,
                        baseBranch: baseBranch
                    )
                    guard confirmed != state.baseBranch,
                          !state.userOverrodeBaseBranch,
                          state.lastConfigBaseBranch == rawDefault else { return }
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
