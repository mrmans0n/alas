import Foundation

enum GGChangesPreparationAction: Equatable, Sendable {
    case newStackCommit
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

        var isEnabled: Bool { disabledReason == nil }
    }

    let reviewAction: ReviewAction?
    let draftAction: DraftAction?
    let reviewRequestActions: [ReviewRequestAction]
    let reconciliationAction: GGStackReadinessModel.Action?
    let syncProgress: GGSyncProgressPresentation?
    let ggActions: [GGAction]
    let mutationError: String?

    var primaryAction: ReviewAction? { reviewAction }

    var isVisible: Bool {
        if !ggActions.isEmpty {
            return mutationError != nil
                || reconciliationAction != nil
                || syncProgress != nil
                || reviewAction != nil
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
        readinessActions: [ReviewReadinessModel.Action]
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
        reconciliationAction = nil
        syncProgress = nil
        ggActions = []
        mutationError = nil
        let builtActions = Self.compactReviewRequestActions(from: readinessActions)
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
        newCommitDisabledReason: String? = nil,
        mutationError: String? = nil,
        reconciliationAction: GGStackReadinessModel.Action? = nil,
        syncProgress: GGSyncProgressPresentation? = nil
    ) -> ChangesPreparationModel {
        let summary = ReviewChangesTriggerSummary.summary(for: changes)
        let stagedChanges = changes.filter { $0.stage == .staged }
        let staged = StagedStats(
            files: stagedChanges.count,
            insertions: stagedChanges.reduce(0) { $0 + $1.add },
            deletions: stagedChanges.reduce(0) { $0 + $1.del }
        )
        return makeGG(
            staged: staged,
            hasDraft: hasDraft,
            capabilities: capabilities,
            hasLoadedCommit: hasLoadedCommit,
            mutationDisabledReason: mutationDisabledReason,
            newCommitDisabledReason: newCommitDisabledReason,
            mutationError: mutationError,
            reconciliationAction: reconciliationAction,
            syncProgress: syncProgress,
            reviewSummary: summary
        )
    }

    static func makeGG(
        staged: StagedStats,
        hasDraft: Bool,
        capabilities: GGCapabilities,
        hasLoadedCommit: Bool = true,
        mutationDisabledReason: String? = nil,
        newCommitDisabledReason: String? = nil,
        mutationError: String? = nil,
        reconciliationAction: GGStackReadinessModel.Action? = nil,
        syncProgress: GGSyncProgressPresentation? = nil
    ) -> ChangesPreparationModel {
        let summary = staged.hasChanges
            ? ReviewChangesTriggerSummary(
                fileCount: staged.files,
                additions: staged.insertions,
                deletions: staged.deletions
            )
            : nil
        return makeGG(
            staged: staged,
            hasDraft: hasDraft,
            capabilities: capabilities,
            hasLoadedCommit: hasLoadedCommit,
            mutationDisabledReason: mutationDisabledReason,
            newCommitDisabledReason: newCommitDisabledReason,
            mutationError: mutationError,
            reconciliationAction: reconciliationAction,
            syncProgress: syncProgress,
            reviewSummary: summary
        )
    }

    func ggAction(_ kind: GGChangesPreparationAction) -> GGAction? {
        ggActions.first { $0.kind == kind }
    }

    private static func makeGG(
        staged: StagedStats,
        hasDraft: Bool,
        capabilities: GGCapabilities,
        hasLoadedCommit: Bool,
        mutationDisabledReason: String?,
        newCommitDisabledReason: String?,
        mutationError: String?,
        reconciliationAction: GGStackReadinessModel.Action?,
        syncProgress: GGSyncProgressPresentation?,
        reviewSummary: ReviewChangesTriggerSummary?
    ) -> ChangesPreparationModel {
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
            syncProgress: syncProgress,
            mutationError: mutationError,
            ggActions: [
                GGAction(
                    kind: .newStackCommit,
                    title: "New stack commit",
                    stats: staged,
                    hasNonEmptyDraft: hasDraft,
                    disabledReason: effectiveNewCommitDisabledReason
                ),
                GGAction(
                    kind: .amendCurrent,
                    title: "Amend current",
                    stats: staged,
                    hasNonEmptyDraft: false,
                    disabledReason: amendDisabledReason
                ),
                GGAction(
                    kind: .absorbIntoStack,
                    title: "Absorb into stack",
                    stats: staged,
                    hasNonEmptyDraft: false,
                    disabledReason: rewriteDisabledReason
                ),
            ]
        )
    }

    private init(
        reviewAction: ReviewAction?,
        reconciliationAction: GGStackReadinessModel.Action?,
        syncProgress: GGSyncProgressPresentation?,
        mutationError: String?,
        ggActions: [GGAction]
    ) {
        self.reviewAction = reviewAction
        draftAction = nil
        reviewRequestActions = []
        self.reconciliationAction = reconciliationAction
        self.syncProgress = syncProgress
        self.mutationError = mutationError
        self.ggActions = ggActions
    }

    private static func compactReviewRequestActions(
        from actions: [ReviewReadinessModel.Action]
    ) -> [ReviewRequestAction] {
        if let merge = actions.first(where: { $0.kind == .merge }) {
            var pair = [convert(merge)]
            if let review = actions.first(where: { $0.kind == .inspectReviewEvidence }) {
                pair.append(convert(review))
            }
            return pair
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
        guard actions.count == 1, let only = actions.first else { return actions }
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
