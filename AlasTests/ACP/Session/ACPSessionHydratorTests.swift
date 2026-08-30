import Foundation
import Testing
@testable import Alas

@Suite("ACPSessionHydrator")
struct ACPSessionHydratorTests {
    private func tmpStorePath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("hydrator-\(UUID()).sqlite").path
    }

    @Test("hydrates row, messages, queue, draft")
    func happyPath() async throws {
        let path = tmpStorePath()
        let store = try ACPSessionStore(path: path)
        try store.upsertSession(.init(
            id: "s", agentId: "claude", title: "demo",
            currentModel: "sonnet", currentMode: "agent",
            autoRun: true,
            createdAt: 1, updatedAt: 1, lastOpenedAt: 1, archived: false))

        // Seed three messages of different kinds. ACPMessage construction
        // and ACPMessageCodec.encode are @MainActor, so we hop.
        let payloads: [(String, Data)] = try await MainActor.run {
            let user: ACPMessage = .user(id: UUID(), text: "hi", attachments: [])
            let agent: ACPMessage = .agent(id: UUID(), StreamingText("yo"))
            let tool: ACPMessage = .toolCall(.init(
                toolCallId: "tc", title: "read", status: "completed",
                content: "abc", preview: "abc", locations: []))
            return try [user, agent, tool].map { ($0.kind, try ACPMessageCodec.encode($0)) }
        }
        for (i, p) in payloads.enumerated() {
            try store.appendMessage(
                sessionId: "s", id: "m\(i)", kind: p.0,
                seq: Int64(i), payload: p.1, createdAt: Int64(i))
        }

        // Seed queue + draft.
        try store.upsertQueue(sessionId: "s", items: [
            QueuedPrompt(blocks: [.text("queued")])
        ])
        try store.upsertComposerDraft(
            sessionId: "s",
            draft: ACPComposerDraft(segments: [.text("draft")]),
            updatedAt: 2)

        let hydrator = try ACPSessionHydrator(path: path)
        let result = try await hydrator.hydrate(sessionId: "s")

        #expect(result.row.id == "s")
        #expect(result.row.title == "demo")
        #expect(result.row.currentModel == "sonnet")
        #expect(result.row.autoRun == true)
        #expect(result.wireMessages.count == 3)
        #expect(result.messages.map(\.createdAt) == [
            Date(timeIntervalSince1970: 0),
            Date(timeIntervalSince1970: 1),
            Date(timeIntervalSince1970: 2)
        ])
        #expect(result.queue.count == 1)
        #expect(result.draft != nil)
        #expect(result.recent.contains(where: { $0.id == "s" }))
    }

    @Test("hydrate preserves remote ACP session id in touched row")
    func hydratePreservesRemoteSessionIdInTouchedRow() async throws {
        let path = tmpStorePath()
        let store = try ACPSessionStore(path: path)
        try store.upsertSession(.init(
            id: "s",
            agentId: "claude",
            title: "t",
            remoteSessionId: "remote-1",
            currentModel: nil,
            currentMode: nil,
            autoRun: false,
            createdAt: 0,
            updatedAt: 0,
            lastOpenedAt: 0,
            archived: false
        ))

        let hydrator = try ACPSessionHydrator(path: path)
        let result = try await hydrator.hydrate(sessionId: "s")

        #expect(result.row.remoteSessionId == "remote-1")
    }

    @Test("missing session throws")
    func missingSession() async throws {
        let path = tmpStorePath()
        _ = try ACPSessionStore(path: path) // create schema
        let hydrator = try ACPSessionHydrator(path: path)
        await #expect(throws: ACPSessionHydrator.Error.self) {
            _ = try await hydrator.hydrate(sessionId: "missing")
        }
    }

    @Test("malformed payload is skipped, others survive")
    func malformedSkip() async throws {
        let path = tmpStorePath()
        let store = try ACPSessionStore(path: path)
        try store.upsertSession(.init(
            id: "s", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))

        // One good message + one corrupt payload.
        let goodPayload = try await MainActor.run {
            let m: ACPMessage = .user(id: UUID(), text: "ok", attachments: [])
            return try ACPMessageCodec.encode(m)
        }
        try store.appendMessage(sessionId: "s", id: "g", kind: "user",
                                seq: 0, payload: goodPayload, createdAt: 0)
        try store.appendMessage(sessionId: "s", id: "bad", kind: "user",
                                seq: 1, payload: Data([0xFF, 0xFE]), createdAt: 1)

        let hydrator = try ACPSessionHydrator(path: path)
        let result = try await hydrator.hydrate(sessionId: "s")
        #expect(result.wireMessages.count == 1)
    }

    @Test("hydrate bumps lastOpenedAt via touch(row)")
    func touchesLastOpenedAt() async throws {
        let path = tmpStorePath()
        let store = try ACPSessionStore(path: path)
        try store.upsertSession(.init(
            id: "s", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 100, updatedAt: 100, lastOpenedAt: 100, archived: false
        ))

        let hydrator = try ACPSessionHydrator(path: path)
        _ = try await hydrator.hydrate(sessionId: "s")

        // touch() rewrites lastOpenedAt to now (a recent unix timestamp).
        let row = try #require(try store.loadSession(id: "s"))
        #expect(row.lastOpenedAt > 100)
    }

    @Test("hydrate of a deleted session does not resurrect it")
    func deletedSessionStaysDeleted() async throws {
        let path = tmpStorePath()
        let store = try ACPSessionStore(path: path)
        try store.upsertSession(.init(
            id: "s", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false
        ))
        let hydrator = try ACPSessionHydrator(path: path)
        // Delete the row through the manager's store handle while the
        // hydrator still holds its own snapshot. With the old
        // `upsertSession` touch the hydrator would re-insert the row.
        try store.deleteSession(id: "s")
        _ = try? await hydrator.hydrate(sessionId: "s")
        #expect(try store.loadSession(id: "s") == nil)
    }

    @Test("hydrate of an archived session does not un-archive it")
    func archivedSessionStaysArchived() async throws {
        let path = tmpStorePath()
        let store = try ACPSessionStore(path: path)
        try store.upsertSession(.init(
            id: "s", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false
        ))
        let hydrator = try ACPSessionHydrator(path: path)
        try store.setArchived(id: "s", archived: true)
        _ = try await hydrator.hydrate(sessionId: "s")
        let row = try #require(try store.loadSession(id: "s"))
        #expect(row.archived == true)
    }
}
