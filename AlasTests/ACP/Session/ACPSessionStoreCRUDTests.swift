import Foundation
import Testing
@testable import Alas

@Suite("ACPSessionStore CRUD")
struct ACPSessionStoreCRUDTests {
    private func tmp() throws -> ACPSessionStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("acp-crud-\(UUID()).sqlite")
        return try ACPSessionStore(path: url.path)
    }

    @Test("insert + load session round-trips fields")
    func sessions() throws {
        let store = try tmp()
        let row = ACPSessionRow(
            id: "s1", agentId: "claude", title: "hello",
            currentModel: "sonnet", currentMode: "agent",
            autoRun: true,
            createdAt: 100, updatedAt: 100, lastOpenedAt: 100, archived: false)
        try store.upsertSession(row)
        let got = try #require(try store.loadSession(id: "s1"))
        #expect(got == row)
    }

    @Test("recent list orders by last_opened_at desc and skips archived")
    func recent() throws {
        let store = try tmp()
        try store.upsertSession(.init(id: "a", agentId: "claude", title: "A",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 1, updatedAt: 1, lastOpenedAt: 10, archived: false))
        try store.upsertSession(.init(id: "b", agentId: "claude", title: "B",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 2, updatedAt: 2, lastOpenedAt: 20, archived: false))
        try store.upsertSession(.init(id: "c", agentId: "claude", title: "C",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 3, updatedAt: 3, lastOpenedAt: 30, archived: true))
        let recent = try store.recentSessions(limit: 10)
        #expect(recent.map(\.id) == ["b", "a"])
    }

    @Test("append + load messages preserves order via seq")
    func messages() throws {
        let store = try tmp()
        try store.upsertSession(.init(id: "s", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        let m1 = Data(#"{"k":"user","v":"hi"}"#.utf8)
        let m2 = Data(#"{"k":"agent","v":"yo"}"#.utf8)
        try store.appendMessage(sessionId: "s", id: "m1", kind: "user", seq: 0, payload: m1, createdAt: 1)
        try store.appendMessage(sessionId: "s", id: "m2", kind: "agent", seq: 1, payload: m2, createdAt: 2)
        let loaded = try store.loadMessages(sessionId: "s")
        #expect(loaded.map(\.kind) == ["user", "agent"])
        #expect(loaded[0].payload == m1)
    }

    @Test("composer draft upsert load and delete round-trips")
    func composerDraftCRUD() throws {
        let store = try tmp()
        try store.upsertSession(.init(id: "s", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))

        let draft = ACPComposerDraft(segments: [
            .text("Read "),
            .mention(displayName: "A.swift", uri: "file:///tmp/A.swift"),
            .text(" please")
        ])
        try store.upsertComposerDraft(sessionId: "s", draft: draft, updatedAt: 123)

        #expect(try store.loadComposerDraft(sessionId: "s") == draft)

        try store.deleteComposerDraft(sessionId: "s")
        #expect(try store.loadComposerDraft(sessionId: "s") == nil)
    }

    @Test("composer draft is deleted with owning session")
    func composerDraftCascadesWithSession() throws {
        let store = try tmp()
        try store.upsertSession(.init(id: "s", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        try store.upsertComposerDraft(
            sessionId: "s",
            draft: ACPComposerDraft(segments: [.text("unsent")]),
            updatedAt: 123
        )

        try store.deleteSession(id: "s")

        #expect(try store.loadComposerDraft(sessionId: "s") == nil)
    }
}
