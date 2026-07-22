import Foundation
import Observation
import os

struct RightPaneGGStackSnapshot: Equatable {
    let stack: GGStack?
    let loadState: GGStackLoadState
}

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

    func state(for worktree: Worktree, baseBranch: String, comparisonMode: AppConfig.Changes.ChangesComparisonMode) -> RightPaneState {
        let id = worktree.id
        let result: RightPaneState
        let rawDefault = Self.effectiveBaseBranch(worktree: worktree, baseBranch: baseBranch)
        if let existing = states[id] {
            let comparisonModeChanged = existing.comparisonMode != comparisonMode

            // Settings change: the configured base branch changed. Reset to the
            // new default unless the user picked a branch themselves.
            if existing.lastConfigBaseBranch != baseBranch {
                existing.lastConfigBaseBranch = baseBranch
                existing.lastEffectiveBaseBranch = rawDefault
                existing.userOverrodeBaseBranch = false
                existing.baseBranch = rawDefault
                existing.reviewLoop.updateBaseBranch(baseBranch)
                existing.behindBase = nil
                existing.baseBranchProbeTask?.cancel()
                existing.isAwaitingBaseBranchProbe = false
                Task { @MainActor in
                    await existing.refresh()
                    await existing.refreshSyncStatus()
                }

                // If the new default points to a guessed origin ref, verify it
                // asynchronously and fall back to the configured base branch
                // if the remote ref does not exist.
                if rawDefault != baseBranch {
                    scheduleBaseBranchProbe(
                        for: existing,
                        worktreePath: worktree.path,
                        rawBaseBranch: baseBranch
                    )
                }
            } else if !existing.userOverrodeBaseBranch && existing.lastEffectiveBaseBranch != rawDefault {
                // The configured base didn't change, but the effective default
                // did (e.g. the worktree branch changed). Follow it without
                // discarding a verified fallback.
                existing.lastEffectiveBaseBranch = rawDefault
                existing.baseBranch = rawDefault
                // The review loop tracks the configured base branch, not the
                // comparison ref, so PR actions target the right remote base.
                existing.behindBase = nil
                existing.baseBranchProbeTask?.cancel()
                Task { @MainActor in
                    await existing.refresh()
                    await existing.refreshSyncStatus()
                }

                if rawDefault != baseBranch {
                    scheduleBaseBranchProbe(
                        for: existing,
                        worktreePath: worktree.path,
                        rawBaseBranch: baseBranch
                    )
                }
            }
            if comparisonModeChanged {
                existing.comparisonMode = comparisonMode
                Task { @MainActor in await existing.refresh() }
            }
            result = existing
        } else {
            // First activation for this worktree. If the effective default is a
            // guessed origin ref, don't start the initial refresh until the
            // probe either confirms it or falls back. That avoids racing two
            // refreshes with different base refs.
            let shouldDeferInitialRefresh = rawDefault != baseBranch
            let new = RightPaneState(worktree: worktree, baseBranch: baseBranch)
            // The commits comparison starts from the effective default, while
            // the review loop keeps the configured base branch for PR actions.
            new.baseBranch = rawDefault
            new.lastConfigBaseBranch = baseBranch
            new.lastEffectiveBaseBranch = rawDefault
            new.comparisonMode = comparisonMode
            new.isAwaitingBaseBranchProbe = shouldDeferInitialRefresh
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
            new.ggContextProvider = { [weak self] branch in
                guard let app = self?.appState,
                      let project = app.projectsManager.projects.first(
                        where: { $0.id == worktree.projectId }
                      )
                else { return .inactive(reason: .policyOff) }
                return app.ggWorktreeContext(
                    project: project,
                    worktree: worktree,
                    branch: branch
                )
            }
            new.refreshProjectTopologyAfterGGMutation = { [weak self] in
                guard let app = self?.appState else { return }
                await app.refreshProjectTopology(projectId: worktree.projectId)
            }
            new.selectWorktreeAtPathAfterGGMutation = { [weak self] path in
                guard let app = self?.appState,
                      let target = app.projectsManager.worktrees(projectId: worktree.projectId)
                          .first(where: { $0.path.path == path })
                else { return }
                app.focusGlobalWorktree(id: target.id, projectId: worktree.projectId)
            }
            new.requestGGSplitCommit = { [weak self] entry in
                guard let app = self?.appState else { return }
                _ = app.tabs.openGGSplitCommit(
                    worktreeId: worktree.id,
                    targetGGID: entry.ggId,
                    targetSHA: entry.sha
                )
            }

            if shouldDeferInitialRefresh {
                new.baseBranchProbeTask = Task { @MainActor [weak self, weak new] in
                    guard let state = new else { return }
                    defer { state.isAwaitingBaseBranchProbe = false }
                    let confirmed = await self?.resolveEffectiveBaseBranch(
                        worktreePath: worktree.path,
                        baseBranch: baseBranch
                    ) ?? baseBranch
                    guard !Task.isCancelled,
                          !state.userOverrodeBaseBranch,
                          confirmed != state.baseBranch else {
                        // Even if we didn't change the base branch, kick off
                        // the deferred initial refresh now that verification
                        // is done, but only if this state is still active.
                        guard self?.activeId == id else { return }
                        state.start()
                        return
                    }
                    // Invalidate any snapshot state populated with the guessed
                    // origin ref before the fallback, then start with the
                    // real base branch.
                    state.markSnapshotUnknown()
                    state.baseBranch = confirmed
                    state.behindBase = nil
                    guard self?.activeId == id else { return }
                    state.start()
                    await state.refresh()
                    await state.refreshSyncStatus()
                }
            }

            states[id] = new
            result = new
        }
        if activeId != id {
            if let prev = activeId, let prevState = states[prev] {
                prevState.stop()
            }
            activeId = id
            // Don't start the state's background work here if we deferred it
            // above to wait for the base-branch probe; the probe's task will
            // call start() once it knows the real comparison ref.
            if !result.isAwaitingBaseBranchProbe {
                result.start()
            }
        }
        return result
    }

    /// Verifies whether `origin/<rawBaseBranch>` resolves in the worktree. If
    /// it does not, applies the original `rawBaseBranch` as the fallback.
    /// Cancels any previous probe on the state first.
    private func scheduleBaseBranchProbe(
        for state: RightPaneState,
        worktreePath: URL,
        rawBaseBranch: String
    ) {
        state.baseBranchProbeTask?.cancel()
        state.baseBranchProbeTask = Task { @MainActor [weak state] in
            guard let state = state else { return }
            defer { state.baseBranchProbeTask = nil }
            let confirmed = await self.resolveEffectiveBaseBranch(
                worktreePath: worktreePath,
                baseBranch: rawBaseBranch
            )
            guard !Task.isCancelled,
                  !state.userOverrodeBaseBranch,
                  confirmed != state.baseBranch else { return }
            // Invalidate any in-flight refresh that may have been started with
            // the guessed origin ref before it falls back.
            state.markSnapshotUnknown()
            state.baseBranch = confirmed
            state.behindBase = nil
            await state.refresh()
            await state.refreshSyncStatus()
        }
    }

    /// Refreshes the cached `RightPaneState` for `worktreeId` if one exists.
    /// No-op when the worktree hasn't been activated yet. Called from the
    /// merge-conflict editor after `Mark resolved` so the Conflicts section
    /// reflects the staged resolution immediately without waiting for the
    /// FSEvents debouncer.
    func refresh(worktreeId: String, forceReviewLoopRemote: Bool = false) async {
        guard let state = states[worktreeId] else { return }
        await state.refresh(forceReviewLoopRemote: forceReviewLoopRemote)
    }

    func invalidateSnapshot(worktreeId: String) {
        states[worktreeId]?.markSnapshotUnknown()
    }

    /// Re-evaluate the gg gate across all cached right-pane states after a
    /// stacked-diffs config change in Settings (master toggle or a
    /// project's ggMode), so stale stack styling and the sidebar badge
    /// clear/reload immediately instead of waiting for the next
    /// watcher-driven refresh.
    func reevaluateGGGates() {
        for state in states.values { state.reevaluateGGGate() }
    }

    /// Re-evaluate the gg gate for one cached worktree after its override
    /// changes. Returns nil when that worktree has no cached pane state.
    @discardableResult
    func reevaluateGGGate(worktreeId: String) -> Task<Void, Never>? {
        states[worktreeId]?.reevaluateGGGate()
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

    /// The first cached state currently reporting that a PR was added to the
    /// merge queue. Like merge errors, this is surfaced app-wide independent
    /// of current selection because the async operation can finish after the
    /// user switches worktrees.
    func stateReportingMergeQueuedMessage() -> RightPaneState? {
        states.values.first { $0.mergeQueuedMessage != nil }
    }

    /// The first cached state with a pending merge confirmation, if any. The
    /// confirmation dialog (see RootView) resolves its owning state through
    /// this rather than the current selection, so switching worktrees while the
    /// dialog is open can't cancel the wrong state and strand `pendingMerge`.
    func stateWithPendingMerge() -> RightPaneState? {
        states.values.first { $0.pendingMerge != nil }
    }

    /// Cached stack state for a worktree path, if its pane has been activated.
    /// A loaded stack whose key no longer matches the live branch/context is
    /// exposed as loading so non-UI consumers cannot treat it as current.
    func ggStackSnapshotForWorktreePath(
        _ path: String,
        effectiveContext: GGWorktreeContext
    ) -> RightPaneGGStackSnapshot? {
        guard let state = states.values.first(where: { $0.worktree.path.path == path }) else {
            return nil
        }
        let loadState: GGStackLoadState
        if state.ggStackLoadState == .loaded,
           (state.ggStackCommitsKey != state.currentGGStackCommitsKey
            || state.ggContext != effectiveContext)
        {
            loadState = effectiveContext.isActive ? .loading : .inactive
        } else {
            loadState = state.ggStackLoadState
        }
        return RightPaneGGStackSnapshot(
            stack: state.ggStack,
            loadState: loadState
        )
    }

    /// Latest branch observed by the cached pane state. Nil when the pane has
    /// never been created, allowing callers to fall back to topology state.
    func currentBranchForWorktreePath(_ path: String) -> String? {
        states.values.first { $0.worktree.path.path == path }?.currentBranch
    }

    /// The first cached state with a pending gg-land confirmation, if any.
    /// Mirrors `stateWithPendingMerge` for the same reason: the confirmation
    /// dialog (see RootView) must resolve its owning state through this
    /// rather than the current selection, so switching worktrees while the
    /// dialog is open can't cancel the wrong state and strand `pendingGGLand`.
    func stateWithPendingGGLand() -> RightPaneState? {
        states.values.first { $0.pendingGGLand != nil }
    }

    func stateWithPendingGGDrop() -> RightPaneState? {
        states.values.first { $0.pendingGGDrop != nil }
    }

    func stateWithPendingGGUnstack() -> RightPaneState? {
        states.values.first { $0.pendingGGUnstack != nil }
    }

    func stateWithPendingGGReorder() -> RightPaneState? {
        states.values.first { $0.pendingGGReorder != nil }
    }

    func stateWithPendingGGRestack() -> RightPaneState? {
        states.values.first { $0.pendingGGRestack != nil }
    }

    /// The first cached state with a pending gg clean-all confirmation.
    /// Mirrors the other cross-worktree confirmations so changing selection
    /// while the dialog is open resolves the state that requested it.
    func stateWithPendingGGCleanAll() -> RightPaneState? {
        states.values.first { $0.pendingGGCleanAll }
    }
}
