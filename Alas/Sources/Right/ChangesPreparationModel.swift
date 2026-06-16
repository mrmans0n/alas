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
        readinessActions: [ReviewReadinessModel.Action]
    ) {
        if let summary = ReviewChangesTriggerSummary.summary(for: changes) {
            reviewAction = ReviewAction(
                title: "Review current changes",
                fileCount: summary.fileCount,
                additions: summary.additions,
                deletions: summary.deletions
            )
        } else {
            reviewAction = nil
        }

        let stagedChanges = changes.filter { $0.stage == .staged }
        if !stagedChanges.isEmpty || hasDraft {
            draftAction = DraftAction(
                title: hasDraft ? "Open draft" : "Draft commit",
                stagedCount: stagedChanges.count,
                additions: stagedChanges.reduce(0) { $0 + $1.add },
                deletions: stagedChanges.reduce(0) { $0 + $1.del },
                hasNonEmptyDraft: draftNonEmpty
            )
        } else {
            draftAction = nil
        }

        reviewRequestAction = Self.compactReviewRequestAction(from: readinessActions)
    }

    private static func compactReviewRequestAction(
        from actions: [ReviewReadinessModel.Action]
    ) -> ReviewRequestAction? {
        for kind in compactActionPriority {
            guard let action = actions.first(where: { $0.kind == kind }) else { continue }
            return ReviewRequestAction(
                kind: action.kind,
                title: action.title,
                isEnabled: action.isEnabled,
                iconName: action.iconName,
                emphasis: action.emphasis
            )
        }
        return nil
    }

    private static let compactActionPriority: [ReviewReadinessActionKind] = [
        .createReviewRequest,
        .pushBranch,
        .openReviewRequest,
        .inspectReviewEvidence,
        .refresh,
    ]
}
