import Foundation
import Testing
@testable import Alas

@Suite("ACPSessionStore — schema + migrations")
struct ACPSessionStoreSchemaTests {
    private func tmpStore() throws -> ACPSessionStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("acp-store-\(UUID()).sqlite")
        return try ACPSessionStore(path: url.path)
    }

    @Test("opens a fresh DB at the target schema version")
    func freshSchema() throws {
        let store = try tmpStore()
        #expect(try store.currentSchemaVersion() == ACPSessionStore.targetSchemaVersion)
    }

    @Test("re-opening doesn't double-apply migrations")
    func idempotent() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("acp-store-\(UUID()).sqlite")
        _ = try ACPSessionStore(path: url.path)
        _ = try ACPSessionStore(path: url.path) // must not throw
    }

    @Test("migrates a version 10 lease table with a stable token column")
    func migratesV10LeaseToken() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("acp-store-\(UUID()).sqlite")
        do {
            let store = try ACPSessionStore(path: url.path)
            try store.db.exec("ALTER TABLE session_leases DROP COLUMN lease_token")
            try store.db.exec("UPDATE schema_version SET version = 10")
        }

        let store = try ACPSessionStore(path: url.path)
        let columns = try store.db.query("PRAGMA table_info(session_leases)")
        #expect(columns.contains { ($0["name"] as? String) == "lease_token" })
        let sessionColumns = try store.db.query("PRAGMA table_info(sessions)")
        #expect(sessionColumns.contains { ($0["name"] as? String) == "helper_proc_stdout_offset" })
        #expect(sessionColumns.contains { ($0["name"] as? String) == "helper_proc_stderr_offset" })
        #expect(sessionColumns.contains { ($0["name"] as? String) == "acp_broker_id" })
        #expect(sessionColumns.contains { ($0["name"] as? String) == "acp_broker_generation" })
        #expect(sessionColumns.contains { ($0["name"] as? String) == "acp_broker_acknowledged_cursor" })
        #expect(try store.currentSchemaVersion() == ACPSessionStore.targetSchemaVersion)

        _ = try ACPSessionStore(path: url.path)
    }

    @Test("migrates schema version 13 with broker state columns and index")
    func migratesV13BrokerState() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("acp-store-\(UUID()).sqlite")
        do {
            let store = try ACPSessionStore(path: url.path)
            try store.db.exec("DROP INDEX IF EXISTS sessions_acp_broker_idx")
            try store.db.exec("ALTER TABLE sessions DROP COLUMN acp_broker_id")
            try store.db.exec("ALTER TABLE sessions DROP COLUMN acp_broker_generation")
            try store.db.exec("ALTER TABLE sessions DROP COLUMN acp_broker_acknowledged_cursor")
            try store.db.exec("UPDATE schema_version SET version = 13")
        }

        let store = try ACPSessionStore(path: url.path)
        let columns = try store.db.query("PRAGMA table_info(sessions)")
        #expect(columns.contains { ($0["name"] as? String) == "acp_broker_id" })
        #expect(columns.contains { ($0["name"] as? String) == "acp_broker_generation" })
        #expect(columns.contains { ($0["name"] as? String) == "acp_broker_acknowledged_cursor" })
        let indexes = try store.db.query("PRAGMA index_list(sessions)")
        #expect(indexes.contains { ($0["name"] as? String) == "sessions_acp_broker_idx" })
        #expect(try store.currentSchemaVersion() == ACPSessionStore.targetSchemaVersion)
    }

    @Test("migrates schema version 1 to current target")
    func migratesV1ToCurrent() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("acp-store-\(UUID()).sqlite")
        do {
            let db = try SQLiteDatabase(path: url.path)
            try db.exec("""
            CREATE TABLE schema_version (
              version INTEGER NOT NULL
            )
            """)
            try db.exec("""
            CREATE TABLE sessions (
              id              TEXT PRIMARY KEY,
              agent_id        TEXT NOT NULL,
              title           TEXT NOT NULL,
              current_model   TEXT,
              current_mode    TEXT,
              auto_run        INTEGER NOT NULL DEFAULT 0,
              created_at      INTEGER NOT NULL,
              updated_at      INTEGER NOT NULL,
              last_opened_at  INTEGER NOT NULL,
              archived        INTEGER NOT NULL DEFAULT 0
            )
            """)
            try db.exec("CREATE INDEX sessions_recent_idx ON sessions(archived, last_opened_at DESC)")
            try db.exec("""
            CREATE TABLE messages (
              id          TEXT PRIMARY KEY,
              session_id  TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
              kind        TEXT NOT NULL,
              seq         INTEGER NOT NULL,
              payload     BLOB NOT NULL,
              created_at  INTEGER NOT NULL
            )
            """)
            try db.exec("CREATE INDEX messages_session_seq_idx ON messages(session_id, seq)")
            try db.exec("""
            CREATE TABLE permission_decisions (
              session_id  TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
              scope_key   TEXT NOT NULL,
              decision    TEXT NOT NULL,
              scope       TEXT NOT NULL,
              decided_at  INTEGER NOT NULL,
              PRIMARY KEY (session_id, scope_key)
            )
            """)
            try db.exec("INSERT INTO schema_version (version) VALUES (?)", bindings: [Int64(1)])
        }

        let store = try ACPSessionStore(path: url.path)
        #expect(try store.currentSchemaVersion() == ACPSessionStore.targetSchemaVersion)

        let draft = ACPComposerDraft(segments: [.text("migrated")])
        try store.upsertSession(.init(id: "s", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        try store.upsertComposerDraft(sessionId: "s", draft: draft, updatedAt: 123)

        #expect(try store.loadComposerDraft(sessionId: "s") == draft)
        #expect(try store.loadComposerDraftRecord(sessionId: "s")?.submittedRecovery == false)
    }

    @Test("streaming salvage never replaces an existing deterministic row")
    @MainActor
    func insertMessageIfMissingPreservesNewOwnerRow() throws {
        let store = try tmpStore()
        try store.upsertSession(.init(id: "s", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        let first = ACPStoredMessage(
            id: "msg-s-1", sessionId: "s", kind: "agent", seq: 1,
            payload: try ACPMessageCodec.encode(.agent(id: UUID(), StreamingText("new owner"))),
            createdAt: 1
        )
        let stale = ACPStoredMessage(
            id: "msg-s-1", sessionId: "s", kind: "agent", seq: 1,
            payload: try ACPMessageCodec.encode(.agent(id: UUID(), StreamingText("former owner"))),
            createdAt: 2
        )

        #expect(try store.insertMessageIfMissing(first))
        #expect(!(try store.insertMessageIfMissing(stale)))
        let stored = try #require(try store.loadMessages(sessionId: "s").first)
        guard case .agent(_, _, let text) = try ACPMessageCodec.decode(kind: stored.kind, payload: stored.payload) else {
            Issue.record("expected agent message")
            return
        }
        #expect(text.value == "new owner")
    }

    @Test("mcp preamble round-trips and survives upsert")
    func mcpPreambleRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-preamble-\(UUID().uuidString).sqlite")
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(id: "s", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))

        // Defaults: nothing pending, not sent.
        var row = try #require(try store.loadSession(id: "s"))
        #expect(row.mcpPreamblePending == nil)
        #expect(row.mcpPreambleSent == false)

        try store.setMCPPreamble(sessionId: "s", pendingText: "<ctx>", sent: false)
        row = try #require(try store.loadSession(id: "s"))
        #expect(row.mcpPreamblePending == "<ctx>")
        #expect(row.mcpPreambleSent == false)

        // A runtime upsert must not clobber preamble state (mirrors
        // context_recovery_pending semantics).
        try store.upsertSession(.init(id: "s", agentId: "claude", title: "t2",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 1, lastOpenedAt: 1, archived: false))
        row = try #require(try store.loadSession(id: "s"))
        #expect(row.mcpPreamblePending == "<ctx>")

        try store.setMCPPreamble(sessionId: "s", pendingText: nil, sent: true)
        row = try #require(try store.loadSession(id: "s"))
        #expect(row.mcpPreamblePending == nil)
        #expect(row.mcpPreambleSent == true)
    }
}
