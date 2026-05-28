import Foundation

final class ACPSessionStore {
    static let targetSchemaVersion = 2
    let db: SQLiteDatabase

    init(path: String) throws {
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        self.db = try SQLiteDatabase(path: path)
        try migrate()
    }

    func currentSchemaVersion() throws -> Int {
        let rows = try db.query("SELECT version FROM schema_version LIMIT 1")
        return (rows.first?["version"] as? Int64).map(Int.init) ?? 0
    }

    private func migrate() throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS schema_version (
          version INTEGER NOT NULL
        )
        """)
        let rows = try db.query("SELECT version FROM schema_version LIMIT 1")
        let current = Int((rows.first?["version"] as? Int64) ?? 0)
        if current < 1 { try migrate_to_v1() }
        if current < 2 { try migrate_to_v2() }
        if current == 0 {
            try db.exec("INSERT INTO schema_version (version) VALUES (?)", bindings: [Int64(Self.targetSchemaVersion)])
        } else if current < Self.targetSchemaVersion {
            try db.exec("UPDATE schema_version SET version = ?", bindings: [Int64(Self.targetSchemaVersion)])
        }
    }

    private func migrate_to_v1() throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS sessions (
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
        try db.exec("CREATE INDEX IF NOT EXISTS sessions_recent_idx ON sessions(archived, last_opened_at DESC)")

        try db.exec("""
        CREATE TABLE IF NOT EXISTS messages (
          id          TEXT PRIMARY KEY,
          session_id  TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
          kind        TEXT NOT NULL,
          seq         INTEGER NOT NULL,
          payload     BLOB NOT NULL,
          created_at  INTEGER NOT NULL
        )
        """)
        try db.exec("CREATE INDEX IF NOT EXISTS messages_session_seq_idx ON messages(session_id, seq)")

        try db.exec("""
        CREATE TABLE IF NOT EXISTS permission_decisions (
          session_id  TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
          scope_key   TEXT NOT NULL,
          decision    TEXT NOT NULL,
          scope       TEXT NOT NULL,
          decided_at  INTEGER NOT NULL,
          PRIMARY KEY (session_id, scope_key)
        )
        """)
    }

    private func migrate_to_v2() throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS composer_drafts (
          session_id  TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
          payload     BLOB NOT NULL,
          updated_at  INTEGER NOT NULL
        )
        """)
    }
}

struct ACPSessionRow: Equatable {
    let id: String
    let agentId: String
    var title: String
    var currentModel: String?
    var currentMode: String?
    var autoRun: Bool
    let createdAt: Int64
    var updatedAt: Int64
    var lastOpenedAt: Int64
    var archived: Bool
}

struct ACPStoredMessage: Equatable {
    let id: String
    let sessionId: String
    let kind: String
    let seq: Int64
    let payload: Data
    let createdAt: Int64
}

extension ACPSessionStore {
    func upsertSession(_ s: ACPSessionRow) throws {
        try db.exec("""
        INSERT INTO sessions (id, agent_id, title, current_model, current_mode, auto_run,
                              created_at, updated_at, last_opened_at, archived)
        VALUES (?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
            title = excluded.title,
            current_model = excluded.current_model,
            current_mode = excluded.current_mode,
            auto_run = excluded.auto_run,
            updated_at = excluded.updated_at,
            last_opened_at = excluded.last_opened_at,
            archived = excluded.archived
        """, bindings: [
            s.id, s.agentId, s.title, s.currentModel, s.currentMode,
            s.autoRun ? 1 : 0,
            s.createdAt, s.updatedAt, s.lastOpenedAt, s.archived ? 1 : 0
        ])
    }

    func loadSession(id: String) throws -> ACPSessionRow? {
        let rows = try db.query("SELECT * FROM sessions WHERE id = ?", bindings: [id])
        return rows.first.map(Self.rowToSession)
    }

    func recentSessions(limit: Int = 50) throws -> [ACPSessionRow] {
        let rows = try db.query("""
        SELECT * FROM sessions WHERE archived = 0 ORDER BY last_opened_at DESC LIMIT ?
        """, bindings: [Int64(limit)])
        return rows.map(Self.rowToSession)
    }

    func deleteSession(id: String) throws {
        try db.exec("DELETE FROM sessions WHERE id = ?", bindings: [id])
    }

    func loadComposerDraft(sessionId: String) throws -> ACPComposerDraft? {
        let rows = try db.query("""
        SELECT payload FROM composer_drafts WHERE session_id = ?
        """, bindings: [sessionId])
        guard let payload = rows.first?["payload"] as? Data else { return nil }
        return try JSONDecoder().decode(ACPComposerDraft.self, from: payload)
    }

    func upsertComposerDraft(sessionId: String, draft: ACPComposerDraft, updatedAt: Int64) throws {
        let payload = try JSONEncoder().encode(draft)
        try db.exec("""
        INSERT INTO composer_drafts (session_id, payload, updated_at)
        VALUES (?,?,?)
        ON CONFLICT(session_id) DO UPDATE SET
            payload = excluded.payload,
            updated_at = excluded.updated_at
        """, bindings: [sessionId, payload, updatedAt])
    }

    func deleteComposerDraft(sessionId: String) throws {
        try db.exec("DELETE FROM composer_drafts WHERE session_id = ?", bindings: [sessionId])
    }

    func setArchived(id: String, archived: Bool) throws {
        try db.exec("UPDATE sessions SET archived = ? WHERE id = ?", bindings: [archived ? 1 : 0, id])
    }

    func appendMessage(sessionId: String, id: String, kind: String, seq: Int64, payload: Data, createdAt: Int64) throws {
        try db.exec("""
        INSERT INTO messages (id, session_id, kind, seq, payload, created_at)
        VALUES (?,?,?,?,?,?)
        """, bindings: [id, sessionId, kind, seq, payload, createdAt])
    }

    func updateMessagePayload(id: String, payload: Data) throws {
        try db.exec("UPDATE messages SET payload = ? WHERE id = ?", bindings: [payload, id])
    }

    func loadMessages(sessionId: String) throws -> [ACPStoredMessage] {
        let rows = try db.query("""
        SELECT id, session_id, kind, seq, payload, created_at
        FROM messages WHERE session_id = ? ORDER BY seq ASC
        """, bindings: [sessionId])
        return rows.map { r in
            ACPStoredMessage(
                id: r["id"] as? String ?? "",
                sessionId: r["session_id"] as? String ?? "",
                kind: r["kind"] as? String ?? "",
                seq: (r["seq"] as? Int64) ?? 0,
                payload: (r["payload"] as? Data) ?? Data(),
                createdAt: (r["created_at"] as? Int64) ?? 0)
        }
    }

    private static func rowToSession(_ r: [String: Any?]) -> ACPSessionRow {
        ACPSessionRow(
            id: r["id"] as? String ?? "",
            agentId: r["agent_id"] as? String ?? "",
            title: r["title"] as? String ?? "",
            currentModel: r["current_model"] as? String,
            currentMode: r["current_mode"] as? String,
            autoRun: ((r["auto_run"] as? Int64) ?? 0) != 0,
            createdAt: (r["created_at"] as? Int64) ?? 0,
            updatedAt: (r["updated_at"] as? Int64) ?? 0,
            lastOpenedAt: (r["last_opened_at"] as? Int64) ?? 0,
            archived: ((r["archived"] as? Int64) ?? 0) != 0)
    }
}
