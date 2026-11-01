import AppKit
import Foundation
import Observation
import os

extension RightPaneState {
    func startRemoteHelperWatching() {
        guard remoteHelperSession == nil,
              let host = RemoteHostRegistry.shared.host(forPath: worktree.path.path)
        else { return }
        let session = RemoteHelperWatchSession(
            host: host,
            root: worktree.path.path,
            kinds: isFolder ? [.files] : [.files, .git]
        )
        session.onEvent = { [weak self] _ in
            self?.remoteEventDebouncer.poke()
        }
        session.onAvailabilityChanged = { [weak self] _ in
            self?.startRemotePolling()
        }
        remoteHelperSession = session
        session.start()
    }

    func startRemotePolling() {
        remotePollTask?.cancel()
        remotePollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let interval = self?.remoteHelperSession?.isAvailable == true
                    ? Self.remoteHelperSafetyNetNanos
                    : Self.remotePollIntervalNanos
                do {
                    try await Task.sleep(nanoseconds: interval)
                } catch {
                    return
                }
                guard let self, !Task.isCancelled, NSApp?.isActive ?? true else { continue }
                await remotePollTick()
                remoteHelperSession?.retryIfNeeded()
            }
        }
    }

    private func remotePollTick() async {
        // A folder has no git status to diff; re-listing its tree is the poll.
        if isFolder {
            await refresh()
            return
        }
        let host = RemoteHostRegistry.shared.host(forPath: worktree.path.path)
        let status = try? await Process.git(["status", "--porcelain=v2", "-z", "--untracked-files=all"], cwd: worktree.path)
        guard let status, !RemoteExec.isConnectionFailure(exitCode: status.exitCode) else {
            if let host { RemoteHostStatusStore.shared.reportConnectionFailure(host: host) }
            return
        }
        if let host { RemoteHostStatusStore.shared.reportSuccess(host: host) }
        guard status.exitCode == 0 else { return }
        let head = try? await Process.git(["rev-parse", "HEAD"], cwd: worktree.path)
        let unstagedDiff = try? await Process.git(["diff", "--no-ext-diff", "--binary"], cwd: worktree.path)
        let stagedDiff = try? await Process.git(["diff", "--cached", "--no-ext-diff", "--binary"], cwd: worktree.path)
        let untrackedContent: ProcessResult?
        if let host {
            untrackedContent = try? await RemoteExec.run(
                host: host,
                cwd: worktree.path.path,
                command: Self.remoteUntrackedContentFingerprintCommand,
                timeout: 15
            )
        } else {
            untrackedContent = nil
        }
        let fingerprint = RemoteStatusFingerprint.make(
            status: status.stdout,
            head: head?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            unstagedDiff: unstagedDiff?.stdout ?? "",
            stagedDiff: stagedDiff?.stdout ?? "",
            untrackedContent: untrackedContent?.stdout ?? ""
        )
        let shouldRefresh = RemoteStatusFingerprint.shouldRefresh(previous: remoteFingerprint, current: fingerprint)
        remoteFingerprint = fingerprint
        if shouldRefresh { await refresh() }
    }

    /// Update the base branch, record it in the recent list, and refresh.
    func selectBaseBranch(_ branch: String) {
        baseBranch = branch
        reviewLoop.updateBaseBranch(branch)
        userOverrodeBaseBranch = true
        behindBase = nil
        recentBaseBranches.removeAll { $0 == branch }
        recentBaseBranches.append(branch)
        if recentBaseBranches.count > 3 {
            recentBaseBranches = Array(recentBaseBranches.suffix(3))
        }
        Task { @MainActor in
            async let r = refresh()
            async let s = refreshSyncStatus()
            _ = await (r, s)
        }
    }

    /// Populate `availableBranches` from git. Best-effort; errors are logged.
    func fetchBranches() async {
        guard !isFetchingBranches else { return }
        isFetchingBranches = true
        defer {
            isFetchingBranches = false
            hasFetchedBranches = true
        }

        do {
            availableBranches = try await git.branches(at: worktree.path)
        } catch {
            logger.error("branch list fetch failed for \(self.worktree.path.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func handleReviewReadinessAction(_ action: ReviewReadinessActionKind, appState: AppState) {
        guard reviewLoop.inFlightAction == nil else { return }

        switch action {
        case .refresh:
            guard reviewLoop.beginAction(action) else { return }
            Task { @MainActor in
                defer { reviewLoop.endAction(action) }
                await refresh(forceReviewLoopRemote: true)
            }
        case .openReviewRequest:
            openReviewLoopProviderPage()
        case .openAgentHandoff:
            guard canOpenReviewLoopHandoff(appState: appState) else { return }
            appState.openReviewLoopHandoff(from: reviewLoop, actionKind: action)
        case .inspectReviewEvidence:
            guard let snapshot = reviewLoop.snapshot,
                  snapshot.reviewRequest != nil
            else { return }
            appState.tabs.openOrFocusReviewPR(
                worktreeId: worktree.id,
                snapshot: snapshot
            )
        case .pushBranch, .pushAndCreateReviewRequest, .forcePushBranch:
            guard let snapshot = reviewLoop.snapshot else { return }
            if action == .pushAndCreateReviewRequest {
                guard snapshot.reviewRequest == nil,
                      snapshot.remote != nil,
                      snapshot.providerAvailable,
                      snapshot.providerAuthenticated,
                      snapshot.local.needsPush,
                      snapshot.local.pushState != .diverged,
                      snapshot.local.pushState != .stale,
                      ReviewReadinessModel.canCreateReviewRequest(snapshot)
                else { return }
            }
            guard reviewLoop.beginAction(action) else { return }
            Task { @MainActor in
                defer { reviewLoop.endAction(action) }
                await performReviewLoopPush(
                    action,
                    snapshot: snapshot,
                    appState: appState,
                    push: {
                        try await Process.git(
                            snapshot.pushArguments(forceWithLease: action == .forcePushBranch),
                            cwd: worktree.path
                        )
                    },
                    refresh: { await self.refresh() }
                )
            }
        case .createReviewRequest:
            guard let snapshot = reviewLoop.snapshot else { return }
            guard appState.tabs.requiresLegacyDraftBranchVerification(worktreeId: worktree.id, snapshot: snapshot) else {
                appState.tabs.openOrFocusDraftReviewRequest(worktreeId: worktree.id, snapshot: snapshot)
                return
            }
            Task { @MainActor in
                await openLegacyReviewRequestDraft(snapshot: snapshot, appState: appState)
            }
        case .rerunFailedChecks:
            guard let snapshot = reviewLoop.snapshot else { return }
            guard reviewLoop.beginAction(action) else { return }
            Task { @MainActor in
                defer { reviewLoop.endAction(action) }
                if await reviewLoop.rerunFailedChecks(snapshot: snapshot) {
                    await refresh(forceReviewLoopRemote: true)
                }
            }
        case .merge:
            guard let snapshot = reviewLoop.snapshot,
                  ReviewReadinessModel.canMergeReviewRequest(snapshot: snapshot)
            else { return }
            pendingMerge = snapshot
        }
    }

    func performReviewLoopPush(
        _ action: ReviewReadinessActionKind,
        snapshot: ReviewLoopSnapshot,
        appState: AppState,
        push: @MainActor () async throws -> ProcessResult,
        refresh: @MainActor () async -> Bool
    ) async {
        do {
            let result = try await push()
            guard result.exitCode == 0 else {
                sidebarError = result.pushFailureMessage
                return
            }
            let refreshed = await refresh()
            if action == .pushAndCreateReviewRequest {
                guard refreshed,
                      let current = reviewLoop.snapshot,
                      current.local.branchName == snapshot.local.branchName,
                      current.local.headSHA == snapshot.local.headSHA,
                      !current.local.needsPush,
                      current.reviewRequest == nil,
                      current.errorMessage == nil,
                      ReviewReadinessModel.canCreateReviewRequest(current)
                else {
                    sidebarError = reviewLoop.lastError ?? "Pushed branch, but could not prepare the review request draft. Refresh and try again."
                    return
                }
                if appState.tabs.requiresLegacyDraftBranchVerification(worktreeId: worktree.id, snapshot: current) {
                    await openLegacyReviewRequestDraft(snapshot: current, appState: appState)
                } else {
                    appState.tabs.openOrFocusDraftReviewRequest(worktreeId: worktree.id, snapshot: current)
                }
            }
        } catch {
            sidebarError = error.localizedDescription
        }
    }

    func openLegacyReviewRequestDraft(
        snapshot: ReviewLoopSnapshot,
        appState: AppState,
        localBranches: (URL) async throws -> [String] = { try await GitService().localBranches(at: $0) }
    ) async {
        do {
            let branches = try await localBranches(worktree.path)
            guard reviewLoop.snapshot?.local.branchName == snapshot.local.branchName,
                  reviewLoop.snapshot?.local.headSHA == snapshot.local.headSHA
            else { return }
            appState.tabs.openOrFocusDraftReviewRequest(
                worktreeId: worktree.id, snapshot: snapshot,
                existingLocalBranches: Set(branches)
            )
        } catch {
            sidebarError = "Could not verify local branches: \(error.localizedDescription)"
        }
    }

    func canOpenReviewLoopHandoff(appState: AppState) -> Bool {
        guard let request = reviewLoop.snapshot?.reviewRequest else { return false }
        guard request.worstCheckBucket == .fail || request.hasActionableFeedback else { return false }
        return appState.availableAgentForHandoff(id: appState.config.changes.aiToolId, worktree: worktree) != nil
    }

    func openReviewLoopProviderPage() {
        guard let url = reviewLoop.snapshot?.reviewRequest?.url else { return }
        NSWorkspace.shared.open(url)
    }

    nonisolated static func reviewLoopAheadCommitCount(
        displayCommits: [CommitInfo],
        baseCommits: [CommitInfo]?
    ) -> Int {
        baseCommits?.count ?? displayCommits.count
    }

    nonisolated static func shouldScheduleGGStackRefresh(inFlightAction: GGStackActionKind?) -> Bool {
        inFlightAction == nil
    }

    nonisolated static func shouldDeferGGStackRefresh(
        inFlightAction: GGStackActionKind?,
        refreshRequired: Bool
    ) -> Bool {
        inFlightAction != nil && refreshRequired
    }

    nonisolated static func shouldPublishGGStackRefresh(
        refreshedCommitsKey: String,
        currentCommitsKey: String
    ) -> Bool {
        refreshedCommitsKey == currentCommitsKey
    }

    nonisolated static func shouldForceGGStackRefresh(
        forceRemote: Bool,
        deferredUntilMutationEnds: Bool
    ) -> Bool {
        forceRemote || deferredUntilMutationEnds
    }

    @discardableResult
    @MainActor
    func refresh(forceReviewLoopRemote: Bool = false) async -> Bool {
        if refreshInFlight {
            refreshRerunRequested = true
            refreshRerunRequiresReviewLoopRemote = refreshRerunRequiresReviewLoopRemote || forceReviewLoopRemote
            return await withCheckedContinuation { continuation in
                refreshWaiters.append(continuation)
            }
        }

        refreshInFlight = true
        var forceRemoteRefresh = forceReviewLoopRemote
        var refreshed = false
        repeat {
            forceRemoteRefresh = forceRemoteRefresh || refreshRerunRequiresReviewLoopRemote
            refreshRerunRequested = false
            refreshRerunRequiresReviewLoopRemote = false
            refreshed = await performRefresh(forceReviewLoopRemote: forceRemoteRefresh)
            forceRemoteRefresh = false
        } while refreshRerunRequested
        refreshInFlight = false
        let waiters = refreshWaiters
        refreshWaiters = []
        for waiter in waiters {
            waiter.resume(returning: refreshed)
        }
        return refreshed
    }

    private func publishRefreshedFileTree(_ tree: [FileTreeNode]) {
        let previousFileTree = self.fileTree
        let preservedLazyPaths = Self.preservedLazyChildPaths(fresh: tree, previous: previousFileTree)
        let mergedFileTree = Self.preservingLazyChildren(fresh: tree, previous: previousFileTree)
        if self.fileTree != mergedFileTree { self.fileTree = mergedFileTree }
        bookmarkReconciliationPaths = Set(preservedLazyPaths)
        let refreshedTreeBookkeeping = Self.bookkeepingAfterPublishingRefreshedTree(
            loaded: loadedFileTreeChildPaths,
            loading: loadingFileTreeChildPaths
        )
        loadedFileTreeChildPaths = refreshedTreeBookkeeping.loaded
        loadingFileTreeChildPaths = refreshedTreeBookkeeping.loading
        fileTreeChildLoadTokens = Self.loadTokensAfterPublishingRefreshedTree(
            tokens: fileTreeChildLoadTokens,
            loading: loadingFileTreeChildPaths
        )
        fileTreeRefreshRevision &+= 1
    }

    /// A folder has no git to ask: refresh only the Files tree.
    @MainActor
    private func performFolderRefresh() async -> Bool {
        let snapshotGeneration = snapshotInvalidationGeneration
        loading = true
        defer { loading = false }
        invalidateFileTreeChildLoadsForRefresh()
        do {
            let tree = try await git.plainDirectoryChildren(worktreePath: worktree.path, path: "")
            guard snapshotGeneration == snapshotInvalidationGeneration else { return false }
            publishRefreshedFileTree(tree)
            sidebarError = nil
            checkpointJournalDiscoverySucceeded = true
            hasLoadedSnapshot = true
            latestSnapshotRefreshSucceeded = true
            return true
        } catch {
            guard snapshotGeneration == snapshotInvalidationGeneration else { return false }
            sidebarError = error.localizedDescription
            hasLoadedSnapshot = true
            latestSnapshotRefreshSucceeded = false
            logger.error("folder refresh failed for \(self.worktree.path.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    @MainActor
    func performRefresh(forceReviewLoopRemote: Bool) async -> Bool {
        if isFolder { return await performFolderRefresh() }
        refreshGeneration += 1
        let currentRefreshGeneration = refreshGeneration
        let reviewLoopInspection = reviewLoop.beginLocalInspection()
        let snapshotGeneration = snapshotInvalidationGeneration
        let checkpointTarget = checkpointTarget
        checkpointJournalDiscoverySucceeded = checkpointTarget?.path.isRemoteAlasPath == true
        checkpointLoadGeneration &+= 1
        let checkpointGeneration = checkpointLoadGeneration
        async let checkpointLoad = loadCheckpointSnapshot(target: checkpointTarget)
        loading = true
        defer { loading = false }
        invalidateFileTreeChildLoadsForRefresh()
        do {
            let commitsResolution = GitService.BaseResolution.forCommits(
                mode: comparisonMode, userOverrodeBaseBranch: userOverrodeBaseBranch
            )
            let reviewLoopResolution = GitService.BaseResolution.forReviewLoopBase(
                mode: comparisonMode, userOverrodeBaseBranch: userOverrodeBaseBranch
            )
            async let s = git.status(worktreePath: worktree.path)
            async let statusRaw = Process.git(
                ["status", "--porcelain=v2", "-z", "--untracked-files=all"],
                cwd: worktree.path
            )
            async let c = git.commitsAhead(
                at: worktree.path,
                baseBranch: baseBranch,
                resolution: commitsResolution
            )
            async let reviewLoopBase = git.commitsAhead(
                at: worktree.path,
                baseBranch: baseBranch,
                resolution: reviewLoopResolution
            )
            async let br = git.currentBranch(worktreePath: worktree.path)
            async let upstream = git.resolveUpstreamRef(worktreePath: worktree.path)
            async let remotesProbe = git.remotes(worktreePath: worktree.path)
            async let stashProbe = git.stashes(worktreePath: worktree.path)
            let entries = try await s
            let tree = try await git.fileTree(worktreePath: worktree.path, statusEntries: entries)
            let (commits, ref) = try await c
            let reviewLoopBaseResult = try? await reviewLoopBase
            let resolvedUpstream = try? await upstream
            let remotes = (try? await remotesProbe) ?? []
            let stashes = (try? await stashProbe) ?? []
            // Sequential rather than an `async let`: `MergeOperationState` is
            // main-actor isolated and cannot leave that context.
            await mergeOp.refresh()
            let indexFingerprint: String
            if let lsResult = try? await Process.git(
                ["ls-files", "-s", "-z"],
                cwd: worktree.path
            ), lsResult.exitCode == 0 {
                // Each NUL-delimited token is "<mode> <sha> <stage>\t<path>".
                // The blob SHA changes whenever the staged content for that path
                // changes; concatenating sorted blob SHAs gives a cheap fingerprint.
                let tokens = lsResult.stdout
                    .split(separator: "\0", omittingEmptySubsequences: true)
                    .map(String.init)
                    .sorted()
                indexFingerprint = tokens.joined(separator: "|")
            } else {
                indexFingerprint = ""
            }
            async let trackedContentFingerprintTask = Self.trackedContentFingerprint(worktreePath: worktree.path)
            let statusRawResult = try? await statusRaw
            let checkpointResult = await checkpointLoad
            let untrackedPaths = Self.untrackedPaths(from: statusRawResult?.stdout ?? "")
            async let untrackedContentFingerprintTask = Self.untrackedContentFingerprint(paths: untrackedPaths, worktreePath: worktree.path)
            let previousBranch = self.currentBranch
            let previousHeadSHA = self.currentHeadSHA
            let currentBranch = (try? await br) ?? self.currentBranch
            let headSHA = (try? await self.git.revParseHEAD(worktreePath: self.worktree.path)) ?? ""
            let trackedContentFingerprint = await trackedContentFingerprintTask
            let untrackedContentFingerprint = await untrackedContentFingerprintTask
            let workingTreeContentFingerprint = "\(trackedContentFingerprint)\u{0000}\(untrackedContentFingerprint)"
            let newChangesFingerprint = Self.changesFingerprint(
                changes: entries,
                indexFingerprint: indexFingerprint,
                workingTreeContentFingerprint: workingTreeContentFingerprint
            )
            guard snapshotGeneration == snapshotInvalidationGeneration else {
                return false
            }
            // Watcher-driven refreshes fire continuously while agents or
            // builds write into the worktree. @Observable invalidates every
            // observer on assignment regardless of value, so skip writes
            // whose value did not change — otherwise each refresh re-renders
            // everything observing these properties (see the draft-commit
            // diff live-lock: docs/plans/2026-07-09-draft-commit-diff-livelock-fix.md).
            if self.upstreamRef != resolvedUpstream?.ref { self.upstreamRef = resolvedUpstream?.ref }
            if self.changes != entries { self.changes = entries }
            pendingStageMutations.removeAll {
                $0.hasAppliedGitMutation && $0.minimumRefreshGeneration <= currentRefreshGeneration
            }
            self.reconcileStashCaches(with: stashes)
            if self.stashes != stashes { self.stashes = stashes }
            publishCheckpointSnapshot(
                checkpointResult,
                snapshotGeneration: snapshotGeneration,
                checkpointGeneration: checkpointGeneration
            )
            if self.lastChangesFingerprint != newChangesFingerprint {
                self.lastChangesFingerprint = newChangesFingerprint
                self.changesGeneration += 1
            }
            if self.indexFingerprint != indexFingerprint { self.indexFingerprint = indexFingerprint }
            publishRefreshedFileTree(tree)
            // Watcher-driven refreshes fire constantly, so keep the loaded
            // older pages unless the history they hang off actually moved;
            // otherwise an old page could be spliced onto a new HEAD.
            if self.commits != commits || self.comparisonRef != ref || previousHeadSHA != headSHA {
                invalidateOlderHistoryForDisplaySourceChange()
            }
            if self.commits != commits { self.commits = commits }
            let nextGGStackSourceCommits = reviewLoopBaseResult?.commits ?? commits
            let ggStackSourceCommitsChanged = self.ggStackSourceCommits != nextGGStackSourceCommits
            self.ggStackSourceCommits = nextGGStackSourceCommits
            if Self.shouldScheduleGGStackRefresh(inFlightAction: ggActionState.inFlightAction) {
                let forceGGStackRemote = Self.shouldForceGGStackRefresh(
                    forceRemote: forceReviewLoopRemote,
                    deferredUntilMutationEnds: ggStackRefreshDeferredUntilMutationEnds
                )
                ggStackRefreshTask?.cancel()
                ggStackRefreshTask = Task { @MainActor [weak self] in
                    await self?.refreshGGStack(forceRemote: forceGGStackRemote)
                }
            } else if Self.shouldDeferGGStackRefresh(
                inFlightAction: ggActionState.inFlightAction,
                refreshRequired: ggStackSourceCommitsChanged
            ) {
                deferGGStackRefreshUntilMutationEnds()
            }
            if self.comparisonRef != ref { self.comparisonRef = ref }
            let preferredCommitRemoteRef = ref ?? baseBranch
            let commitRemote = CodeHostRemoteDetector.detect(
                from: remotes,
                preferredRemoteName: CodeHostRemoteDetector.preferredRemoteName(
                    forBaseBranch: preferredCommitRemoteRef,
                    remotes: remotes
                )
            )
            if self.commitRemote != commitRemote { self.commitRemote = commitRemote }
            let primaryCommitRemote: CodeHostRemote?
            if let upstreamRemoteName = resolvedUpstream?.remote {
                primaryCommitRemote = CodeHostRemoteDetector.detectAll(
                    from: remotes,
                    preferredRemoteName: upstreamRemoteName
                ).first { $0.remoteName == upstreamRemoteName }
            } else {
                primaryCommitRemote = nil
            }
            if self.primaryCommitRemote != primaryCommitRemote { self.primaryCommitRemote = primaryCommitRemote }
            if self.currentBranch != currentBranch { self.currentBranch = currentBranch }
            if self.currentHeadSHA != headSHA { self.currentHeadSHA = headSHA }
            if previousBranch != currentBranch || previousHeadSHA != headSHA {
                // Branch or HEAD changed (checkout, rebase, reset, amend, …).
                // The behind chips were probed against the OLD branch's base
                // and upstream — clear them so the header doesn't render
                // stale counts, then re-probe in the background.
                self.behindBase = nil
                self.behindUpstream = nil
                Task { @MainActor in await self.refreshSyncStatus() }
            }
            // Smart first-open default: if there are no working-tree
            // changes AND no commits ahead of upstream, surface Files
            // instead of an empty Changes pane. A clean worktree with
            // ahead commits should stay on Changes so the Commits section
            // is visible. Applied exactly once; user toggles win thereafter.
            if !didInitDefaultTab {
                // The tab bar is live before this first refresh lands, so only
                // claim the default when the user hasn't already picked a tab.
                if activeTab == .changes, activePluginPanel == nil, entries.isEmpty, commits.isEmpty, !tree.isEmpty {
                    activeTab = .files
                }
                didInitDefaultTab = true
            }
            self.hasLoadedSnapshot = true
            self.latestSnapshotRefreshSucceeded = true
            ggLocalSnapshotRecoveryTask = nil
            let previousReviewRequestFingerprint = Self.reviewRequestReloadFingerprint(reviewLoop.snapshot?.reviewRequest)
            let upstreamBranchName = resolvedUpstream.map {
                String($0.ref.dropFirst($0.remote.count + 1))
            }
            await refreshReviewLoop(
                inspection: reviewLoopInspection,
                changes: entries,
                displayCommits: commits,
                baseCommits: reviewLoopBaseResult?.commits,
                headSHA: headSHA,
                upstreamRemoteName: resolvedUpstream?.remote,
                upstreamBranchName: upstreamBranchName,
                remotes: remotes,
                forceRemote: forceReviewLoopRemote
            )
            let currentReviewRequestFingerprint = Self.reviewRequestReloadFingerprint(reviewLoop.snapshot?.reviewRequest)
            if previousReviewRequestFingerprint != currentReviewRequestFingerprint {
                changesGeneration += 1
            }
            guard snapshotGeneration == snapshotInvalidationGeneration else { return false }
            attentionSnapshotDidChange?(attentionSnapshot)
            return true
        } catch is CancellationError {
            reviewLoop.cancelLocalRefresh(reviewLoopInspection)
            return false
        } catch {
            reviewLoop.failLocalRefresh(reviewLoopInspection, error: error)
            guard snapshotGeneration == snapshotInvalidationGeneration else {
                return false
            }
            let checkpointResult = await checkpointLoad
            publishCheckpointSnapshot(
                checkpointResult,
                snapshotGeneration: snapshotGeneration,
                checkpointGeneration: checkpointGeneration
            )
            sidebarError = error.localizedDescription
            hasLoadedSnapshot = true
            latestSnapshotRefreshSucceeded = false
            changesGeneration += 1
            // Surface failures via os.Logger so they're visible in Console.app
            // and the unified log. The previous `print` here silently kept
            // `self.changes` at its last successful value, which presented as
            // an empty Changes pane when the very first refresh failed.
            logger.error("refresh failed for worktree \(self.worktree.path.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func markSnapshotUnknown() {
        snapshotInvalidationGeneration += 1
        hasLoadedSnapshot = false
        latestSnapshotRefreshSucceeded = false
        changes = []
        stashes = []
        expandedStashRefs = []
        stashFilesByRef = [:]
        loadingStashRefs = []
        pendingStashChanges = false
        pendingStashDrop = nil
        checkpointJournalDiscoverySucceeded = false
        indexFingerprint = ""
        fileTree = []
        commits = []
        // gg stack state is derived from commits above — reset it here too,
        // and cancel any in-flight load, so a delayed or failed refresh
        // after this invalidation can't leave a stale "Stack · …"
        // header/sidebar badge rendered against the now-empty commit list.
        ggStackSourceCommits = []
        invalidateGGPresentation(startingRefresh: false)
        comparisonRef = nil
        commitRemote = nil
        primaryCommitRemote = nil
        commitsNeedPush = true
        sidebarError = nil
        pendingDiscard = nil
        lastChangesFingerprint = ""
        changesGeneration += 1
        invalidateFileTreeChildLoadsForRefresh()
    }

    private func refreshReviewLoop(
        inspection: ReviewLoopRefreshAttempt,
        changes: [ChangedFile],
        displayCommits: [CommitInfo],
        baseCommits: [CommitInfo]?,
        headSHA: String,
        upstreamRemoteName: String?,
        upstreamBranchName: String?,
        remotes: [GitRemote],
        forceRemote: Bool
    ) async {
        async let needsPushProbe = git.needsPush(worktreePath: worktree.path)
        async let upstreamAheadProbe = git.upstreamAheadCommitCount(worktreePath: worktree.path)
        let needsPush = (try? await needsPushProbe) ?? true
        let upstreamAheadCommitCount = (try? await upstreamAheadProbe) ?? 0
        self.commitsNeedPush = needsPush
        let local = ReviewLoopLocalState(
            branchName: currentBranch,
            headSHA: headSHA,
            baseBranch: reviewLoop.currentBaseBranch,
            hasWorkingTreeChanges: !changes.isEmpty,
            hasStagedChanges: changes.contains { $0.stage == .staged },
            aheadCommitCount: Self.reviewLoopAheadCommitCount(
                displayCommits: displayCommits,
                baseCommits: baseCommits
            ),
            hasUpstream: upstreamRef != nil,
            upstreamRemoteName: upstreamRemoteName,
            upstreamBranchName: upstreamBranchName,
            upstreamAheadCommitCount: upstreamAheadCommitCount,
            needsPush: needsPush
        )

        guard let attempt = reviewLoop.beginLocalRefresh(from: inspection, local: local) else {
            return
        }

        let fingerprint = ReviewLoopRemoteFingerprint(
            branchName: local.branchName,
            headSHA: local.headSHA,
            baseBranch: local.baseBranch,
            hasWorkingTreeChanges: local.hasWorkingTreeChanges,
            hasStagedChanges: local.hasStagedChanges,
            aheadCommitCount: local.aheadCommitCount,
            hasUpstream: local.hasUpstream,
            upstreamRemoteName: local.upstreamRemoteName,
            upstreamBranchName: local.upstreamBranchName,
            upstreamAheadCommitCount: local.upstreamAheadCommitCount,
            needsPush: local.needsPush,
            remotes: Self.reviewLoopRemoteFingerprintRemotes(remotes)
        )
        let now = Date()
        guard forceRemote || Self.shouldRefreshReviewLoopRemote(
            now: now,
            lastRefreshAt: lastReviewLoopRemoteRefreshAt,
            lastFingerprint: lastReviewLoopRemoteFingerprint,
            fingerprint: fingerprint,
            minimumInterval: reviewLoopRemoteRefreshMinimumInterval
        ) else {
            reviewLoop.finishLocalRefresh(attempt, preservingRemoteWith: local)
            return
        }

        lastReviewLoopRemoteRefreshAt = now
        lastReviewLoopRemoteFingerprint = fingerprint
        await reviewLoop.refresh(attempt, remotes: remotes)
        if let snapshot = reviewLoop.snapshot {
            reviewSnapshotDidChange?(snapshot)
        }
    }

    nonisolated static func reviewRequestReloadFingerprint(_ request: ReviewRequest?) -> String {
        guard let request else { return "nil" }
        return [
            request.id,
            request.headSHA ?? "",
            request.headRefName,
            request.baseRefName
        ].joined(separator: "\u{0000}")
    }

    static func reviewLoopRemoteFingerprintRemotes(_ remotes: [GitRemote]) -> [String] {
        remotes
            .map { remote in
                "\(remote.name)\u{1F}\(remote.direction)\u{1F}\(remote.url)"
            }
            .sorted()
    }

    static func shouldRefreshReviewLoopRemote(
        now: Date,
        lastRefreshAt: Date?,
        lastFingerprint: ReviewLoopRemoteFingerprint?,
        fingerprint: ReviewLoopRemoteFingerprint,
        minimumInterval: TimeInterval
    ) -> Bool {
        guard lastFingerprint == fingerprint,
              let lastRefreshAt else {
            return true
        }
        return now.timeIntervalSince(lastRefreshAt) >= minimumInterval
    }

    /// Extracts untracked paths from `git status --porcelain=v2 -z` output.
    nonisolated static func untrackedPaths(from statusRaw: String) -> [String] {
        statusRaw
            .split(separator: "\0", omittingEmptySubsequences: true)
            .compactMap { line -> String? in
                let str = String(line)
                guard str.hasPrefix("? ") else { return nil }
                return String(str.dropFirst(2))
            }
    }

    /// Returns a content fingerprint for tracked changes. Raw diff metadata is
    /// insufficient for unstaged worktree edits because Git reports an all-zero
    /// destination object when the filesystem copy is out of sync with the
    /// index, but full binary patches can be very large. Keep the cheap raw
    /// metadata and add path-scoped worktree blob hashes instead.
    nonisolated static func trackedContentFingerprint(worktreePath: URL) async -> String {
        if let raw = try? await Process.git(
            ["diff", "--raw", "-z", "--no-renames", "HEAD"],
            cwd: worktreePath
        ), raw.exitCode == 0 {
            let paths = await gitChangedPaths(
                ["diff", "--name-only", "-z", "--no-renames", "HEAD"],
                worktreePath: worktreePath
            )
            let content = await pathContentFingerprint(paths: paths, worktreePath: worktreePath)
            return "\(raw.stdout)\u{0000}\(content)"
        }

        let cachedRaw = (try? await Process.git(
            ["diff", "--raw", "-z", "--no-renames", "--cached"],
            cwd: worktreePath
        )).flatMap { $0.exitCode == 0 ? $0.stdout : nil } ?? ""
        let unstagedRaw = (try? await Process.git(
            ["diff", "--raw", "-z", "--no-renames"],
            cwd: worktreePath
        )).flatMap { $0.exitCode == 0 ? $0.stdout : nil } ?? ""
        let cachedPaths = await gitChangedPaths(
            ["diff", "--name-only", "-z", "--no-renames", "--cached"],
            worktreePath: worktreePath
        )
        let unstagedPaths = await gitChangedPaths(
            ["diff", "--name-only", "-z", "--no-renames"],
            worktreePath: worktreePath
        )
        let paths = cachedPaths + unstagedPaths
        let content = await pathContentFingerprint(paths: paths, worktreePath: worktreePath)
        return "\(cachedRaw)\u{0000}\(unstagedRaw)\u{0000}\(content)"
    }

    /// Hashes the contents of untracked files so content edits that leave the
    /// status line unchanged still invalidate the change fingerprint.
    nonisolated static func untrackedContentFingerprint(paths: [String], worktreePath: URL) async -> String {
        await pathContentFingerprint(paths: paths, worktreePath: worktreePath)
    }

    nonisolated private static func gitChangedPaths(_ args: [String], worktreePath: URL) async -> [String] {
        guard let result = try? await Process.git(args, cwd: worktreePath), result.exitCode == 0 else {
            return []
        }
        return result.stdout
            .split(separator: "\0", omittingEmptySubsequences: true)
            .map(String.init)
    }

    nonisolated private static func pathContentFingerprint(paths: [String], worktreePath: URL) async -> String {
        let sortedPaths = Array(Set(paths)).sorted()
        guard !sortedPaths.isEmpty else { return "" }

        var pathKinds: [String: String] = [:]
        var filePaths: [String] = []
        for path in sortedPaths {
            let fileURL = worktreePath.appendingPathComponent(path)
            let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
            if let fileType = attributes?[.type] as? FileAttributeType {
                switch fileType {
                case .typeSymbolicLink:
                    let destination = (try? FileManager.default.destinationOfSymbolicLink(atPath: fileURL.path)) ?? "unreadable"
                    pathKinds[path] = "symlink:\(destination)"
                case .typeDirectory:
                    pathKinds[path] = "directory"
                case .typeRegular:
                    filePaths.append(path)
                default:
                    pathKinds[path] = "special:\(fileType.rawValue)"
                }
                continue
            }

            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else {
                pathKinds[path] = "missing"
                continue
            }
            if isDirectory.boolValue {
                pathKinds[path] = "directory"
            } else {
                filePaths.append(path)
            }
        }

        let hashes = await hashObjects(paths: filePaths, worktreePath: worktreePath)
        return sortedPaths.map { path in
            let value = pathKinds[path] ?? hashes[path] ?? "hash-error"
            return "\(path)\u{0000}\(value)"
        }.joined(separator: "\u{0000}")
    }

    nonisolated private static func hashObjects(paths: [String], worktreePath: URL) async -> [String: String] {
        guard !paths.isEmpty else { return [:] }

        var hashes: [String: String] = [:]
        for startIndex in stride(from: 0, to: paths.count, by: hashObjectBatchSize) {
            let endIndex = min(startIndex + hashObjectBatchSize, paths.count)
            let batch = Array(paths[startIndex..<endIndex])
            if let result = try? await Process.git(["hash-object", "--"] + batch, cwd: worktreePath),
               result.exitCode == 0 {
                let batchHashes = result.stdout.split(whereSeparator: \.isNewline).map(String.init)
                if batchHashes.count == batch.count {
                    for (path, hash) in zip(batch, batchHashes) {
                        hashes[path] = hash
                    }
                    continue
                }
            }

            for path in batch {
                guard let result = try? await Process.git(["hash-object", "--", path], cwd: worktreePath),
                      result.exitCode == 0 else {
                    continue
                }
                hashes[path] = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return hashes
    }

    /// Stable fingerprint of the effective change list, including staged
    /// index contents, tracked/untracked file contents, and status metadata.
    /// Used to decide whether `changesGeneration` really changed.
    nonisolated static func changesFingerprint(
        changes: [ChangedFile],
        indexFingerprint: String,
        workingTreeContentFingerprint: String
    ) -> String {
        let base = ReviewChangesLoadKey.fingerprint(
            changes: changes,
            indexFingerprint: indexFingerprint,
            changesGeneration: 0
        )
        return "\(base)\u{0000}\(workingTreeContentFingerprint)"
    }

    nonisolated static func applyingStageMutations(
        _ mutations: [(paths: Set<String>, target: ChangeStage)],
        to changes: [ChangedFile]
    ) -> [ChangedFile] {
        mutations.reduce(changes) { projected, mutation in
            projected.map { file in
                guard mutation.paths.contains(file.path), file.stage != mutation.target else {
                    return file
                }
                return ChangedFile(
                    path: file.path,
                    status: file.status,
                    stage: mutation.target,
                    add: file.add,
                    del: file.del,
                    renameFrom: file.renameFrom,
                    conflict: file.conflict
                )
            }
        }
    }
}
