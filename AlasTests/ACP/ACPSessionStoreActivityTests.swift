import Testing
import Foundation
@testable import Alas

@Suite struct ACPSessionStoreActivityTests {
    @Test("persisting messages bumps the session's updated_at to the write time")
    func upsertMessagesBumpsSessionUpdatedAt() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("activity-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let created: Int64 = 100
        try store.upsertSession(ACPSessionRow(
            id: "s1", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: created, updatedAt: created, lastOpenedAt: created, archived: false))

        // A message arrives long after the session's title/model were last
        // touched — the session row itself never changes, only the transcript.
        let writeTime: Int64 = 5_000
        try store.upsertMessages([
            ACPStoredMessage(
                id: "m1", sessionId: "s1", kind: "text", seq: 0,
                payload: Data("hi".utf8), createdAt: 200),
        ], activityAt: writeTime)

        let row = try #require(try store.loadSession(id: "s1"))
        #expect(row.updatedAt == writeTime)
    }

    @Test("upsertMessages uses the write time, not a message's own (possibly stale) createdAt")
    func upsertMessagesUsesWriteTimeNotStaleMessageCreatedAt() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("activity-stale-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let created: Int64 = 100
        try store.upsertSession(ACPSessionRow(
            id: "s1", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: created, updatedAt: created, lastOpenedAt: created, archived: false))

        // A streamed agent message keeps its first-chunk createdAt across
        // every subsequent chunk update — it must not be mistaken for the
        // time of THIS write, or a long response looks stale once reloaded.
        let firstChunkTime: Int64 = 200
        let thisWriteTime: Int64 = 9_000
        try store.upsertMessages([
            ACPStoredMessage(
                id: "m1", sessionId: "s1", kind: "text", seq: 0,
                payload: Data("final chunk".utf8), createdAt: firstChunkTime),
        ], activityAt: thisWriteTime)

        let row = try #require(try store.loadSession(id: "s1"))
        #expect(row.updatedAt == thisWriteTime)
    }

    @Test("a salvage insert via insertMessageIfMissing bumps session updated_at to the write time")
    func insertMessageIfMissingBumpsSessionUpdatedAt() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("activity-salvage-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let created: Int64 = 100
        try store.upsertSession(ACPSessionRow(
            id: "s1", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: created, updatedAt: created, lastOpenedAt: created, archived: false))

        let writeTime: Int64 = 5_000
        let inserted = try store.insertMessageIfMissing(ACPStoredMessage(
            id: "m1", sessionId: "s1", kind: "text", seq: 0,
            payload: Data("hi".utf8), createdAt: 200), activityAt: writeTime)

        #expect(inserted)
        let row = try #require(try store.loadSession(id: "s1"))
        #expect(row.updatedAt == writeTime)
    }

    @Test("a no-op insertMessageIfMissing (row already exists) does not bump updated_at")
    func insertMessageIfMissingNoOpDoesNotBumpUpdatedAt() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("activity-salvage-noop-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let created: Int64 = 100
        try store.upsertSession(ACPSessionRow(
            id: "s1", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: created, updatedAt: created, lastOpenedAt: created, archived: false))
        try store.upsertMessages([
            ACPStoredMessage(id: "m1", sessionId: "s1", kind: "text", seq: 0,
                payload: Data("hi".utf8), createdAt: created),
        ], activityAt: created)

        // Same id already exists — ON CONFLICT DO NOTHING — so this must be
        // a true no-op, including for the session's activity timestamp.
        let inserted = try store.insertMessageIfMissing(ACPStoredMessage(
            id: "m1", sessionId: "s1", kind: "text", seq: 0,
            payload: Data("hi".utf8), createdAt: 200), activityAt: 9_999)

        #expect(!inserted)
        let row = try #require(try store.loadSession(id: "s1"))
        #expect(row.updatedAt == created)
    }

    @Test("persisting messages never moves updated_at backward")
    func upsertMessagesNeverRegressesUpdatedAt() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("activity-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let created: Int64 = 5_000
        try store.upsertSession(ACPSessionRow(
            id: "s1", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: created, updatedAt: created, lastOpenedAt: created, archived: false))

        // A stale/backfilled write (e.g. history import) older than the
        // session's own updated_at must not rewind the activity timestamp.
        try store.upsertMessages([
            ACPStoredMessage(
                id: "m1", sessionId: "s1", kind: "text", seq: 0,
                payload: Data("hi".utf8), createdAt: 50),
        ], activityAt: 100)

        let row = try #require(try store.loadSession(id: "s1"))
        #expect(row.updatedAt == created)
    }
}
