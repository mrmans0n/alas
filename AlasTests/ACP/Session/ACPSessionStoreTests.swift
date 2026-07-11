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
}
