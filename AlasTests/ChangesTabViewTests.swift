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

    @Test func changesPreparationCardHiddenWhenGGDrawerIsActive() {
        #expect(ChangesTabView.shouldShowChangesPreparationCard(
            preparationIsVisible: true,
            ggDrawerIsActive: false
        ))
        #expect(!ChangesTabView.shouldShowChangesPreparationCard(
            preparationIsVisible: true,
            ggDrawerIsActive: true
        ))
        #expect(!ChangesTabView.shouldShowChangesPreparationCard(
            preparationIsVisible: false,
            ggDrawerIsActive: false
        ))
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
}
