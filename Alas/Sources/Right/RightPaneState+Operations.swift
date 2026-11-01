import AppKit
import Foundation
import Observation
import os

extension RightPaneState {
    /// Probes the worktree's "behind" status against the trunk base AND
    /// against the branch's own upstream tracking ref (when one exists).
    /// Fetches each resolvable remote ref when the last probe was older
    /// than 30s. Errors are logged but never surfaced; chips reflect the
    /// last successful probe (or stay hidden if none has succeeded yet).
    @MainActor
    func refreshSyncStatus(force: Bool = false) async {
        guard !isFolder else { return }
        await refreshBehindBase(force: force)
        await refreshBehindUpstream(force: force)
    }

    /// Force an immediate fetch + recompute of the behind chips, bypassing the
    /// 30s probe throttle. Backs the "Fetch now" menu item.
    @MainActor
    func fetchNow() {
        guard !fetchInFlight, !pullInFlight else { return }
        fetchInFlight = true
        Task { @MainActor in
            defer { fetchInFlight = false }
            await self.refreshSyncStatus(force: true)
        }
    }

    @MainActor
    private func shouldFetchSyncTarget(remote: String, branch: String, force: Bool) -> Bool {
        let target = SyncFetchTarget(remote: remote, branch: branch)
        let now = Date()
        if force || now.timeIntervalSince(lastSyncFetchAtByTarget[target] ?? .distantPast) > 30 {
            lastSyncFetchAtByTarget[target] = now
            return true
        }
        return false
    }

    @MainActor
    private func refreshBehindBase(force: Bool = false) async {
        do {
            guard let resolved = try await git.resolveBaseRef(
                worktreePath: worktree.path,
                baseBranch: baseBranch,
                preferLocal: userOverrodeBaseBranch
            ) else {
                behindBase = nil
                return
            }
            if let remote = resolved.remote {
                let branch = resolved.fetchBranch ?? baseBranch
                if shouldFetchSyncTarget(remote: remote, branch: branch, force: force) {
                    do {
                        try await git.fetchRef(
                            worktreePath: worktree.path,
                            remote: remote,
                            branch: branch
                        )
                    } catch {
                        logger.error("base fetch failed for \(self.worktree.path.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
            self.behindBase = try await git.behindStatus(
                worktreePath: worktree.path,
                ref: resolved.baseRef
            )
        } catch {
            logger.error("behind-base probe failed for \(self.worktree.path.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    @MainActor
    private func refreshBehindUpstream(force: Bool = false) async {
        do {
            guard let upstream = try await git.resolveUpstreamRef(
                worktreePath: worktree.path
            ) else {
                behindUpstream = nil
                upstreamRef = nil
                return
            }
            upstreamRef = upstream.ref
            // Upstream ref looks like "origin/<branch>"; the local branch name
            // is what we fetch.
            let branchName = String(upstream.ref.dropFirst(upstream.remote.count + 1))
            if shouldFetchSyncTarget(remote: upstream.remote, branch: branchName, force: force) {
                do {
                    try await git.fetchRef(
                        worktreePath: worktree.path,
                        remote: upstream.remote,
                        branch: branchName
                    )
                } catch {
                    logger.error("upstream fetch failed for \(self.worktree.path.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            self.behindUpstream = try await git.behindStatus(
                worktreePath: worktree.path,
                ref: upstream.ref
            )
        } catch {
            logger.error("behind-upstream probe failed for \(self.worktree.path.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Load the next page of pre-divergence history. Uses the oldest
    /// currently-visible SHA as the cursor; falls back to HEAD when the
    /// section is sitting on base (or there's no comparison ref at all).
    /// Concurrent re-entry is blocked by `isLoadingOlder` — the view
    /// hides the tap target while a load is in flight.
    @MainActor
    func loadOlder() async {
        guard !isLoadingOlder,
              hasMoreOlder,
              ggStackLoadState != .loading
        else { return }
        let displayGeneration = commitDisplayGeneration
        let cursor: String
        if let last = olderCommits.last {
            cursor = last.sha
        } else if let last = commitsForDisplay.last {
            cursor = last.sha
        } else {
            cursor = "HEAD"
        }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        do {
            let page = try await git.commitsOlder(
                worktreePath: worktree.path,
                beforeSha: cursor,
                count: 20
            )
            let cursorStillValid = (olderCommits.last?.sha == cursor)
                || (olderCommits.isEmpty && commitsForDisplay.last?.sha == cursor)
                || (olderCommits.isEmpty && commitsForDisplay.isEmpty && cursor == "HEAD")
            guard displayGeneration == commitDisplayGeneration,
                  cursorStillValid
            else { return }
            self.olderCommits.append(contentsOf: page)
            if page.count < 20 {
                self.hasMoreOlder = false
            }
        } catch is CancellationError {
            // user-cancelled
        } catch {
            logger.error("loadOlder failed for worktree \(self.worktree.path.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            self.hasMoreOlder = false
        }
    }

    func invalidateOlderHistoryForDisplaySourceChange() {
        commitDisplayGeneration &+= 1
        olderCommits = []
        hasMoreOlder = true
    }

    // MARK: - Merge / rebase / cherry-pick operations

    /// Runs `git merge <branch>`, refreshes state, and auto-opens the first
    /// conflicted file (via `openConflict`) when the result is a conflict.
    @MainActor
    func runMerge(branch: String) {
        guard !checkpointMutationsDisabled else { return }
        Task { @MainActor in
            do {
                guard await self.checkpointMutationAllowedAfterJournalRevalidation() else { return }
                let result = try await git.merge(worktreePath: worktree.path, branch: branch)
                await refresh()
                handleOperationResult(result)
            } catch {
                logger.error("merge failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    @MainActor
    func runRebase(onto: String) {
        guard !checkpointMutationsDisabled else { return }
        Task { @MainActor in
            do {
                guard await self.checkpointMutationAllowedAfterJournalRevalidation() else { return }
                let result = try await git.rebase(worktreePath: worktree.path, onto: onto)
                await refresh()
                handleOperationResult(result)
            } catch {
                logger.error("rebase failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    @MainActor
    func runCherryPick(sha: String) {
        guard !checkpointMutationsDisabled else { return }
        Task { @MainActor in
            do {
                guard await self.checkpointMutationAllowedAfterJournalRevalidation() else { return }
                let result = try await git.cherryPick(worktreePath: worktree.path, sha: sha)
                await refresh()
                handleOperationResult(result)
            } catch {
                logger.error("cherry-pick failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Pull the current branch's upstream (fetch + rebase onto it). Surfaces
    /// conflicts through the existing `OperationCard` via `refresh()` +
    /// `handleOperationResult`. No-ops unless the upstream chip is actually
    /// showing (behind by >0, attached HEAD), and when an operation is already
    /// in flight or a pull is already running. Gating on `showBehindUpstreamChip`
    /// keeps the action's safety with the action rather than relying on the
    /// view to hide the chip.
    @MainActor
    func pull() {
        guard showBehindUpstreamChip, mergeOp.current == nil, !pullInFlight, !checkpointMutationsDisabled else { return }
        sidebarError = nil
        pullInFlight = true
        Task { @MainActor in
            defer { pullInFlight = false }
            await performPull(autoOpenConflicts: { true })
        }
    }

    /// Sidebar-driven pull that the caller can await. Returns when the rebase
    /// (and its follow-up refreshes) finishes so the sidebar keeps its
    /// spinner up for exactly as long as the work runs. Returns nil when a
    /// guard declined the pull; `.clean` when the pull succeeded; `.conflict`
    /// when the worktree is left mid-rebase; `.error` when git reported a
    /// failure.
    ///
    /// The checkpoint journal revalidation lives in `performPull()` rather
    /// than here: the sidebar can reach a worktree whose pane was never
    /// activated (and therefore never ran journal discovery), and the cached
    /// `checkpointMutationsDisabled` would silently veto the pull.
    ///
    /// - Parameter autoOpenConflicts: Evaluated once, at completion, to
    ///   decide whether a `.conflict` result auto-opens the first conflicted
    ///   file. The sidebar passes a selection check so the pull the user is
    ///   looking at behaves like a changes-tab pull, while a background pull
    ///   stays silent (an invisible tab activation would also clear a viewing
    ///   native peer session's selection).
    @discardableResult
    @MainActor
    func pullAwaited(autoOpenConflicts: @escaping () -> Bool) async -> MergeResult? {
        guard showBehindUpstreamChip, mergeOp.current == nil, !pullInFlight else { return nil }
        sidebarError = nil
        pullInFlight = true
        defer { pullInFlight = false }
        return await performPull(autoOpenConflicts: autoOpenConflicts)
    }

    /// The body shared by `pull()` and `pullAwaited()`. Both entry points own
    /// their `pullInFlight` bookkeeping around this; the body performs the
    /// guarded work, records the failure message in `sidebarError`, and
    /// returns the pull outcome (nil when a checkpoint guard rejected it).
    ///
    /// - Parameter autoOpenConflicts: Evaluated at completion to decide
    ///   whether a `.conflict` result auto-opens the first conflicted file's
    ///   tab. Constant true from `pull()`; a selection check from
    ///   `pullAwaited()` — see its doc comment.
    @MainActor
    private func performPull(autoOpenConflicts: () -> Bool) async -> MergeResult? {
        do {
            guard await checkpointMutationAllowedAfterJournalRevalidation() else { return nil }
            let result = try await git.pull(worktreePath: worktree.path)
            await refresh()
            // pull() already fetched upstream; skip the redundant network
            // fetch and just recount against the already-fresh tracking ref.
            await refreshSyncStatus()
            if autoOpenConflicts() {
                handleOperationResult(result)
            }
            if case .error(let message) = result {
                sidebarError = message
            }
            return result
        } catch {
            // Unlike the pure rebase/merge siblings, surface the failure to
            // the user: a pull is the only signal they have that it ran.
            sidebarError = error.localizedDescription
            logger.error("pull failed: \(error.localizedDescription, privacy: .public)")
            return .error(message: error.localizedDescription)
        }
    }

    @MainActor
    func runRevert(sha: String) {
        guard !checkpointMutationsDisabled else { return }
        Task { @MainActor in
            do {
                guard await self.checkpointMutationAllowedAfterJournalRevalidation() else { return }
                let result = try await git.revert(worktreePath: worktree.path, sha: sha)
                await refresh()
                handleOperationResult(result)
            } catch {
                logger.error("revert failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    @MainActor
    func continueOperation() {
        guard !checkpointMutationsDisabled else { return }
        Task { @MainActor in
            guard let op = mergeOp.current else { return }
            do {
                guard await self.checkpointMutationAllowedAfterJournalRevalidation() else { return }
                let result = try await git.continueOperation(worktreePath: worktree.path, op: op)
                await refresh()
                handleOperationResult(result)
            } catch {
                logger.error("continue failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    @MainActor
    func abortOperation() {
        guard !checkpointMutationsDisabled else { return }
        Task { @MainActor in
            guard let op = mergeOp.current else { return }
            do {
                guard await self.checkpointMutationAllowedAfterJournalRevalidation() else { return }
                try await git.abortOperation(worktreePath: worktree.path, op: op)
                await refresh()
            } catch {
                logger.error("abort failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    @MainActor
    func skipOperation() {
        guard !checkpointMutationsDisabled else { return }
        Task { @MainActor in
            guard let op = mergeOp.current else { return }
            do {
                guard await self.checkpointMutationAllowedAfterJournalRevalidation() else { return }
                let result = try await git.skipOperation(worktreePath: worktree.path, op: op)
                await refresh()
                handleOperationResult(result)
            } catch {
                logger.error("skip failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    @MainActor
    func useOurs(file: ChangedFile) {
        guard !checkpointMutationsDisabled else { return }
        Task { @MainActor in
            do {
                guard await self.checkpointMutationAllowedAfterJournalRevalidation() else { return }
                try await git.useOurs(worktreePath: worktree.path, relativePath: file.path)
                try await git.markResolved(worktreePath: worktree.path, relativePath: file.path)
                await refresh()
            } catch {
                logger.error("useOurs failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    @MainActor
    func useTheirs(file: ChangedFile) {
        Task { @MainActor in
            do {
                guard await self.checkpointMutationAllowedAfterJournalRevalidation() else { return }
                try await git.useTheirs(worktreePath: worktree.path, relativePath: file.path)
                try await git.markResolved(worktreePath: worktree.path, relativePath: file.path)
                await refresh()
            } catch {
                logger.error("useTheirs failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    @MainActor
    func keepDeleted(file: ChangedFile) {
        Task { @MainActor in
            do {
                guard await self.checkpointMutationAllowedAfterJournalRevalidation() else { return }
                try await git.keepDeleted(worktreePath: worktree.path, relativePath: file.path)
                await refresh()
            } catch {
                logger.error("keepDeleted failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    @MainActor
    func markResolved(file: ChangedFile) {
        Task { @MainActor in
            do {
                guard await self.checkpointMutationAllowedAfterJournalRevalidation() else { return }
                try await git.markResolved(worktreePath: worktree.path, relativePath: file.path)
                await refresh()
            } catch {
                logger.error("markResolved failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Hands the configured agent the whole worktree (CWD'd at
    /// `worktree.path`) with a single "fix every merge conflict" prompt.
    /// The agent uses its own tools to enumerate conflicted files, read
    /// surrounding code for context, write reconciled output, and stage.
    /// One call instead of N gives the agent cross-file context (which
    /// is the entire point of resolving merges with a coding agent) and
    /// avoids paying CLI startup cost per file.
    @MainActor
    func resolveAllConflicts(
        using agent: AgentDefinition,
        prompt: String,
        target: AgentExecutionTarget = .local,
        agentBinaryUnavailable: ((AgentExecutionTarget) async -> Void)? = nil
    ) {
        guard !checkpointMutationsDisabled else { return }
        guard bulkResolveTask == nil else { return }
        guard changes.contains(where: { $0.conflict != nil }) else { return }
        bulkResolveInFlight = true
        bulkResolveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var report: BulkConflictResolveReport
            do {
                guard await self.checkpointMutationAllowedAfterJournalRevalidation() else { return }
                let agentOutput = try await MergeAgent.resolveAllInWorkspace(
                    agent: agent,
                    prompt: prompt,
                    worktreePath: self.worktree.path,
                    target: target
                )
                await self.refresh()
                let remaining = self.changes.filter { $0.conflict != nil }.count
                let headline: String = {
                    if remaining == 0 {
                        return "All conflicts resolved."
                    }
                    return "Agent finished — \(remaining) conflict(s) still need attention."
                }()
                report = BulkConflictResolveReport(
                    success: true,
                    remainingConflicts: remaining,
                    summary: headline,
                    details: agentOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            } catch let runError as AgentRunError {
                if case .binaryNotFound = runError,
                   case .ssh = target {
                    await agentBinaryUnavailable?(target)
                }
                await self.refresh()
                let remaining = self.changes.filter { $0.conflict != nil }.count
                report = BulkConflictResolveReport(
                    success: false,
                    remainingConflicts: remaining,
                    summary: "Agent failed: \(runError.localizedDescription)",
                    details: ""
                )
            } catch {
                await self.refresh()
                let remaining = self.changes.filter { $0.conflict != nil }.count
                report = BulkConflictResolveReport(
                    success: false,
                    remainingConflicts: remaining,
                    summary: "Agent failed: \(error.localizedDescription)",
                    details: ""
                )
            }
            self.bulkResolveInFlight = false
            self.bulkResolveTask = nil
            self.bulkResolveDidFinish?(report)
        }
    }

    /// Cancels an in-flight bulk resolve by tearing down the agent
    /// process via Task cancellation (AgentRunner forwards as SIGTERM).
    @MainActor
    func cancelBulkResolve() {
        bulkResolveTask?.cancel()
    }

    /// On `.conflict`, auto-open the first conflicted file via the injected
    /// `openConflict` closure. On `.clean`/`.error`, do nothing (refresh already
    /// updated the operation card; `.error` is logged but not surfaced for v1).
    private func handleOperationResult(_ result: MergeResult) {
        switch result {
        case .clean:
            return
        case .conflict(let files):
            guard let first = files.first else { return }
            openConflict?(first.path)
        case .error(let message):
            logger.error("operation returned error: \(message, privacy: .public)")
        }
    }
}
