import Foundation
import Testing
@testable import Alas

struct ReviewScopeSelectionTests {
    private let path = URL(fileURLWithPath: "/tmp/repo")

    private func info(_ sha: String, _ subject: String) -> CommitInfo {
        CommitInfo(sha: sha, shortSha: String(sha.prefix(7)), author: "A", authorInitials: "A",
                   date: Date(timeIntervalSince1970: 0), subject: subject, conventionalTag: nil,
                   filesChanged: 0, insertions: 0, deletions: 0)
    }

    @Test func workingTreeBuildsLocalChangesTarget() {
        let target = ReviewScopeSelection.target(for: .workingTree, worktreeID: "wt", repositoryPath: path)
        #expect(target.kind == .localChanges)
    }

    @Test func rangeBuildsParentBaseAndNewerHead() {
        let older = info("aaaaaaa1", "first")
        let newer = info("bbbbbbb2", "second")
        let target = ReviewScopeSelection.target(for: .range(older: older, newer: newer), worktreeID: "wt", repositoryPath: path)
        #expect(target.kind == .commitRange)
        #expect(target.payload == .commitRange(base: "aaaaaaa1^", head: "bbbbbbb2"))
    }

    @Test func branchBuildsThreeDotAgainstHead() {
        let target = ReviewScopeSelection.target(for: .branch(name: "main"), worktreeID: "wt", repositoryPath: path)
        #expect(target.kind == .branch)
        #expect(target.payload == .branch(base: "main", head: "HEAD"))
    }

    @Test func branchWithHeadSHAEmbedsConcreteSHA() {
        let target = ReviewScopeSelection.target(
            for: .branch(name: "main"),
            worktreeID: "wt",
            repositoryPath: path,
            headSHA: "abc1234abc1234abc1234abc1234abc1234abc1234"
        )
        #expect(target.kind == .branch)
        #expect(target.payload == .branch(base: "main", head: "abc1234abc1234abc1234abc1234abc1234abc1234"))
    }

    @Test func branchWithBranchBaseSHAPinsBase() {
        let target = ReviewScopeSelection.target(
            for: .branch(name: "main"),
            worktreeID: "wt",
            repositoryPath: path,
            headSHA: "abc1234abc1234abc1234abc1234abc1234abc1234",
            branchBaseSHA: "def5678def5678def5678def5678def5678def567"
        )
        #expect(target.kind == .branch)
        #expect(target.payload == .branch(
            base: "def5678def5678def5678def5678def5678def567",
            head: "abc1234abc1234abc1234abc1234abc1234abc1234"
        ))
        // The branch name is retained only for display.
        #expect(target.title == "Review HEAD against main")
    }

    @Test func branchTargetIDVariesWithBranchBaseSHA() {
        let targetA = ReviewScopeSelection.target(
            for: .branch(name: "main"),
            worktreeID: "wt",
            repositoryPath: path,
            headSHA: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            branchBaseSHA: "1111111111111111111111111111111111111111"
        )
        let targetB = ReviewScopeSelection.target(
            for: .branch(name: "main"),
            worktreeID: "wt",
            repositoryPath: path,
            headSHA: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            branchBaseSHA: "2222222222222222222222222222222222222222"
        )
        #expect(targetA.id != targetB.id)
        #expect(targetA.draftSessionID != targetB.draftSessionID)
    }

    @Test func branchTargetIDVariesWithHeadSHA() {
        let targetA = ReviewScopeSelection.target(
            for: .branch(name: "main"),
            worktreeID: "wt",
            repositoryPath: path,
            headSHA: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        )
        let targetB = ReviewScopeSelection.target(
            for: .branch(name: "main"),
            worktreeID: "wt",
            repositoryPath: path,
            headSHA: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        )
        #expect(targetA.id != targetB.id)
        #expect(targetA.draftSessionID != targetB.draftSessionID)
    }

    @Test func filterMatchesShaSubjectAndIsCaseInsensitive() {
        let commits = [info("abc1234", "Fix login"), info("def5678", "Add export")]
        #expect(ReviewScopeSelection.filteredCommits(commits, query: "").map(\.sha) == ["abc1234", "def5678"])
        #expect(ReviewScopeSelection.filteredCommits(commits, query: "export").map(\.sha) == ["def5678"])
        #expect(ReviewScopeSelection.filteredCommits(commits, query: "ABC12").map(\.sha) == ["abc1234"])
    }
}
