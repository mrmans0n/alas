import Foundation

final class ACPSessionStore {
    static let targetSchemaVersion = 7
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
        if current < 3 { try migrate_to_v3() }
        if current < 4 { try migrate_to_v4() }
        if current < 5 { try migrate_to_v5() }
        if current < 6 { try migrate_to_v6() }
        if current < 7 { try migrate_to_v7() }
        try recoverFromConcurrentWriters()
        if current == 0 {
            try db.exec("INSERT INTO schema_version (version) VALUES (?)", bindings: [Int64(Self.targetSchemaVersion)])
        } else if current < Self.targetSchemaVersion {
            try db.exec("UPDATE schema_version SET version = ?", bindings: [Int64(Self.targetSchemaVersion)])
        }
        try db.exec("CREATE INDEX IF NOT EXISTS messages_session_kind_seq_idx ON messages(session_id, kind, seq)")
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

    private func migrate_to_v3() throws {
        // One row per session holds the JSON-encoded queue payload.
        // We rewrite the whole row on every mutation — items are small
        // and queue churn is low, so the cost is negligible. ON DELETE
        // CASCADE keeps the row in lockstep with the session.
        try db.exec("""
        CREATE TABLE IF NOT EXISTS session_queue (
          session_id  TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
          payload     BLOB NOT NULL,
          updated_at  INTEGER NOT NULL
        )
        """)
    }

    private func migrate_to_v4() throws {
        // Add title_source so manual renames are protected from auto-title
        // overwrites. Existing rows with a non-placeholder title are treated
        // as manual to avoid clobbering user-provided names; rows still at
        // "New session" (or empty) are placeholder.
        try db.exec("""
        ALTER TABLE sessions ADD COLUMN title_source TEXT NOT NULL DEFAULT 'manual'
        """)
        try db.exec("""
        UPDATE sessions SET title_source = 'placeholder'
        WHERE title = '' OR title = 'New session'
        """)
    }

    private func migrate_to_v5() throws {
        try db.exec("ALTER TABLE sessions ADD COLUMN remote_session_id TEXT")
    }

    private func migrate_to_v6() throws {
        try db.exec("ALTER TABLE sessions ADD COLUMN context_recovery_pending INTEGER NOT NULL DEFAULT 0")
    }

    /// One-time-per-open repair for databases damaged by two instances
    /// writing the same session before leases existed. Collapses
    /// duplicate (session_id, seq) message rows (keeping the newest by
    /// created_at) so hydration's `ORDER BY seq` stops yielding
    /// conflicting entries. Idempotent: a clean DB has no duplicates.
    private func recoverFromConcurrentWriters() throws {
        try db.exec("""
        DELETE FROM messages
        WHERE rowid NOT IN (
            SELECT rowid FROM (
                SELECT rowid,
                       ROW_NUMBER() OVER (
                           PARTITION BY session_id, seq
                           ORDER BY created_at DESC, rowid DESC
                       ) AS rn
                FROM messages
            ) WHERE rn = 1
        )
        """)
    }

    private func migrate_to_v7() throws {
        // One row per *owned* session. Presence + a live owner means a
        // writer holds the session; absence/staleness means it's free.
        // ON DELETE CASCADE keeps the lease in lockstep with the session.
        try db.exec("""
        CREATE TABLE IF NOT EXISTS session_leases (
          session_id      TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
          owner_instance  TEXT NOT NULL,
          pid             INTEGER NOT NULL,
          heartbeat_at    INTEGER NOT NULL,
          status          TEXT NOT NULL DEFAULT 'idle'
        )
        """)
    }
}

struct ACPSessionLease: Equatable {
    let sessionId: String
    let ownerInstance: String
    let pid: Int64
    let heartbeatAt: Int64
    let status: String   // "idle" | "busy"
}

struct ACPSessionRow: Equatable {
    let id: String
    let agentId: String
    var title: String
    var titleSource: ACPSessionTitleSource = .placeholder
    var remoteSessionId: String? = nil
    var contextRecoveryPending: Bool = false
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
        INSERT INTO sessions (id, agent_id, title, title_source, remote_session_id, context_recovery_pending,
                              current_model, current_mode, auto_run, created_at, updated_at, last_opened_at, archived)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
            title = excluded.title,
            title_source = excluded.title_source,
            remote_session_id = COALESCE(excluded.remote_session_id, sessions.remote_session_id),
            context_recovery_pending = sessions.context_recovery_pending,
            current_model = excluded.current_model,
            current_mode = excluded.current_mode,
            auto_run = excluded.auto_run,
            updated_at = excluded.updated_at,
            last_opened_at = excluded.last_opened_at,
            archived = excluded.archived
        """, bindings: [
            s.id, s.agentId, s.title, s.titleSource.rawValue, s.remoteSessionId, s.contextRecoveryPending ? 1 : 0,
            s.currentModel, s.currentMode, s.autoRun ? 1 : 0,
            s.createdAt, s.updatedAt, s.lastOpenedAt, s.archived ? 1 : 0
        ])
    }

    func loadSession(id: String) throws -> ACPSessionRow? {
        let rows = try db.query("SELECT * FROM sessions WHERE id = ?", bindings: [id])
        return rows.first.map(Self.rowToSession)
    }

    /// Bump `last_opened_at` for an existing row without touching any
    /// other field. No-op if the row is gone (the user deleted the
    /// session) — unlike `upsertSession`, this never resurrects a
    /// deleted row or flips `archived` back to false.
    func touchLastOpenedAt(id: String, at timestamp: Int64) throws {
        try db.exec(
            "UPDATE sessions SET last_opened_at = ? WHERE id = ?",
            bindings: [timestamp, id]
        )
    }

    func setContextRecoveryPending(sessionId: String, pending: Bool) throws {
        try db.exec(
            "UPDATE sessions SET context_recovery_pending = ? WHERE id = ?",
            bindings: [pending ? 1 : 0, sessionId]
        )
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

    func messageCount(sessionId: String) throws -> Int {
        let rows = try db.query("""
        SELECT COUNT(*) AS count
        FROM messages WHERE session_id = ?
        """, bindings: [sessionId])
        return Int((rows.first?["count"] as? Int64) ?? 0)
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

    func loadToolCallContent(sessionId: String, toolCallId: String) throws -> String? {
        let rows = try db.query("""
        SELECT payload FROM messages
        WHERE session_id = ? AND kind = 'tool_call'
        ORDER BY seq ASC
        """, bindings: [sessionId])
        let decoder = JSONDecoder()
        for row in rows {
            guard let payload = row["payload"] as? Data,
                  let tc = try? decoder.decode(ACPMessage.ToolCall.self, from: payload),
                  tc.toolCallId == toolCallId
            else { continue }
            return tc.content
        }
        return nil
    }

    private static func rowToSession(_ r: [String: Any?]) -> ACPSessionRow {
        let rawSource = r["title_source"] as? String ?? "placeholder"
        return ACPSessionRow(
            id: r["id"] as? String ?? "",
            agentId: r["agent_id"] as? String ?? "",
            title: r["title"] as? String ?? "",
            titleSource: ACPSessionTitleSource(rawValue: rawSource) ?? .placeholder,
            remoteSessionId: r["remote_session_id"] as? String,
            contextRecoveryPending: ((r["context_recovery_pending"] as? Int64) ?? 0) != 0,
            currentModel: r["current_model"] as? String,
            currentMode: r["current_mode"] as? String,
            autoRun: ((r["auto_run"] as? Int64) ?? 0) != 0,
            createdAt: (r["created_at"] as? Int64) ?? 0,
            updatedAt: (r["updated_at"] as? Int64) ?? 0,
            lastOpenedAt: (r["last_opened_at"] as? Int64) ?? 0,
            archived: ((r["archived"] as? Int64) ?? 0) != 0)
    }
}

extension ACPSessionStore {
    /// Replace the persisted queue for `sessionId` with `items`. An empty
    /// array deletes the row so `loadQueue` returns `[]` cleanly without
    /// an empty-array JSON blob lingering.
    func upsertQueue(sessionId: String, items: [QueuedPrompt]) throws {
        if items.isEmpty {
            try db.exec("DELETE FROM session_queue WHERE session_id = ?", bindings: [sessionId])
            return
        }
        let payload = try JSONEncoder().encode(items)
        let now = Int64(Date().timeIntervalSince1970)
        try db.exec("""
        INSERT INTO session_queue (session_id, payload, updated_at)
        VALUES (?,?,?)
        ON CONFLICT(session_id) DO UPDATE SET
            payload = excluded.payload,
            updated_at = excluded.updated_at
        """, bindings: [sessionId, payload, now])
    }

    func loadQueue(sessionId: String) throws -> [QueuedPrompt] {
        let rows = try db.query(
            "SELECT payload FROM session_queue WHERE session_id = ?",
            bindings: [sessionId])
        guard let payload = rows.first?["payload"] as? Data else { return [] }
        return (try? JSONDecoder().decode([QueuedPrompt].self, from: payload)) ?? []
    }
}

extension ACPSessionStore {
    func loadLease(sessionId: String) throws -> ACPSessionLease? {
        let rows = try db.query(
            "SELECT * FROM session_leases WHERE session_id = ?", bindings: [sessionId])
        guard let r = rows.first else { return nil }
        return ACPSessionLease(
            sessionId: r["session_id"] as? String ?? "",
            ownerInstance: r["owner_instance"] as? String ?? "",
            pid: (r["pid"] as? Int64) ?? 0,
            heartbeatAt: (r["heartbeat_at"] as? Int64) ?? 0,
            status: r["status"] as? String ?? "idle")
    }

    /// Atomically claim the writer role for `sessionId`. Returns true if
    /// this instance owns the lease afterwards.
    ///
    /// A lease is reclaimable when its heartbeat is older than
    /// `staleAfter` seconds, OR its owning process is no longer alive
    /// (fast crash reclaim). Re-claiming a lease this instance already
    /// holds always succeeds and refreshes the heartbeat.
    ///
    /// The dead-pid reclaim, the UPSERT, and the confirming read run in
    /// one `BEGIN IMMEDIATE` transaction so two instances racing on the
    /// same dead-owner lease can't both delete-then-insert and both win.
    /// A plain `BEGIN` (WAL) would defer the write lock and still race.
    func claimLease(sessionId: String, instanceId: String, pid: Int64,
                    now: Int64, staleAfter: Int64) throws -> Bool {
        let staleCutoff = now - staleAfter
        try db.exec("BEGIN IMMEDIATE")
        do {
            // Fast-path crash reclaim: a lease whose owner pid is dead can
            // be removed unconditionally — a dead pid never comes back.
            if let existing = try loadLease(sessionId: sessionId),
               existing.ownerInstance != instanceId,
               !ACPProcessLiveness.pidAlive(existing.pid) {
                try db.exec(
                    "DELETE FROM session_leases WHERE session_id = ? AND owner_instance = ?",
                    bindings: [sessionId, existing.ownerInstance])
            }
            try db.exec("""
            INSERT INTO session_leases (session_id, owner_instance, pid, heartbeat_at, status)
            VALUES (?,?,?,?,'idle')
            ON CONFLICT(session_id) DO UPDATE SET
                owner_instance = excluded.owner_instance,
                pid = excluded.pid,
                heartbeat_at = excluded.heartbeat_at,
                status = 'idle'
            WHERE session_leases.owner_instance = excluded.owner_instance
               OR session_leases.heartbeat_at < ?
            """, bindings: [sessionId, instanceId, pid, now, staleCutoff])
            let won = try loadLease(sessionId: sessionId)?.ownerInstance == instanceId
            try db.exec("COMMIT")
            return won
        } catch {
            try? db.exec("ROLLBACK")
            throw error
        }
    }

    /// Refresh heartbeat (and optionally status) — no-op if we no longer
    /// own the lease (someone took over).
    func refreshHeartbeat(sessionId: String, instanceId: String,
                          now: Int64, status: String) throws {
        try db.exec("""
        UPDATE session_leases SET heartbeat_at = ?, status = ?
        WHERE session_id = ? AND owner_instance = ?
        """, bindings: [now, status, sessionId, instanceId])
    }

    func releaseLease(sessionId: String, instanceId: String) throws {
        try db.exec(
            "DELETE FROM session_leases WHERE session_id = ? AND owner_instance = ?",
            bindings: [sessionId, instanceId])
    }

    /// Forcibly seize the lease (explicit user takeover) regardless of
    /// the current owner's liveness.
    func seizeLease(sessionId: String, instanceId: String, pid: Int64, now: Int64) throws {
        try db.exec("""
        INSERT INTO session_leases (session_id, owner_instance, pid, heartbeat_at, status)
        VALUES (?,?,?,?,'idle')
        ON CONFLICT(session_id) DO UPDATE SET
            owner_instance = excluded.owner_instance,
            pid = excluded.pid,
            heartbeat_at = excluded.heartbeat_at,
            status = 'idle'
        """, bindings: [sessionId, instanceId, pid, now])
    }
}
