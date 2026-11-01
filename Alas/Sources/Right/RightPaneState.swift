import AppKit
import Foundation
import Observation
import os

enum RightPaneTab: String {
    case changes, files, agent, run, schedules

    /// Folder projects have no git, so no Changes tab.
    static func available(isFolder: Bool = false) -> [Self] {
        isFolder ? [.files, .agent, .run, .schedules] : [.changes, .files, .agent, .run, .schedules]
    }

    /// A peer worktree exposes read-only changes and files, and its sessions;
    /// schedules belong to this Mac; Run needs a host that serves
    /// `host.runs.scripts.v1`.
    static func peerAvailable(isFolder: Bool = false, servesRuns: Bool = false) -> [Self] {
        let tabs: [Self] = isFolder ? [.files, .agent] : [.changes, .files, .agent]
        return servesRuns ? tabs + [.run] : tabs
    }
}

struct RightPaneAttentionSnapshot: Equatable {
    let mergeOperation: MergeOperation?
    let conflictedPaths: [String]
    let review: ReviewLoopSnapshot?
}

enum CheckpointOperationKind: Equatable {
    case capture
    case preview
    case restore
    case delete
    case recovery
}

struct CheckpointCreatePresentation: Identifiable, Equatable {
    let id = UUID()
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

struct SyncFetchTarget: Hashable {
    let remote: String
    let branch: String
}

struct PendingStageMutation: Identifiable {
    let id = UUID()
    let paths: Set<String>
    let gitPaths: [String]
    let target: ChangeStage
    var hasAppliedGitMutation = false
    var minimumRefreshGeneration = 0
}

struct CheckpointSnapshotLoadError: Error {
    let message: String
}

@Observable
@MainActor
final class RightPaneState: GGSplitCommitServicing {
    nonisolated static let remoteUntrackedContentFingerprintCommand = "git ls-files --others --exclude-standard -z | xargs -0 sh -c '[ \"$#\" -gt 0 ] || exit 0; git hash-object -- \"$@\"' sh 2>/dev/null"

    let worktree: Worktree
    /// Folder projects have no git: only the Files tree refreshes, from the
    /// filesystem, and every git probe is skipped.
    let isFolder: Bool
    var defaultTab: RightPaneTab { isFolder ? .files : .changes }
    let reviewLoop: ReviewLoopState
    @ObservationIgnored var requestGGSplitCommit: ((GGStackEntry) -> Void)? = nil
    @ObservationIgnored
    var reviewSnapshotDidChange: ((ReviewLoopSnapshot) -> Void)?
    @ObservationIgnored
    var attentionSnapshotDidChange: ((RightPaneAttentionSnapshot) -> Void)?
    @ObservationIgnored
    var worktreeDidChange: (() -> Void)?

    var attentionSnapshot: RightPaneAttentionSnapshot {
        RightPaneAttentionSnapshot(
            mergeOperation: mergeOp.current,
            conflictedPaths: changes.filter { $0.conflict != nil }.map(\.path).sorted(),
            review: reviewLoop.snapshot
        )
    }
    var changes: [ChangedFile] = []
    var stashes: [GitStash] = []
    var stashesExpanded: Bool = false
    var expandedStashRefs: Set<String> = []
    var stashFilesByRef: [String: [GitStashFile]] = [:]
    var loadingStashRefs: Set<String> = []
    var pendingStashChanges: Bool = false
    var pendingStashDrop: PendingStashDrop? = nil
    var stashOperationInFlight: Bool = false
    var discardOperationInFlight: Bool = false

    // MARK: Checkpoints

    var checkpointSummaries: [WorktreeCheckpointSummary] = []
    var checkpointStorageUsage: Int64 = 0
    var checkpointsExpanded: Bool = true
    var automaticCheckpointsExpanded: Bool = false
    var expandedCheckpointIDs: Set<CheckpointID> = []
    /// Current window (0-based page index) of an expanded checkpoint's file
    /// list. Only this page's groups render; navigating pages never
    /// accumulates previously shown groups, so the card renders at most
    /// `CheckpointPresentation.maxInlineFileGroups` rows regardless of how
    /// many pages a huge checkpoint has or how far the user has paged.
    var checkpointFileListPageIndices: [CheckpointID: Int] = [:]
    var checkpointManifests: [CheckpointID: WorktreeCheckpointManifest] = [:]
    var loadingCheckpointManifestIDs: Set<CheckpointID> = []
    var checkpointManifestErrors: [CheckpointID: String] = [:]
    var pendingCheckpointCreation: CheckpointCreatePresentation? = nil
    var pendingCheckpointDeletion: WorktreeCheckpointSummary? = nil
    var checkpointRestorePreview: CheckpointRestorePreview? = nil
    var nonterminalCheckpointJournals: [CheckpointRestoreJournal] = []
    var checkpointJournalDiscoverySucceeded: Bool = false
    var checkpointOperationInFlight: CheckpointOperationKind? = nil
    var lastCheckpointError: String? = nil
    var lastCheckpointStatus: String? = nil
    var checkpointLoadError: String? = nil
    @ObservationIgnored var checkpointCoordinationProvider: (@MainActor (Set<String>) -> CheckpointCoordinationSnapshot)?
    @ObservationIgnored var checkpointTargetProvider: (@MainActor () -> CheckpointWorktreeTarget?)?
    @ObservationIgnored let checkpointService: any WorktreeCheckpointServicing

    var hasInterruptedCheckpointRestore: Bool { !nonterminalCheckpointJournals.isEmpty }
    var checkpointMutationsDisabled: Bool {
        checkpointOperationInFlight != nil || !checkpointJournalDiscoverySucceeded || hasInterruptedCheckpointRestore
    }
    var checkpointRestoreBlocksWriters: Bool {
        checkpointOperationInFlight != nil || hasInterruptedCheckpointRestore
    }
    var hasOtherGitMutationInFlight: Bool {
        mergeOp.current != nil || stageMutationWorker != nil || stashOperationInFlight || discardOperationInFlight
            || pullInFlight || ggActionState.inFlightAction != nil
    }
    var hasLoadedSnapshot: Bool = false
    var latestSnapshotRefreshSucceeded: Bool = false
    var hasCurrentAttentionSnapshot: Bool {
        hasLoadedSnapshot && latestSnapshotRefreshSucceeded
    }
    var displayChanges: [ChangedFile] {
        guard hasLoadedSnapshot else { return [] }
        return Self.applyingStageMutations(
            pendingStageMutations.map { (paths: $0.paths, target: $0.target) },
            to: changes
        )
    }
    var pendingStageMutations: [PendingStageMutation] = []
    /// Increments whenever `refresh()` publishes a new change list. This
    /// catches same-line unstaged edits whose add/delete totals stay constant.
    /// It is now guarded by an effective-change fingerprint so no-op
    /// watcher-driven refreshes do not re-fire downstream loaders.
    var changesGeneration: Int = 0
    @ObservationIgnored
    var lastChangesFingerprint: String = ""
    /// Increments whenever cached snapshot data is explicitly invalidated.
    /// In-flight refreshes capture this before doing async work and must not
    /// publish if it changed underneath them.
    var snapshotInvalidationGeneration: Int = 0
    /// Ensures only the newest checkpoint catalog load can publish. Checkpoint
    /// captures do not invalidate the broader worktree snapshot, so they need
    /// their own ordering boundary.
    var checkpointLoadGeneration: UInt = 0
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
    var pullInFlight: Bool = false
    var fetchInFlight: Bool = false
    var lastSyncFetchAtByTarget: [SyncFetchTarget: Date] = [:]
    var fileTree: [FileTreeNode] = [] {
        didSet {
            if oldValue != fileTree { fileTreeRevision &+= 1 }
        }
    }
    var loading: Bool = false
    var openPaths: Set<String> = []   // expanded directories in the tree
    /// Expanded directories inside the bookmarks drawer. Separate from
    /// `openPaths` so expanding a bookmark leaves the tree above it alone.
    var bookmarkOpenPaths: Set<String> = []
    /// Bookmark roots already seeded into `bookmarkOpenPaths`, so a root the
    /// user collapses is not re-expanded on the next render.
    var seededBookmarkRoots: Set<String> = []
    var revealPath: String? = nil
    var revealTick: Int = 0
    var pendingRevealForPaneMount = false
    var loadedFileTreeChildPaths: Set<String> = [""]
    var loadingFileTreeChildPaths: Set<String> = []
    var fileTreeChildLoadTokens: [String: Int] = [:]
    var nextFileTreeChildLoadToken: Int = 0
    var failedFileTreeChildPaths: Set<String> = []
    var fileTreeGeneration: Int = 0
    /// Advances when a refreshed or lazily loaded tree is actually published.
    /// Views that resolve paths against the tree use this to avoid running
    /// against the pre-refresh snapshot.
    private(set) var fileTreeRevision: Int = 0
    /// Lazy directories carried over during a refresh. They must be relisted
    /// before bookmarks can trust their retained descendants.
    var bookmarkReconciliationPaths: Set<String> = []
    var fileTreeRefreshRevision: Int = 0

    // New in right-sidebar-refactor:
    var activeTab: RightPaneTab = .changes {
        didSet {
            if oldValue != activeTab { endAttentionReveal() }
            // Choosing a built-in tab, by the user or by a reveal, always shows it.
            activePluginPanel = nil
        }
    }
    /// A plugin panel shown instead of `activeTab` while it is set and still offered.
    var activePluginPanel: PluginPanelRef?
    var attentionScrollRequest: AppKitDiffScrollRequest?
    private(set) var attentionRevealedTarget: AttentionJumpTarget?
    private var attentionRevealGeneration = 0

    func endAttentionReveal() {
        attentionRevealedTarget = nil
        attentionScrollRequest = nil
    }

    /// Validate the destination before switching the visible Changes surface.
    func revealAttentionTarget(_ target: AttentionJumpTarget) -> Bool {
        let rowID: String?
        switch target {
        case .conflicts(let path):
            let conflicts = changes.filter { $0.conflict != nil }
            guard !conflicts.isEmpty, path == nil || conflicts.contains(where: { $0.path == path }) else { return false }
            workingTreeExpanded = true
            rowID = "changes-conflicts"
        case .gitOperation:
            guard mergeOp.current != nil else { return false }
            rowID = "changes-operation"
        case .reviewRequest(let number):
            guard let snapshot = reviewLoop.snapshot,
                  snapshot.providerAvailable,
                  snapshot.providerAuthenticated,
                  snapshot.errorMessage == nil,
                  let request = snapshot.reviewRequest,
                  number == nil || request.number == number else { return false }
            reviewLoop.setExpanded(true)
            rowID = nil
        default: return false
        }
        activeTab = .changes
        attentionRevealedTarget = target
        attentionRevealGeneration += 1
        attentionScrollRequest = rowID.map {
            AppKitDiffScrollRequest(targetID: $0, fallbackID: nil, alignment: .top, animated: false, generation: attentionRevealGeneration)
        }
        return true
    }

    var commits: [CommitInfo] = []
    var comparisonRef: String? = nil
    var workingTreeExpanded: Bool = true
    var commitsExpanded: Bool = true

    // Older-history paging — populated lazily by `loadOlder()`.
    // Cleared (and `hasMoreOlder` reset to true) when a refresh finds that
    // HEAD, the comparison ref, or the ahead commits moved, because the
    // divergence cursor may have moved with them.
    var olderCommits: [CommitInfo] = []
    var hasMoreOlder: Bool = true
    var isLoadingOlder: Bool = false
    @ObservationIgnored var commitDisplayGeneration: UInt = 0

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
    var ggStackRemoteError: String? = nil
    var ggStackRemoteEnrichmentPending = false
    var ggStackRemoteMetadataCache: GGStack?
    @ObservationIgnored
    var ggCapabilities: @MainActor () -> GGCapabilities = {
        GGAvailability.shared.capabilities
    }
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
    @ObservationIgnored let ggLandingStore: GGLandingStore
    @ObservationIgnored var didAttemptGGUndoRestore = false
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
    @ObservationIgnored var ggStackRefreshTask: Task<Void, Never>? = nil
    /// Gate reevaluations must join a changed-HEAD local recovery, not race it.
    @ObservationIgnored var ggLocalSnapshotRecoveryTask: Task<Bool?, Never>? = nil
    @ObservationIgnored var ggExplicitStackRefreshID: UUID? = nil
    @ObservationIgnored var ggStackRefreshDeferredUntilMutationEnds = false
    @ObservationIgnored var ggStackRefreshDeferralGeneration: UInt = 0
    /// A refresh result may still arrive after its task was cancelled. Only
    /// the most recently started GG refresh may publish snapshot-derived
    /// stack state.
    @ObservationIgnored var ggStackRefreshGeneration: UInt = 0

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

    var cachedGGStackSnapshot: GGStackSnapshot? {
        guard !ggCommitSelectionIsStale, let ggStack else { return nil }
        return GGStackSnapshot(version: GGStackSnapshot.supportedSchemaVersion, stack: ggStack)
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
    var didInitDefaultTab: Bool = false

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
    @ObservationIgnored var pendingGGLandPrepared: GGPreparedMutation? = nil
    var pendingGGDrop: GGDropPresentation? = nil
    @ObservationIgnored var pendingGGDropPrepared: GGPreparedMutation? = nil
    var pendingGGUnstack: GGUnstackModel? = nil
    @ObservationIgnored var pendingGGUnstackPrepared: GGPreparedMutation? = nil
    var pendingGGCleanAll: Bool = false
    @ObservationIgnored var pendingGGCleanPrepared: GGPreparedMutation? = nil
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

    /// Delivers the completed bulk-resolve outcome to the owning store.
    @ObservationIgnored
    var bulkResolveDidFinish: ((BulkConflictResolveReport) -> Void)? = nil

    /// Task handle for the in-flight bulk resolve so the user can
    /// cancel the agent (SIGTERM via Process cancellation).
    @ObservationIgnored
    var bulkResolveTask: Task<Void, Never>? = nil

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
    var recentBaseBranches: [String] = []

    /// Branches available in this worktree, populated on-demand by
    /// `fetchBranches()`. Used by the base-branch picker.
    var availableBranches: [String] = []
    var isFetchingBranches: Bool = false
    var hasFetchedBranches: Bool = false

    /// Upstream tracking ref of the current branch (e.g. `origin/main`),
    /// resolved during `refreshSyncStatus()`. Used by the base-branch
    /// picker to include the upstream in the smart shortlist.
    var upstreamRef: String? = nil

    let git = GitService()
    let watcher: WorktreeWatcher
    let logger = Logger(subsystem: "io.nlopez.alas", category: "right-pane-state")

    @ObservationIgnored
    private var syncStatusTimer: Task<Void, Never>? = nil

    @ObservationIgnored
    var refreshInFlight = false

    @ObservationIgnored
    var refreshGeneration = 0

    @ObservationIgnored
    var refreshRerunRequested = false

    @ObservationIgnored
    var refreshRerunRequiresReviewLoopRemote = false

    @ObservationIgnored
    var refreshWaiters: [CheckedContinuation<Bool, Never>] = []

    @ObservationIgnored
    var stageMutationWorker: Task<Void, Never>? = nil

    @ObservationIgnored
    var pendingStageMutationsSucceeded = true

    @ObservationIgnored
    var lastReviewLoopRemoteRefreshAt: Date?

    @ObservationIgnored
    var lastReviewLoopRemoteFingerprint: ReviewLoopRemoteFingerprint?

    /// Refresh interval for `syncStatusTimer`. 5 minutes per design;
    /// constant in v1.
    @ObservationIgnored
    private let syncStatusInterval: UInt64 = 5 * 60 * 1_000_000_000 // ns

    @ObservationIgnored
    let reviewLoopRemoteRefreshMinimumInterval: TimeInterval = 45
    @ObservationIgnored var remotePollTask: Task<Void, Never>?
    @ObservationIgnored var remoteHelperSession: RemoteHelperWatchSession?
    @ObservationIgnored let remoteEventDebouncer = DebounceTimer(interval: 0.5, maxWait: 2.0)
    @ObservationIgnored var remoteFingerprint: String?
    nonisolated static let hashObjectBatchSize = 256
    static let remotePollIntervalNanos: UInt64 = 7 * 1_000_000_000
    static let remoteHelperSafetyNetNanos: UInt64 = 5 * 60 * 1_000_000_000

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

    init(
        worktree: Worktree,
        baseBranch: String,
        isFolder: Bool = false,
        ggLandingStore: GGLandingStore = .shared,
        checkpointService: any WorktreeCheckpointServicing = WorktreeCheckpointService(),
        reviewLoop: ReviewLoopState? = nil
    ) {
        self.worktree = worktree
        self.isFolder = isFolder
        self.checkpointService = checkpointService
        self.ggLandingStore = ggLandingStore
        self.baseBranch = baseBranch
        self.currentBranch = worktree.branch
        self.reviewLoop = reviewLoop ?? ReviewLoopState(worktreePath: worktree.path, baseBranch: baseBranch)
        self.mergeOp = MergeOperationState(worktreePath: worktree.path, gitService: GitService())
        self.watcher = WorktreeWatcher(path: worktree.path, watchesGitDir: !isFolder)
        activeTab = defaultTab
        watcher.onChange = { [weak self] in
            Task { @MainActor in
                self?.worktreeDidChange?()
                await self?.refresh()
            }
        }
        remoteEventDebouncer.onFire = { [weak self] in
            Task { @MainActor in
                self?.worktreeDidChange?()
                await self?.refresh()
            }
        }
    }

    var ggMutationCoordinator: GGMutationCoordinator {
        if let coordinator = ggMutationCoordinatorStorage { return coordinator }
        let coordinator = GGMutationCoordinator(
            worktreeId: worktree.id,
            worktreePath: worktree.path.path,
            service: ggService,
            actionState: ggActionState,
            syncJSONLCapability: { [weak self] in self?.ggCapabilities().syncJSONL ?? false },
            landJSONLCapability: { [weak self] in self?.ggCapabilities().landJSONL ?? false },
            context: GGMutationContext(
                loadFreshStack: { [weak self] in
                    guard let self else { throw GGServiceError.commandFailed(stderr: "Worktree is no longer available.") }
                    return try await self.ggService.currentStackSnapshot(
                        worktreePath: self.worktree.path.path
                    )
                },
                loadCurrentBranch: { [weak self] in
                    guard let self else { throw GGServiceError.commandFailed(stderr: "Worktree is no longer available.") }
                    return try await self.git.currentBranch(worktreePath: self.worktree.path)
                },
                loadCurrentHead: { [weak self] in
                    guard let self else { throw GGServiceError.commandFailed(stderr: "Worktree is no longer available.") }
                    return try await self.git.revParseHEAD(worktreePath: self.worktree.path)
                },
                refreshStack: { [weak self] in
                    guard let self else { return }
                    await self.reevaluateGGGate().value
                },
                refreshGitChanges: { [weak self] in await self?.refresh() },
                refreshProviderReviews: { [weak self] in await self?.refresh(forceReviewLoopRemote: true) },
                refreshProjectTopology: { [weak self] in await self?.refreshProjectTopologyAfterGGMutation?() },
                finishPendingStaging: { [weak self] in
                    guard let self else { return false }
                    return await self.finishPendingStageMutations()
                },
                worktreeExists: { [weak self] in
                    guard let self else { return false }
                    return FileManager.default.fileExists(atPath: self.worktree.path.path)
                },
                invalidateInbox: { [weak self] in
                    guard let self else { return }
                    GGInboxStore.shared.invalidate(projectId: self.worktree.projectId)
                },
                selectWorktreeAtPath: { [weak self] path in await self?.selectWorktreeAtPathAfterGGMutation?(path) },
                currentBranch: { [weak self] in self?.currentBranch },
                publishLandEvent: { [ggLandingStore, projectId = worktree.projectId] event in
                    ggLandingStore.receive(event, projectId: projectId)
                }
            )
        )
        ggMutationCoordinatorStorage = coordinator
        return coordinator
    }

    func start() {
        if isFolder {
            if worktree.path.isRemoteAlasPath {
                startRemoteHelperWatching()
                startRemotePolling()
            } else {
                watcher.start()
            }
            Task { @MainActor in await self.refresh() }
            return
        }
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
        ggLocalSnapshotRecoveryTask?.cancel()
        ggLocalSnapshotRecoveryTask = nil
        ggStackRefreshDeferredUntilMutationEnds = false
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
