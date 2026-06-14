import Foundation
import Testing
@testable import Alas

@Suite("Review draft models")
struct ReviewDraftModelsTests {
    @Test func localChangesSessionIDIsStableForSameWorktree() {
        let first = ReviewDraftSessionID.localChanges(
            worktreeID: "wt-1",
            worktreePath: URL(fileURLWithPath: "/repo"),
            scope: .all
        )
        let second = ReviewDraftSessionID.localChanges(
            worktreeID: "wt-1",
            worktreePath: URL(fileURLWithPath: "/repo"),
            scope: .all
        )

        #expect(first == second)
        #expect(first.rawValue.contains("local-changes"))
        #expect(first.rawValue.contains("wt-1"))
    }

    @Test func commitAndProviderSessionsDoNotCollide() {
        let commit = ReviewDraftSessionID.commit(
            worktreeID: "wt",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            sha: "abc123"
        )
        let pr = ReviewDraftSessionID.reviewRequest(
            worktreeID: "wt",
            provider: .github,
            host: "github.com",
            repositorySlug: "mrmans0n/alas",
            number: 520
        )

        #expect(commit != pr)
        #expect(commit.sourceKind == .commit)
        #expect(pr.sourceKind == .reviewRequest)
    }

    @Test func draftCommentRangeNormalizesLineOrder() {
        let comment = ReviewDraftComment(
            id: "c1",
            sessionID: .localChanges(
                worktreeID: "wt",
                worktreePath: URL(fileURLWithPath: "/repo"),
                scope: .all
            ),
            fileID: DiffReviewFileID(namespace: "unstaged", path: "Sources/App.swift"),
            path: "Sources/App.swift",
            originalPath: nil,
            side: .new,
            startLine: 8,
            endLine: 3,
            selectedText: "let value = 1",
            bodyMarkdown: "Please extract this.",
            state: .active,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2)
        )

        #expect(comment.normalizedLineRange == 3...8)
        #expect(comment.isActive)
    }
}
