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

    @Test func genericGitActionsAreHiddenOnlyAboveTheKnownCurrentStackPosition() {
        let stack = GGStack(
            name: "stack",
            base: "main",
            totalCommits: 4,
            syncedCommits: 0,
            currentPosition: 2,
            behindBase: nil,
            entries: [
                GGStackEntry(position: 1, sha: "one", title: "one"),
                GGStackEntry(position: 2, sha: "two", title: "two", isCurrent: true),
                GGStackEntry(position: 3, sha: "three", title: "three"),
                GGStackEntry(position: 4, sha: "four", title: "four"),
            ]
        )

        #expect(!CommitsSectionView.genericGitActionsAllowed(for: stack.entries[3], in: stack))
        #expect(!CommitsSectionView.genericGitActionsAllowed(for: stack.entries[2], in: stack))
        #expect(CommitsSectionView.genericGitActionsAllowed(for: stack.entries[1], in: stack))
        #expect(CommitsSectionView.genericGitActionsAllowed(for: stack.entries[0], in: stack))
    }

    @Test func unknownStackPositionKeepsGenericGitActionsAvailable() {
        let entry = GGStackEntry(position: 1, sha: "one", title: "one")
        let stack = GGStack(
            name: "stack",
            base: "main",
            totalCommits: 1,
            syncedCommits: 0,
            currentPosition: nil,
            behindBase: nil,
            entries: [entry]
        )

        #expect(CommitsSectionView.genericGitActionsAllowed(for: entry, in: stack))
        #expect(CommitsSectionView.genericGitActionsAllowed(for: nil, in: stack))
        #expect(CommitsSectionView.genericGitActionsAllowed(for: entry, in: nil))
    }

    @Test func sectionCountIncludesPrimaryAndOlderRows() {
        let primary = [commit(sha: "one"), commit(sha: "two"), commit(sha: "three"), commit(sha: "four")]
        let older = [commit(sha: "five"), commit(sha: "six")]

        #expect(CommitsSectionView.sectionCount(primary: primary, older: older) == 6)
        #expect(CommitsSectionView.sectionCount(primary: [], older: []) == nil)
    }
}
