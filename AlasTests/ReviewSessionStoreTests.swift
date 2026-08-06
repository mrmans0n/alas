import Foundation
import Testing
@testable import Alas

@Suite("Review session store")
struct ReviewSessionStoreTests {
    @Test func roundTripsSessionRecords() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("review-sessions.json")
        let store = ReviewSessionStore(url: url)
        let target = ReviewSessionTarget.commit(
            worktreeID: "wt-1",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            sha: "abc123",
            title: "Review abc123"
        )
        let record = ReviewSessionRecord(
            id: target.id,
            target: target,
            selectedFileID: DiffReviewFileID(namespace: "commit", path: "Sources/A.swift"),
            focusedCommentID: "comment-1",
            status: .active,
            handoffs: [],
            lastSendError: nil,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2)
        )

        try store.save(record)

        #expect(try store.load(id: target.id) == record)
        #expect(try store.findActive(targetID: target.id) == record)
        #expect(try store.list(worktreeID: "wt-1") == [record])
    }

    @Test func listSortsByUpdatedAtDescendingWithinWorktree() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("review-sessions.json")
        let store = ReviewSessionStore(url: url)
        let older = makeRecord(id: "older", worktreeID: "wt-1", updatedAt: 10)
        let newer = makeRecord(id: "newer", worktreeID: "wt-1", updatedAt: 20)
        let otherWorktree = makeRecord(id: "other", worktreeID: "wt-2", updatedAt: 30)

        try store.save(older)
        try store.save(otherWorktree)
        try store.save(newer)

        #expect(try store.list(worktreeID: "wt-1").map(\.id.rawValue) == ["newer", "older"])
    }

    @Test func archiveRemovesSessionFromActiveReuse() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("review-sessions.json")
        let store = ReviewSessionStore(url: url)
        let target = ReviewSessionTarget.localChanges(
            worktreeID: "wt-1",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            scope: .all
        )
        var record = ReviewSessionRecord(
            id: target.id,
            target: target,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        try store.save(record)

        record.status = .archived
        try store.save(record)

        #expect(try store.findActive(targetID: target.id) == nil)
        #expect(try store.load(id: target.id)?.status == .archived)
    }

    @Test func findActiveMatchesTargetIDWhenRecordIDDiffers() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("review-sessions.json")
        let store = ReviewSessionStore(url: url)
        let target = ReviewSessionTarget.commit(
            worktreeID: "wt-1",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            sha: "abc123",
            title: "Review abc123"
        )
        let record = ReviewSessionRecord(
            id: ReviewSessionID(rawValue: "session-override"),
            target: target,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2)
        )

        try store.save(record)

        #expect(try store.load(id: record.id) == record)
        #expect(try store.findActive(targetID: target.id) == record)
    }

    @Test func findActiveCanExcludeCurrentRetargetedSession() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("review-sessions.json")
        let store = ReviewSessionStore(url: url)
        let revision = try #require(TrackedRevision(
            expression: "HEAD~2",
            baselineBranch: "feature",
            baselineHEAD: "head",
            resolvedSHA: "sha"
        ))
        let target = ReviewSessionTarget.trackedCommit(
            worktreeID: "wt-1",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            revision: revision,
            title: "Review HEAD~2"
        )
        let existing = ReviewSessionRecord(
            id: ReviewSessionID(rawValue: "existing"),
            target: target,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        let current = ReviewSessionRecord(
            id: ReviewSessionID(rawValue: "current"),
            target: target,
            createdAt: Date(timeIntervalSince1970: 3),
            updatedAt: Date(timeIntervalSince1970: 4)
        )
        try store.save(existing)
        try store.save(current)

        #expect(try store.findActive(targetID: target.id, excluding: current.id) == existing)
        #expect(try store.findActive(targetID: target.id, excluding: existing.id) == current)
        #expect(try store.findActive(targetID: target.id, excluding: ReviewSessionID(rawValue: "missing")) == current)
    }

    @Test func replaceRemovesOldRecordIDWhenRetargetingRekeys() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("review-sessions.json")
        let store = ReviewSessionStore(url: url)
        let source = makeRecord(id: "source", worktreeID: "wt-1", updatedAt: 1)
        var retargeted = source
        retargeted.id = ReviewSessionID(rawValue: "retargeted")

        try store.save(source)
        try store.replace(id: source.id, with: retargeted)

        #expect(try store.load(id: source.id) == retargeted)
        #expect(try store.load(id: retargeted.id) == retargeted)
    }

    @Test func replaceRewritesExistingAliasesTransitively() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("review-sessions.json")
        let store = ReviewSessionStore(url: url)
        let source = makeRecord(id: "source", worktreeID: "wt-1", updatedAt: 1)
        var middle = source
        middle.id = ReviewSessionID(rawValue: "middle")
        var final = source
        final.id = ReviewSessionID(rawValue: "final")

        try store.save(source)
        try store.replace(id: source.id, with: middle)
        try store.replace(id: middle.id, with: final)

        #expect(try store.load(id: source.id) == final)
        #expect(try store.load(id: middle.id) == final)
        #expect(try store.load(id: final.id) == final)
    }

    @Test func replaceCanAliasSourceToExistingDestination() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("review-sessions.json")
        let store = ReviewSessionStore(url: url)
        let source = makeRecord(id: "source", worktreeID: "wt-1", updatedAt: 1)
        var destination = makeRecord(id: "destination", worktreeID: "wt-1", updatedAt: 2)
        destination.selectedFileID = DiffReviewFileID(namespace: "commit", path: "Merged.swift")

        try store.save(source)
        try store.save(makeRecord(id: "destination", worktreeID: "wt-1", updatedAt: 1))
        try store.replace(id: source.id, with: destination)

        #expect(try store.load(id: source.id) == destination)
        #expect(try store.loadReplacement(for: source.id) == destination)
        #expect(try store.load(id: destination.id) == destination)
    }

    @Test func replacementLookupStaysAuthoritativeAfterOldIDReuse() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("review-sessions.json")
        let store = ReviewSessionStore(url: url)
        let source = makeRecord(id: "source", worktreeID: "wt-1", updatedAt: 1)
        var retargeted = source
        retargeted.id = ReviewSessionID(rawValue: "retargeted")
        retargeted.updatedAt = Date(timeIntervalSince1970: 2)
        var reopened = source
        reopened.updatedAt = Date(timeIntervalSince1970: 3)

        try store.save(source)
        try store.replace(id: source.id, with: retargeted)
        try store.save(reopened)

        #expect(try store.load(id: source.id) == reopened)
        #expect(try store.loadReplacement(for: source.id) == retargeted)
    }

    private func makeRecord(id: String, worktreeID: String, updatedAt: TimeInterval) -> ReviewSessionRecord {
        let target = ReviewSessionTarget.commit(
            worktreeID: worktreeID,
            repositoryPath: URL(fileURLWithPath: "/repo"),
            sha: id,
            title: "Review \(id)"
        )
        return ReviewSessionRecord(
            id: ReviewSessionID(rawValue: id),
            target: target,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }
}
