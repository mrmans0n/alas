import AppKit
import Foundation
import Observation
import os

enum RightPaneTab: String { case changes, files }

enum GGStackLoadState: Equatable {
    case inactive
    case loading
    case empty
    case loaded
    case failed(String)

    var hasLoadedCommit: Bool { self == .loaded }
}

struct ReviewLoopRemoteFingerprint: Equatable, Sendable {
    var branchName: String
    var headSHA: String
    var baseBranch: String
    var hasWorkingTreeChanges: Bool
    var hasStagedChanges: Bool
    var aheadCommitCount: Int
    var hasUpstream: Bool
    var upstreamRemoteName: String?
    var upstreamBranchName: String?
    var upstreamAheadCommitCount: Int
    var needsPush: Bool
    var remotes: [String]
}

private struct SyncFetchTarget: Hashable {
    let remote: String
    let branch: String
}

private struct PendingStageMutation: Identifiable {
    let id = UUID()
    let paths: Set<String>
    let gitPaths: [String]
    let target: ChangeStage
    var hasAppliedGitMutation = false
    var minimumRefreshGeneration = 0
}

@Observable
@MainActor
final class RightPaneState: GGSplitCommitServicing {
    nonisolated static let remoteUntrackedContentFingerprintCommand = "git ls-files --others --exclude-standard -z | xargs -0 sh -c '[ \"$#\" -gt 0 ] || exit 0; git hash-object -- \"$@\"' sh 2>/dev/null"

    let worktree: Worktree
    let reviewLoop: ReviewLoopState
    @ObservationIgnored
    var reviewSnapshotDidChange: ((ReviewLoopSnapshot) -> Void)?
    var changes: [ChangedFile] = []
    var stashes: [GitStash] = []
    var stashesExpanded: Bool = false
    var expandedStashRefs: Set<String> = []
    var stashFilesByRef: [String: [GitStashFile]] = [:]
    var loadingStashRefs: Set<String> = []
    var pendingStashChanges: Bool = false
    var pendingStashDrop: PendingStashDrop? = nil
    private(set) var stashOperationInFlight: Bool = false
    private(set) var hasLoadedSnapshot: Bool = false
    var displayChanges: [ChangedFile] {
        guard hasLoadedSnapshot else { return [] }
        return Self.applyingStageMutations(
            pendingStageMutations.map { (paths: $0.paths, target: $0.target) },
            to: changes
        )
    }
    private var pendingStageMutations: [PendingStageMutation] = []
    /// Increments whenever `refresh()` publishes a new change list. This
    /// catches same-line unstaged edits whose add/delete totals stay constant.
    /// It is now guarded by an effective-change fingerprint so no-op
    /// watcher-driven refreshes do not re-fire downstream loaders.
    private(set) var changesGeneration: Int = 0
    @ObservationIgnored
    private var lastChangesFingerprint: String = ""
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
    /// True while a `pull()` is running; drives the upstream chip's spinner
    /// and disables re-entry. Only `pull()` mutates it.
    private(set) var pullInFlight: Bool = false
    private var fetchInFlight: Bool = false
    private var lastSyncFetchAtByTarget: [SyncFetchTarget: Date] = [:]
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
    @ObservationIgnored private var commitDisplayGeneration: UInt = 0

    /// Current gg stack for this worktree's branch; nil when inactive or when
    /// gg reports that the active context has no stack metadata.
    var ggStack: GGStack? = nil
    var ggStackDisplayCommits: [CommitInfo] = []
    var commitsForDisplay: [CommitInfo] {
        ggStackLoadState == .loaded ? ggStackDisplayCommits : commits
    }
    var ggEffectiveConfig: GGEffectiveConfig = .defaults
    var ggContext: GGWorktreeContext = .inactive(reason: .policyOff)
    var ggStackLoadState: GGStackLoadState = .inactive
    /// Injected by RightPaneStore to resolve the current live branch against
    /// app-, project-, and worktree-level GG policy.
    var ggContextProvider: (@MainActor (_ branch: String) -> GGWorktreeContext)? = nil
    /// Injected by RightPaneStore so mutations that add or remove worktrees
    /// can reconcile app-level project topology.
    @ObservationIgnored
    var refreshProjectTopologyAfterGGMutation: (@MainActor () async -> Void)? = nil
    @ObservationIgnored
    var selectWorktreeAtPathAfterGGMutation: (@MainActor (String) async -> Void)? = nil
    var ggService = GGService() {
        didSet {
            ggMutationCoordinatorStorage = nil
            didAttemptGGUndoRestore = false
        }
    }
    @ObservationIgnored
    private var ggMutationCoordinatorStorage: GGMutationCoordinator? = nil
    @ObservationIgnored private var didAttemptGGUndoRestore = false
    /// Backing store for the stack drawer's mutation UI (in-flight action,
    /// sync progress, paused/error state). Not snapshot-derived, so
    /// `markSnapshotUnknown()` does not reset it.
    let ggActionState = GGStackActionState()
    /// Commits ahead of base used for the gg stack-shape check and cache
    /// key — deliberately NOT the display `commits` list. `commits` follows
    /// the user's chosen comparison mode, and under "Branch upstream" it is
    /// `@{u}..HEAD`: once a stack is fully pushed (`gg sync` already ran),
    /// that list is empty even though the branch still carries GG-ID
    /// commits relative to its stack base. This tracks the review-loop's
    /// base-relative commit set instead (`GitService.BaseResolution
    /// .forReviewLoopBase`, computed in `performRefresh`), which never
    /// resolves to upstream and so always reflects true stack membership.
    @ObservationIgnored var ggStackSourceCommits: [CommitInfo] = []
    @ObservationIgnored
    var ggStackCommitLoader: @MainActor (URL, [String]) async throws -> [String: CommitInfo] = {
        worktree, shas in
        try await GitService().stackCommitInfos(at: worktree, shas: shas)
    }
    /// SHA-set key of the last commits list gg was queried for. `gg ls
    /// --json` hits the forge API (best-effort PR-state refresh), and
    /// performRefresh fires continuously from the file watcher — so only
    /// re-query gg when the commit set actually changed.
    // Exposed (not `private`) so tests can seed/inspect it via `@testable
    // import` without a real git repo driving `refresh()`. Bookkeeping only,
    // never read by a view — kept out of observation to avoid invalidation
    // churn on the hot refresh path.
    var ggStackCommitsKey: String? = nil
    /// Off-critical-path gg stack load. Cancelled+restarted per refresh so a
    /// slow `gg ls --json` never blocks the Changes-pane snapshot.
    @ObservationIgnored private var ggStackRefreshTask: Task<Void, Never>? = nil
    /// A refresh result may still arrive after its task was cancelled. Only
    /// the most recently started GG refresh may publish snapshot-derived
    /// stack state.
    @ObservationIgnored private var ggStackRefreshGeneration: UInt = 0

    var currentGGStackCommitsKey: String {
        let contextIdentity: String
        switch ggContext {
        case .active(let stackName):
            contextIdentity = "active:\(stackName)"
        case .inactive:
            contextIdentity = "inactive"
        }
        return "\(currentBranch)|\(contextIdentity)|"
            + ggStackSourceCommits.map(\.sha).joined(separator: "|")
    }

    var ggCommitSelectionIsStale: Bool {
        ggStack != nil && ggStackCommitsKey != currentGGStackCommitsKey
    }

    // Sync-nudge state. All fields are in-memory only; nothing is
    // persisted to AppConfig. Two independent conditions:
    //   - behindBase: HEAD is behind the trunk base (origin/main).
    //   - behindUpstream: HEAD is behind its own remote tracking branch
    //     (someone else pushed to it, or you pushed from elsewhere).
    var behindBase: GitService.BehindStatus? = nil
    var behindUpstream: GitService.BehindStatus? = nil

    /// Hosted remote used for commit browser links in the Commits section.
    /// Nil when the worktree has no recognized GitHub/GitLab fetch remote.
    var commitRemote: CodeHostRemote? = nil
    /// Hosted remote used for primary/ahead commit rows. This follows the
    /// current branch's upstream remote, not the comparison/base remote.
    var primaryCommitRemote: CodeHostRemote? = nil
    /// True until the current branch is known to have no commits ahead of its
    /// upstream. Used to avoid remote links for local-only primary commit rows.
    var commitsNeedPush: Bool = true

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

    /// The last raw base branch value that came from `AppConfig` (not from the
    /// selector, and not the effective `origin/<base>` default). Used by
    /// `RightPaneStore` to distinguish a Settings change (new config value)
    /// from a normal render (same config value).
    var lastConfigBaseBranch: String = ""

    /// The last effective base branch default applied by `RightPaneStore`
    /// (e.g. `origin/main` when on the base branch). Used to detect when the
    /// effective default changed because the worktree branch changed, without
    /// overwriting a verified fallback on every render.
    var lastEffectiveBaseBranch: String = ""

    /// Task handle for the async origin-ref probe, if one is in flight.
    /// Cancelled when the base branch changes again before verification
    /// finishes, so stale probe results never overwrite a newer default.
    @ObservationIgnored
    var baseBranchProbeTask: Task<Void, Never>? = nil

    /// True for newly-created states whose initial `start()` is being deferred
    /// until the `origin/<base>` probe confirms or falls back. Prevents
    /// activation from starting an unverified refresh.
    @ObservationIgnored
    var isAwaitingBaseBranchProbe: Bool = false

    /// Mirrors `AppConfig.changes.comparisonMode`. Synced by `RightPaneStore`
    /// on every `state(for:)` call. Combined with `userOverrodeBaseBranch`, it
    /// selects the `BaseResolution` `refresh()` passes to `commitsAhead`.
    var comparisonMode: AppConfig.Changes.ChangesComparisonMode = .auto

    var pendingDiscard: PendingDiscard? = nil
    var pendingCherryPickSHA: String? = nil
    var pendingMerge: ReviewLoopSnapshot? = nil
    var mergeError: String? = nil
    var mergeQueuedMessage: String? = nil
    var pendingGGLand: GGLandRequest? = nil
    @ObservationIgnored private var pendingGGLandPrepared: GGPreparedMutation? = nil
    var pendingGGDrop: GGDropPresentation? = nil
    @ObservationIgnored private var pendingGGDropPrepared: GGPreparedMutation? = nil
    var pendingGGUnstack: GGUnstackModel? = nil
    @ObservationIgnored var pendingGGUnstackPrepared: GGPreparedMutation? = nil
    var pendingGGCleanAll: Bool = false
    @ObservationIgnored private var pendingGGCleanPrepared: GGPreparedMutation? = nil
    var pendingGGReorder: GGReorderPresentation? = nil
    var pendingGGRestack: GGRestackPresentation? = nil

    var ggLocalChangeStatistics: GGLocalChangeStatistics {
        GGLocalChangeStatistics(
            staged: changes.filter { $0.stage == .staged }.count,
            unstaged: changes.filter { $0.stage == .unstaged }.count
        )
    }

    var ggUndoCandidate: GGUndoCandidate? {
        ggMutationCoordinator.undoCandidate
    }

    /// The split target of an in-flight `.applySplit`, if any, so a split tab
    /// can tell whether the running split is its own apply or another tab's.
    var activeSplitTargetIdentity: GGSplitTargetIdentity? {
        guard case let .applySplit(_, identity, _)? = ggMutationCoordinatorStorage?.activeRequest else {
            return nil
        }
        return identity
    }

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

    @ObservationIgnored
    private var refreshInFlight = false

    @ObservationIgnored
    private var refreshGeneration = 0

    @ObservationIgnored
    private var refreshRerunRequested = false

    @ObservationIgnored
    private var refreshRerunRequiresReviewLoopRemote = false

    @ObservationIgnored
    private var refreshWaiters: [CheckedContinuation<Bool, Never>] = []

    @ObservationIgnored
    private var stageMutationWorker: Task<Void, Never>? = nil

    @ObservationIgnored
    private var lastReviewLoopRemoteRefreshAt: Date?

    @ObservationIgnored
    private var lastReviewLoopRemoteFingerprint: ReviewLoopRemoteFingerprint?

    /// Refresh interval for `syncStatusTimer`. 5 minutes per design;
    /// constant in v1.
    @ObservationIgnored
    private let syncStatusInterval: UInt64 = 5 * 60 * 1_000_000_000 // ns

    @ObservationIgnored
    private let reviewLoopRemoteRefreshMinimumInterval: TimeInterval = 45
    @ObservationIgnored private var remotePollTask: Task<Void, Never>?
    @ObservationIgnored private var remoteHelperSession: RemoteHelperWatchSession?
    @ObservationIgnored private let remoteEventDebouncer = DebounceTimer(interval: 0.5, maxWait: 2.0)
    @ObservationIgnored private var remoteFingerprint: String?
    nonisolated private static let hashObjectBatchSize = 256
    private static let remotePollIntervalNanos: UInt64 = 7 * 1_000_000_000
    private static let remoteHelperSafetyNetNanos: UInt64 = 5 * 60 * 1_000_000_000

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
        remoteEventDebouncer.onFire = { [weak self] in
            Task { @MainActor in await self?.refresh() }
        }
    }

    private var ggMutationCoordinator: GGMutationCoordinator {
        if let coordinator = ggMutationCoordinatorStorage { return coordinator }
        let coordinator = GGMutationCoordinator(
            worktreeId: worktree.id,
            worktreePath: worktree.path.path,
            service: ggService,
            actionState: ggActionState,
            context: GGMutationContext(
                loadFreshStack: { [weak self] in
                    guard let self else { throw GGServiceError.commandFailed(stderr: "Worktree is no longer available.") }
                    return try await self.ggService.currentStackSnapshot(
                        worktreePath: self.worktree.path.path
                    )
                },
                refreshStack: { [weak self] in
                    guard let self else { return }
                    await self.reevaluateGGGate().value
                },
                refreshGitChanges: { [weak self] in await self?.refresh() },
                refreshProviderReviews: { [weak self] in await self?.refresh(forceReviewLoopRemote: true) },
                refreshProjectTopology: { [weak self] in await self?.refreshProjectTopologyAfterGGMutation?() },
                worktreeExists: { [weak self] in
                    guard let self else { return false }
                    return FileManager.default.fileExists(atPath: self.worktree.path.path)
                },
                invalidateInbox: { [weak self] in
                    guard let self else { return }
                    GGInboxStore.shared.invalidate(projectId: self.worktree.projectId)
                },
                selectWorktreeAtPath: { [weak self] path in await self?.selectWorktreeAtPathAfterGGMutation?(path) },
                currentBranch: { [weak self] in self?.currentBranch }
            )
        )
        ggMutationCoordinatorStorage = coordinator
        return coordinator
    }

    func start() {
        if !worktree.path.isRemoteAlasPath {
            watcher.start()
        } else {
            startRemoteHelperWatching()
            startRemotePolling()
        }
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
        remotePollTask?.cancel()
        remotePollTask = nil
        remoteHelperSession?.stop()
        remoteHelperSession = nil
        remoteEventDebouncer.cancel()
        ggStackRefreshTask?.cancel()
        ggStackRefreshTask = nil
    }

    private func startRemoteHelperWatching() {
        guard remoteHelperSession == nil,
              let host = RemoteHostRegistry.shared.host(forPath: worktree.path.path)
        else { return }
        let session = RemoteHelperWatchSession(
            host: host,
            root: worktree.path.path,
            kinds: [.files, .git]
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

    private func startRemotePolling() {
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
        case .pushBranch, .forcePushBranch:
            guard let snapshot = reviewLoop.snapshot else { return }
            guard reviewLoop.beginAction(action) else { return }
            Task { @MainActor in
                defer { reviewLoop.endAction(action) }
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

    @MainActor
    private func performRefresh(forceReviewLoopRemote: Bool) async -> Bool {
        refreshGeneration += 1
        let currentRefreshGeneration = refreshGeneration
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
            async let mergeRefresh: Void = mergeOp.refresh()
            let entries = try await s
            let tree = try await git.fileTree(worktreePath: worktree.path, statusEntries: entries)
            let (commits, ref) = try await c
            let reviewLoopBaseResult = try? await reviewLoopBase
            let resolvedUpstream = try? await upstream
            let remotes = (try? await remotesProbe) ?? []
            let stashes = (try? await stashProbe) ?? []
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
            async let trackedContentFingerprintTask = Self.trackedContentFingerprint(worktreePath: worktree.path)
            let statusRawResult = try? await statusRaw
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
            if self.lastChangesFingerprint != newChangesFingerprint {
                self.lastChangesFingerprint = newChangesFingerprint
                self.changesGeneration += 1
            }
            if self.indexFingerprint != indexFingerprint { self.indexFingerprint = indexFingerprint }
            let mergedFileTree = Self.preservingLazyChildren(fresh: tree, previous: self.fileTree)
            if self.fileTree != mergedFileTree { self.fileTree = mergedFileTree }
            if self.commits != commits { self.commits = commits }
            self.ggStackSourceCommits = reviewLoopBaseResult?.commits ?? commits
            ggStackRefreshTask?.cancel()
            ggStackRefreshTask = Task { @MainActor [weak self] in
                await self?.refreshGGStack(forceRemote: forceReviewLoopRemote)
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
                if entries.isEmpty && commits.isEmpty && !tree.isEmpty {
                    activeTab = .files
                }
                didInitDefaultTab = true
            }
            self.hasLoadedSnapshot = true
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
            return true
        } catch {
            reviewLoop.failLocalRefresh(reviewLoopInspection, error: error)
            guard snapshotGeneration == snapshotInvalidationGeneration else {
                return false
            }
            sidebarError = error.localizedDescription
            hasLoadedSnapshot = true
            changesGeneration += 1
            // Surface failures via os.Logger so they're visible in Console.app
            // and the unified log. The previous `print` here silently kept
            // `self.changes` at its last successful value, which presented as
            // an empty Changes pane when the very first refresh failed.
            logger.error("refresh failed for worktree \(self.worktree.path.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // Not `private` so tests can call it directly against injected
    // `ggStackSourceCommits` / `ggService` without needing a real git repo +
    // watcher.
    @MainActor
    func seedGGContext(branch: String) {
        if currentBranch != branch {
            currentBranch = branch
            ggStackCommitsKey = nil
        }
        let branchContext = ggContextProvider?(branch) ?? .inactive(reason: .policyOff)
        if branchContext.isActive || !branchContext.permitsCurrentStackQuery || !ggContext.isActive {
            if ggContext != branchContext { ggContext = branchContext }
        }
        if ggStackLoadState == .loaded {
            invalidateOlderHistoryForDisplaySourceChange()
        }
        ggStackLoadState = branchContext.permitsCurrentStackQuery ? .loading : .inactive
    }

    @MainActor
    func refreshGGStack(forceRemote: Bool = false) async {
        let snapshotGeneration = snapshotInvalidationGeneration
        ggStackRefreshGeneration &+= 1
        let refreshGeneration = ggStackRefreshGeneration
        let branchContext = ggContextProvider?(currentBranch) ?? .inactive(reason: .policyOff)
        if branchContext.isActive || !branchContext.permitsCurrentStackQuery || !ggContext.isActive {
            if ggContext != branchContext { ggContext = branchContext }
        }
        reconcilePausedOperation()
        guard branchContext.permitsCurrentStackQuery else {
            if ggStackLoadState == .loaded {
                invalidateOlderHistoryForDisplaySourceChange()
            }
            ggStackCommitsKey = nil
            ggStackLoadState = .inactive
            if ggStack != nil { ggStack = nil }
            if !ggStackDisplayCommits.isEmpty { ggStackDisplayCommits = [] }
            if GGStackSummaryStore.shared.summaries[worktree.path.path] != nil {
                GGStackSummaryStore.shared.summaries[worktree.path.path] = nil
            }
            // Context can be inactive transiently while startup availability
            // resolves. Hide the candidate but retain its persisted marker for
            // a later active-context reconciliation.
            ggMutationCoordinator.suspendUndoCandidate()
            return
        }
        ggEffectiveConfig = GGConfigReader.effectiveConfig(repoPath: worktree.path.path)
        // `gg ls --json` reaches out to gh/glab for PR state — skip watcher-
        // driven refreshes when the branch and commit set are unchanged.
        // Explicit remote refreshes must still pick up approval and CI changes.
        // The branch is part of the key because `gg ls` answers for the
        // *current* branch — a checkout to a different branch that happens
        // to share the same commits (e.g. right after `git checkout -b`)
        // must not reuse the old branch's cached stack.
        let key = currentGGStackCommitsKey
        guard forceRemote || key != ggStackCommitsKey else {
            await reconcileGGUndoCandidateIfNeeded()
            return
        }
        let previousStack = ggStack
        let previousDisplayCommits = ggStackDisplayCommits
        let previousKey = ggStackCommitsKey
        let previousLoadState = ggStackLoadState
        let previousSummary = GGStackSummaryStore.shared.summaries[worktree.path.path]
        defer {
            if Task.isCancelled,
               snapshotGeneration == snapshotInvalidationGeneration,
               refreshGeneration == ggStackRefreshGeneration,
               ggStackLoadState == .loading {
                let canRestorePreviousSnapshot = previousKey == key
                    && key == currentGGStackCommitsKey
                    && (previousLoadState == .loaded || previousLoadState == .empty)
                if canRestorePreviousSnapshot {
                    invalidateOlderHistoryForDisplaySourceChange()
                    ggStack = previousStack
                    ggStackDisplayCommits = previousDisplayCommits
                    ggStackCommitsKey = previousKey
                    ggStackLoadState = previousLoadState
                    GGStackSummaryStore.shared.summaries[worktree.path.path] = previousSummary
                } else {
                    ggStack = nil
                    ggStackDisplayCommits = []
                    ggStackCommitsKey = nil
                    ggStackLoadState = .failed(
                        "Stack refresh was interrupted. Retry to load it again."
                    )
                    GGStackSummaryStore.shared.summaries[worktree.path.path] = nil
                }
            }
        }
        invalidateOlderHistoryForDisplaySourceChange()
        ggStackLoadState = .loading
        ggStackCommitsKey = nil
        if ggStack != nil { ggStack = nil }
        if !ggStackDisplayCommits.isEmpty { ggStackDisplayCommits = [] }
        if GGStackSummaryStore.shared.summaries[worktree.path.path] != nil {
            GGStackSummaryStore.shared.summaries[worktree.path.path] = nil
        }
        ggMutationCoordinator.suspendUndoCandidate()
        do {
            let stack = try await ggService.currentStack(worktreePath: worktree.path.path)
            let displayCommits: [CommitInfo]
            if let stack {
                let infos = stack.entries.isEmpty
                    ? [:]
                    : try await ggStackCommitLoader(worktree.path, stack.entries.map(\.sha))
                displayCommits = try stack.projectCommits(infos)
            } else {
                displayCommits = []
            }
            // A newer refresh, or a `markSnapshotUnknown()` invalidation,
            // superseded this one — its own `refreshGGStack` call (or the
            // invalidation's own reset) will write the current state;
            // writing here would race it with a stale result.
            if Task.isCancelled { return }
            guard snapshotGeneration == snapshotInvalidationGeneration,
                  refreshGeneration == ggStackRefreshGeneration
            else { return }
            let resolvedContext: GGWorktreeContext
            if branchContext.isActive {
                resolvedContext = branchContext
            } else if let stack {
                resolvedContext = .active(stackName: stack.name)
            } else {
                resolvedContext = branchContext
            }
            if ggContext != resolvedContext { ggContext = resolvedContext }
            ggStackCommitsKey = currentGGStackCommitsKey
            if ggStack != stack { ggStack = stack }
            ggStackDisplayCommits = displayCommits
            let stackIsEmpty = stack.map { $0.totalCommits == 0 || $0.entries.isEmpty } ?? true
            if !stackIsEmpty {
                invalidateOlderHistoryForDisplaySourceChange()
            }
            ggStackLoadState = stackIsEmpty ? .empty : .loaded
            let summary = stackIsEmpty ? nil : stack?.summary
            if GGStackSummaryStore.shared.summaries[worktree.path.path] != summary {
                GGStackSummaryStore.shared.summaries[worktree.path.path] = summary
            }
            await reconcileGGUndoCandidateIfNeeded()
        } catch {
            // A transient gg/provider failure (gh/glab auth hiccup, network
            // blip, etc.) must not cache the *failed* key `key` — it stays
            // unset so the next refresh for it retries instead of being
            // skipped by the unchanged-key guard above. But whatever
            // `ggStack` currently holds was loaded for the *previous*
            // cached key (the guard above only lets us reach this point
            // when `key` differs from it) — e.g. the previous branch's
            // stack, if the user just checked out a different stack-shaped
            // branch and this fetch for it failed. Rendering it against the
            // now-different `commits` would misattribute its header, PR
            // chips, and sidebar badge to the wrong branch, so clear it and
            // degrade to plain commits. Clearing `ggStackCommitsKey` too
            // (not just leaving it at the previous key) matters just as
            // much: leaving it would make the guard above wrongly treat a
            // later return to that same branch/commit set as "already
            // cached" and skip re-fetching the now-cleared stack.
            if Task.isCancelled { return }
            guard snapshotGeneration == snapshotInvalidationGeneration,
                  refreshGeneration == ggStackRefreshGeneration
            else { return }
            if ggContext != branchContext { ggContext = branchContext }
            ggStackCommitsKey = nil
            if ggStack != nil { ggStack = nil }
            if !ggStackDisplayCommits.isEmpty { ggStackDisplayCommits = [] }
            if GGStackSummaryStore.shared.summaries[worktree.path.path] != nil {
                GGStackSummaryStore.shared.summaries[worktree.path.path] = nil
            }
            ggStackLoadState = .failed(
                (error as? GGServiceError)?.userMessage ?? error.localizedDescription
            )
            // The cached stack we just dropped belonged to a different key, so
            // the current stack identity is unknown until a refresh succeeds.
            // Hide any recovery candidate (keeping its marker) so the drawer
            // does not offer an Undo scoped to the previous stack; it is
            // rebuilt once a later reconcile validates against the new stack.
            ggMutationCoordinator.suspendUndoCandidate()
        }
    }

    private func reconcileGGUndoCandidateIfNeeded() async {
        let coordinator = ggMutationCoordinator
        guard !didAttemptGGUndoRestore || coordinator.hasUndoStateToReconcile else { return }
        if Self.ggUndoRecoveryIsBlockedByGenericGitOperation(
            operationInProgress: GGStackGate.operationInProgress(repoPath: worktree.path.path),
            alasGGOperationInProgress: GGStackGate.alasGGOperationInProgress(repoPath: worktree.path.path)
        ) {
            coordinator.suspendUndoCandidate()
            return
        }
        didAttemptGGUndoRestore = true
        await coordinator.restoreUndoCandidate(currentStackName: ggStack?.name)
    }

    /// Supersedes every prior stack refresh and clears its published
    /// presentation. Active callers may atomically install a replacement
    /// refresh; quiescent callers leave the state invalidated for activation.
    @MainActor
    @discardableResult
    func invalidateGGPresentation(
        startingRefresh shouldRefresh: Bool
    ) -> Task<Void, Never>? {
        // Advance ownership before cancellation: a direct/untracked caller may
        // ignore cancellation, but its generation guard must still reject the
        // response after this presentation is invalidated.
        ggStackRefreshGeneration &+= 1
        ggStackRefreshTask?.cancel()
        ggStackRefreshTask = nil
        invalidateOlderHistoryForDisplaySourceChange()
        ggStackCommitsKey = nil
        if ggStack != nil { ggStack = nil }
        if !ggStackDisplayCommits.isEmpty { ggStackDisplayCommits = [] }
        ggStackLoadState = ggContext.isActive ? .loading : .inactive
        if GGStackSummaryStore.shared.summaries[worktree.path.path] != nil {
            GGStackSummaryStore.shared.summaries[worktree.path.path] = nil
        }
        guard shouldRefresh else { return nil }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshGGStack()
        }
        ggStackRefreshTask = task
        return task
    }

    /// Re-run the gg gate immediately (e.g. after a Settings toggle) rather
    /// than waiting for the next watcher-driven refresh. Resets the
    /// commits-key so the gate is fully re-evaluated even when commits are
    /// unchanged, then reloads or clears stack state. Returns the
    /// underlying task so tests can await completion; production call
    /// sites ignore the return value.
    @MainActor
    @discardableResult
    func reevaluateGGGate() -> Task<Void, Never> {
        invalidateGGPresentation(startingRefresh: false)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshGGStack()
        }
        ggStackRefreshTask = task
        return task
    }

    /// Pure filesystem probe → `ggActionState.pausedOperation` sync. Runs
    /// after the GG gates pass, but only for an already-known/active GG
    /// operation. Plain git conflicts use the same marker files and must keep
    /// their regular recovery UI.
    private func reconcilePausedOperation() {
        let operationInProgress = GGStackGate.operationInProgress(repoPath: worktree.path.path)
        if !operationInProgress {
            GGStackGate.clearAlasGGOperationInProgress(repoPath: worktree.path.path)
        }
        if operationInProgress,
           ggActionState.inFlightAction != nil
               || ggActionState.pausedOperation != nil
               || GGStackGate.alasGGOperationInProgress(repoPath: worktree.path.path)
        {
            if ggActionState.pausedOperation == nil {
                ggActionState.setPaused(GGPausedOperation(pausedBy: ggActionState.inFlightAction ?? .sync))
            }
        } else {
            ggActionState.clearPaused()
        }
    }

    /// Dispatches a stack-drawer action kind to its gg mutation. `.land`
    /// stages a confirmation (see `requestGGLand`/`performGGLand`) rather
    /// than mutating directly, and `.checkout` is dispatched directly by the
    /// entry menu (Task 9) via `requestGGCheckout` instead of going through
    /// this dispatcher.
    @MainActor
    func onGGStackAction(_ kind: GGStackActionKind, appState: AppState) {
        switch kind {
        case .sync:
            runGGMutation(.sync)
        case .clean:
            requestGGCleanAll()
        case .continueOp:
            runGGMutation(.continueOperation)
        case .abortOp:
            runGGMutation(.abortOperation)
        case .checkout:
            break
        case .land:
            requestGGLand(.ready)
        case .amendCurrent:
            runGGMutation(.amendCurrent)
        case .absorbStaged:
            runGGMutation(.absorbStaged)
        case .restack:
            requestGGRestack()
        case .rebase:
            guard let stackBase = ggStack?.base else {
                ggActionState.setError("The stack base is no longer available. Refresh and try again.")
                return
            }
            runGGMutation(.rebase(target: Self.ggManualRebaseTarget(
                stackBase: stackBase,
                behindBase: behindBase
            )))
        case .reorder:
            requestGGReorder()
        case .undo:
            guard let candidate = ggUndoCandidate else { return }
            runGGMutation(.undo(operationID: candidate.operationID))
        case .drop, .unstack, .split:
            break
        }
    }

    func requestGGReorder() {
        guard let stack = ggStack,
              stack.entries.allSatisfy({ $0.ggId != nil })
        else {
            ggActionState.setError("Every stack commit needs a GG ID before it can be reordered.")
            return
        }
        let entries = stack.entries.sorted(by: { $0.position < $1.position }).map { entry in
            let id = entry.ggId!
            return entry.prState == .merged
                ? GGReorderEntry.immutable(id: id, title: entry.title)
                : GGReorderEntry.mutable(id: id, title: entry.title)
        }
        let model = GGReorderModel(entries: entries)
        Task { @MainActor in
            do {
                let prepared = try await ggMutationCoordinator.prepare(.reorder(order: model.orderedIDs))
                pendingGGReorder = GGReorderPresentation(snapshot: prepared.snapshot, model: model)
            } catch {
                ggActionState.setError(GGErrorPresentation.message(for: error))
            }
        }
    }

    func cancelGGReorder() {
        pendingGGReorder = nil
    }

    func submitGGReorder(_ model: GGReorderModel) async throws {
        guard let pending = pendingGGReorder,
              model.hasChanges
        else { throw GGMutationError.staleConfirmation }
        guard mergeOp.current == nil else { throw GGMutationError.blockingGitOperation }
        try await ggMutationCoordinator.apply(
            .reorder(order: model.orderedIDs),
            confirmedAgainst: pending.snapshot
        )
        pendingGGReorder = nil
    }

    func requestGGRestack() {
        Task { @MainActor in
            do {
                pendingGGRestack = GGRestackPresentation(
                    prepared: try await ggMutationCoordinator.prepareRestackPreview()
                )
            } catch {
                ggActionState.setError(GGErrorPresentation.message(for: error))
            }
        }
    }

    func cancelGGRestack() {
        pendingGGRestack = nil
    }

    func submitGGRestack() async throws {
        guard let pending = pendingGGRestack, pending.hasWork else {
            throw GGMutationError.staleConfirmation
        }
        guard mergeOp.current == nil else { throw GGMutationError.blockingGitOperation }
        // The stack identity only carries the base name + head SHA, so a base
        // ref that advanced since the preview was built would still match.
        // Re-run the dry-run plan and require it to equal the reviewed one, so
        // Apply can't rewrite against a different parent than the user saw.
        let revalidated = try await ggMutationCoordinator.prepareRestackPreview()
        guard revalidated.plan == pending.prepared.plan else {
            pendingGGRestack = GGRestackPresentation(prepared: revalidated)
            throw GGMutationError.staleConfirmation
        }
        try await ggMutationCoordinator.apply(.restack, confirmedAgainst: revalidated.snapshot)
        pendingGGRestack = nil
    }

    func requestGGLand(_ request: GGLandRequest) {
        guard let stack = ggStack,
              let target = Self.ggLandUntilTarget(for: request, in: stack)
        else {
            ggActionState.setError("This stack is no longer ready to land.")
            return
        }
        Task { @MainActor in
            do {
                let prepared = try await ggMutationCoordinator.prepare(.land(target: target))
                guard case .land(_, let readyCommits) = prepared.confirmation,
                      readyCommits > 0 else {
                    throw GGMutationError.staleConfirmation
                }
                pendingGGLandPrepared = prepared
                pendingGGLand = request
            } catch {
                ggActionState.setError(GGErrorPresentation.message(for: error))
            }
        }
    }

    func handleGGCommitAction(_ action: GGCommitAction, commit: CommitInfo, appState: AppState) {
        guard let entry = ggStack?.entry(matchingCommitSHA: commit.sha) else {
            ggActionState.setError("The stack changed. Refresh and try again.")
            return
        }

        switch action {
        case .reviewProviderRequest(let number, let url):
            guard entry.prNumber == number,
                  commitRemote?.reviewRequestURL(number: number) == url
            else {
                ggActionState.setError("The provider review changed. Refresh and try again.")
                return
            }
            Task { @MainActor in
                let response = await appState.cliOpenProviderReview(
                    worktree: worktree,
                    target: url.absoluteString
                )
                if let message = Self.ggProviderReviewError(response) {
                    ggActionState.setError(message)
                }
            }
        case .openProviderRequest(let number):
            guard entry.prNumber == number, let remote = commitRemote else {
                ggActionState.setError("The provider review is no longer available.")
                return
            }
            NSWorkspace.shared.open(remote.reviewRequestURL(number: number))
        case .checkout:
            requestGGCheckout(target: entry.id)
        case .splitCommit:
            guard mergeOp.current == nil else {
                ggActionState.setError("Finish the current Git operation before splitting a commit.")
                return
            }
            requestGGSplitCommit?(entry)
        case .dropCommit:
            requestGGDrop(entry)
        case .unstackHere:
            requestGGUnstack(entry)
        case .landThrough:
            requestGGLand(.until(entryId: entry.id, title: entry.title))
        }
    }

    static func ggProviderReviewError(_ response: AlasCLIResponse) -> String? {
        guard case .error(let message) = response else { return nil }
        return message
    }

    @ObservationIgnored var requestGGSplitCommit: ((GGStackEntry) -> Void)? = nil

    func loadDescription(target: GGSplitCommitTarget) async throws -> GGSplitLoadedDescription {
        let before = try await ggService.currentStackSnapshot(worktreePath: worktree.path.path)
        guard let identity = before.identity else { throw GGMutationError.staleConfirmation }
        let description = try await ggService.describeSplit(
            worktreePath: worktree.path.path,
            target: target.commandTarget
        )
        let after = try await ggService.currentStackSnapshot(worktreePath: worktree.path.path)
        guard after.identity == identity else { throw GGMutationError.staleConfirmation }
        return GGSplitLoadedDescription(description: description, stackIdentity: identity)
    }

    func applySplit(
        planURL: URL,
        target: GGSplitTargetIdentity,
        planToken: String,
        confirmedAgainst identity: GGStackIdentity
    ) async throws {
        try await ggMutationCoordinator.apply(
            .applySplit(planURL: planURL, target: target, planToken: planToken),
            confirmedAgainst: identity
        )
    }

    func requestGGDrop(_ entry: GGStackEntry) {
        Task { @MainActor in
            do {
                let prepared = try await ggMutationCoordinator.prepare(.drop(target: entry.id))
                guard case .drop(_, let descendants, let hasOpenReview) = prepared.confirmation else {
                    throw GGMutationError.staleConfirmation
                }
                pendingGGDropPrepared = prepared
                pendingGGDrop = GGDropPresentation(
                    target: entry.id,
                    title: entry.title,
                    rewrittenDescendants: descendants,
                    openReviewLabel: hasOpenReview
                        ? (commitRemote?.kind.reviewRequestLabel ?? "review")
                        : nil
                )
            } catch {
                ggActionState.setError(GGErrorPresentation.message(for: error))
            }
        }
    }

    func cancelGGDrop() {
        pendingGGDrop = nil
        pendingGGDropPrepared = nil
    }

    func performGGDrop() {
        guard let prepared = pendingGGDropPrepared else { return }
        pendingGGDrop = nil
        pendingGGDropPrepared = nil
        runGGMutation(prepared)
    }

    func requestGGUnstack(_ entry: GGStackEntry) {
        let name = GGUnstackModel.derivedStackName(from: entry.title)
        let request = GGMutationRequest.unstack(
            target: entry.id,
            name: name,
            createWorktree: true
        )
        Task { @MainActor in
            do {
                let prepared = try await ggMutationCoordinator.prepare(request)
                let model = try GGUnstackModel(
                    prepared: prepared,
                    supportsKeepCurrent: GGAvailability.shared.capabilities.keepCurrentUnstack
                )
                pendingGGUnstackPrepared = prepared
                pendingGGUnstack = model
            } catch {
                ggActionState.setError(GGErrorPresentation.message(for: error))
            }
        }
    }

    func cancelGGUnstack() {
        pendingGGUnstack = nil
        pendingGGUnstackPrepared = nil
    }

    func submitGGUnstack(_ model: GGUnstackModel) async throws -> GGUnstackSubmissionResult {
        guard let pending = pendingGGUnstack,
              let prepared = pendingGGUnstackPrepared,
              pending.id == model.id,
              let name = model.validatedStackName
        else {
            throw GGMutationError.staleConfirmation
        }
        let request = GGMutationRequest.unstack(
            target: model.targetID,
            name: name,
            createWorktree: model.createWorktree
        )

        let freshPrepared = try await ggMutationCoordinator.prepare(request)
        if request != prepared.request
            || freshPrepared.snapshot != prepared.snapshot
            || freshPrepared.confirmation != prepared.confirmation
        {
            let freshModel = try GGUnstackModel(
                prepared: freshPrepared,
                supportsKeepCurrent: GGAvailability.shared.capabilities.keepCurrentUnstack
            )
            pendingGGUnstackPrepared = freshPrepared
            pendingGGUnstack = freshModel
            return .reconfirm(freshModel)
        }

        pendingGGUnstackPrepared = freshPrepared
        try await ggMutationCoordinator.apply(freshPrepared)
        pendingGGUnstack = nil
        pendingGGUnstackPrepared = nil
        return .applied
    }

    func cancelGGLand() {
        pendingGGLand = nil
        pendingGGLandPrepared = nil
    }
    func requestGGCleanAll() {
        Task { @MainActor in
            do {
                pendingGGCleanPrepared = try await ggMutationCoordinator.prepare(.clean)
                pendingGGCleanAll = true
            } catch {
                ggActionState.setError(GGErrorPresentation.message(for: error))
            }
        }
    }
    func cancelGGCleanAll() {
        pendingGGCleanAll = false
        pendingGGCleanPrepared = nil
    }
    func performGGCleanAll() {
        guard pendingGGCleanAll, let prepared = pendingGGCleanPrepared else { return }
        pendingGGCleanAll = false
        pendingGGCleanPrepared = nil
        runGGMutation(prepared.request, confirmedAgainst: prepared.snapshot)
    }

    /// Checks out a stack entry (`gg mv <target>`) through the shared mutation
    /// lifecycle so it gets the same gating and refresh behavior as other actions.
    @MainActor
    func requestGGCheckout(target: String) {
        runGGMutation(.checkout(target: target))
    }

    /// Pure landability check used both to stage the confirmation and to
    /// re-verify against a freshly re-fetched stack before mutating.
    func ggLandTargetStillLandable(_ request: GGLandRequest, in stack: GGStack) -> Bool {
        switch request {
        case .ready:
            return !Self.ggLandReadyPrefix(in: stack).isEmpty
        case .until(let entryId, _):
            guard let target = stack.entries.first(where: { $0.id == entryId }),
                  Self.ggEntryIsReadyToLand(target)
            else { return false }
            return stack.entries
                .filter { $0.position < target.position }
                .allSatisfy(Self.ggEntryDoesNotBlockLand)
        }
    }

    static func ggEntryIsReadyToLand(_ entry: GGStackEntry) -> Bool {
        entry.prState == .open && entry.approved && (entry.ciStatus == nil || entry.ciStatus == .success)
    }

    static func ggEntryDoesNotBlockLand(_ entry: GGStackEntry) -> Bool {
        entry.prState == .merged || ggEntryIsReadyToLand(entry)
    }

    static func ggLandReadyPrefix(in stack: GGStack) -> [GGStackEntry] {
        var entries: [GGStackEntry] = []
        for entry in stack.entries.sorted(by: { $0.position < $1.position }) {
            if entry.prState == .merged { continue }
            guard ggEntryIsReadyToLand(entry) else { break }
            entries.append(entry)
        }
        return entries
    }

    static func ggLandStackFingerprint(_ stack: GGStack) -> String {
        let entryFingerprint = stack.entries
            .sorted(by: { $0.position < $1.position })
            .map { "\($0.position):\($0.id):\($0.sha)" }
            .joined(separator: "|")
        return "\(stack.name)|\(stack.base)|\(entryFingerprint)"
    }

    static func ggLandStackMatchesPendingConfirmation(_ stack: GGStack, fingerprint: String?) -> Bool {
        guard let fingerprint else { return false }
        return ggLandStackFingerprint(stack) == fingerprint
    }

    static func ggLandUntilTarget(for request: GGLandRequest, in stack: GGStack) -> String? {
        switch request {
        case .ready:
            return ggLandReadyPrefix(in: stack).last?.id
        case .until(let entryId, _):
            return entryId
        }
    }

    static func ggLandConfirmationMessage(for request: GGLandRequest, stack: GGStack?) -> String {
        switch request {
        case .ready:
            let n = stack.map { Self.ggLandReadyPrefix(in: $0).count } ?? 0
            return "Merge \(n) approved, passing PR\(n == 1 ? "" : "s") from the bottom of the stack."
        case .until(_, let title):
            return "Land the stack up to and including \u{201C}\(title)\u{201D}."
        }
    }

    static func ggManualRebaseTarget(
        stackBase: String,
        behindBase: GitService.BehindStatus?
    ) -> String {
        guard let ref = behindBase?.ref else { return stackBase }
        if ref == stackBase { return ref }
        let components = ref.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard components.count == 2, components[1] == stackBase else { return stackBase }
        return ref
    }

    static func ggUndoRecoveryIsBlockedByGenericGitOperation(
        operationInProgress: Bool,
        alasGGOperationInProgress: Bool
    ) -> Bool {
        operationInProgress && !alasGGOperationInProgress
    }

    var pendingGGLandConfirmationMessage: String? {
        guard let request = pendingGGLand else { return nil }
        guard case .land(_, let readyCommits) = pendingGGLandPrepared?.confirmation else {
            return Self.ggLandConfirmationMessage(for: request, stack: ggStack)
        }
        switch request {
        case .ready:
            return "Merge \(readyCommits) approved, passing PR\(readyCommits == 1 ? "" : "s") from the bottom of the stack."
        case .until(_, let title):
            return "Land the stack up to and including \u{201C}\(title)\u{201D}."
        }
    }

    @MainActor
    func performGGLand() {
        guard pendingGGLand != nil, let prepared = pendingGGLandPrepared else { return }
        pendingGGLand = nil
        pendingGGLandPrepared = nil
        runGGMutation(prepared.request, confirmedAgainst: prepared.snapshot)
    }

    @discardableResult
    func runGGMutation(
        _ request: GGMutationRequest,
        confirmedAgainst identity: GGStackIdentity? = nil
    ) -> Task<Void, Never>? {
        guard let operation = ggMutationCoordinator.startApplying(
            request,
            confirmedAgainst: identity
        ) else { return nil }
        let actionGeneration = ggActionState.actionGeneration
        return Task { @MainActor in
            do {
                try await operation.value
            } catch {
                publishGGMutationPresentationError(error, forActionGeneration: actionGeneration)
            }
        }
    }

    @discardableResult
    func runGGMutation(_ prepared: GGPreparedMutation) -> Task<Void, Never>? {
        guard let operation = ggMutationCoordinator.startApplying(prepared) else { return nil }
        let actionGeneration = ggActionState.actionGeneration
        return Task { @MainActor in
            do {
                try await operation.value
            } catch {
                publishGGMutationPresentationError(error, forActionGeneration: actionGeneration)
            }
        }
    }

    private func publishGGMutationPresentationError(
        _ error: Error,
        forActionGeneration generation: UInt
    ) {
        guard ggActionState.shouldPublishError(forActionGeneration: generation) else { return }
        ggActionState.setError(GGErrorPresentation.message(for: error))
    }

    func markSnapshotUnknown() {
        snapshotInvalidationGeneration += 1
        hasLoadedSnapshot = false
        changes = []
        stashes = []
        expandedStashRefs = []
        stashFilesByRef = [:]
        loadingStashRefs = []
        pendingStashChanges = false
        pendingStashDrop = nil
        stashOperationInFlight = false
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

    func invalidateFileTreeChildLoadsForRefresh() {
        fileTreeGeneration += 1
        loadedFileTreeChildPaths = [""]
        loadingFileTreeChildPaths = []
        failedFileTreeChildPaths = []
        fileTree = Self.resetLoadingFileTreeChildren(in: fileTree)
    }

    func toggleStage(_ file: ChangedFile) {
        if file.stage == .staged {
            unstageAll([file])
        } else {
            stageAll([file])
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

    /// Carries previously loaded lazy-directory subtrees from `previous` into a
    /// freshly rebuilt `fresh` tree.
    ///
    /// `GitService.fileTree` rebuilds lazily-loaded directories (ignored or
    /// excluded roots, and anything expanded on demand) as `.notLoaded` with no
    /// children. Assigning that tree verbatim on refresh collapses any directory
    /// the user had already expanded — it briefly renders the uncompacted tree,
    /// re-loads it level by level, and re-collapses (the "blink"). Grafting the
    /// prior subtree keeps the expanded, compacted state stable across refreshes;
    /// contents are still reconciled in the background by `loadFileTreeChildren`.
    nonisolated static func preservingLazyChildren(
        fresh: [FileTreeNode],
        previous: [FileTreeNode]
    ) -> [FileTreeNode] {
        var previousByPath: [String: FileTreeNode] = [:]
        for node in previous { previousByPath[node.path] = node }
        return fresh.map { node in
            var updated = node
            let prior = previousByPath[node.path]
            if node.kind == .dir,
               node.childrenState == .notLoaded,
               node.children == nil,
               let prior,
               prior.kind == .dir,
               prior.childrenState == .loaded,
               let priorChildren = prior.children {
                updated.childrenState = .loaded
                updated.children = priorChildren
                return updated
            }
            if let children = node.children {
                updated.children = preservingLazyChildren(
                    fresh: children,
                    previous: prior?.children ?? []
                )
            }
            return updated
        }
    }

    /// Reconciles the child list of the directory at `path` against a fresh
    /// listing from `GitService.fileTreeChildren`. Used when re-loading an
    /// already-loaded directory on refresh.
    ///
    /// `mergingChildren` seeds from the existing children and only overlays
    /// incoming entries, so deletions/renames linger. This instead treats the
    /// listing as authoritative for what exists on disk and prunes entries that
    /// are gone — but only when they are *filesystem*-authoritative (ignored or
    /// excluded, with no git badge). Git-authoritative entries are kept even
    /// when the listing omits them, because `fileTreeChildren` is a filesystem
    /// scan and cannot represent them:
    ///   - a tracked file deleted from disk still appears in the full tree with
    ///     a `D` badge and must remain selectable;
    ///   - surviving entries keep their badge, visibility, submodule flag, and
    ///     any already-loaded subtree, since the listing has `badges: [:]` and a
    ///     `.tracked` default that would otherwise erase that metadata.
    nonisolated static func replacingChildren(
        in nodes: [FileTreeNode],
        for path: String,
        with children: [FileTreeNode],
        state: DirectoryChildrenState
    ) -> (nodes: [FileTreeNode], didMerge: Bool) {
        var didMerge = false
        let updatedNodes = nodes.map { node -> FileTreeNode in
            if node.path == path {
                didMerge = true
                var updated = node
                var existingByID: [String: FileTreeNode] = [:]
                for child in node.children ?? [] { existingByID[child.id] = child }
                let incomingIDs = Set(children.map(\.id))
                var reconciled = children.map { incoming -> FileTreeNode in
                    guard let existing = existingByID[incoming.id] else { return incoming }
                    var refreshed = incoming
                    refreshed.badge = incoming.badge ?? existing.badge
                    refreshed.visibility = mergedVisibility(existing: existing.visibility, incoming: incoming.visibility)
                    refreshed.isSubmodule = incoming.isSubmodule || existing.isSubmodule
                    refreshed.childrenState = mergedChildrenState(existing: existing.childrenState, incoming: incoming.childrenState)
                    if refreshed.children == nil {
                        refreshed.children = existing.children
                    }
                    return refreshed
                }
                // Keep git-authoritative entries the filesystem listing can't
                // show (e.g. tracked deletions); drop only ignored/excluded
                // entries with no badge that are actually gone from disk.
                let keptDeletions = (node.children ?? []).filter { existing in
                    guard !incomingIDs.contains(existing.id) else { return false }
                    let filesystemAuthoritative =
                        (existing.visibility == .ignored || existing.visibility == .excluded)
                        && existing.badge == nil
                    return !filesystemAuthoritative
                }
                reconciled.append(contentsOf: keptDeletions)
                updated.children = reconciled.sorted { lhs, rhs in
                    if lhs.kind != rhs.kind { return lhs.kind == .dir }
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
                updated.childrenState = state
                return updated
            }
            guard let existing = node.children else { return node }
            var updated = node
            let result = replacingChildren(in: existing, for: path, with: children, state: state)
            didMerge = didMerge || result.didMerge
            updated.children = result.nodes
            return updated
        }
        return (updatedNodes, didMerge)
    }

    nonisolated static func fileTreeNode(at path: String, in nodes: [FileTreeNode]) -> FileTreeNode? {
        for node in nodes {
            if node.path == path { return node }
            if let children = node.children,
               let found = fileTreeNode(at: path, in: children) {
                return found
            }
        }
        return nil
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
        // A directory whose children were carried over from a previous load
        // (e.g. across a refresh) is being reconciled, not loaded for the first
        // time. Flipping it to `.loading` would drop it out of a compacted chain
        // and make the row visibly collapse and re-expand, so keep it `.loaded`
        // and refresh its contents in the background instead.
        let alreadyLoaded = Self.fileTreeNode(at: path, in: fileTree)
            .map { $0.childrenState == .loaded && $0.children != nil } ?? false
        if !alreadyLoaded {
            let loadingMerge = Self.mergingChildren(in: fileTree, for: path, with: [], state: .loading)
            guard loadingMerge.didMerge else {
                loadingFileTreeChildPaths.remove(path)
                return
            }
            fileTree = loadingMerge.nodes
        }
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
                // On the first load, merge so concurrent per-level loads (e.g. the
                // reveal flow expanding several ancestors at once) accumulate.
                // When reconciling an already-loaded directory, rebuild its child
                // list from the fresh filesystem listing so deleted/renamed
                // entries drop out — `mergingChildren` only overlays and would
                // leave stale children behind.
                let result = alreadyLoaded
                    ? Self.replacingChildren(in: self.fileTree, for: path, with: children, state: .loaded)
                    : Self.mergingChildren(in: self.fileTree, for: path, with: children, state: .loaded)
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
        enqueueStageMutation(files: files, target: .staged, gitPaths: files.map(\.path))
    }

    func unstageAll(_ files: [ChangedFile]) {
        enqueueStageMutation(
            files: files,
            target: .unstaged,
            gitPaths: files.flatMap(Self.unstagePaths(for:))
        )
    }

    private func enqueueStageMutation(
        files: [ChangedFile],
        target: ChangeStage,
        gitPaths: [String]
    ) {
        guard !files.isEmpty else { return }
        sidebarError = nil
        pendingStageMutations.append(PendingStageMutation(
            paths: Set(files.map(\.path)),
            gitPaths: gitPaths,
            target: target
        ))
        guard stageMutationWorker == nil else { return }
        stageMutationWorker = Task { @MainActor [weak self] in
            await self?.runStageMutationQueue()
        }
    }

    private func runStageMutationQueue() async {
        while let mutation = pendingStageMutations.first(where: { !$0.hasAppliedGitMutation }) {
            do {
                if mutation.target == .staged {
                    try await git.stageAll(worktreePath: worktree.path, files: mutation.gitPaths)
                } else {
                    try await git.unstageAll(worktreePath: worktree.path, files: mutation.gitPaths)
                }
                if let index = pendingStageMutations.firstIndex(where: { $0.id == mutation.id }) {
                    pendingStageMutations[index].hasAppliedGitMutation = true
                    pendingStageMutations[index].minimumRefreshGeneration = refreshGeneration + 1
                }
                await refresh()
            } catch {
                pendingStageMutations.removeAll { $0.id == mutation.id }
                sidebarError = (error as NSError).localizedDescription
                await refresh()
            }
        }
        stageMutationWorker = nil
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

    func cancelMerge() {
        pendingMerge = nil
    }

    func clearMergeError() {
        mergeError = nil
    }

    func clearMergeQueuedMessage() {
        mergeQueuedMessage = nil
    }

    static func mergeConfirmationMessage(for request: ReviewRequest?) -> String {
        guard let request else {
            return "Squash-merge this review request and delete the branch."
        }
        if request.isMergeQueueEnabled {
            return "Add \(request.displayIdentity) to the merge queue for \(request.baseRefName)."
        }
        return "Squash-merge \(request.displayIdentity) into \(request.baseRefName) and delete the branch."
    }

    func performMerge() {
        guard let pending = pendingMerge else { return }
        pendingMerge = nil
        // Fast reject against the currently-cached snapshot (also re-validates
        // if the dialog captured a now-stale snapshot).
        guard let cached = reviewLoop.snapshot,
              ReviewReadinessModel.canMergeReviewRequest(snapshot: cached) else {
            mergeError = Self.mergeUnavailableMessage
            return
        }
        // The PR + head the user actually confirmed. After the forced refresh we
        // require the fresh snapshot to still be this exact request/head, so a
        // branch switch mid-dialog can't redirect the merge to a different PR.
        let confirmedRequestID = pending.reviewRequest?.id
        let confirmedHeadSHA = pending.reviewRequest?.headSHA
        guard reviewLoop.beginAction(.merge) else { return }
        Task { @MainActor in
            defer { reviewLoop.endAction(.merge) }
            // The cached snapshot can still lag reality: WorktreeWatcher
            // debounces change events up to ~2s, so a commit created just
            // before confirming may not have flipped `needsPush` yet. Force a
            // live refresh (recomputes HEAD/upstream + provider checks and
            // mergeability), then re-validate and merge the fresh snapshot.
            await refresh()
            guard let snapshot = reviewLoop.snapshot,
                  ReviewReadinessModel.canMergeReviewRequest(snapshot: snapshot),
                  snapshot.reviewRequest?.id == confirmedRequestID,
                  snapshot.reviewRequest?.headSHA == confirmedHeadSHA
            else {
                mergeError = Self.mergeUnavailableMessage
                return
            }
            // The generation-guarded refresh above can be superseded by a
            // concurrent watcher refresh and return without publishing, leaving
            // the snapshot stale. Do a final authoritative read straight from
            // git so a just-created commit or dirty tree can't slip through.
            guard let reviewedHead = snapshot.reviewRequest?.headSHA,
                  await localHeadIsCleanlyAt(reviewedHead)
            else {
                mergeError = Self.mergeUnavailableMessage
                return
            }
            switch await reviewLoop.merge(snapshot: snapshot) {
            case .merged:
                await refresh(forceReviewLoopRemote: true)
            case .queued:
                mergeQueuedMessage = "Added to merge queue."
                await refresh(forceReviewLoopRemote: true)
            case nil:
                mergeError = reviewLoop.lastError ?? "Merge failed."
            }
        }
    }

    /// Authoritative, point-in-time check that the worktree HEAD is exactly the
    /// reviewed head and the tree is clean — read straight from git, not via the
    /// review-loop refresh (whose generation guard lets a concurrent watcher
    /// refresh supersede the merge-triggered one without publishing).
    private func localHeadIsCleanlyAt(_ reviewedHeadSHA: String) async -> Bool {
        guard let head = try? await Process.git(["rev-parse", "HEAD"], cwd: worktree.path),
              head.exitCode == 0,
              head.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == reviewedHeadSHA
        else { return false }
        guard let status = try? await Process.git(["status", "--porcelain"], cwd: worktree.path),
              status.exitCode == 0
        else { return false }
        return status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // Merge failures are surfaced via an app-level alert (hosted in RootView
    // next to the confirmation dialog) rather than `sidebarError`, because a
    // merge can be launched from the Review tab in the center pane while the
    // right pane — the only place `sidebarError` renders — is collapsed.
    private static let mergeUnavailableMessage =
        "Merge is no longer available — the branch or review state changed."

    func requestCherryPick(sha: String) {
        pendingCherryPickSHA = sha
    }

    func cancelCherryPick() {
        pendingCherryPickSHA = nil
    }

    func confirmCherryPick() {
        guard let sha = pendingCherryPickSHA else { return }
        pendingCherryPickSHA = nil
        runCherryPick(sha: sha)
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

    func requestStashChanges() {
        guard !changes.isEmpty, mergeOp.current == nil, !stashOperationInFlight else { return }
        pendingStashChanges = true
    }

    func cancelStashChanges() {
        pendingStashChanges = false
    }

    func stashChanges(message: String, includeUntracked: Bool) {
        guard pendingStashChanges, !stashOperationInFlight else { return }
        pendingStashChanges = false
        stashOperationInFlight = true
        sidebarError = nil
        Task { @MainActor in
            defer { self.stashOperationInFlight = false }
            do {
                let result = try await self.git.pushStash(
                    worktreePath: self.worktree.path,
                    message: message,
                    includeUntracked: includeUntracked
                )
                await self.refresh()
                self.handleStashOperationResult(result)
            } catch {
                self.sidebarError = error.localizedDescription
            }
        }
    }

    func toggleStashExpanded(_ stash: GitStash) {
        if expandedStashRefs.contains(stash.ref) {
            expandedStashRefs.remove(stash.ref)
        } else {
            expandedStashRefs.insert(stash.ref)
            loadFiles(for: stash)
        }
    }

    func loadFiles(for stash: GitStash) {
        guard stashFilesByRef[stash.ref] == nil, !loadingStashRefs.contains(stash.ref) else { return }
        let snapshotGeneration = snapshotInvalidationGeneration
        loadingStashRefs.insert(stash.ref)
        Task { @MainActor in
            defer { self.loadingStashRefs.remove(stash.ref) }
            do {
                let files = try await self.git.stashFiles(worktreePath: self.worktree.path, stash: stash)
                guard snapshotGeneration == self.snapshotInvalidationGeneration else { return }
                guard self.stashes.contains(where: { $0.ref == stash.ref && $0.sha == stash.sha }) else { return }
                self.stashFilesByRef[stash.ref] = files
            } catch {
                guard snapshotGeneration == self.snapshotInvalidationGeneration else { return }
                self.sidebarError = error.localizedDescription
            }
        }
    }

    func applyStash(_ stash: GitStash) {
        runStashOperation {
            try await self.git.applyStash(worktreePath: self.worktree.path, stash: stash)
        }
    }

    func popStash(_ stash: GitStash) {
        runStashOperation {
            try await self.git.popStash(worktreePath: self.worktree.path, stash: stash)
        }
    }

    func requestDropStash(_ stash: GitStash) {
        pendingStashDrop = PendingStashDrop(stash: stash)
    }

    func cancelDropStash() {
        pendingStashDrop = nil
    }

    func confirmDropStash(_ pending: PendingStashDrop) {
        if pendingStashDrop == pending {
            pendingStashDrop = nil
        }
        guard !stashOperationInFlight else { return }
        stashOperationInFlight = true
        sidebarError = nil
        Task { @MainActor in
            defer { self.stashOperationInFlight = false }
            do {
                try await self.git.dropStash(worktreePath: self.worktree.path, stash: pending.stash)
                await self.refresh()
            } catch {
                self.sidebarError = error.localizedDescription
            }
        }
    }

    func reconcileStashCaches(with newStashes: [GitStash]) {
        let previousSHAsByRef = Dictionary(uniqueKeysWithValues: stashes.map { ($0.ref, $0.sha) })
        let newSHAsByRef = Dictionary(uniqueKeysWithValues: newStashes.map { ($0.ref, $0.sha) })
        let stableRefs = Set(newSHAsByRef.compactMap { ref, sha in
            previousSHAsByRef[ref] == sha ? ref : nil
        })

        expandedStashRefs.formIntersection(stableRefs)
        stashFilesByRef = stashFilesByRef.filter { stableRefs.contains($0.key) }
    }

    private func runStashOperation(_ operation: @escaping @MainActor () async throws -> StashOperationResult) {
        guard !stashOperationInFlight else { return }
        stashOperationInFlight = true
        sidebarError = nil
        Task { @MainActor in
            defer { self.stashOperationInFlight = false }
            do {
                let result = try await operation()
                await self.refresh()
                self.handleStashOperationResult(result)
            } catch {
                self.sidebarError = error.localizedDescription
            }
        }
    }

    private func handleStashOperationResult(_ result: StashOperationResult) {
        switch result {
        case .clean:
            return
        case .conflict(let message), .error(let message):
            sidebarError = message
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
    func refreshSyncStatus(force: Bool = false) async {
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

    private func invalidateOlderHistoryForDisplaySourceChange() {
        commitDisplayGeneration &+= 1
        olderCommits = []
        hasMoreOlder = true
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

    /// Pull the current branch's upstream (fetch + rebase onto it). Surfaces
    /// conflicts through the existing `OperationCard` via `refresh()` +
    /// `handleOperationResult`. No-ops unless the upstream chip is actually
    /// showing (behind by >0, attached HEAD), and when an operation is already
    /// in flight or a pull is already running. Gating on `showBehindUpstreamChip`
    /// keeps the action's safety with the action rather than relying on the
    /// view to hide the chip.
    @MainActor
    func pull() {
        guard showBehindUpstreamChip, mergeOp.current == nil, !pullInFlight else { return }
        sidebarError = nil
        pullInFlight = true
        Task { @MainActor in
            defer { pullInFlight = false }
            do {
                let result = try await git.pull(worktreePath: worktree.path)
                await refresh()
                // pull() already fetched upstream; skip the redundant network
                // fetch and just recount against the already-fresh tracking ref.
                await refreshSyncStatus()
                handleOperationResult(result)
                if case .error(let message) = result {
                    sidebarError = message
                }
            } catch {
                // Unlike the pure rebase/merge siblings, surface the failure to
                // the user: a pull is the only signal they have that it ran.
                sidebarError = error.localizedDescription
                logger.error("pull failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    @MainActor
    func runRevert(sha: String) {
        Task { @MainActor in
            do {
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

struct GGDropPresentation: Equatable {
    let target: String
    let title: String
    let rewrittenDescendants: Int
    let openReviewLabel: String?

    var message: String {
        let descendants = "\(rewrittenDescendants) descendant commit\(rewrittenDescendants == 1 ? "" : "s")"
        let reviewWarning = openReviewLabel.map { " The selected commit has an open \($0)." } ?? ""
        return "Drop \u{201C}\(title)\u{201D}. GG will rewrite and retain \(descendants).\(reviewWarning)"
    }
}
