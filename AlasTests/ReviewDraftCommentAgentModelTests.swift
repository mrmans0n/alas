import Foundation
import Testing
@testable import Alas

@Suite("Review draft comment agent model")
struct ReviewDraftCommentAgentModelTests {
    private func tempStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("review-draft-comments.json")
    }

    private func makeComment(
        id: String = "c1",
        worktreeID: String = "wt-1",
        author: ReviewDraftCommentAuthor? = nil
    ) -> ReviewDraftComment {
        ReviewDraftComment(
            id: id,
            sessionID: .localChanges(
                worktreeID: worktreeID,
                worktreePath: URL(fileURLWithPath: "/repo"),
                scope: .all
            ),
            fileID: DiffReviewFileID(namespace: "review", path: "Sources/A.swift"),
            path: "Sources/A.swift",
            originalPath: nil,
            side: .new,
            startLine: 10,
            endLine: nil,
            selectedText: nil,
            bodyMarkdown: "Fix this",
            state: .active,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            author: author
        )
    }

    /// The exact shape ReviewDraftComment persisted before author/replies/
    /// resolvedBy existed. Decoding it must succeed with user defaults.
    private struct LegacyComment: Encodable {
        var id: String
        var sessionID: ReviewDraftSessionID
        var fileID: DiffReviewFileID
        var path: String
        var side: DiffReviewInlineFeedbackSide
        var startLine: Int
        var bodyMarkdown: String
        var state: ReviewDraftCommentState
        var createdAt: Date
        var updatedAt: Date
    }

    @Test func legacyCommentDecodesWithUserAuthorAndNoReplies() throws {
        let legacy = LegacyComment(
            id: "old-1",
            sessionID: .localChanges(
                worktreeID: "wt-1",
                worktreePath: URL(fileURLWithPath: "/repo"),
                scope: .all
            ),
            fileID: DiffReviewFileID(namespace: "review", path: "a.swift"),
            path: "a.swift",
            side: .new,
            startLine: 3,
            bodyMarkdown: "hi",
            state: .active,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let data = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(ReviewDraftComment.self, from: data)
        #expect(decoded.effectiveAuthor == .user)
        #expect(decoded.allReplies.isEmpty)
        #expect(decoded.resolvedBy == nil)
    }

    @Test func agentFieldsRoundTripThroughTheStore() throws {
        let store = ReviewDraftCommentStore(url: tempStoreURL())
        var comment = makeComment(author: .agent(name: "Reviewer"))
        comment.replies = [
            ReviewCommentReply(
                id: "r1",
                author: .agent(name: "Reviewer"),
                bodyMarkdown: "done",
                createdAt: Date(timeIntervalSince1970: 2)
            )
        ]
        comment.resolvedBy = .agent(name: "Reviewer")

        try store.save(comment)

        let loaded = try store.load(sessionID: comment.sessionID)
        #expect(loaded == [comment])
        #expect(loaded[0].effectiveAuthor == .agent(name: "Reviewer"))
    }

    @Test func sessionIDWorktreeScopingMatchesOnlyItsWorktree() {
        let id = ReviewDraftSessionID.localChanges(
            worktreeID: "wt-1",
            worktreePath: URL(fileURLWithPath: "/repo"),
            scope: .all
        )
        #expect(id.isFor(worktreeID: "wt-1"))
        #expect(!id.isFor(worktreeID: "wt-2"))
        #expect(!id.isFor(worktreeID: "wt"))
    }

    @Test func loadAllAndFindSpanSessions() throws {
        let store = ReviewDraftCommentStore(url: tempStoreURL())
        let a = makeComment(id: "a", worktreeID: "wt-1")
        let b = makeComment(id: "b", worktreeID: "wt-2")
        try store.save(a)
        try store.save(b)

        #expect(try store.loadAll().count == 2)
        #expect(try store.find(commentID: "b")?.id == "b")
        #expect(try store.find(commentID: "zzz") == nil)
    }

    @Test func authorDisplayHelpers() {
        #expect(ReviewDraftCommentAuthor.user.isAgent == false)
        #expect(ReviewDraftCommentAuthor.agent(name: "Claude").isAgent)
        #expect(ReviewDraftCommentAuthor.user.displayName == "You")
        #expect(ReviewDraftCommentAuthor.agent(name: "Claude").displayName == "Claude")
        #expect(ReviewDraftCommentAuthor.agent(name: "").displayName == "Agent")
    }
}
