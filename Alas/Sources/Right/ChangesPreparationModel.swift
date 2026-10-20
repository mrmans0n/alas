import Foundation

enum GGChangesPreparationAction: Equatable, Sendable {
    case newStackCommit
    case commitAndSync
    case amendCurrent
    case absorbIntoStack
}

struct ChangesPreparationModel: Equatable {
    struct StagedStats: Equatable, Sendable {
        let files: Int
        let insertions: Int
        let deletions: Int

        static let zero = StagedStats(files: 0, insertions: 0, deletions: 0)

        var hasChanges: Bool { files > 0 }
    }

    struct ReviewAction: Equatable {
        let title: String
        let fileCount: Int
        let additions: Int?
        let deletions: Int?
    }

    struct DraftAction: Equatable {
        let title: String
        let stagedCount: Int
        let additions: Int
        let deletions: Int
        let hasNonEmptyDraft: Bool
    }

    struct ReviewRequestAction: Equatable {
        let kind: ReviewReadinessActionKind
        let title: String
        let isEnabled: Bool
        let isInFlight: Bool
        let iconName: String
        let emphasis: ReviewReadinessModel.Action.Emphasis
    }

    struct GGAction: Equatable {
        let kind: GGChangesPreparationAction
        let title: String
        let stats: StagedStats
        let hasNonEmptyDraft: Bool
        let disabledReason: String?
        let isInFlight: Bool

        var isEnabled: Bool { disabledReason == nil }
    }

    struct GGLandingStatus: Equatable {
        let completed: Int
        let total: Int
        let reviewNumber: Int?
        let detail: String
    }

    enum GGStackStatus: Equatable {
        case unavailable, loading, empty, refreshingRemote, remoteUnavailable
        case synced(commits: Int)
        case unsynced(commits: Int)

        var text: String {
            switch self {
            case .unavailable: "Stack unavailable"
            case .loading: "Loading stack…"
            case .empty: "No stack commits"
            case .refreshingRemote: "Refreshing remote status…"
            case .remoteUnavailable: "Remote status unavailable"
            case .synced(let count): count == 1 ? "1 commit synced" : "\(count) commits synced"
            case .unsynced(let count): count == 1 ? "1 commit not synced" : "\(count) commits not synced"
            }
        }
    }

    let reviewAction: ReviewAction?
    let draftAction: DraftAction?
    let publishAction: CommitPublishAvailability?
    let reviewRequestActions: [ReviewRequestAction]
    let reconciliationAction: GGStackReadinessModel.Action?
    let landingStatus: GGLandingStatus?
    let syncProgress: GGSyncProgressPresentation?
    let canDismissSyncFailure: Bool
    let ggActions: [GGAction]
    let mutationError: String?
    let ggStackStatus: GGStackStatus?
    let hasLocalChanges: Bool

    var primaryAction: ReviewAction? { reviewAction }

    var showsGGCommitActions: Bool {
        hasLocalChanges || ggActions.contains {
            $0.hasNonEmptyDraft || $0.isInFlight
        }
    }

    /// No actions of its own: the card renders only its Review button.
    static let reviewScopesOnly = ChangesPreparationModel(
        changes: [],
        hasDraft: false,
        draftNonEmpty: false,
        readinessActions: []
    )

    var isVisible: Bool {
        if landingStatus != nil {
            return true
        }
        if !ggActions.isEmpty {
            return mutationError != nil
                || reconciliationAction != nil
                || syncProgress != nil
                || reviewAction != nil
                || ggActions.contains(where: \.isInFlight)
                || ggAction(.newStackCommit)?.isEnabled == true
        }
        return reviewAction != nil || draftAction != nil || !reviewRequestActions.isEmpty
    }

    init(
        changes: [ChangedFile],
        hasDraft: Bool,
        draftNonEmpty: Bool,
        aheadCommitCount: Int = 0,
        local: ReviewLoopLocalState? = nil,
        readinessActions: [ReviewReadinessModel.Action],
        publishAvailability: CommitPublishAvailability? = nil,
        pushAndCreateReviewRequestLabel: String? = nil,
        pushAndCreateReviewRequestInFlight: Bool = false
    ) {
        let builtReviewAction: ReviewAction?
        if let summary = ReviewChangesTriggerSummary.summary(for: changes) {
            builtReviewAction = ReviewAction(
                title: "Review current changes",
                fileCount: summary.fileCount,
                additions: summary.additions,
                deletions: summary.deletions
            )
        } else {
            builtReviewAction = nil
        }

        let stagedChanges = changes.filter { $0.stage == .staged }
        let builtDraftAction: DraftAction?
        if !stagedChanges.isEmpty || (hasDraft && draftNonEmpty) {
            builtDraftAction = DraftAction(
                title: hasDraft ? "Open draft" : "Draft commit",
                stagedCount: stagedChanges.count,
                additions: stagedChanges.reduce(0) { $0 + $1.add },
                deletions: stagedChanges.reduce(0) { $0 + $1.del },
                hasNonEmptyDraft: draftNonEmpty
            )
        } else {
            builtDraftAction = nil
        }

        reviewAction = builtReviewAction
        draftAction = builtDraftAction
        publishAction = builtDraftAction == nil ? nil : publishAvailability
        reconciliationAction = nil
        landingStatus = nil
        syncProgress = nil
        canDismissSyncFailure = false
        ggActions = []
        mutationError = nil
        ggStackStatus = nil
        hasLocalChanges = !changes.isEmpty
        let availableActions = publishAction == nil ? readinessActions : readinessActions.filter {
            $0.kind != .pushBranch && $0.kind != .createReviewRequest
        }
        let builtActions = Self.compactReviewRequestActions(
            from: availableActions,
            pushAndCreateReviewRequestLabel: pushAndCreateReviewRequestLabel,
            pushAndCreateReviewRequestInFlight: pushAndCreateReviewRequestInFlight
        )
        let effectiveAheadCommitCount = local?.aheadCommitCount ?? aheadCommitCount
        reviewRequestActions = Self.applyingHideRules(
            builtActions,
            hasReviewAction: builtReviewAction != nil,
            hasDraftAction: builtDraftAction != nil,
            local: local,
            aheadCommitCount: effectiveAheadCommitCount
        )
    }

    static func makeGG(
        changes: [ChangedFile],
        hasDraft: Bool,
        capabilities: GGCapabilities,
        hasLoadedCommit: Bool = true,
        mutationDisabledReason: String? = nil,
        inFlightAction: GGStackActionKind? = nil,
        newCommitDisabledReason: String? = nil,
        mutationError: String? = nil,
        reconciliationAction: GGStackReadinessModel.Action? = nil,
        landingStatus: GGLandingStatus? = nil,
        syncProgress: GGSyncProgressPresentation? = nil,
        canDismissSyncFailure: Bool = false,
        stackStatus: GGStackStatus? = nil
    ) -> ChangesPreparationModel {
        let summary = ReviewChangesTriggerSummary.summary(for: changes)
        let stagedChanges = changes.filter { $0.stage == .staged }
        let staged = StagedStats(
            files: stagedChanges.count,
            insertions: stagedChanges.reduce(0) { $0 + $1.add },
            deletions: stagedChanges.reduce(0) { $0 + $1.del }
        )
        return makeGG(
            hasLocalChanges: !changes.isEmpty,
            staged: staged,
            hasDraft: hasDraft,
            capabilities: capabilities,
            hasLoadedCommit: hasLoadedCommit,
            mutationDisabledReason: mutationDisabledReason,
            inFlightAction: inFlightAction,
            newCommitDisabledReason: newCommitDisabledReason,
            mutationError: mutationError,
            reconciliationAction: reconciliationAction,
            landingStatus: landingStatus,
            syncProgress: syncProgress,
            canDismissSyncFailure: canDismissSyncFailure,
            reviewSummary: summary,
            stackStatus: stackStatus
        )
    }

    static func makeGG(
        staged: StagedStats,
        hasDraft: Bool,
        capabilities: GGCapabilities,
        hasLoadedCommit: Bool = true,
        mutationDisabledReason: String? = nil,
        inFlightAction: GGStackActionKind? = nil,
        newCommitDisabledReason: String? = nil,
        mutationError: String? = nil,
        reconciliationAction: GGStackReadinessModel.Action? = nil,
        landingStatus: GGLandingStatus? = nil,
        syncProgress: GGSyncProgressPresentation? = nil,
        canDismissSyncFailure: Bool = false,
        stackStatus: GGStackStatus? = nil
    ) -> ChangesPreparationModel {
        let summary = staged.hasChanges
            ? ReviewChangesTriggerSummary(
                fileCount: staged.files,
                additions: staged.insertions,
                deletions: staged.deletions
            )
            : nil
        return makeGG(
            hasLocalChanges: staged.hasChanges,
            staged: staged,
            hasDraft: hasDraft,
            capabilities: capabilities,
            hasLoadedCommit: hasLoadedCommit,
            mutationDisabledReason: mutationDisabledReason,
            inFlightAction: inFlightAction,
            newCommitDisabledReason: newCommitDisabledReason,
            mutationError: mutationError,
            reconciliationAction: reconciliationAction,
            landingStatus: landingStatus,
            syncProgress: syncProgress,
            canDismissSyncFailure: canDismissSyncFailure,
            reviewSummary: summary,
            stackStatus: stackStatus
        )
    }

    func ggAction(_ kind: GGChangesPreparationAction) -> GGAction? {
        ggActions.first { $0.kind == kind }
    }

    private static func makeGG(
        hasLocalChanges: Bool,
        staged: StagedStats,
        hasDraft: Bool,
        capabilities: GGCapabilities,
        hasLoadedCommit: Bool,
        mutationDisabledReason: String?,
        inFlightAction: GGStackActionKind?,
        newCommitDisabledReason: String?,
        mutationError: String?,
        reconciliationAction: GGStackReadinessModel.Action?,
        landingStatus: GGLandingStatus?,
        syncProgress: GGSyncProgressPresentation?,
        canDismissSyncFailure: Bool,
        reviewSummary: ReviewChangesTriggerSummary?,
        stackStatus: GGStackStatus?
    ) -> ChangesPreparationModel {
        if let landingStatus {
            return ChangesPreparationModel(
                landingStatus: landingStatus,
                mutationError: mutationError
            )
        }
        let reviewAction = reviewSummary.map {
            ReviewAction(
                title: "Review current changes",
                fileCount: $0.fileCount,
                additions: $0.additions,
                deletions: $0.deletions
            )
        }
        let effectiveNewCommitDisabledReason = mutationDisabledReason
            ?? newCommitDisabledReason
            ?? (staged.hasChanges || hasDraft ? nil : "Stage changes first")
        let rewriteDisabledReason = mutationDisabledReason
            ?? (hasLoadedCommit ? nil : "Create the first stack commit.")
            ?? (staged.hasChanges ? nil : "Stage changes first")
        let amendDisabledReason = mutationDisabledReason
            ?? (hasLoadedCommit ? nil : "Create the first stack commit.")
            ?? (capabilities.stagedOnlyAmend
                ? rewriteDisabledReason
                : "Update GG to amend staged changes safely")
        return ChangesPreparationModel(
            reviewAction: reviewAction,
            reconciliationAction: reconciliationAction,
            landingStatus: nil,
            syncProgress: syncProgress,
            canDismissSyncFailure: canDismissSyncFailure,
            mutationError: mutationError,
            ggStackStatus: stackStatus,
            hasLocalChanges: hasLocalChanges,
            ggActions: [
                GGAction(
                    kind: .newStackCommit,
                    title: "New stack commit",
                    stats: staged,
                    hasNonEmptyDraft: hasDraft,
                    disabledReason: effectiveNewCommitDisabledReason,
                    isInFlight: false
                ),
                GGAction(
                    kind: .commitAndSync,
                    title: "Commit & sync",
                    stats: staged,
                    hasNonEmptyDraft: hasDraft,
                    disabledReason: effectiveNewCommitDisabledReason,
                    isInFlight: false
                ),
                GGAction(
                    kind: .amendCurrent,
                    title: "Amend current",
                    stats: staged,
                    hasNonEmptyDraft: false,
                    disabledReason: amendDisabledReason,
                    isInFlight: inFlightAction == .amendCurrent
                ),
                GGAction(
                    kind: .absorbIntoStack,
                    title: "Absorb into stack",
                    stats: staged,
                    hasNonEmptyDraft: false,
                    disabledReason: rewriteDisabledReason,
                    isInFlight: inFlightAction == .absorbStaged
                ),
            ]
        )
    }

    private init(
        reviewAction: ReviewAction?,
        reconciliationAction: GGStackReadinessModel.Action?,
        landingStatus: GGLandingStatus?,
        syncProgress: GGSyncProgressPresentation?,
        canDismissSyncFailure: Bool,
        mutationError: String?,
        ggStackStatus: GGStackStatus?,
        hasLocalChanges: Bool,
        ggActions: [GGAction]
    ) {
        self.reviewAction = reviewAction
        draftAction = nil
        publishAction = nil
        reviewRequestActions = []
        self.reconciliationAction = reconciliationAction
        self.landingStatus = landingStatus
        self.syncProgress = syncProgress
        self.canDismissSyncFailure = canDismissSyncFailure
        self.mutationError = mutationError
        self.ggStackStatus = ggStackStatus
        self.hasLocalChanges = hasLocalChanges
        self.ggActions = ggActions
    }

    private init(
        landingStatus: GGLandingStatus,
        mutationError: String?
    ) {
        reviewAction = nil
        draftAction = nil
        publishAction = nil
        reviewRequestActions = []
        reconciliationAction = nil
        self.landingStatus = landingStatus
        syncProgress = nil
        canDismissSyncFailure = false
        self.mutationError = mutationError
        ggActions = []
        ggStackStatus = nil
        hasLocalChanges = false
    }

    private static func compactReviewRequestActions(
        from actions: [ReviewReadinessModel.Action],
        pushAndCreateReviewRequestLabel: String?,
        pushAndCreateReviewRequestInFlight: Bool
    ) -> [ReviewRequestAction] {
        if let merge = actions.first(where: { $0.kind == .merge }) {
            var pair = [convert(merge)]
            if let review = actions.first(where: { $0.kind == .inspectReviewEvidence }) {
                pair.append(convert(review))
            }
            return pair
        }
        if pushAndCreateReviewRequestInFlight, let label = pushAndCreateReviewRequestLabel {
            return [convert(ReviewReadinessModel.Action(
                kind: .pushAndCreateReviewRequest,
                title: "Push & create \(label)",
                isEnabled: false,
                isInFlight: true
            ))]
        }
        if let label = pushAndCreateReviewRequestLabel,
           let push = actions.first(where: { $0.kind == .pushBranch }),
           push.isEnabled, !push.isInFlight {
            return [
                convert(push),
                convert(ReviewReadinessModel.Action(
                    kind: .pushAndCreateReviewRequest,
                    title: "Push & create \(label)",
                    isEnabled: true
                )),
            ]
        }
        if let single = compactSingleAction(from: actions) {
            return [single]
        }
        return []
    }

    private static func compactSingleAction(
        from actions: [ReviewReadinessModel.Action]
    ) -> ReviewRequestAction? {
        if let action = actions.first(where: { $0.isInFlight }) {
            return convert(action)
        }
        for kind in compactActionPriority {
            guard let action = actions.first(where: { $0.kind == kind }) else { continue }
            return convert(action)
        }
        return nil
    }

    private static func convert(_ action: ReviewReadinessModel.Action) -> ReviewRequestAction {
        ReviewRequestAction(
            kind: action.kind,
            title: action.title,
            isEnabled: action.isEnabled,
            isInFlight: action.isInFlight,
            iconName: action.iconName,
            emphasis: action.emphasis
        )
    }

    private static func applyingHideRules(
        _ actions: [ReviewRequestAction],
        hasReviewAction: Bool,
        hasDraftAction: Bool,
        local: ReviewLoopLocalState?,
        aheadCommitCount: Int
    ) -> [ReviewRequestAction] {
        guard let only = actions.first else { return actions }
        if only.kind == .refresh,
           !only.isInFlight,
           !hasReviewAction,
           !hasDraftAction,
           aheadCommitCount == 0 {
            return []
        }
        if only.kind == .pushBranch,
           !only.isInFlight,
           !hasReviewAction,
           !hasDraftAction,
           pushHasNothingToPush(local: local, aheadCommitCount: aheadCommitCount) {
            return []
        }
        return actions
    }

    private static let compactActionPriority: [ReviewReadinessActionKind] = [
        // `.merge` is handled by the pair path before the single-action
        // fallback runs, so this entry is defensive and never actually matches.
        .merge,
        .createReviewRequest,
        .pushBranch,
        .inspectReviewEvidence,
        .openReviewRequest,
        .refresh,
    ]

    /// A `pushBranch` action is only useful when there's something to push.
    /// `GitService.needsPush` returns `true` whenever the branch has no
    /// upstream (so a fresh branch with no commits still reports "needs
    /// push"), which surfaces a no-op Push button on clean worktrees. Hide
    /// it when there's no upstream and no commits ahead of base — pushing
    /// in that state has nothing to send. When an upstream exists, trust
    /// `needsPush` since `@{u}..HEAD` reflects real unpushed commits.
    private static func pushHasNothingToPush(
        local: ReviewLoopLocalState?,
        aheadCommitCount: Int
    ) -> Bool {
        guard let local else { return aheadCommitCount == 0 }
        if local.needsPush == false { return true }
        return !local.hasUpstream && local.aheadCommitCount == 0
    }
}

/// Review targets in the Prepare card's review menu, between the primary
/// button (every uncommitted change) and the palette catch-all.
enum ChangesReviewScopeOption: Equatable {
    /// A pull/merge request on the branch's code host.
    struct HostedReview: Equatable {
        let remote: CodeHostRemote
        let number: Int
        let title: String
    }

    /// The branch's commits since it forked from `comparisonRef`, as one diff.
    case branchCommits(comparisonRef: String, commitCount: Int)
    /// The branch's commits plus every uncommitted change, as one diff.
    case branchWithLocalChanges(comparisonRef: String, commitCount: Int)
    /// What changed in the working tree since feedback last went to an agent.
    case sinceLastReview(ReviewedWorkingTreeSnapshot)
    /// The staged half of a partially staged working tree.
    case stagedOnly(fileCount: Int)
    case hostedReview(HostedReview)

    /// `canSnapshotWorkingTree` is false for remote worktrees: the combined
    /// diff snapshots the working tree through a scratch index on this Mac.
    static func options(
        changes: [ChangedFile],
        commitCount: Int,
        comparisonRef: String?,
        canSnapshotWorkingTree: Bool = true,
        lastReview: ReviewedWorkingTreeSnapshot? = nil,
        hostedReviews: [HostedReview] = []
    ) -> [Self] {
        var options: [Self] = []
        if let comparisonRef, commitCount > 0 {
            options.append(.branchCommits(comparisonRef: comparisonRef, commitCount: commitCount))
            if !changes.isEmpty, canSnapshotWorkingTree {
                options.append(.branchWithLocalChanges(comparisonRef: comparisonRef, commitCount: commitCount))
            }
        }
        if let lastReview {
            options.append(.sinceLastReview(lastReview))
        }
        // With nothing unstaged, staged-only is the primary button's diff.
        let stagedPaths = Set(changes.filter { $0.stage == .staged }.map(\.path))
        if !stagedPaths.isEmpty, changes.contains(where: { $0.stage == .unstaged }) {
            options.append(.stagedOnly(fileCount: stagedPaths.count))
        }
        options.append(contentsOf: hostedReviews.map(Self.hostedReview))
        return options
    }

    /// The open requests worth reviewing: every unmerged gg stack entry with
    /// one, else the branch's own request.
    static func hostedReviews(
        stack: GGStack?,
        stackRemote: CodeHostRemote?,
        branchRequest: ReviewRequest?
    ) -> [HostedReview] {
        if let stack {
            guard let stackRemote else { return [] }
            return stack.entries.compactMap { entry in
                guard let number = entry.prNumber, entry.prState != .merged, entry.prState != .closed else { return nil }
                return HostedReview(remote: stackRemote, number: number, title: entry.title)
            }
        }
        guard let branchRequest, branchRequest.state == .open else { return [] }
        return [HostedReview(remote: branchRequest.remote, number: branchRequest.number, title: branchRequest.title)]
    }

    var id: String {
        switch self {
        case .branchCommits: "branch-commits"
        case .branchWithLocalChanges: "branch-with-local-changes"
        case .sinceLastReview: "since-last-review"
        case .stagedOnly: "staged"
        case .hostedReview(let review): "hosted-\(review.number)"
        }
    }

    func title(now: Date = Date()) -> String {
        switch self {
        case .branchCommits(_, let commitCount):
            return "Review Branch Commits (\(commitCount))"
        case .branchWithLocalChanges(_, let commitCount):
            return "Review Branch Commits (\(commitCount)) + Uncommitted"
        case .sinceLastReview(let snapshot):
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            let age = formatter.localizedString(for: min(snapshot.capturedAt, now), relativeTo: now)
            return "Review Changes Since Last Review (\(age))"
        case .stagedOnly(let fileCount):
            return "Review Staged Only (\(fileCount) \(fileCount == 1 ? "file" : "files"))"
        case .hostedReview(let review):
            let prefix = review.remote.kind.reviewRequestNumberPrefix
            let title = review.title.count > 60 ? review.title.prefix(59) + "…" : review.title
            return "Review \(prefix)\(review.number) · \(title)"
        }
    }

    var accessibilityIdentifier: String { "changes-preparation-review-\(id)" }

    /// Resolves the session target, pinning the comparison ref (and HEAD for
    /// commits-only) to SHAs the way the review palette does, so a stored
    /// review keeps its merge base when the ref moves.
    func target(
        worktree: Worktree,
        git: GitService = GitService(),
        providers: CodeHostProviderRegistry = .live()
    ) async throws -> ReviewSessionTarget {
        switch self {
        case .branchCommits(let comparisonRef, _):
            let headSHA = try await git.headSHA(at: worktree.path)
            let baseSHA = try await git.resolveRevision(at: worktree.path, ref: comparisonRef)
            return ReviewScopeSelection.target(
                for: .branch(name: comparisonRef),
                worktreeID: worktree.id,
                repositoryPath: worktree.path,
                headSHA: headSHA,
                branchBaseSHA: baseSHA
            )
        case .branchWithLocalChanges(let comparisonRef, _):
            let baseSHA = try await git.resolveRevision(at: worktree.path, ref: comparisonRef)
            return ReviewScopeSelection.target(
                for: .branchWithLocalChanges(name: comparisonRef),
                worktreeID: worktree.id,
                repositoryPath: worktree.path,
                branchBaseSHA: baseSHA
            )
        case .sinceLastReview(let snapshot):
            let exists = try await Process.git(["cat-file", "-e", "\(snapshot.tree)^{tree}"], cwd: worktree.path)
            guard exists.exitCode == 0 else { throw ChangesReviewScopeError.snapshotPruned }
            return .sinceSnapshot(worktreeID: worktree.id, repositoryPath: worktree.path, tree: snapshot.tree)
        case .stagedOnly:
            return ReviewScopeSelection.target(
                for: .staged,
                worktreeID: worktree.id,
                repositoryPath: worktree.path
            )
        case .hostedReview(let review):
            guard let provider = providers.provider(for: review.remote.kind) else {
                throw ChangesReviewScopeError.unsupportedHost(review.remote.kind)
            }
            // Fetch fresh so the session pins the request's current head.
            let request = try await provider.reviewRequest(remote: review.remote, number: review.number, cwd: worktree.path)
            return .reviewRequest(
                worktreeID: worktree.id,
                repositoryPath: worktree.path,
                provider: request.provider,
                host: request.remote.host,
                repositorySlug: request.remote.repositorySlug,
                number: request.number,
                url: request.url,
                title: request.title,
                headSHA: request.headSHA
            )
        }
    }
}

enum ChangesReviewScopeError: LocalizedError, Equatable {
    case snapshotPruned
    case unsupportedHost(CodeHostKind)

    var errorDescription: String? {
        switch self {
        case .snapshotPruned:
            "The last review's snapshot is gone from the repository, likely pruned by git gc."
        case .unsupportedHost(let kind):
            "\(kind.displayName) reviews are not supported yet."
        }
    }
}
