import Testing
@testable import Alas

@MainActor
struct ChangesTabViewTests {
    @Test func genericOperationCardHiddenDuringPausedGGOperation() {
        let operation = MergeOperation.merge(sourceBranch: "main")

        #expect(ChangesTabView.shouldShowGenericOperationCard(
            mergeOperation: operation,
            pausedGGOperation: nil
        ))
        #expect(!ChangesTabView.shouldShowGenericOperationCard(
            mergeOperation: operation,
            pausedGGOperation: GGPausedOperation(pausedBy: .sync)
        ))
        #expect(!ChangesTabView.shouldShowGenericOperationCard(
            mergeOperation: nil,
            pausedGGOperation: nil
        ))
    }

    @Test func changesPreparationCardVisibilityDoesNotDependOnGGDrawer() {
        #expect(ChangesTabView.shouldShowChangesPreparationCard(
            preparationIsVisible: true
        ))
        #expect(!ChangesTabView.shouldShowChangesPreparationCard(
            preparationIsVisible: false
        ))
    }

    @Test func regularGitOperationDisablesGGPreparationMutations() {
        let reason = ChangesTabView.ggPreparationMutationDisabledReason(
            hasStack: true,
            pausedOperation: nil,
            inFlightAction: nil,
            mergeOperation: .merge(sourceBranch: "main")
        )

        #expect(reason == "Finish the current Git operation first.")
    }

    @Test func newStackCommitRequiresActualStackHeadCheckout() {
        let stack = stack(currentPosition: 1)

        #expect(ChangesTabView.ggNewStackCommitDisabledReason(
            stack: stack,
            currentHeadSHA: "1111111111111111111111111111111111111111"
        ) == "Checkout the stack head to create a new stack commit.")
        #expect(ChangesTabView.ggNewStackCommitDisabledReason(
            stack: stack,
            currentHeadSHA: "2222222222222222222222222222222222222222"
        ) == nil)
    }

    @Test func newStackCommitIsConservativelyDisabledWithoutVerifiableHead() {
        #expect(ChangesTabView.ggNewStackCommitDisabledReason(
            stack: stack(currentPosition: nil, entries: []),
            currentHeadSHA: "1111111111111111111111111111111111111111"
        ) == "Checkout the stack head to create a new stack commit.")
        #expect(ChangesTabView.ggNewStackCommitDisabledReason(
            stack: stack(currentPosition: 2),
            currentHeadSHA: ""
        ) == "Checkout the stack head to create a new stack commit.")
    }

    @Test func ggDrawerActiveForStackOrPausedOperation() {
        #expect(!ChangesTabView.shouldShowGGDrawer(stack: nil, pausedGGOperation: nil))
        #expect(ChangesTabView.shouldShowGGDrawer(
            stack: GGStack(
                name: "feat",
                base: "main",
                totalCommits: 0,
                syncedCommits: 0,
                currentPosition: nil,
                behindBase: nil,
                entries: []
            ),
            pausedGGOperation: nil
        ))
        #expect(ChangesTabView.shouldShowGGDrawer(
            stack: nil,
            pausedGGOperation: GGPausedOperation(pausedBy: .sync)
        ))
    }

    private func stack(
        currentPosition: Int?,
        entries: [GGStackEntry] = [
            GGStackEntry(
                position: 1,
                sha: "1111111",
                title: "First",
                isCurrent: true
            ),
            GGStackEntry(
                position: 2,
                sha: "2222222",
                title: "Second"
            ),
        ]
    ) -> GGStack {
        GGStack(
            name: "feat",
            base: "main",
            totalCommits: entries.count,
            syncedCommits: 0,
            currentPosition: currentPosition,
            behindBase: nil,
            entries: entries
        )
    }
}
