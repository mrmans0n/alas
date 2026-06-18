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
    let reviewRequestAction: ReviewRequestAction?

    var isVisible: Bool {
        reviewAction != nil || draftAction != nil || reviewRequestAction != nil
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
        let builtReviewRequestAction = Self.compactReviewRequestAction(from: readinessActions)
        let effectiveAheadCommitCount = local?.aheadCommitCount ?? aheadCommitCount
        if builtReviewRequestAction?.kind == .refresh,
           builtReviewRequestAction?.isInFlight != true,
           builtReviewAction == nil,
           builtDraftAction == nil,
           effectiveAheadCommitCount == 0 {
            reviewRequestAction = nil
        } else if builtReviewRequestAction?.kind == .pushBranch,
                   builtReviewRequestAction?.isInFlight != true,
                   local?.needsPush == false,
                   builtReviewAction == nil,
                   builtDraftAction == nil {
            reviewRequestAction = nil
        } else {
            reviewRequestAction = builtReviewRequestAction
        }
    }

    private static func compactReviewRequestAction(
        from actions: [ReviewReadinessModel.Action]
    ) -> ReviewRequestAction? {
        if let action = actions.first(where: { $0.isInFlight }) {
            return ReviewRequestAction(
                kind: action.kind,
                title: action.title,
                isEnabled: action.isEnabled,
                isInFlight: action.isInFlight,
                iconName: action.iconName,
                emphasis: action.emphasis
            )
        }

        for kind in compactActionPriority {
            guard let action = actions.first(where: { $0.kind == kind }) else { continue }
            return ReviewRequestAction(
                kind: action.kind,
                title: action.title,
                isEnabled: action.isEnabled,
                isInFlight: action.isInFlight,
                iconName: action.iconName,
                emphasis: action.emphasis
            )
        }
        return nil
    }

    private static let compactActionPriority: [ReviewReadinessActionKind] = [
        .createReviewRequest,
        .pushBranch,
        .inspectReviewEvidence,
        .openReviewRequest,
        .refresh,
    ]
}
