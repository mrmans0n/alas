import Foundation
import Testing
@testable import Alas

@Suite("Review draft comment store")
struct ReviewDraftCommentStoreTests {
    @Test @MainActor func controllerAddsEditsDeletesAndResolvesComments() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("review-draft-comments.json")
        let store = ReviewDraftCommentStore(store: PersistenceStore(), url: url)
        let session = ReviewDraftSessionID.localChanges(
            worktreeID: "wt",
            worktreePath: URL(fileURLWithPath: "/repo"),
            scope: .all
        )
        let controller = ReviewDraftCommentController(
            sessionID: session,
            store: store,
            now: { Date(timeIntervalSince1970: 100) }
        )
        let anchor = DiffReviewLineAnchor(
            path: "Sources/App.swift",
            side: .new,
            line: 42,
            rowIndex: 3,
            selectedText: "let value = 1"
        )
        let fileID = DiffReviewFileID(namespace: "unstaged", path: "Sources/App.swift")

        try controller.load()
        #expect(controller.comments.isEmpty)

        try controller.add(anchor: anchor, fileID: fileID, bodyMarkdown: "Please revisit this.")
        let added = try #require(controller.comments.single)
        #expect(added.sessionID == session)
        #expect(added.fileID == fileID)
        #expect(added.path == "Sources/App.swift")
        #expect(added.originalPath == nil)
        #expect(added.side == .new)
        #expect(added.startLine == 42)
        #expect(added.endLine == nil)
        #expect(added.selectedText == "let value = 1")
        #expect(added.bodyMarkdown == "Please revisit this.")
        #expect(added.state == .active)
        #expect(added.createdAt == Date(timeIntervalSince1970: 100))
        #expect(added.updatedAt == Date(timeIntervalSince1970: 100))
        #expect(try store.load(sessionID: session).single?.id == added.id)

        try controller.edit(commentID: added.id, bodyMarkdown: "Updated")
        #expect(controller.comments.single?.bodyMarkdown == "Updated")
        #expect(try store.load(sessionID: session).single?.bodyMarkdown == "Updated")

        try controller.resolve(commentID: added.id)
        #expect(controller.comments.single?.state == .resolved)
        #expect(try store.load(sessionID: session).single?.state == .resolved)

        try controller.dismiss(commentID: added.id)
        #expect(controller.comments.single?.state == .dismissed)
        #expect(try store.load(sessionID: session).single?.state == .dismissed)

        try controller.delete(commentID: added.id)
        #expect(controller.comments.isEmpty)
        #expect(try store.load(sessionID: session).isEmpty)
        #expect(controller.errorMessage == nil)
    }

    @Test func savesLoadsAndDeletesCommentsBySession() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("review-draft-comments.json")
        let store = ReviewDraftCommentStore(store: PersistenceStore(), url: url)
        let session = ReviewDraftSessionID.localChanges(
            worktreeID: "wt",
            worktreePath: URL(fileURLWithPath: "/repo"),
            scope: .all
        )
        let comment = ReviewDraftComment(
            id: "comment-1",
            sessionID: session,
            fileID: DiffReviewFileID(namespace: "unstaged", path: "A.swift"),
            path: "A.swift",
            originalPath: nil,
            side: .new,
            startLine: 4,
            endLine: nil,
            selectedText: "let a = 1",
            bodyMarkdown: "**Fix** this.",
            state: .active,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 11)
        )

        try store.save(comment)
        #expect(try store.load(sessionID: session) == [comment])

        var edited = comment
        edited.bodyMarkdown = "Updated"
        edited.state = .resolved
        edited.updatedAt = Date(timeIntervalSince1970: 12)
        try store.save(edited)
        #expect(try store.load(sessionID: session).single?.bodyMarkdown == "Updated")
        #expect(try store.load(sessionID: session).single?.state == .resolved)

        try store.delete(commentID: "comment-1", sessionID: session)
        #expect(try store.load(sessionID: session).isEmpty)
    }

    @Test func brokenStoreFileReturnsEmptySessions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("review-draft-comments.json")
        try Data("not json".utf8).write(to: url)
        let store = ReviewDraftCommentStore(store: PersistenceStore(), url: url)
        let session = ReviewDraftSessionID.localChanges(
            worktreeID: "wt",
            worktreePath: URL(fileURLWithPath: "/repo"),
            scope: .all
        )

        #expect(try store.load(sessionID: session).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func loadUsesDeterministicTieBreakersForSameLineComments() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("review-draft-comments.json")
        let store = ReviewDraftCommentStore(store: PersistenceStore(), url: url)
        let session = ReviewDraftSessionID.localChanges(
            worktreeID: "wt",
            worktreePath: URL(fileURLWithPath: "/repo"),
            scope: .all
        )
        let date = Date(timeIntervalSince1970: 10)
        let laterRange = makeComment(id: "b", session: session, startLine: 4, endLine: 6, createdAt: date)
        let earlierRange = makeComment(id: "a", session: session, startLine: 4, endLine: 5, createdAt: date)
        let sameRangeLaterID = makeComment(id: "c", session: session, startLine: 4, endLine: 5, createdAt: date)

        try store.save(laterRange)
        try store.save(sameRangeLaterID)
        try store.save(earlierRange)

        #expect(try store.load(sessionID: session).map(\.id) == ["a", "c", "b"])
    }

    private func makeComment(
        id: String,
        session: ReviewDraftSessionID,
        startLine: Int,
        endLine: Int?,
        createdAt: Date
    ) -> ReviewDraftComment {
        ReviewDraftComment(
            id: id,
            sessionID: session,
            fileID: DiffReviewFileID(namespace: "unstaged", path: "A.swift"),
            path: "A.swift",
            originalPath: nil,
            side: .new,
            startLine: startLine,
            endLine: endLine,
            selectedText: nil,
            bodyMarkdown: "Comment \(id)",
            state: .active,
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}
