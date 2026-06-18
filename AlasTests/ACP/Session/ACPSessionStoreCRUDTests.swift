import Foundation
import Testing
@testable import Alas

@Suite("ACPSessionStore CRUD")
struct ACPSessionStoreCRUDTests {
    private func tmpURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("acp-crud-\(UUID()).sqlite")
    }

    private func tmp() throws -> ACPSessionStore {
        try ACPSessionStore(path: tmpURL().path)
    }

    @Test("insert + load session round-trips fields")
    func sessions() throws {
        let store = try tmp()
        let row = ACPSessionRow(
            id: "s1", agentId: "claude", title: "hello",
            titleSource: .manual,
            currentModel: "sonnet", currentMode: "agent",
            autoRun: true,
            createdAt: 100, updatedAt: 100, lastOpenedAt: 100, archived: false)
        try store.upsertSession(row)
        let got = try #require(try store.loadSession(id: "s1"))
        #expect(got == row)
    }

    @Test("session row persists remote ACP session id")
    func sessionRowPersistsRemoteSessionId() throws {
        let store = try tmp()
        try store.upsertSession(.init(
            id: "local-1",
            agentId: "claude",
            title: "Restored",
            titleSource: .manual,
            remoteSessionId: "remote-1",
            currentModel: "sonnet",
            currentMode: "agent",
            autoRun: true,
            createdAt: 1,
            updatedAt: 2,
            lastOpenedAt: 3,
            archived: false
        ))

        let row = try #require(try store.loadSession(id: "local-1"))
        #expect(row.remoteSessionId == "remote-1")
        #expect(row.currentModel == "sonnet")
        #expect(row.currentMode == "agent")
        #expect(row.autoRun == true)
    }

    @Test("session metadata updates preserve stored remote ACP session id")
    func sessionMetadataUpdatesPreserveRemoteSessionId() throws {
        let store = try tmp()
        try store.upsertSession(.init(
            id: "local-1",
            agentId: "claude",
            title: "Restored",
            titleSource: .manual,
            remoteSessionId: "remote-1",
            currentModel: "sonnet",
            currentMode: "agent",
            autoRun: true,
            createdAt: 1,
            updatedAt: 2,
            lastOpenedAt: 3,
            archived: false
        ))

        try store.upsertSession(.init(
            id: "local-1",
            agentId: "claude",
            title: "Updated",
            titleSource: .manual,
            currentModel: "opus",
            currentMode: "agent",
            autoRun: true,
            createdAt: 1,
            updatedAt: 4,
            lastOpenedAt: 5,
            archived: false
        ))

        let row = try #require(try store.loadSession(id: "local-1"))
        #expect(row.remoteSessionId == "remote-1")
        #expect(row.title == "Updated")
        #expect(row.currentModel == "opus")
    }

    @Test("metadata-only upsert can preserve stored title")
    func sessionMetadataUpsertPreservesStoredTitleWhenRequested() throws {
        let store = try tmp()
        try store.upsertSession(.init(
            id: "local-1",
            agentId: "claude",
            title: "Remote Title",
            titleSource: .manual,
            currentModel: "sonnet",
            currentMode: nil,
            autoRun: false,
            createdAt: 1,
            updatedAt: 2,
            lastOpenedAt: 3,
            archived: false
        ))

        try store.upsertSession(.init(
            id: "local-1",
            agentId: "claude",
            title: "Stale Writer Title",
            titleSource: .placeholder,
            currentModel: "opus",
            currentMode: nil,
            autoRun: true,
            createdAt: 1,
            updatedAt: 4,
            lastOpenedAt: 5,
            archived: false
        ), preserveTitle: true)

        let row = try #require(try store.loadSession(id: "local-1"))
        #expect(row.title == "Remote Title")
        #expect(row.titleSource == .manual)
        #expect(row.currentModel == "opus")
        #expect(row.autoRun)
    }

    @Test("rename session reports archived rows as unchanged")
    func renameSessionReportsArchivedRowsAsUnchanged() throws {
        let store = try tmp()
        try store.upsertSession(.init(
            id: "local-1",
            agentId: "claude",
            title: "Archived",
            titleSource: .placeholder,
            currentModel: nil,
            currentMode: nil,
            autoRun: false,
            createdAt: 1,
            updatedAt: 2,
            lastOpenedAt: 3,
            archived: true
        ))

        let renamed = try store.renameSession(
            id: "local-1",
            title: "Remote Title",
            titleSource: .manual,
            updatedAt: 4
        )

        let row = try #require(try store.loadSession(id: "local-1"))
        #expect(!renamed)
        #expect(row.title == "Archived")
        #expect(row.titleSource == .placeholder)
    }

    @Test("generated title update only changes placeholder title rows")
    func generatedTitleUpdateOnlyChangesPlaceholderRows() throws {
        let store = try tmp()
        try store.upsertSession(.init(
            id: "placeholder",
            agentId: "claude",
            title: "New session",
            titleSource: .placeholder,
            currentModel: nil,
            currentMode: nil,
            autoRun: false,
            createdAt: 1,
            updatedAt: 2,
            lastOpenedAt: 3,
            archived: false
        ))
        try store.upsertSession(.init(
            id: "manual",
            agentId: "claude",
            title: "Remote Title",
            titleSource: .manual,
            currentModel: nil,
            currentMode: nil,
            autoRun: false,
            createdAt: 1,
            updatedAt: 2,
            lastOpenedAt: 3,
            archived: false
        ))

        let placeholderChanged = try store.updateGeneratedTitleIfPlaceholder(
            id: "placeholder",
            title: "Generated Title",
            updatedAt: 4
        )
        let manualChanged = try store.updateGeneratedTitleIfPlaceholder(
            id: "manual",
            title: "Stale Generated Title",
            updatedAt: 4
        )

        let placeholder = try #require(try store.loadSession(id: "placeholder"))
        let manual = try #require(try store.loadSession(id: "manual"))
        #expect(placeholderChanged)
        #expect(placeholder.title == "Generated Title")
        #expect(placeholder.titleSource == .generated)
        #expect(manualChanged == false)
        #expect(manual.title == "Remote Title")
        #expect(manual.titleSource == .manual)
    }

    @Test("context recovery pending is stored separately from metadata upserts")
    func contextRecoveryPendingRoundTrip() throws {
        let store = try tmp()
        try store.upsertSession(.init(
            id: "local-1",
            agentId: "claude",
            title: "Restored",
            titleSource: .manual,
            remoteSessionId: "remote-1",
            currentModel: nil,
            currentMode: nil,
            autoRun: false,
            createdAt: 1,
            updatedAt: 2,
            lastOpenedAt: 3,
            archived: false
        ))

        try store.setContextRecoveryPending(sessionId: "local-1", pending: true)
        try store.upsertSession(.init(
            id: "local-1",
            agentId: "claude",
            title: "Updated",
            titleSource: .manual,
            currentModel: "opus",
            currentMode: nil,
            autoRun: false,
            createdAt: 1,
            updatedAt: 4,
            lastOpenedAt: 5,
            archived: false
        ))

        var row = try #require(try store.loadSession(id: "local-1"))
        #expect(row.contextRecoveryPending)
        #expect(row.title == "Updated")

        try store.setContextRecoveryPending(sessionId: "local-1", pending: false)
        row = try #require(try store.loadSession(id: "local-1"))
        #expect(!row.contextRecoveryPending)
    }

    @Test("recent list orders by last_opened_at desc and skips archived")
    func recent() throws {
        let store = try tmp()
        try store.upsertSession(.init(id: "a", agentId: "claude", title: "A",
            titleSource: .manual,
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 1, updatedAt: 1, lastOpenedAt: 10, archived: false))
        try store.upsertSession(.init(id: "b", agentId: "claude", title: "B",
            titleSource: .manual,
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 2, updatedAt: 2, lastOpenedAt: 20, archived: false))
        try store.upsertSession(.init(id: "c", agentId: "claude", title: "C",
            titleSource: .manual,
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 3, updatedAt: 3, lastOpenedAt: 30, archived: true))
        let recent = try store.recentSessions(limit: 10)
        #expect(recent.map(\.id) == ["b", "a"])
    }

    @Test("append + load messages preserves order via seq")
    func messages() throws {
        let store = try tmp()
        try store.upsertSession(.init(id: "s", agentId: "claude", title: "t",
            titleSource: .placeholder,
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

    @Test("message row updates report whether a row existed")
    func updateMessageRowReportsChanges() throws {
        let store = try tmp()
        try store.upsertSession(.init(id: "s", agentId: "claude", title: "t",
            titleSource: .placeholder,
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        try store.appendMessage(
            sessionId: "s",
            id: "m1",
            kind: "agent",
            seq: 1,
            payload: Data("old".utf8),
            createdAt: 1
        )

        #expect(try store.updateMessageRow(
            id: "m1",
            kind: "user",
            seq: 0,
            payload: Data("new".utf8)
        ))
        #expect(try store.updateMessageRow(
            id: "missing",
            kind: "agent",
            seq: 2,
            payload: Data("ignored".utf8)
        ) == false)

        let loaded = try store.loadMessages(sessionId: "s")
        #expect(loaded.map(\.id) == ["m1"])
        #expect(loaded[0].kind == "user")
        #expect(loaded[0].seq == 0)
        #expect(loaded[0].payload == Data("new".utf8))
    }

    @Test("message count uses a narrow aggregate query")
    func messageCount() throws {
        let store = try tmp()
        try store.upsertSession(.init(id: "s", agentId: "claude", title: "t",
            titleSource: .placeholder,
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        try store.upsertSession(.init(id: "other", agentId: "claude", title: "t",
            titleSource: .placeholder,
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))

        try store.appendMessage(sessionId: "s", id: "m1", kind: "user", seq: 0, payload: Data("one".utf8), createdAt: 1)
        try store.appendMessage(sessionId: "s", id: "m2", kind: "agent", seq: 1, payload: Data("two".utf8), createdAt: 2)
        try store.appendMessage(sessionId: "other", id: "m3", kind: "agent", seq: 0, payload: Data("three".utf8), createdAt: 3)

        #expect(try store.messageCount(sessionId: "s") == 2)
        #expect(try store.messageCount(sessionId: "other") == 1)
        #expect(try store.messageCount(sessionId: "missing") == 0)
    }

    @Test("composer draft upsert load and delete round-trips")
    func composerDraftCRUD() throws {
        let url = tmpURL()
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(id: "s", agentId: "claude", title: "t",
            titleSource: .placeholder,
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))

        let draft = ACPComposerDraft(segments: [
            .text("Read "),
            .mention(displayName: "A.swift", uri: "file:///tmp/A.swift"),
            .text(" please")
        ])
        try store.upsertComposerDraft(sessionId: "s", draft: draft, updatedAt: 123)

        #expect(try store.loadComposerDraft(sessionId: "s") == draft)
        #expect(try ACPSessionStore(path: url.path).loadComposerDraft(sessionId: "s") == draft)

        try store.deleteComposerDraft(sessionId: "s")
        #expect(try store.loadComposerDraft(sessionId: "s") == nil)
    }

    @Test("composer draft is deleted with owning session")
    func composerDraftCascadesWithSession() throws {
        let store = try tmp()
        try store.upsertSession(.init(id: "s", agentId: "claude", title: "t",
            titleSource: .placeholder,
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
