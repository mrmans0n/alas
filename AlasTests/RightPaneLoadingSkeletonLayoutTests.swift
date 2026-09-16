import Testing
@testable import Alas

struct RightPaneLoadingSkeletonLayoutTests {
    @Test func filesSkeletonIsNonEmpty() {
        #expect(!RightPaneSkeletonLayout.files.isEmpty)
    }

    @Test func filesSkeletonStartsAtRootDepth() {
        #expect(RightPaneSkeletonLayout.files.first?.depth == 0)
    }

    @Test func filesSkeletonDepthNeverJumpsMoreThanOneLevel() {
        // Same constraint a real expanded tree satisfies: a row can only be
        // one level deeper than the row directly above it.
        var previousDepth = 0
        for row in RightPaneSkeletonLayout.files {
            #expect(row.depth <= previousDepth + 1)
            previousDepth = row.depth
        }
    }

    @Test func filesSkeletonInsetsMatchTheRealTreeRows() {
        // The skeleton borrows FileTreeListView's own indentation function,
        // so rows land at the same x the real tree will use once it loads.
        for row in RightPaneSkeletonLayout.files {
            #expect(FileTreeListView.rowLeadingPadding(depth: row.depth) == 12 + CGFloat(row.depth * 14))
        }
    }

    @Test func agentSkeletonHasActiveAndHistorySections() {
        #expect(RightPaneSkeletonLayout.agentSections.map(\.title) == ["Active", "History"])
        #expect(RightPaneSkeletonLayout.agentSections.allSatisfy { $0.cardCount > 0 })
    }

    @Test func runSkeletonHasRepoAndGlobalSections() {
        #expect(RightPaneSkeletonLayout.runSections.map(\.title) == ["Repo", "Global"])
        #expect(RightPaneSkeletonLayout.runSections.allSatisfy { !$0.rowWidths.isEmpty })
    }
}
