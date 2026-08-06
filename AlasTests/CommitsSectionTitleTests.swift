import Testing
@testable import Alas

struct CommitsSectionTitleTests {
    @Test func commitRowsAreSplitIntoSmallContiguousBatches() {
        let batches = CommitsSectionView.rowBatches(count: 40)

        #expect(batches.count == 5)
        #expect(batches.allSatisfy { $0.count <= CommitsSectionView.rowBatchSize })
        #expect(batches.flatMap(Array.init) == Array(0 ..< 40))
    }

    @Test func commitRowBatchesHandleEmptyAndPartialLists() {
        #expect(CommitsSectionView.rowBatches(count: 0).isEmpty)
        #expect(CommitsSectionView.rowBatches(count: 10) == [0 ..< 8, 8 ..< 10])
    }

    @Test func commitRowBatchIdentityTracksCommitContent() {
        let original = (0 ..< CommitsSectionView.rowBatchSize).map { commit(sha: "commit-\($0)") }
        var refreshed = original
        refreshed[3] = commit(sha: "replacement")

        let originalBatch = try! #require(CommitsSectionView.rowBatches(for: original).first)
        let refreshedBatch = try! #require(CommitsSectionView.rowBatches(for: refreshed).first)

        #expect(originalBatch.range == refreshedBatch.range)
        #expect(originalBatch.id != refreshedBatch.id)
    }

    private func commit(sha: String) -> CommitInfo {
        CommitInfo(
            sha: sha,
            shortSha: String(sha.prefix(7)),
            author: "Author",
            authorInitials: "A",
            date: .now,
            subject: "Subject",
            conventionalTag: nil,
            filesChanged: 0,
            insertions: 0,
            deletions: 0
        )
    }

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
