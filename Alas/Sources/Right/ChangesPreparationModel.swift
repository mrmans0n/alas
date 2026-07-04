import Foundation

struct ChangesPreparationModel: Equatable {
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

    let reviewAction: ReviewAction?
    let draftAction: DraftAction?
    let reviewRequestActions: [ReviewRequestAction]

    var isVisible: Bool {
        reviewAction != nil || draftAction != nil || !reviewRequestActions.isEmpty
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
