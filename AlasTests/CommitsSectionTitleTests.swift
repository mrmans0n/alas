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
        #expect(CommitsSectionView.sectionTitle(ggStack: nil, commitsEmpty: false) == "Commits")
        #expect(CommitsSectionView.sectionTitle(ggStack: nil, commitsEmpty: true) == "Commits")
    }

    @Test func stackTitleWhenStackPresentAndCommitsNonEmpty() {
        #expect(
            CommitsSectionView.sectionTitle(ggStack: stack(), commitsEmpty: false)
                == "Stack · nacho/stack"
        )
    }

    /// A synced stack under "Branch upstream" comparison mode loads
    /// `ggStack` (feeding the sidebar badge) while the display `commits`
    /// list is empty. The header must not promise "Stack · …" content that
    /// the (empty) body can't render.
    @Test func plainCommitsWhenStackPresentButCommitsEmpty() {
        #expect(CommitsSectionView.sectionTitle(ggStack: stack(), commitsEmpty: true) == "Commits")
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
