import AppKit
import Foundation
import Observation
import os

enum RightPaneTab: String { case changes, files }

@Observable
@MainActor
final class RightPaneState {
    let worktree: Worktree
    let reviewLoop: ReviewLoopState
    var changes: [ChangedFile] = []
    private(set) var hasLoadedSnapshot: Bool = false
    var displayChanges: [ChangedFile] {
        hasLoadedSnapshot ? changes : []
    }
    /// Increments whenever `refresh()` publishes a new change list. This
    /// catches same-line unstaged edits whose add/delete totals stay constant.
    private(set) var changesGeneration: Int = 0
    /// Increments whenever cached snapshot data is explicitly invalidated.
    /// In-flight refreshes capture this before doing async work and must not
    /// publish if it changed underneath them.
    private var snapshotInvalidationGeneration: Int = 0
    /// Fingerprint of the staged index contents (concatenated blob SHAs of
    /// staged files). Changes whenever any staged file's contents change,
    /// even when add/del totals are identical. Used by views that need to
    /// re-fire async work when the staged patch shifts under them.
    var indexFingerprint: String = ""
    /// Per-worktree in-progress merge / rebase / cherry-pick state.
    /// Refreshed alongside `changes` from `refresh()`.
    let mergeOp: MergeOperationState
    /// Most recent user-facing error from a sidebar-triggered operation
    /// (discard, copy-diff, ignore, conflict resolution, etc.). Cleared
    /// when the next sidebar op starts. Surfaces in `OperationCard` or as
    /// a future inline strip — for now, set this and rely on existing
    /// log output for diagnosability.
    var sidebarError: String? = nil
    var fileTree: [FileTreeNode] = []
    var loading: Bool = false
    var openPaths: Set<String> = []   // expanded directories in the tree
    var revealPath: String? = nil
    private(set) var revealTick: Int = 0
    private(set) var loadedFileTreeChildPaths: Set<String> = [""]
    private(set) var loadingFileTreeChildPaths: Set<String> = []
    private(set) var failedFileTreeChildPaths: Set<String> = []
    private(set) var fileTreeGeneration: Int = 0

    // New in right-sidebar-refactor:
    var activeTab: RightPaneTab = .changes
    var commits: [CommitInfo] = []
    var comparisonRef: String? = nil
    var workingTreeExpanded: Bool = true
    var commitsExpanded: Bool = true

    // Older-history paging — populated lazily by `loadOlder()`.
    // Cleared (and `hasMoreOlder` reset to true) on any `refresh()`
    // that re-fetches `commits`, because the divergence cursor may
    // have moved.
    var olderCommits: [CommitInfo] = []
    var hasMoreOlder: Bool = true
    var isLoadingOlder: Bool = false

    // Sync-nudge state. All fields are in-memory only; nothing is
    // persisted to AppConfig. Two independent conditions:
    //   - behindBase: HEAD is behind the trunk base (origin/main).
    //   - behindUpstream: HEAD is behind its own remote tracking branch
    //     (someone else pushed to it, or you pushed from elsewhere).
    var behindBase: GitService.BehindStatus? = nil
    var behindUpstream: GitService.BehindStatus? = nil

    /// Live branch name, refreshed on each `refresh()`. The `worktree.branch`
    /// snapshot captured at construction goes stale after a `git checkout`
    /// inside the same worktree, so the chip predicates read this instead.
    /// Empty when HEAD is detached or unborn.
    var currentBranch: String

    /// Live HEAD SHA, refreshed on each `refresh()`. Detects rebase, reset,
    /// amend, fast-forward, etc. so the behind chips update even when the
    /// branch name hasn't changed.
    var currentHeadSHA: String = ""

    /// `true` once `refresh()` has decided the initial `activeTab`. After
    /// that, the user's tab choice is sticky and refreshes leave it alone.
    private var didInitDefaultTab: Bool = false

    /// `var` so `RightPaneStore` can keep this in sync with
    /// `AppConfig.worktrees.baseBranch` when the user edits it in Settings,
    /// without throwing away the rest of the cached state.
    var baseBranch: String

    /// `true` once the user has explicitly picked a base branch via the
    /// selector. Prevents `RightPaneStore` from snapping the branch back to
    /// the global config default on the next render.
    var userOverrodeBaseBranch: Bool = false

    /// The last base branch value that came from `AppConfig` (not from the
    /// selector). Used by `RightPaneStore` to distinguish a Settings change
    /// (new config value) from a normal render (same config value).
    var lastConfigBaseBranch: String = ""

    /// Mirrors `AppConfig.changes.trackUpstreamForCommits`. Synced by
    /// `RightPaneStore` on every `state(for:)` call. When false (the
    /// default) — or when `userOverrodeBaseBranch` is true — `refresh()`
    /// passes `ignoreUpstream: true` to `commitsAhead`, so the Commits
    /// section compares HEAD against the base branch instead of `@{u}`.
    var trackUpstreamForCommits: Bool = false

    var pendingDiscard: PendingDiscard? = nil

    /// True while the workspace-level agent invocation is running.
    /// Surfaced in the Conflicts section header as a spinner; the
    /// resolve button flips into Cancel.
    var bulkResolveInFlight: Bool = false

    /// Last completed bulk-resolve outcome, or nil when none has run
    /// since this state was created (or since the user dismissed the
    /// banner). Cleared by `dismissBulkResolveReport`.
    var bulkResolveReport: BulkConflictResolveReport? = nil

    /// Task handle for the in-flight bulk resolve so the user can
    /// cancel the agent (SIGTERM via Process cancellation).
    @ObservationIgnored
    private var bulkResolveTask: Task<Void, Never>? = nil

    /// Injected by `RightPaneStore` after creation so `confirmDiscard` can
    /// close any open diff tabs whose path was just discarded. Nil in tests
    /// that construct `RightPaneState` directly.
    var closeDiffTabs: (([String]) -> Void)? = nil

    /// Injected by `RightPaneStore` to open the conflict resolution UI for a
    /// given file. In Plan 1, this routes to the existing unified DiffTabView.
    /// In Plan 2, it will route to the new 3-column merge editor.
    var openConflict: ((String) -> Void)? = nil

    /// In-memory ring buffer of recently selected base branches for this
    /// worktree. Max 3 entries; newest at the end. Not persisted.
    private(set) var recentBaseBranches: [String] = []

    /// Branches available in this worktree, populated on-demand by
    /// `fetchBranches()`. Used by the base-branch picker.
    private(set) var availableBranches: [String] = []
    private(set) var isFetchingBranches: Bool = false
    private(set) var hasFetchedBranches: Bool = false

    /// Upstream tracking ref of the current branch (e.g. `origin/main`),
    /// resolved during `refreshSyncStatus()`. Used by the base-branch
    /// picker to include the upstream in the smart shortlist.
    private(set) var upstreamRef: String? = nil

    private let git = GitService()
    private let watcher: WorktreeWatcher
    private let logger = Logger(subsystem: "io.nlopez.alas", category: "right-pane-state")

    @ObservationIgnored
    private var syncStatusTimer: Task<Void, Never>? = nil

    /// Refresh interval for `syncStatusTimer`. 5 minutes per design;
    /// constant in v1.
    @ObservationIgnored
    private let syncStatusInterval: UInt64 = 5 * 60 * 1_000_000_000 // ns

    /// True iff the "behind base" chip should be shown.
    var showBehindBaseChip: Bool {
        guard let s = behindBase else { return false }
        guard s.count > 0 else { return false }
        guard !currentBranch.isEmpty else { return false } // detached HEAD
        guard currentBranch != baseBranch else { return false }
        return true
    }

    /// True iff the "behind upstream" chip should be shown. Independent of
    /// `showBehindBaseChip` — both can be true simultaneously.
    var showBehindUpstreamChip: Bool {
        guard let s = behindUpstream else { return false }
        guard s.count > 0 else { return false }
        guard !currentBranch.isEmpty else { return false } // detached HEAD
        return true
    }

    init(worktree: Worktree, baseBranch: String) {
        self.worktree = worktree
        self.baseBranch = baseBranch
        self.currentBranch = worktree.branch
        self.reviewLoop = ReviewLoopState(worktreePath: worktree.path, baseBranch: baseBranch)
        self.mergeOp = MergeOperationState(worktreePath: worktree.path, gitService: GitService())
        self.watcher = WorktreeWatcher(path: worktree.path)
        watcher.onChange = { [weak self] in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func start() {
        watcher.start()
        Task { @MainActor in await self.refresh() }
        Task { @MainActor in await self.refreshSyncStatus() }
        syncStatusTimer?.cancel()
        syncStatusTimer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: self?.syncStatusInterval ?? 0)
                } catch {
                    return // cancelled
                }
                guard let self else { return }
                await self.refreshSyncStatus()
            }
        }
    }

    func stop() {
        watcher.stop()
        syncStatusTimer?.cancel()
        syncStatusTimer = nil
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
        switch action {
        case .refresh:
            Task { @MainActor in await refresh() }
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
        case .pushBranch, .forcePushBranch:
            guard let snapshot = reviewLoop.snapshot else { return }
            Task { @MainActor in
                do {
                    let result = try await Process.git(
                        Self.reviewLoopPushArguments(
                            snapshot: snapshot,
                            forceWithLease: action == .forcePushBranch
                        ),
                        cwd: worktree.path
                    )
                    guard result.exitCode == 0 else {
                        sidebarError = Self.reviewLoopPushFailureMessage(result)
                        return
                    }
                    await refresh()
                } catch {
                    sidebarError = error.localizedDescription
                }
            }
        case .createReviewRequest:
            guard let snapshot = reviewLoop.snapshot else { return }
            appState.tabs.openOrFocusDraftReviewRequest(worktreeId: worktree.id, snapshot: snapshot)
        case .rerunFailedChecks:
            guard let snapshot = reviewLoop.snapshot else { return }
            Task { @MainActor in
                if await reviewLoop.rerunFailedChecks(snapshot: snapshot) {
                    await refresh()
                }
            }
        case .merge:
            break
        }
    }

    func canOpenReviewLoopHandoff(appState: AppState) -> Bool {
        guard let request = reviewLoop.snapshot?.reviewRequest else { return false }
        guard request.worstCheckBucket == .fail || request.hasActionableFeedback else { return false }
        let agentID = appState.config.changes.aiToolId
        return agentID != "none" && appState.agent(id: agentID) != nil
    }

    func openReviewLoopProviderPage() {
        guard let url = reviewLoop.snapshot?.reviewRequest?.url else { return }
        NSWorkspace.shared.open(url)
    }

    nonisolated static func reviewLoopPushArguments(
        snapshot: ReviewLoopSnapshot,
        forceWithLease: Bool
    ) -> [String] {
        var args = ["push"]
        if forceWithLease {
            args.append("--force-with-lease")
        }
        let remoteName = snapshot.local.upstreamRemoteName
            ?? snapshot.local.headRemoteName
            ?? snapshot.remote?.remoteName
            ?? "origin"
        let pushRef = snapshot.local.upstreamBranchName.map { "HEAD:\($0)" } ?? snapshot.local.branchName
        args.append(contentsOf: ["-u", remoteName, pushRef])
        return args
    }

    nonisolated static func reviewLoopPushFailureMessage(_ result: ProcessResult) -> String {
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty { return stderr }
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stdout.isEmpty { return stdout }
        return "git push failed with exit code \(result.exitCode)."
    }

    nonisolated static func reviewLoopAheadCommitCount(
        displayCommits: [CommitInfo],
        baseCommits: [CommitInfo]?
    ) -> Int {
        baseCommits?.count ?? displayCommits.count
    }

    @MainActor
    func refresh() async {
        let reviewLoopInspection = reviewLoop.beginLocalInspection()
        let snapshotGeneration = snapshotInvalidationGeneration
        loading = true
        defer { loading = false }
        invalidateFileTreeChildLoadsForRefresh()
        do {
            // Any refresh re-anchors the older-history cursor; drop the
            // accumulated pages so we don't accidentally splice an old
            // page onto a new HEAD.
            self.olderCommits = []
            self.hasMoreOlder = true
            self.isLoadingOlder = false
            let ignoreUpstream = userOverrodeBaseBranch || !trackUpstreamForCommits
            async let s = git.status(worktreePath: worktree.path)
            async let c = git.commitsAhead(
                at: worktree.path,
                baseBranch: baseBranch,
                ignoreUpstream: ignoreUpstream
            )
            async let reviewLoopBase = git.commitsAhead(
                at: worktree.path,
                baseBranch: baseBranch,
                ignoreUpstream: true
            )
            async let br = git.currentBranch(worktreePath: worktree.path)
            async let upstream = git.resolveUpstreamRef(worktreePath: worktree.path)
            async let mergeRefresh: Void = mergeOp.refresh()
            let entries = try await s
            let tree = try await git.fileTree(worktreePath: worktree.path, statusEntries: entries)
            let (commits, ref) = try await c
            let reviewLoopBaseResult = try? await reviewLoopBase
            let resolvedUpstream = try? await upstream
            _ = await mergeRefresh
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
            let previousBranch = self.currentBranch
            let previousHeadSHA = self.currentHeadSHA
            let currentBranch = (try? await br) ?? self.currentBranch
            let headSHA = (try? await self.git.revParseHEAD(worktreePath: self.worktree.path)) ?? ""
            guard snapshotGeneration == snapshotInvalidationGeneration else {
                return
            }
            self.upstreamRef = resolvedUpstream?.ref
            self.changes = entries
            self.changesGeneration += 1
            self.indexFingerprint = indexFingerprint
            self.fileTree = tree
            self.commits = commits
            self.comparisonRef = ref
            self.currentBranch = currentBranch
            self.currentHeadSHA = headSHA
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
                if entries.isEmpty && commits.isEmpty && !tree.isEmpty {
                    activeTab = .files
                }
                didInitDefaultTab = true
            }
            self.hasLoadedSnapshot = true
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
                upstreamBranchName: upstreamBranchName
            )
        } catch {
            reviewLoop.failLocalRefresh(reviewLoopInspection, error: error)
            guard snapshotGeneration == snapshotInvalidationGeneration else {
                return
            }
            sidebarError = error.localizedDescription
            hasLoadedSnapshot = true
            changesGeneration += 1
            // Surface failures via os.Logger so they're visible in Console.app
            // and the unified log. The previous `print` here silently kept
            // `self.changes` at its last successful value, which presented as
            // an empty Changes pane when the very first refresh failed.
            logger.error("refresh failed for worktree \(self.worktree.path.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func markSnapshotUnknown() {
        snapshotInvalidationGeneration += 1
        hasLoadedSnapshot = false
        changes = []
        indexFingerprint = ""
        fileTree = []
        commits = []
        olderCommits = []
        comparisonRef = nil
        sidebarError = nil
        pendingDiscard = nil
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
        upstreamBranchName: String?
    ) async {
        async let needsPushProbe = git.needsPush(worktreePath: worktree.path)
        async let upstreamAheadProbe = git.upstreamAheadCommitCount(worktreePath: worktree.path)
        let needsPush = (try? await needsPushProbe) ?? true
        let upstreamAheadCommitCount = (try? await upstreamAheadProbe) ?? 0
        let local = ReviewLoopLocalState(
            branchName: currentBranch,
            headSHA: headSHA,
            baseBranch: baseBranch,
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
        do {
            let remotes = try await git.remotes(worktreePath: worktree.path)
            await reviewLoop.refresh(attempt, remotes: remotes)
        } catch {
            reviewLoop.failLocalRefresh(attempt, error: error)
            logger.error("review loop refresh failed for worktree \(self.worktree.path.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func invalidateFileTreeChildLoadsForRefresh() {
        fileTreeGeneration += 1
        loadedFileTreeChildPaths = [""]
        loadingFileTreeChildPaths = []
        failedFileTreeChildPaths = []
        fileTree = Self.resetLoadingFileTreeChildren(in: fileTree)
    }

    func toggleStage(_ file: ChangedFile) {
        sidebarError = nil
        Task { @MainActor in
            do {
                if file.stage == .staged {
                    // For a staged rename, include the original path so both
                    // sides of the rename are restored to the working tree;
                    // otherwise the deletion of the old path remains staged.
                    try await git.unstage(worktreePath: worktree.path, files: Self.unstagePaths(for: file))
                } else {
                    try await git.stage(worktreePath: worktree.path, files: [file.path])
                }
            } catch {
                self.sidebarError = (error as NSError).localizedDescription
            }
            await self.refresh()
        }
    }

    static func unstagePaths(for file: ChangedFile) -> [String] {
        if file.status == "R", let from = file.renameFrom, !from.isEmpty {
            return [file.path, from]
        }
        return [file.path]
    }

    nonisolated static func mergingChildren(
        in nodes: [FileTreeNode],
        for path: String,
        with children: [FileTreeNode],
        state: DirectoryChildrenState
    ) -> (nodes: [FileTreeNode], didMerge: Bool) {
        var didMerge = false
        let updatedNodes = nodes.map { node in
            if node.path == path {
                didMerge = true
                var updated = node
                var merged: [String: FileTreeNode] = [:]
                for child in node.children ?? [] {
                    merged[child.id] = child
                }
                for child in children {
                    if let existing = merged[child.id] {
                        var refreshed = existing
                        refreshed.badge = child.badge ?? existing.badge
                        refreshed.visibility = mergedVisibility(existing: existing.visibility, incoming: child.visibility)
                        refreshed.isSubmodule = child.isSubmodule || existing.isSubmodule
                        refreshed.childrenState = mergedChildrenState(existing: existing.childrenState, incoming: child.childrenState)
                        if refreshed.children == nil {
                            refreshed.children = child.children
                        }
                        merged[child.id] = refreshed
                    } else {
                        merged[child.id] = child
                    }
                }
                updated.children = merged.values.sorted { lhs, rhs in
                    if lhs.kind != rhs.kind { return lhs.kind == .dir }
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
                updated.childrenState = state
                return updated
            }
            guard let existing = node.children else { return node }
            var updated = node
            let result = mergingChildren(in: existing, for: path, with: children, state: state)
            didMerge = didMerge || result.didMerge
            updated.children = result.nodes
            return updated
        }
        return (updatedNodes, didMerge)
    }

    nonisolated private static func mergedVisibility(
        existing: FileVisibility,
        incoming: FileVisibility
    ) -> FileVisibility {
        if incoming == .tracked, existing != .tracked {
            return existing
        }
        return incoming
    }

    nonisolated private static func mergedChildrenState(
        existing: DirectoryChildrenState,
        incoming: DirectoryChildrenState
    ) -> DirectoryChildrenState {
        if incoming == .notLoaded, existing != .notLoaded {
            return existing
        }
        return incoming
    }

    nonisolated static func resetLoadingFileTreeChildren(in nodes: [FileTreeNode]) -> [FileTreeNode] {
        nodes.map { node in
            var updated = node
            if let children = node.children {
                updated.children = resetLoadingFileTreeChildren(in: children)
            }
            if node.kind == .dir, node.childrenState == .loading {
                updated.children = nil
                updated.childrenState = .notLoaded
            }
            return updated
        }
    }

    nonisolated static func shouldAutoLoadFileTreeChildren(
        path: String,
        childrenState: DirectoryChildrenState,
        loadedPaths: Set<String>,
        loadingPaths: Set<String>,
        failedPaths: Set<String>
    ) -> Bool {
        guard !loadedPaths.contains(path),
              !loadingPaths.contains(path),
              !failedPaths.contains(path) else { return false }
        return childrenState == .notLoaded || childrenState == .loaded
    }

    func shouldAutoLoadFileTreeChildren(path: String, childrenState: DirectoryChildrenState) -> Bool {
        Self.shouldAutoLoadFileTreeChildren(
            path: path,
            childrenState: childrenState,
            loadedPaths: loadedFileTreeChildPaths,
            loadingPaths: loadingFileTreeChildPaths,
            failedPaths: failedFileTreeChildPaths
        )
    }

    func loadFileTreeChildren(path: String) {
        guard !loadedFileTreeChildPaths.contains(path),
              !loadingFileTreeChildPaths.contains(path) else { return }
        loadingFileTreeChildPaths.insert(path)
        let loadingMerge = Self.mergingChildren(in: fileTree, for: path, with: [], state: .loading)
        guard loadingMerge.didMerge else {
            loadingFileTreeChildPaths.remove(path)
            return
        }
        fileTree = loadingMerge.nodes
        let generation = fileTreeGeneration
        Task { @MainActor in
            defer {
                if self.fileTreeGeneration == generation {
                    self.loadingFileTreeChildPaths.remove(path)
                }
            }
            do {
                let children = try await git.fileTreeChildren(worktreePath: worktree.path, path: path)
                guard self.fileTreeGeneration == generation else { return }
                let result = Self.mergingChildren(in: self.fileTree, for: path, with: children, state: .loaded)
                guard result.didMerge else { return }
                self.loadedFileTreeChildPaths.insert(path)
                self.failedFileTreeChildPaths.remove(path)
                self.fileTree = result.nodes
            } catch {
                guard self.fileTreeGeneration == generation else { return }
                let result = Self.mergingChildren(in: self.fileTree, for: path, with: [], state: .failed)
                guard result.didMerge else { return }
                self.failedFileTreeChildPaths.insert(path)
                self.fileTree = result.nodes
                logger.error("file tree child load failed for \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func reveal(path: String) {
        activeTab = .files
        let pathComponents = path.split(separator: "/").map(String.init)
        for i in 0..<(pathComponents.count - 1) {
            let ancestor = pathComponents[0...i].joined(separator: "/")
            openPaths.insert(ancestor)
            if !loadedFileTreeChildPaths.contains(ancestor) {
                loadFileTreeChildren(path: ancestor)
            }
        }
        revealPath = path
        revealTick += 1
    }

    func clearReveal() {
        revealPath = nil
    }

    /// Paths to discard for the given file path. Expands staged renames into
    /// both new and original paths so the deletion of the old side is also
    /// restored. Returns `[]` if the path is not in `changes` (stale request).
    static func discardPaths(forFileAt path: String, in changes: [ChangedFile]) -> [String] {
        guard let file = changes.first(where: { $0.path == path }) else { return [] }
        return unstagePaths(for: file)
    }

    /// Paths to discard for every change under a folder (recursive). Folders
    /// in the Changes tree are virtual — built from changed paths only — so
    /// a prefix match against `"<folder>/"` is exhaustive. Staged renames
    /// under the folder include their original path even if the origin lives
    /// outside the folder (rare but possible after a refactor).
    static func discardPaths(forFolderAt folder: String, in changes: [ChangedFile]) -> [String] {
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        let matching = changes.filter { $0.path.hasPrefix(prefix) }
        return matching.flatMap(unstagePaths(for:))
    }

    /// Every changed path in the worktree (staged + unstaged + untracked),
    /// with staged renames expanded.
    static func discardPaths(forAllIn changes: [ChangedFile]) -> [String] {
        // Deduplicate while preserving first-seen order.
        var seen = Set<String>()
        var out: [String] = []
        for file in changes {
            for p in unstagePaths(for: file) where seen.insert(p).inserted {
                out.append(p)
            }
        }
        return out
    }

    func stageAll(_ files: [ChangedFile]) {
        let paths = files.map(\.path)
        sidebarError = nil
        Task { @MainActor in
            do { try await git.stageAll(worktreePath: worktree.path, files: paths) }
            catch { self.sidebarError = (error as NSError).localizedDescription }
            await self.refresh()
        }
    }

    func unstageAll(_ files: [ChangedFile]) {
        let paths = files.flatMap(Self.unstagePaths(for:))
        sidebarError = nil
        Task { @MainActor in
            do { try await git.unstageAll(worktreePath: worktree.path, files: paths) }
            catch { self.sidebarError = (error as NSError).localizedDescription }
            await self.refresh()
        }
    }

    func requestDiscardFile(path: String) {
        let paths = Self.discardPaths(forFileAt: path, in: changes)
        guard !paths.isEmpty else { return }
        pendingDiscard = PendingDiscard(target: .file(path: path), paths: paths)
    }

    func requestDiscardFolder(path: String) {
        let paths = Self.discardPaths(forFolderAt: path, in: changes)
        // Folder count = distinct ChangedFile entries under the prefix, not
        // path count (a staged rename contributes two paths but one file).
        let prefix = path.hasSuffix("/") ? path : path + "/"
        let fileCount = changes.filter { $0.path.hasPrefix(prefix) }.count
        guard fileCount > 0 else { return }
        pendingDiscard = PendingDiscard(
            target: .folder(path: path, fileCount: fileCount),
            paths: paths
        )
    }

    func requestDiscardAll() {
        let paths = Self.discardPaths(forAllIn: changes)
        guard !changes.isEmpty else { return }
        pendingDiscard = PendingDiscard(
            target: .all(fileCount: changes.count),
            paths: paths
        )
    }

    func cancelDiscard() {
        pendingDiscard = nil
    }

    @MainActor
    func confirmDiscard() async {
        guard let pending = pendingDiscard else { return }
        pendingDiscard = nil
        await runDiscard(pending)
    }

    /// Run a previously-snapshotted discard. Used by view-layer callers that
    /// need to capture and clear `pendingDiscard` synchronously in the alert
    /// button action — the alert's `isPresented` binding fires its `set`
    /// closure synchronously on dismissal, which would clear `pendingDiscard`
    /// before the async `confirmDiscard()` could read it.
    @MainActor
    func confirmDiscard(_ pending: PendingDiscard) async {
        // Defensive: if the caller didn't clear `pendingDiscard`, do it now.
        if pendingDiscard == pending { pendingDiscard = nil }
        await runDiscard(pending)
    }

    @MainActor
    private func runDiscard(_ pending: PendingDiscard) async {
        let paths = pending.paths
        sidebarError = nil
        do {
            try await git.discardPaths(worktreePath: worktree.path, files: paths)
        } catch {
            sidebarError = (error as NSError).localizedDescription
            return
        }
        await refresh()
        let remainingChangedPaths = Set(changes.flatMap(Self.unstagePaths(for:)))
        let cleanPaths = paths.filter { !remainingChangedPaths.contains($0) }
        if !cleanPaths.isEmpty {
            closeDiffTabs?(cleanPaths)
        }
    }

    /// Run `git diff HEAD -- <file>` (or `--cached` on unborn HEAD, or
    /// `/dev/null` for untracked) and put the unified-diff output on the
    /// general pasteboard. `renameFrom` is the staged-rename origin path
    /// (from `ChangedFile.renameFrom`); when present it's included in the
    /// pathspec so `git diff` emits the rename-from/rename-to header
    /// instead of an add-only patch. Best-effort: errors are surfaced via
    /// `sidebarError`. Single source of truth so the context menu and
    /// any future "Copy Diff" affordances agree.
    func copyDiff(for path: String, renameFrom: String? = nil) {
        let wt = worktree.path
        Task { @MainActor in
            do {
                // A staged deletion is *not* in the index (`ls-files` returns
                // non-zero) but IS in HEAD — falling back to `--no-index` for
                // that case yields an empty patch. Probe HEAD via `cat-file`
                // so staged D entries still route through HEAD-based diff.
                let inIndex = (try? await Process.git(
                    ["ls-files", "--error-unmatch", "--", path],
                    cwd: wt
                ))?.exitCode == 0
                let head = (try? await self.git.hasHead(worktreePath: wt)) ?? true
                let inHead: Bool
                if head {
                    inHead = (try? await Process.git(
                        ["cat-file", "-e", "HEAD:\(path)"],
                        cwd: wt
                    ))?.exitCode == 0
                } else {
                    inHead = false
                }
                // For staged renames, `git diff HEAD -- <new>` strips the
                // rename header (emits an add-only patch). Pass both paths
                // in the pathspec so the rename-from/rename-to header is
                // preserved. Only relevant when we're using a HEAD-based
                // diff; the rename concept doesn't apply to untracked or
                // unborn-HEAD cases.
                let extraPath: String? = (renameFrom?.isEmpty == false) ? renameFrom : nil
                let args: [String]
                if head, inIndex || inHead {
                    var a = ["diff", "--no-color", "HEAD", "--", path]
                    if let extraPath { a.append(extraPath) }
                    args = a
                } else if !head, inIndex {
                    // Unborn HEAD: staged-add — diff index vs empty tree.
                    args = ["diff", "--no-color", "--cached", "--", path]
                } else {
                    args = ["diff", "--no-color", "--no-index", "--", "/dev/null", path]
                }
                let result = try await Process.git(args, cwd: wt)
                // `--no-index` exits 1 when there ARE differences (the expected
                // case for an untracked file).
                if result.exitCode > 1 {
                    self.sidebarError = result.stderr
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return
                }
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(result.stdout, forType: .string)
            } catch {
                self.sidebarError = (error as NSError).localizedDescription
            }
        }
    }

    /// Append a gitignore pattern for `path` to `destination` and refresh
    /// the changes list. Idempotent at the service level — calling this for
    /// a pattern that already exists in the destination is a no-op.
    ///
    /// For `.infoExclude`, resolves the actual `info/exclude` path via
    /// `git rev-parse --git-path` so linked worktrees write to the
    /// per-worktree git dir (where `.git` is a gitfile, not a directory).
    func ignore(path: String, isDirectory: Bool, destination: IgnoreDestination) {
        let repoURL = worktree.path
        Task { @MainActor in
            do {
                let infoExcludeURL: URL?
                if destination == .infoExclude {
                    infoExcludeURL = try await resolveInfoExcludeURL(worktreePath: repoURL)
                } else {
                    infoExcludeURL = nil
                }
                _ = try GitIgnoreService.appendIgnore(
                    entryPath: path,
                    isDirectory: isDirectory,
                    destination: destination,
                    repoURL: repoURL,
                    infoExcludeURL: infoExcludeURL
                )
            } catch {
                logger.error("ignore failed for \(path, privacy: .public) in worktree \(self.worktree.path.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            await self.refresh()
        }
    }

    /// Resolve the absolute URL of `info/exclude` for this worktree via
    /// `git rev-parse --git-path info/exclude`. Output is relative to the
    /// worktree path unless git emits an absolute path.
    private func resolveInfoExcludeURL(worktreePath: URL) async throws -> URL {
        let result = try await Process.git(
            ["rev-parse", "--git-path", "info/exclude"],
            cwd: worktreePath
        )
        let raw = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("/") {
            return URL(fileURLWithPath: raw)
        }
        return URL(fileURLWithPath: raw, relativeTo: worktreePath).standardizedFileURL
    }

    /// Probes the worktree's "behind" status against the trunk base AND
    /// against the branch's own upstream tracking ref (when one exists).
    /// Fetches each resolvable remote ref when the last probe was older
    /// than 30s. Errors are logged but never surfaced; chips reflect the
    /// last successful probe (or stay hidden if none has succeeded yet).
    @MainActor
    func refreshSyncStatus() async {
        await refreshBehindBase()
        await refreshBehindUpstream()
    }

    @MainActor
    private func refreshBehindBase() async {
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
                let last = behindBase?.probedAt ?? .distantPast
                if Date().timeIntervalSince(last) > 30 {
                    do {
                        try await git.fetchRef(
                            worktreePath: worktree.path,
                            remote: remote,
                            branch: resolved.fetchBranch ?? baseBranch
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
    private func refreshBehindUpstream() async {
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
            let last = behindUpstream?.probedAt ?? .distantPast
            if Date().timeIntervalSince(last) > 30 {
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
        guard !isLoadingOlder, hasMoreOlder else { return }
        let cursor: String
        if let last = olderCommits.last {
            cursor = last.sha
        } else if let last = commits.last {
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
                || (olderCommits.isEmpty && commits.last?.sha == cursor)
                || (olderCommits.isEmpty && commits.isEmpty && cursor == "HEAD")
            guard cursorStillValid else { return }
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

    // MARK: - Merge / rebase / cherry-pick operations

    /// Runs `git merge <branch>`, refreshes state, and auto-opens the first
    /// conflicted file (via `openConflict`) when the result is a conflict.
    @MainActor
    func runMerge(branch: String) {
        Task { @MainActor in
            do {
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
        Task { @MainActor in
            do {
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
        Task { @MainActor in
            do {
                let result = try await git.cherryPick(worktreePath: worktree.path, sha: sha)
                await refresh()
                handleOperationResult(result)
            } catch {
                logger.error("cherry-pick failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    @MainActor
    func continueOperation() {
        Task { @MainActor in
            guard let op = mergeOp.current else { return }
            do {
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
        Task { @MainActor in
            guard let op = mergeOp.current else { return }
            do {
                try await git.abortOperation(worktreePath: worktree.path, op: op)
                await refresh()
            } catch {
                logger.error("abort failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    @MainActor
    func skipOperation() {
        Task { @MainActor in
            guard let op = mergeOp.current else { return }
            do {
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
        Task { @MainActor in
            do {
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
    func resolveAllConflicts(using agent: AgentDefinition, prompt: String) {
        guard bulkResolveTask == nil else { return }
        guard changes.contains(where: { $0.conflict != nil }) else { return }
        bulkResolveReport = nil
        bulkResolveInFlight = true
        bulkResolveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var report: BulkConflictResolveReport
            do {
                let agentOutput = try await MergeAgent.resolveAllInWorkspace(
                    agent: agent,
                    prompt: prompt,
                    worktreePath: self.worktree.path
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
            self.bulkResolveReport = report
            self.bulkResolveTask = nil
        }
    }

    /// Cancels an in-flight bulk resolve by tearing down the agent
    /// process via Task cancellation (AgentRunner forwards as SIGTERM).
    @MainActor
    func cancelBulkResolve() {
        bulkResolveTask?.cancel()
    }

    /// Clears the post-run banner so it doesn't linger after the user
    /// has acknowledged the outcome.
    @MainActor
    func dismissBulkResolveReport() {
        bulkResolveReport = nil
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
