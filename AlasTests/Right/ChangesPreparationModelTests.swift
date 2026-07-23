import Foundation
import Testing
@testable import Alas

struct ChangesPreparationModelTests {
    private typealias Action = ReviewReadinessModel.Action
    private let stagedOnlyCapabilities = GGCapabilities(
        structuredSplit: false,
        keepCurrentUnstack: false,
        stagedOnlyAmend: true
    )

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

    @Test func nonGGPreparationKeepsExistingActions() {
        let model = ChangesPreparationModel(
            changes: [changedFile("Sources/App.swift", stage: .staged, add: 3, del: 1)],
            hasDraft: false,
            draftNonEmpty: false,
            readinessActions: []
        )

        #expect(model.reviewAction?.title == "Review current changes")
        #expect(model.draftAction?.title == "Draft commit")
        #expect(model.ggActions.isEmpty)
    }

    @Test func ggPreparationShowsReviewAndThreeDestinations() {
        let model = ChangesPreparationModel.makeGG(
            staged: .init(files: 2, insertions: 8, deletions: 3),
            hasDraft: false,
            capabilities: stagedOnlyCapabilities
        )

        #expect(model.primaryAction?.title == "Review current changes")
        #expect(model.ggActions.map(\.kind) == [.newStackCommit, .amendCurrent, .absorbIntoStack])
        #expect(model.ggActions.map(\.title) == ["New stack commit", "Amend current", "Absorb into stack"])
        #expect(model.ggActions.allSatisfy { $0.isEnabled })
    }

    @Test func ggRewriteDestinationsRequireStagedChanges() {
        let model = ChangesPreparationModel.makeGG(
            staged: .zero,
            hasDraft: true,
            capabilities: stagedOnlyCapabilities
        )

        #expect(model.ggAction(.newStackCommit)?.isEnabled == true)
        #expect(model.ggAction(.amendCurrent)?.disabledReason == "Stage changes first")
        #expect(model.ggAction(.absorbIntoStack)?.disabledReason == "Stage changes first")
    }

    @Test func ggRewriteDestinationsShowStagedStatistics() {
        let model = ChangesPreparationModel.makeGG(
            staged: .init(files: 2, insertions: 8, deletions: 3),
            hasDraft: false,
            capabilities: stagedOnlyCapabilities
        )

        #expect(model.ggAction(.amendCurrent)?.stats == .init(files: 2, insertions: 8, deletions: 3))
        #expect(model.ggAction(.absorbIntoStack)?.stats == .init(files: 2, insertions: 8, deletions: 3))
    }

    @Test func emptyGGPreparationIsHiddenButKeepsStableDestinations() {
        let model = ChangesPreparationModel.makeGG(
            staged: .zero,
            hasDraft: false,
            capabilities: stagedOnlyCapabilities
        )

        #expect(model.ggActions.map(\.kind) == [.newStackCommit, .amendCurrent, .absorbIntoStack])
        #expect(!model.ggActions.contains { $0.isEnabled })
        #expect(!model.isVisible)
    }

    @Test func ggReconciliationMakesEmptyPreparationVisible() {
        let reconciliationAction = GGStackReadinessModel.Action(
            kind: .sync,
            title: "Sync stack",
            detail: nil,
            isEnabled: true,
            isInFlight: false,
            emphasis: .primary
        )
        let model = ChangesPreparationModel.makeGG(
            staged: .zero,
            hasDraft: false,
            capabilities: stagedOnlyCapabilities,
            reconciliationAction: reconciliationAction
        )

        #expect(model.reconciliationAction == reconciliationAction)
        #expect(model.isVisible)
    }

    @Test func synchronizedEmptyGGPreparationRemainsHidden() {
        let model = ChangesPreparationModel.makeGG(
            staged: .zero,
            hasDraft: false,
            capabilities: stagedOnlyCapabilities,
            reconciliationAction: nil
        )

        #expect(model.reconciliationAction == nil)
        #expect(!model.isVisible)
    }

    @Test func ggReconciliationPreservesReadinessPresentation() {
        let reconciliationAction = GGStackReadinessModel.Action(
            kind: .sync,
            title: "Sync stack",
            detail: "Includes rebase onto main",
            isEnabled: false,
            isInFlight: true,
            emphasis: .primary
        )
        let model = ChangesPreparationModel.makeGG(
            staged: .zero,
            hasDraft: false,
            capabilities: stagedOnlyCapabilities,
            reconciliationAction: reconciliationAction
        )

        #expect(model.reconciliationAction == reconciliationAction)
    }

    @Test func oldGGDisablesOnlyUnsafeAmendWithUpdateReason() {
        let model = ChangesPreparationModel.makeGG(
            staged: .init(files: 1, insertions: 2, deletions: 1),
            hasDraft: false,
            capabilities: GGCapabilities(structuredSplit: false, keepCurrentUnstack: false)
        )

        #expect(model.ggAction(.newStackCommit)?.isEnabled == true)
        #expect(model.ggAction(.absorbIntoStack)?.isEnabled == true)
        #expect(model.ggAction(.amendCurrent)?.disabledReason == "Update GG to amend staged changes safely")
    }

    @Test func pausedGGOperationDisablesEveryMutationDestination() {
        let model = ChangesPreparationModel.makeGG(
            staged: .init(files: 1, insertions: 2, deletions: 1),
            hasDraft: true,
            capabilities: stagedOnlyCapabilities,
            mutationDisabledReason: "Continue or abort the paused GG operation first."
        )

        #expect(model.ggActions.allSatisfy { !$0.isEnabled })
        #expect(model.ggActions.allSatisfy {
            $0.disabledReason == "Continue or abort the paused GG operation first."
        })
    }

    @Test func nonHeadCheckoutDisablesOnlyNewStackCommit() {
        let model = ChangesPreparationModel.makeGG(
            staged: .init(files: 1, insertions: 2, deletions: 1),
            hasDraft: true,
            capabilities: stagedOnlyCapabilities,
            newCommitDisabledReason: "Checkout the stack head to create a new stack commit."
        )

        #expect(model.ggAction(.newStackCommit)?.disabledReason ==
            "Checkout the stack head to create a new stack commit.")
        #expect(model.ggAction(.amendCurrent)?.isEnabled == true)
        #expect(model.ggAction(.absorbIntoStack)?.isEnabled == true)
    }

    @Test func globalMutationGateTakesPriorityOverNewCommitGate() {
        let model = ChangesPreparationModel.makeGG(
            staged: .init(files: 1, insertions: 2, deletions: 1),
            hasDraft: true,
            capabilities: stagedOnlyCapabilities,
            mutationDisabledReason: "Another GG operation is running.",
            newCommitDisabledReason: "Checkout the stack head to create a new stack commit."
        )

        #expect(model.ggActions.allSatisfy {
            $0.disabledReason == "Another GG operation is running."
        })
    }
}

private func changedFile(
    _ path: String,
    stage: ChangeStage,
    add: Int,
    del: Int
) -> ChangedFile {
    ChangedFile(
        path: path,
        status: "M",
        stage: stage,
        add: add,
        del: del,
        renameFrom: nil,
        conflict: nil
    )
}
