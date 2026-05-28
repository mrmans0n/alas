import Foundation
import Testing
@testable import Alas

@Suite("ACPSessionStore queue")
struct ACPSessionStoreQueueTests {
    private func mkStore() throws -> (ACPSessionStore, String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("acp-queue-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(
            id: "sx", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        return (store, "sx")
    }

    @Test("loadQueue returns empty for a session with no queue")
    func emptyWhenAbsent() throws {
        let (store, sid) = try mkStore()
        let q = try store.loadQueue(sessionId: sid)
        #expect(q.isEmpty)
    }

    @Test("upsertQueue + loadQueue round-trips items in order")
    func roundTrip() throws {
        let (store, sid) = try mkStore()
        let items = [
            QueuedPrompt(blocks: [.text("one")], status: .pending),
            QueuedPrompt(blocks: [.text("two")], status: .sending),
        ]
        try store.upsertQueue(sessionId: sid, items: items)
        let loaded = try store.loadQueue(sessionId: sid)
        #expect(loaded == items)
    }

    @Test("upsertQueue replaces previous queue for the same session")
    func upsertReplaces() throws {
        let (store, sid) = try mkStore()
        try store.upsertQueue(sessionId: sid, items: [QueuedPrompt(blocks: [.text("a")])])
        try store.upsertQueue(sessionId: sid, items: [QueuedPrompt(blocks: [.text("b")])])
        let loaded = try store.loadQueue(sessionId: sid)
        #expect(loaded.count == 1)
        #expect(loaded[0].blocks == [.text("b")])
    }

    @Test("upsertQueue with empty array deletes the row")
    func emptyDeletes() throws {
        let (store, sid) = try mkStore()
        try store.upsertQueue(sessionId: sid, items: [QueuedPrompt(blocks: [.text("a")])])
        try store.upsertQueue(sessionId: sid, items: [])
        let loaded = try store.loadQueue(sessionId: sid)
        #expect(loaded.isEmpty)
    }

    @Test("schema target version includes session_queue (v3+)")
    func schemaIsV3() throws {
        let (store, _) = try mkStore()
        #expect(try store.currentSchemaVersion() == 3)
        #expect(ACPSessionStore.targetSchemaVersion == 3)
    }
}

@MainActor
@Suite("ACPSessionManager queue restore")
struct ACPSessionManagerQueueRestoreTests {
    @Test("openSession restores persisted queue, flipping .sending to .pending")
    func restoreNormalizes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mgr-q-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(
            id: "sm", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        try store.upsertQueue(sessionId: "sm", items: [
            QueuedPrompt(blocks: [.text("a")], status: .sending, lastError: nil),
            QueuedPrompt(blocks: [.text("b")], status: .pending, lastError: "previously failed"),
        ])

        let mgr = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp", store: store)
        let session = mgr.openSession(id: "sm")
        #expect(session != nil)
        #expect(session?.queue.count == 2)
        #expect(session?.queue[0].status == .pending)   // was .sending
        #expect(session?.queue[1].status == .pending)
        #expect(session?.queue[1].lastError == "previously failed")
    }
}
