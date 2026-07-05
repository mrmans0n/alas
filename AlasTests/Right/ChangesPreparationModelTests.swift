import Foundation
import Testing
@testable import Alas

struct ChangesPreparationModelTests {
    private typealias Action = ReviewReadinessModel.Action

    private func makeModel(actions: [Action], aheadCommitCount: Int = 1) -> ChangesPreparationModel {
        ChangesPreparationModel(
            changes: [],
            hasDraft: false,
            draftNonEmpty: false,
            aheadCommitCount: aheadCommitCount,
            local: nil,
            readinessActions: actions
        )
    }

    @Test func greenMergePairsMergeAndReviewDiff() {
        let model = makeModel(actions: [
            Action(kind: .merge, title: "Merge PR", isEnabled: true),
            Action(kind: .openReviewRequest, title: "Open PR", isEnabled: true),
            Action(kind: .inspectReviewEvidence, title: "Review diff", isEnabled: true, emphasis: .normal),
        ])

        #expect(model.reviewRequestActions.map(\.kind) == [.merge, .inspectReviewEvidence])
        #expect(model.reviewRequestActions.first?.title == "Merge PR")
        #expect(model.reviewRequestActions.first?.emphasis == .primary)
        #expect(model.reviewRequestActions.last?.title == "Review diff")
        #expect(!model.reviewRequestActions.map(\.kind).contains(.openReviewRequest))
        #expect(model.isVisible)
    }

    @Test func nonGreenCollapsesToSingleAction() {
        let model = makeModel(actions: [
            Action(kind: .openReviewRequest, title: "Open PR", isEnabled: true),
            Action(kind: .inspectReviewEvidence, title: "Inspect", isEnabled: true),
        ])

        #expect(model.reviewRequestActions.map(\.kind) == [.inspectReviewEvidence])
    }

    @Test func refreshOnlyHiddenWhenNothingAhead() {
        let model = makeModel(
            actions: [Action(kind: .refresh, title: "Refresh", isEnabled: true)],
            aheadCommitCount: 0
        )
        #expect(model.reviewRequestActions.isEmpty)
        #expect(!model.isVisible)
    }
}
