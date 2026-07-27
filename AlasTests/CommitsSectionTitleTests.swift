import Testing
@testable import Alas

struct CommitsSectionTitleTests {
    private func stack(name: String = "nacho/stack") -> GGStack {
        GGStack(
            name: name, base: "main", totalCommits: 1, syncedCommits: 1,
            currentPosition: nil, behindBase: nil, entries: []
        )
    }

    @Test func plainCommitsWhenNoStack() {
        #expect(CommitsSectionView.sectionTitle(ggStack: nil) == "Commits")
    }

    @Test func activeStackUsesOnlyItsName() {
        #expect(CommitsSectionView.sectionTitle(ggStack: stack()) == "nacho/stack")
    }

    @Test func activeStackTitleDoesNotDependOnVisibleCommitRows() {
        let visibleCommits: [CommitInfo] = []

        #expect(visibleCommits.isEmpty)
        #expect(CommitsSectionView.sectionTitle(ggStack: stack(name: "fully-synced")) == "fully-synced")
    }

    @Test func ggRowMutationsFollowDrawerBusyGate() {
        #expect(CommitsSectionView.ggRowMutationsEnabled(
            inFlightAction: nil,
            mergeOperation: nil,
            pausedGGOperation: nil
        ))
        #expect(!CommitsSectionView.ggRowMutationsEnabled(
            inFlightAction: .sync,
            mergeOperation: nil,
            pausedGGOperation: nil
        ))
        #expect(!CommitsSectionView.ggRowMutationsEnabled(
            inFlightAction: nil,
            mergeOperation: .merge(sourceBranch: "main"),
            pausedGGOperation: nil
        ))
        #expect(!CommitsSectionView.ggRowMutationsEnabled(
            inFlightAction: nil,
            mergeOperation: .merge(sourceBranch: "main"),
            pausedGGOperation: GGPausedOperation(pausedBy: .sync)
        ))
    }
}
