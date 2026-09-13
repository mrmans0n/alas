import Testing
import Foundation
@testable import Alas

@Suite struct ACPSessionStoreActivityTests {
    @Test("persisting messages bumps the session's updated_at to the latest message time")
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
        let laterMessageTime: Int64 = 5_000
        try store.upsertMessages([
            ACPStoredMessage(
                id: "m1", sessionId: "s1", kind: "text", seq: 0,
                payload: Data("hi".utf8), createdAt: laterMessageTime),
        ])

        let row = try #require(try store.loadSession(id: "s1"))
        #expect(row.updatedAt == laterMessageTime)
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

        // A stale/backfilled message older than the session's own updated_at
        // (e.g. history import) must not rewind the activity timestamp.
        try store.upsertMessages([
            ACPStoredMessage(
                id: "m1", sessionId: "s1", kind: "text", seq: 0,
                payload: Data("hi".utf8), createdAt: 100),
        ])

        let row = try #require(try store.loadSession(id: "s1"))
        #expect(row.updatedAt == created)
    }
}
