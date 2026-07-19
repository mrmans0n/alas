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
}
