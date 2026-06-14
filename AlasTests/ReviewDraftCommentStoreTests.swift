import Foundation
import Testing
@testable import Alas

@Suite("Review draft comment store")
struct ReviewDraftCommentStoreTests {
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
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}
