import Foundation
import Testing
@testable import Alas

struct ReviewSessionTargetTests {
    @Test func commitRangeAndBranchHaveDistinctDraftSessionIDsForSameEndpoints() {
        let path = URL(fileURLWithPath: "/tmp/repo")
        let range = ReviewSessionTarget.commitRange(worktreeID: "wt", repositoryPath: path, base: "aaa", head: "bbb")
        let branch = ReviewSessionTarget.branch(worktreeID: "wt", repositoryPath: path, base: "aaa", head: "bbb")
        let commit = ReviewSessionTarget.commit(worktreeID: "wt", repositoryPath: path, sha: "aaa", title: "t")

        #expect(range.draftSessionID != branch.draftSessionID)
        #expect(range.draftSessionID != commit.draftSessionID)
        #expect(branch.draftSessionID != commit.draftSessionID)
        #expect(range.draftSessionID.sourceKind == .commitRange)
    }
}
