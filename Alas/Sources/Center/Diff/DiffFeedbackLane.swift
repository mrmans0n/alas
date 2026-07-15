enum DiffFeedbackLane: Equatable, Sendable {
    case left
    case right
    case full
}

enum DiffFeedbackLaneResolver {
    static func lane(for anchor: DiffReviewLineAnchor) -> DiffFeedbackLane {
        let changedSides = Set(anchor.selectedLines.lazy.filter(\.isChange).map(\.side))

        if changedSides.contains(.new) {
            return .right
        }
        if changedSides.contains(.old) {
            return .left
        }
        return lane(for: anchor.side)
    }

    static func lane(for comment: ReviewDraftComment) -> DiffFeedbackLane {
        lane(for: comment.side)
    }

    static func lane(for feedback: DiffReviewInlineFeedback) -> DiffFeedbackLane {
        lane(for: feedback.anchor.side)
    }

    static func lane(for thread: DiffInlineCommentThread) -> DiffFeedbackLane {
        thread.isOldSide ? .left : .right
    }

    static func lane(for annotation: DiffInlineAnnotation) -> DiffFeedbackLane {
        lane(for: DiffReviewInlineFeedbackSide.new)
    }

    static func lane(for side: DiffReviewInlineFeedbackSide) -> DiffFeedbackLane {
        switch side {
        case .old:
            .left
        case .new, .unknown:
            .right
        }
    }
}
