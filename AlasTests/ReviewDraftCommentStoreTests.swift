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
            endLine: 44,
            rowIndex: 3,
            selectedText: """
let value = 1
let other = 2
return value + other
"""
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
        #expect(added.endLine == 44)
        #expect(added.selectedText == """
let value = 1
let other = 2
return value + other
""")
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

    @Test @MainActor func controllerPersistsOriginalPathForRenamedFileDrafts() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("review-draft-comments.json")
        let store = ReviewDraftCommentStore(store: PersistenceStore(), url: url)
        let session = ReviewDraftSessionID.reviewRequest(
            worktreeID: "wt",
            provider: .gitlab,
            host: "gitlab.example.com",
            repositorySlug: "platform/mobile/alas",
            number: 42
        )
        let controller = ReviewDraftCommentController(
            sessionID: session,
            store: store,
            now: { Date(timeIntervalSince1970: 100) }
        )
        let anchor = DiffReviewLineAnchor(
            path: "Sources/NewApp.swift",
            side: .old,
            line: 12,
            rowIndex: 0,
            selectedText: "oldValue"
        )
        let fileID = DiffReviewFileID(namespace: "gitlab-mr", path: "Sources/NewApp.swift")

        try controller.load()
        try controller.add(
            anchor: anchor,
            fileID: fileID,
            originalPath: "Sources/OldApp.swift",
            bodyMarkdown: "Please revisit this removal."
        )

        #expect(controller.comments.single?.originalPath == "Sources/OldApp.swift")
        #expect(try store.load(sessionID: session).single?.originalPath == "Sources/OldApp.swift")
    }

    @Test @MainActor func controllerPersistsFileAndImageAnchors() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("review-draft-comments.json")
        let controller = ReviewDraftCommentController(
            sessionID: .localChanges(
                worktreeID: "wt",
                worktreePath: URL(fileURLWithPath: "/repo"),
                scope: .all
            ),
            store: ReviewDraftCommentStore(store: PersistenceStore(), url: url)
        )
        let fileID = DiffReviewFileID(namespace: "unstaged", path: "icon.png")

        try controller.load()
        try controller.add(anchor: .file, path: "icon.png", fileID: fileID, bodyMarkdown: "Whole file")
        try controller.add(
            anchor: .image(side: .new, normalizedX: 0.625, normalizedY: 0.25),
            path: "icon.png",
            fileID: fileID,
            bodyMarkdown: "This pixel"
        )

        #expect(controller.comments.map(\.anchor) == [
            .file,
            .image(side: .new, normalizedX: 0.625, normalizedY: 0.25),
        ])
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

    @Test func migrateMovesAndRekeysDrafts() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("review-draft-comments.json")
        let store = ReviewDraftCommentStore(store: PersistenceStore(), url: url)
        let oldID = ReviewDraftSessionID.commit(
            worktreeID: "wt",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            sha: "aaa"
        )
        let newID = ReviewDraftSessionID.trackedCommit(
            worktreeID: "wt",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            targetKey: "HEAD~3"
        )
        let existing = makeComment(
            id: "draft-1",
            session: newID,
            startLine: 8,
            endLine: nil,
            createdAt: Date(timeIntervalSince1970: 8)
        )
        let moved = makeComment(
            id: "draft-1",
            session: oldID,
            startLine: 4,
            endLine: nil,
            createdAt: Date(timeIntervalSince1970: 10)
        )

        try store.save(existing)
        try store.save(moved)
        try store.migrate(from: oldID, to: newID)

        #expect(try store.load(sessionID: oldID).isEmpty)
        let rekeyed = try #require(store.load(sessionID: newID).single)
        #expect(rekeyed.sessionID == newID)
        #expect(rekeyed.startLine == 4)
    }

    @Test func snapshotRestorePreservesDraftsAfterMigration() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("review-draft-comments.json")
        let store = ReviewDraftCommentStore(store: PersistenceStore(), url: url)
        let oldID = ReviewDraftSessionID.commit(
            worktreeID: "wt",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            sha: "aaa"
        )
        let newID = ReviewDraftSessionID.trackedCommit(
            worktreeID: "wt",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            targetKey: "HEAD~3"
        )
        let source = makeComment(
            id: "draft-1",
            session: oldID,
            startLine: 4,
            endLine: nil,
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let destination = makeComment(
            id: "draft-2",
            session: newID,
            startLine: 8,
            endLine: nil,
            createdAt: Date(timeIntervalSince1970: 11)
        )

        try store.save(source)
        try store.save(destination)
        let snapshot = try store.snapshot()
        try store.migrate(from: oldID, to: newID)
        try store.restore(snapshot)

        #expect(try store.load(sessionID: oldID) == [source])
        #expect(try store.load(sessionID: newID) == [destination])
    }

    @Test @MainActor func controllerMarksDraftPublishedAndRecordsProviderErrors() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("review-draft-comments.json")
        let store = ReviewDraftCommentStore(store: PersistenceStore(), url: url)
        let session = ReviewDraftSessionID.reviewRequest(
            worktreeID: "wt",
            provider: .github,
            host: "github.com",
            repositorySlug: "mrmans0n/alas",
            number: 527
        )
        var now = Date(timeIntervalSince1970: 100)
        let controller = ReviewDraftCommentController(
            sessionID: session,
            store: store,
            now: { now }
        )
        var comment = makeComment(
            id: "draft-1",
            session: session,
            startLine: 4,
            endLine: nil,
            createdAt: Date(timeIntervalSince1970: 10)
        )
        comment.providerError = ReviewDraftProviderError(
            provider: .github,
            message: "old error",
            occurredAt: Date(timeIntervalSince1970: 20)
        )
        let resolved = makeComment(
            id: "resolved",
            session: session,
            startLine: 8,
            endLine: nil,
            createdAt: Date(timeIntervalSince1970: 11),
            state: .resolved
        )
        try store.save(comment)
        try store.save(resolved)
        try controller.load()
        controller.errorMessage = "previous"
        #expect(controller.activeUnpublishedComments.map(\.id) == ["draft-1"])

        let publish = ReviewDraftProviderPublish(
            provider: .github,
            host: "github.com",
            repositorySlug: "mrmans0n/alas",
            reviewNumber: 527,
            threadID: "thread-1",
            commentID: "comment-1",
            url: URL(string: "https://github.com/mrmans0n/alas/pull/527#discussion_r1"),
            publishedAt: Date(timeIntervalSince1970: 30)
        )
        now = Date(timeIntervalSince1970: 101)
        try controller.markPublished(commentID: "draft-1", publish: publish)

        let published = try #require(controller.comments.first { $0.id == "draft-1" })
        #expect(published.providerPublish == publish)
        #expect(published.providerError == nil)
        #expect(published.updatedAt == Date(timeIntervalSince1970: 101))
        #expect(controller.activeUnpublishedComments.isEmpty)
        #expect(controller.errorMessage == nil)
        #expect(try store.load(sessionID: session).first { $0.id == "draft-1" }?.providerPublish == publish)

        let error = ReviewDraftProviderError(
            provider: .github,
            message: "line is outdated",
            occurredAt: Date(timeIntervalSince1970: 40)
        )
        now = Date(timeIntervalSince1970: 102)
        try controller.recordProviderError(commentID: "draft-1", error: error)

        let failed = try #require(controller.comments.first { $0.id == "draft-1" })
        #expect(failed.providerPublish == publish)
        #expect(failed.providerError == error)
        #expect(failed.updatedAt == Date(timeIntervalSince1970: 102))
        #expect(controller.errorMessage == nil)
        #expect(try store.load(sessionID: session).first { $0.id == "draft-1" }?.providerError == error)

        try controller.markPublished(commentID: "missing", publish: publish)
        try controller.recordProviderError(commentID: "missing", error: error)
        #expect(controller.comments.count == 2)
    }

    @Test func publishedMetadataSurvivesStoreRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("review-draft-comments.json")
        let store = ReviewDraftCommentStore(store: PersistenceStore(), url: url)
        let session = ReviewDraftSessionID.reviewRequest(
            worktreeID: "wt",
            provider: .github,
            host: "github.com",
            repositorySlug: "mrmans0n/alas",
            number: 527
        )
        var published = makeComment(
            id: "published",
            session: session,
            startLine: 12,
            endLine: nil,
            createdAt: Date(timeIntervalSince1970: 10)
        )
        published.providerPublish = ReviewDraftProviderPublish(
            provider: .github,
            host: "github.com",
            repositorySlug: "mrmans0n/alas",
            reviewNumber: 527,
            threadID: "thread-1",
            commentID: "comment-1",
            url: URL(string: "https://github.com/mrmans0n/alas/pull/527#discussion_r1"),
            publishedAt: Date(timeIntervalSince1970: 30)
        )
        published.providerError = ReviewDraftProviderError(
            provider: .github,
            message: "line is outdated",
            occurredAt: Date(timeIntervalSince1970: 40)
        )

        try store.save(published)

        let reloaded = try #require(store.load(sessionID: session).single)
        #expect(reloaded == published)
        #expect(reloaded.providerPublish == published.providerPublish)
        #expect(reloaded.providerError == published.providerError)
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
        createdAt: Date,
        state: ReviewDraftCommentState = .active
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
            state: state,
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}
