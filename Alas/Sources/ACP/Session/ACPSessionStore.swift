import Foundation

final class ACPSessionStore {
    static let targetSchemaVersion = 15
    let path: String
    let db: SQLiteDatabase

    init(path: String, busyTimeoutMilliseconds: Int32 = 5_000) throws {
        self.path = path
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        self.db = try SQLiteDatabase(path: path, busyTimeoutMilliseconds: busyTimeoutMilliseconds)
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
        if current < 8 { try migrate_to_v8() }
        if current < 9 { try migrate_to_v9() }
        if current < 10 { try migrate_to_v10() }
        if current < 11 { try migrate_to_v11() }
        if current < 12 { try migrate_to_v12() }
        if current < 13 { try migrate_to_v13() }
        if current < 14 { try migrate_to_v14() }
        if current < 15 { try migrate_to_v15() }
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

    private func migrate_to_v8() throws {
        try db.exec("ALTER TABLE sessions ADD COLUMN origin TEXT NOT NULL DEFAULT 'alasCreated'")
        try db.exec("""
        CREATE INDEX IF NOT EXISTS sessions_agent_remote_idx
        ON sessions(agent_id, remote_session_id)
        WHERE remote_session_id IS NOT NULL
        """)
    }

    private func migrate_to_v9() throws {
        try db.exec("ALTER TABLE composer_drafts ADD COLUMN submitted_recovery INTEGER NOT NULL DEFAULT 0")
    }

    private func migrate_to_v10() throws {
        try db.exec("ALTER TABLE composer_drafts ADD COLUMN submitted_after_seq INTEGER")
    }

    private func migrate_to_v11() throws {
        let columns = try db.query("PRAGMA table_info(session_leases)")
        guard !columns.contains(where: { ($0["name"] as? String) == "lease_token" }) else { return }
        try db.exec("ALTER TABLE session_leases ADD COLUMN lease_token TEXT NOT NULL DEFAULT ''")
    }

    private func migrate_to_v12() throws {
        let columns = try db.query("PRAGMA table_info(sessions)")
        let names = Set(columns.compactMap { $0["name"] as? String })
        if !names.contains("helper_proc_stdout_offset") {
            try db.exec("ALTER TABLE sessions ADD COLUMN helper_proc_stdout_offset INTEGER")
        }
        if !names.contains("helper_proc_stderr_offset") {
            try db.exec("ALTER TABLE sessions ADD COLUMN helper_proc_stderr_offset INTEGER")
        }
    }

    private func migrate_to_v13() throws {
        let columns = try db.query("PRAGMA table_info(sessions)")
        let names = Set(columns.compactMap { $0["name"] as? String })
        if !names.contains("mcp_preamble_pending") {
            try db.exec("ALTER TABLE sessions ADD COLUMN mcp_preamble_pending TEXT")
        }
        if !names.contains("mcp_preamble_sent") {
            try db.exec("ALTER TABLE sessions ADD COLUMN mcp_preamble_sent INTEGER NOT NULL DEFAULT 0")
        }
    }

    private func migrate_to_v14() throws {
        let columns = try db.query("PRAGMA table_info(sessions)")
        let names = Set(columns.compactMap { $0["name"] as? String })
        if !names.contains("acp_broker_id") {
            try db.exec("ALTER TABLE sessions ADD COLUMN acp_broker_id TEXT")
        }
        if !names.contains("acp_broker_generation") {
            try db.exec("ALTER TABLE sessions ADD COLUMN acp_broker_generation INTEGER")
        }
        if !names.contains("acp_broker_acknowledged_cursor") {
            try db.exec("ALTER TABLE sessions ADD COLUMN acp_broker_acknowledged_cursor INTEGER NOT NULL DEFAULT 0")
        }
        try db.exec("""
        CREATE INDEX IF NOT EXISTS sessions_acp_broker_idx
        ON sessions(acp_broker_id)
        WHERE acp_broker_id IS NOT NULL
        """)
    }

    private func migrate_to_v15() throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS session_forks (
          target_session_id          TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
          source_session_id          TEXT NOT NULL,
          source_agent_id            TEXT NOT NULL,
          source_boundary_seq        INTEGER NOT NULL,
          inherited_message_count    INTEGER NOT NULL,
          phase                      TEXT NOT NULL,
          mechanism                  TEXT,
          context_delivery_pending   INTEGER NOT NULL DEFAULT 0
        )
        """)
    }
}

struct ACPSessionLease: Equatable, Sendable {
    let sessionId: String
    let ownerInstance: String
    let pid: Int64
    let heartbeatAt: Int64
    let status: String   // "idle" | "busy"
    let token: String
}

struct ACPSessionLeaseFence: Equatable, Sendable {
    let sessionId: String
    let ownerInstance: String
    let token: String
}

enum ACPSessionOrigin: String, Codable, Equatable, Sendable {
    case alasCreated
    case agentImported
    case agentForked
}

struct ACPSessionRow: Equatable, Sendable {
    let id: String
    let agentId: String
    var title: String
    var titleSource: ACPSessionTitleSource = .placeholder
    var remoteSessionId: String? = nil
    var origin: ACPSessionOrigin = .alasCreated
    var contextRecoveryPending: Bool = false
    var mcpPreamblePending: String? = nil
    var mcpPreambleSent: Bool = false
    var currentModel: String?
    var currentMode: String?
    var autoRun: Bool
    var helperProcStdoutOffset: Int64? = nil
    var helperProcStderrOffset: Int64? = nil
    var acpBrokerId: String? = nil
    var acpBrokerGeneration: Int64? = nil
    var acpBrokerAcknowledgedCursor: Int64 = 0
    let createdAt: Int64
    var updatedAt: Int64
    var lastOpenedAt: Int64
    var archived: Bool
}

struct ACPStoredMessage: Equatable, Sendable {
    let id: String
    let sessionId: String
    let kind: String
    let seq: Int64
    let payload: Data
    let createdAt: Int64
}

struct ACPStoredComposerDraft: Equatable, Sendable {
    let draft: ACPComposerDraft
    let updatedAt: Int64
    let payload: Data
    let submittedRecovery: Bool
    let submittedAfterSeq: Int64?
}

extension ACPSessionStore {
    func recordPermissionDecision(
        sessionId: String,
        scopeKey: String,
        decision: ACPPermissionDecision,
        scope: ACPPermissionScopeKind,
        decidedAt: Int64
    ) throws {
        try db.exec("""
        INSERT INTO permission_decisions (session_id, scope_key, decision, scope, decided_at)
        VALUES (?,?,?,?,?)
        ON CONFLICT(session_id, scope_key) DO UPDATE SET
            decision = excluded.decision,
            scope = excluded.scope,
            decided_at = excluded.decided_at
        """, bindings: [sessionId, scopeKey, decision.rawValue, scope.rawValue, decidedAt])
    }

    func lookupPermissionDecision(sessionId: String, scopeKey: String) throws -> ACPPermissionDecision? {
        let sessionRows = try db.query("""
        SELECT decision FROM permission_decisions WHERE session_id = ? AND scope_key = ?
        """, bindings: [sessionId, scopeKey])
        if let decision = sessionRows.first?["decision"] as? String {
            return ACPPermissionDecision(rawValue: decision)
        }
        let projectRows = try db.query("""
        SELECT decision FROM permission_decisions
        WHERE scope_key = ? AND scope = 'project' LIMIT 1
        """, bindings: [scopeKey])
        return (projectRows.first?["decision"] as? String).flatMap(ACPPermissionDecision.init(rawValue:))
    }
}

extension ACPSessionStore {
    func createFork(
        session: ACPSessionRow,
        messages: [ACPStoredMessage],
        record: ACPSessionForkRecord
    ) throws {
        try db.transaction {
            try upsertSession(session)
            for message in messages {
                try appendMessage(
                    sessionId: message.sessionId,
                    id: message.id,
                    kind: message.kind,
                    seq: message.seq,
                    payload: message.payload,
                    createdAt: message.createdAt
                )
            }
            try upsertFork(record)
        }
    }

    func upsertFork(_ record: ACPSessionForkRecord) throws {
        try db.exec("""
        INSERT INTO session_forks (
          target_session_id, source_session_id, source_agent_id,
          source_boundary_seq, inherited_message_count, phase,
          mechanism, context_delivery_pending
        ) VALUES (?,?,?,?,?,?,?,?)
        ON CONFLICT(target_session_id) DO UPDATE SET
          source_session_id = excluded.source_session_id,
          source_agent_id = excluded.source_agent_id,
          source_boundary_seq = excluded.source_boundary_seq,
          inherited_message_count = excluded.inherited_message_count,
          phase = excluded.phase,
          mechanism = excluded.mechanism,
          context_delivery_pending = excluded.context_delivery_pending
        """, bindings: [
            record.targetSessionID,
            record.sourceSessionID,
            record.sourceAgentID,
            record.sourceBoundarySequence,
            record.inheritedMessageCount,
            record.phase.rawValue,
            record.mechanism?.rawValue,
            record.contextDeliveryPending ? 1 : 0
        ])
    }

    func loadFork(targetSessionID: String) throws -> ACPSessionForkRecord? {
        let rows = try db.query(
            "SELECT * FROM session_forks WHERE target_session_id = ?",
            bindings: [targetSessionID]
        )
        guard let row = rows.first,
              let phaseValue = row["phase"] as? String,
              let phase = ACPSessionForkCreationPhase(rawValue: phaseValue)
        else { return nil }
        return ACPSessionForkRecord(
            targetSessionID: row["target_session_id"] as? String ?? "",
            sourceSessionID: row["source_session_id"] as? String ?? "",
            sourceAgentID: row["source_agent_id"] as? String ?? "",
            sourceBoundarySequence: (row["source_boundary_seq"] as? Int64) ?? 0,
            inheritedMessageCount: Int((row["inherited_message_count"] as? Int64) ?? 0),
            phase: phase,
            mechanism: (row["mechanism"] as? String).flatMap(ACPSessionForkMechanism.init(rawValue:)),
            contextDeliveryPending: ((row["context_delivery_pending"] as? Int64) ?? 0) != 0
        )
    }

    func finalizeFork(
        targetSessionID: String,
        mechanism: ACPSessionForkMechanism,
        remoteSessionID: String?
    ) throws {
        try db.transaction {
            try db.exec("""
            UPDATE session_forks
            SET phase = ?, mechanism = ?, context_delivery_pending = ?
            WHERE target_session_id = ?
            """, bindings: [
                ACPSessionForkCreationPhase.ready.rawValue,
                mechanism.rawValue,
                mechanism == .transcriptTransfer ? 1 : 0,
                targetSessionID
            ])
            if let remoteSessionID {
                try db.exec(
                    "UPDATE sessions SET remote_session_id = ?, origin = ? WHERE id = ?",
                    bindings: [remoteSessionID, ACPSessionOrigin.agentForked.rawValue, targetSessionID]
                )
            }
        }
    }

    func clearForkContextDeliveryPending(targetSessionID: String) throws {
        try db.exec("""
        UPDATE session_forks
        SET context_delivery_pending = 0
        WHERE target_session_id = ?
        """, bindings: [targetSessionID])
    }

    func upsertSession(_ s: ACPSessionRow, preserveTitle: Bool = false) throws {
        try db.exec("""
        INSERT INTO sessions (id, agent_id, title, title_source, remote_session_id, origin, context_recovery_pending,
                              mcp_preamble_pending, mcp_preamble_sent,
                              current_model, current_mode, auto_run, helper_proc_stdout_offset,
                              helper_proc_stderr_offset, acp_broker_id, acp_broker_generation,
                              acp_broker_acknowledged_cursor, created_at, updated_at, last_opened_at, archived)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
            title = CASE WHEN ? THEN sessions.title ELSE excluded.title END,
            title_source = CASE WHEN ? THEN sessions.title_source ELSE excluded.title_source END,
            remote_session_id = COALESCE(excluded.remote_session_id, sessions.remote_session_id),
            origin = excluded.origin,
            context_recovery_pending = sessions.context_recovery_pending,
            mcp_preamble_pending = sessions.mcp_preamble_pending,
            mcp_preamble_sent = sessions.mcp_preamble_sent,
            current_model = excluded.current_model,
            current_mode = excluded.current_mode,
            auto_run = excluded.auto_run,
            helper_proc_stdout_offset = COALESCE(excluded.helper_proc_stdout_offset, sessions.helper_proc_stdout_offset),
            helper_proc_stderr_offset = COALESCE(excluded.helper_proc_stderr_offset, sessions.helper_proc_stderr_offset),
            acp_broker_id = COALESCE(excluded.acp_broker_id, sessions.acp_broker_id),
            acp_broker_generation = COALESCE(excluded.acp_broker_generation, sessions.acp_broker_generation),
            acp_broker_acknowledged_cursor = CASE
                WHEN COALESCE(excluded.acp_broker_id, sessions.acp_broker_id) IS sessions.acp_broker_id
                 AND COALESCE(excluded.acp_broker_generation, sessions.acp_broker_generation) IS sessions.acp_broker_generation
                THEN MAX(sessions.acp_broker_acknowledged_cursor, excluded.acp_broker_acknowledged_cursor)
                ELSE excluded.acp_broker_acknowledged_cursor
            END,
            updated_at = excluded.updated_at,
            last_opened_at = excluded.last_opened_at,
            archived = excluded.archived
        """, bindings: [
            s.id, s.agentId, s.title, s.titleSource.rawValue, s.remoteSessionId, s.origin.rawValue,
            s.contextRecoveryPending ? 1 : 0,
            s.mcpPreamblePending, s.mcpPreambleSent ? 1 : 0,
            s.currentModel, s.currentMode, s.autoRun ? 1 : 0,
            s.helperProcStdoutOffset, s.helperProcStderrOffset,
            s.acpBrokerId, s.acpBrokerGeneration, s.acpBrokerAcknowledgedCursor,
            s.createdAt, s.updatedAt, s.lastOpenedAt, s.archived ? 1 : 0,
            preserveTitle ? 1 : 0,
            preserveTitle ? 1 : 0
        ])
    }

    func loadSession(id: String) throws -> ACPSessionRow? {
        let rows = try db.query("SELECT * FROM sessions WHERE id = ?", bindings: [id])
        return rows.first.map(Self.rowToSession)
    }

    func loadSession(acpBrokerId: String) throws -> ACPSessionRow? {
        let rows = try db.query("""
        SELECT * FROM sessions
        WHERE acp_broker_id = ? AND archived = 0
        ORDER BY last_opened_at DESC
        LIMIT 1
        """, bindings: [acpBrokerId])
        return rows.first.map(Self.rowToSession)
    }

    func loadSession(agentId: String, remoteSessionId: String) throws -> ACPSessionRow? {
        let rows = try db.query("""
        SELECT * FROM sessions
        WHERE agent_id = ? AND remote_session_id = ? AND archived = 0
        ORDER BY last_opened_at DESC
        LIMIT 1
        """, bindings: [agentId, remoteSessionId])
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

    func setMCPPreamble(sessionId: String, pendingText: String?, sent: Bool) throws {
        try db.exec(
            "UPDATE sessions SET mcp_preamble_pending = ?, mcp_preamble_sent = ? WHERE id = ?",
            bindings: [pendingText, sent ? 1 : 0, sessionId]
        )
    }

    func updateHelperProcOffsets(sessionId: String, stdoutOffset: Int64?, stderrOffset: Int64?) throws -> Bool {
        try db.execChanges("""
        UPDATE sessions
        SET helper_proc_stdout_offset = CASE
                WHEN ? IS NULL THEN helper_proc_stdout_offset
                WHEN helper_proc_stdout_offset IS NULL OR helper_proc_stdout_offset < ? THEN ?
                ELSE helper_proc_stdout_offset
            END,
            helper_proc_stderr_offset = CASE
                WHEN ? IS NULL THEN helper_proc_stderr_offset
                WHEN helper_proc_stderr_offset IS NULL OR helper_proc_stderr_offset < ? THEN ?
                ELSE helper_proc_stderr_offset
            END
        WHERE id = ?
        """, bindings: [
            stdoutOffset, stdoutOffset, stdoutOffset,
            stderrOffset, stderrOffset, stderrOffset,
            sessionId
        ]) > 0
    }

    func resetHelperProcOffsets(sessionId: String) throws -> Bool {
        try db.execChanges("""
        UPDATE sessions
        SET helper_proc_stdout_offset = 0,
            helper_proc_stderr_offset = 0
        WHERE id = ?
        """, bindings: [sessionId]) > 0
    }

    func updateACPBrokerState(
        sessionId: String,
        brokerId: String,
        generation: Int64,
        acknowledgedCursor: Int64
    ) throws -> Bool {
        try db.execChanges("""
        UPDATE sessions
        SET acp_broker_id = ?,
            acp_broker_generation = ?,
            acp_broker_acknowledged_cursor = ?
        WHERE id = ?
        """, bindings: [brokerId, generation, acknowledgedCursor, sessionId]) > 0
    }

    func updateACPBrokerAcknowledgedCursor(
        sessionId: String,
        brokerId: String,
        generation: Int64,
        cursor: Int64
    ) throws -> Bool {
        try db.execChanges("""
        UPDATE sessions
        SET acp_broker_acknowledged_cursor = CASE
                WHEN acp_broker_acknowledged_cursor < ? THEN ?
                ELSE acp_broker_acknowledged_cursor
            END
        WHERE id = ?
          AND acp_broker_id = ?
          AND acp_broker_generation = ?
        """, bindings: [cursor, cursor, sessionId, brokerId, generation]) > 0
    }

    func clearACPBrokerState(sessionId: String) throws -> Bool {
        try db.execChanges("""
        UPDATE sessions
        SET acp_broker_id = NULL,
            acp_broker_generation = NULL,
            acp_broker_acknowledged_cursor = 0
        WHERE id = ?
        """, bindings: [sessionId]) > 0
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
        try loadComposerDraftRecord(sessionId: sessionId)?.draft
    }

    func loadComposerDraftRecord(sessionId: String) throws -> ACPStoredComposerDraft? {
        let rows = try db.query("""
        SELECT payload, updated_at, submitted_recovery, submitted_after_seq
        FROM composer_drafts WHERE session_id = ?
        """, bindings: [sessionId])
        guard let row = rows.first,
              let payload = row["payload"] as? Data,
              let updatedAt = row["updated_at"] as? Int64
        else { return nil }
        return try ACPStoredComposerDraft(
            draft: JSONDecoder().decode(ACPComposerDraft.self, from: payload),
            updatedAt: updatedAt,
            payload: payload,
            submittedRecovery: (row["submitted_recovery"] as? Int64) == 1,
            submittedAfterSeq: row["submitted_after_seq"] as? Int64
        )
    }

    func upsertComposerDraft(
        sessionId: String,
        draft: ACPComposerDraft,
        updatedAt: Int64,
        submittedRecovery: Bool = false,
        submittedAfterSeq: Int64? = nil
    ) throws {
        let payload = try JSONEncoder().encode(draft)
        try db.exec("""
        INSERT INTO composer_drafts (session_id, payload, updated_at, submitted_recovery, submitted_after_seq)
        VALUES (?,?,?,?,?)
        ON CONFLICT(session_id) DO UPDATE SET
            payload = excluded.payload,
            updated_at = excluded.updated_at,
            submitted_recovery = excluded.submitted_recovery,
            submitted_after_seq = excluded.submitted_after_seq
        """, bindings: [sessionId, payload, updatedAt, submittedRecovery ? 1 : 0, submittedAfterSeq])
    }

    func deleteComposerDraft(sessionId: String) throws {
        try db.exec("DELETE FROM composer_drafts WHERE session_id = ?", bindings: [sessionId])
    }

    func deleteComposerDraft(sessionId: String, matching stored: ACPStoredComposerDraft) throws -> Bool {
        return try db.execChanges("""
        DELETE FROM composer_drafts
        WHERE session_id = ?
          AND payload = ?
          AND updated_at = ?
          AND submitted_recovery = ?
          AND (
            (submitted_after_seq IS NULL AND ? IS NULL)
            OR submitted_after_seq = ?
          )
        """, bindings: [
            sessionId,
            stored.payload,
            stored.updatedAt,
            stored.submittedRecovery ? 1 : 0,
            stored.submittedAfterSeq,
            stored.submittedAfterSeq
        ]) > 0
    }

    func setArchived(id: String, archived: Bool) throws {
        try db.exec("UPDATE sessions SET archived = ? WHERE id = ?", bindings: [archived ? 1 : 0, id])
    }

    func renameSession(id: String, title: String, titleSource: ACPSessionTitleSource, updatedAt: Int64) throws -> Bool {
        try db.execChanges("""
        UPDATE sessions
        SET title = ?, title_source = ?, updated_at = ?
        WHERE id = ? AND archived = 0
        """, bindings: [title, titleSource.rawValue, updatedAt, id]) > 0
    }

    func updateGeneratedTitleIfPlaceholder(id: String, title: String, updatedAt: Int64) throws -> Bool {
        try db.execChanges("""
        UPDATE sessions
        SET title = ?, title_source = ?, updated_at = ?
        WHERE id = ? AND archived = 0 AND title_source = ?
        """, bindings: [title, ACPSessionTitleSource.generated.rawValue, updatedAt, id,
                         ACPSessionTitleSource.placeholder.rawValue]) > 0
    }

    func updateGeneratedTitleIfNotManual(id: String, title: String, updatedAt: Int64) throws -> Bool {
        try db.execChanges("""
        UPDATE sessions
        SET title = ?, title_source = ?, updated_at = ?
        WHERE id = ? AND archived = 0 AND title_source != ?
        """, bindings: [title, ACPSessionTitleSource.generated.rawValue, updatedAt, id,
                         ACPSessionTitleSource.manual.rawValue]) > 0
    }

    func clearGeneratedTitleIfNotManual(id: String, updatedAt: Int64) throws -> Bool {
        try db.execChanges("""
        UPDATE sessions
        SET title = ?, title_source = ?, updated_at = ?
        WHERE id = ? AND archived = 0 AND title_source != ?
        """, bindings: ["New session", ACPSessionTitleSource.placeholder.rawValue, updatedAt, id,
                         ACPSessionTitleSource.manual.rawValue]) > 0
    }

    func appendMessage(sessionId: String, id: String, kind: String, seq: Int64, payload: Data, createdAt: Int64) throws {
        try db.exec("""
        INSERT INTO messages (id, session_id, kind, seq, payload, created_at)
        VALUES (?,?,?,?,?,?)
        """, bindings: [id, sessionId, kind, seq, payload, createdAt])
    }

    func upsertMessages(_ messages: [ACPStoredMessage]) throws {
        for message in messages {
            let payload = try payloadPreservingStoredToolCallContent(for: message)
            try db.exec("""
            INSERT INTO messages (id, session_id, kind, seq, payload, created_at)
            VALUES (?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
                kind = excluded.kind,
                seq = excluded.seq,
                payload = excluded.payload
            """, bindings: [
                message.id,
                message.sessionId,
                message.kind,
                message.seq,
                payload,
                message.createdAt
            ])
        }
    }

    /// Salvage a streamed row received by the former owner only when the new
    /// owner has not created that deterministic row id yet. Unlike the normal
    /// upsert path this must never replace a concurrent takeover's transcript.
    func insertMessageIfMissing(_ message: ACPStoredMessage) throws -> Bool {
        try db.execChanges("""
        INSERT INTO messages (id, session_id, kind, seq, payload, created_at)
        VALUES (?,?,?,?,?,?)
        ON CONFLICT(id) DO NOTHING
        """, bindings: [
            message.id,
            message.sessionId,
            message.kind,
            message.seq,
            message.payload,
            message.createdAt
        ]) > 0
    }

    private func payloadPreservingStoredToolCallContent(for message: ACPStoredMessage) throws -> Data {
        guard message.kind == "tool_call",
              var incoming = try? JSONDecoder().decode(ACPMessage.ToolCall.self, from: message.payload),
              let existingPayload = try loadMessagePayload(id: message.id),
              let existing = try? JSONDecoder().decode(ACPMessage.ToolCall.self, from: existingPayload),
              incoming.isContentTruncated
                || (existing.content.count > incoming.content.count
                    && existing.content.hasPrefix(incoming.content))
        else { return message.payload }
        incoming.content = existing.content
        incoming.isContentTruncated = existing.isContentTruncated
        return try JSONEncoder().encode(incoming)
    }

    func updateMessagePayload(id: String, payload: Data) throws {
        try db.exec("UPDATE messages SET payload = ? WHERE id = ?", bindings: [payload, id])
    }

    func updateMessageRow(id: String, kind: String, seq: Int64, payload: Data) throws -> Bool {
        try db.execChanges(
            "UPDATE messages SET kind = ?, seq = ?, payload = ? WHERE id = ?",
            bindings: [kind, seq, payload, id]
        ) > 0
    }

    func updateMessagePayloadIfUnchanged(id: String, payload: Data, expectedPayload: Data) throws -> Bool {
        let mergedPayload: Data
        if var incoming = try? JSONDecoder().decode(ACPMessage.ToolCall.self, from: payload),
           let existing = try? JSONDecoder().decode(ACPMessage.ToolCall.self, from: expectedPayload),
           incoming.isContentTruncated
             || (existing.content.count > incoming.content.count
                 && existing.content.hasPrefix(incoming.content)) {
            incoming.content = existing.content
            incoming.isContentTruncated = existing.isContentTruncated
            mergedPayload = try JSONEncoder().encode(incoming)
        } else {
            mergedPayload = payload
        }
        return try db.execChanges("""
        UPDATE messages
        SET payload = ?
        WHERE id = ? AND payload = ?
        """, bindings: [mergedPayload, id, expectedPayload]) > 0
    }

    func loadMessagePayload(id: String) throws -> Data? {
        let rows = try db.query("SELECT payload FROM messages WHERE id = ?", bindings: [id])
        return rows.first?["payload"] as? Data
    }

    func messageCount(sessionId: String) throws -> Int {
        let rows = try db.query("""
        SELECT COUNT(*) AS count
        FROM messages WHERE session_id = ?
        """, bindings: [sessionId])
        return Int((rows.first?["count"] as? Int64) ?? 0)
    }

    func latestMessageSeq(sessionId: String) throws -> Int64? {
        let rows = try db.query("""
        SELECT MAX(seq) AS seq
        FROM messages WHERE session_id = ?
        """, bindings: [sessionId])
        return rows.first?["seq"] as? Int64
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
            origin: ACPSessionOrigin(rawValue: r["origin"] as? String ?? "") ?? .alasCreated,
            contextRecoveryPending: ((r["context_recovery_pending"] as? Int64) ?? 0) != 0,
            mcpPreamblePending: r["mcp_preamble_pending"] as? String,
            mcpPreambleSent: ((r["mcp_preamble_sent"] as? Int64) ?? 0) != 0,
            currentModel: r["current_model"] as? String,
            currentMode: r["current_mode"] as? String,
            autoRun: ((r["auto_run"] as? Int64) ?? 0) != 0,
            helperProcStdoutOffset: r["helper_proc_stdout_offset"] as? Int64,
            helperProcStderrOffset: r["helper_proc_stderr_offset"] as? Int64,
            acpBrokerId: r["acp_broker_id"] as? String,
            acpBrokerGeneration: r["acp_broker_generation"] as? Int64,
            acpBrokerAcknowledgedCursor: (r["acp_broker_acknowledged_cursor"] as? Int64) ?? 0,
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
            status: r["status"] as? String ?? "idle",
            token: r["lease_token"] as? String ?? "")
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
                    now: Int64, staleAfter: Int64,
                    leaseToken: String = UUID().uuidString) throws -> Bool {
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
            INSERT INTO session_leases (session_id, owner_instance, pid, heartbeat_at, status, lease_token)
            VALUES (?,?,?,?,'idle',?)
            ON CONFLICT(session_id) DO UPDATE SET
                owner_instance = excluded.owner_instance,
                pid = excluded.pid,
                heartbeat_at = excluded.heartbeat_at,
                status = 'idle',
                lease_token = CASE
                    WHEN session_leases.owner_instance = excluded.owner_instance
                    THEN session_leases.lease_token
                    ELSE excluded.lease_token
                END
            WHERE session_leases.owner_instance = excluded.owner_instance
               OR session_leases.heartbeat_at < ?
            """, bindings: [sessionId, instanceId, pid, now, leaseToken, staleCutoff])
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

    func releaseLease(sessionId: String, instanceId: String, leaseToken: String? = nil) throws {
        if let leaseToken {
            try db.exec(
                "DELETE FROM session_leases WHERE session_id = ? AND owner_instance = ? AND lease_token = ?",
                bindings: [sessionId, instanceId, leaseToken])
        } else {
            try db.exec(
                "DELETE FROM session_leases WHERE session_id = ? AND owner_instance = ?",
                bindings: [sessionId, instanceId])
        }
    }

    /// Forcibly seize the lease (explicit user takeover) regardless of
    /// the current owner's liveness.
    func seizeLease(
        sessionId: String,
        instanceId: String,
        pid: Int64,
        now: Int64,
        leaseToken: String = UUID().uuidString
    ) throws {
        try db.exec("""
        INSERT INTO session_leases (session_id, owner_instance, pid, heartbeat_at, status, lease_token)
        VALUES (?,?,?,?,'idle',?)
        ON CONFLICT(session_id) DO UPDATE SET
            owner_instance = excluded.owner_instance,
            pid = excluded.pid,
            heartbeat_at = excluded.heartbeat_at,
            status = 'idle',
            lease_token = excluded.lease_token
        """, bindings: [sessionId, instanceId, pid, now, leaseToken])
    }

    func withLeaseFence<T>(_ fence: ACPSessionLeaseFence, _ operation: () throws -> T) throws -> T? {
        try db.exec("BEGIN IMMEDIATE")
        do {
            let lease = try loadLease(sessionId: fence.sessionId)
            guard lease?.ownerInstance == fence.ownerInstance,
                  lease?.token == fence.token else {
                try db.exec("ROLLBACK")
                return nil
            }
            let result = try operation()
            try db.exec("COMMIT")
            return result
        } catch {
            try? db.exec("ROLLBACK")
            throw error
        }
    }
}
