import Foundation

final class ACPOrchestrationStore {
    enum Error: Swift.Error, Equatable {
        case duplicateChildSession(String)
        case malformedWorktreeRequest
    }

    static let targetSchemaVersion = 1

    let path: String
    let db: SQLiteDatabase

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private let decoder = JSONDecoder()

    init(path: String, busyTimeoutMilliseconds: Int32 = 5_000) throws {
        self.path = path
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        self.db = try SQLiteDatabase(path: path, busyTimeoutMilliseconds: busyTimeoutMilliseconds)
        try migrate()
    }

    func currentSchemaVersion() throws -> Int {
        let rows = try db.query("SELECT version FROM schema_version LIMIT 1")
        return Int((rows.first?["version"] as? Int64) ?? 0)
    }

    func insert(_ record: ACPDelegationRecord) throws {
        try db.exec("BEGIN IMMEDIATE")
        do {
            if try delegation(childSessionId: record.childSessionId) != nil {
                throw Error.duplicateChildSession(record.childSessionId)
            }
            try db.exec("""
            INSERT INTO delegations (
                child_session_id, parent_session_id, project_id, parent_worktree_id,
                child_worktree_id, agent_id, worktree_request, pending_initial_prompt,
                phase, failure_message, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, bindings: [
                record.childSessionId,
                record.parentSessionId,
                record.projectId,
                record.parentWorktreeId,
                record.childWorktreeId,
                record.agentId,
                try encoder.encode(record.worktreeRequest),
                record.pendingInitialPrompt,
                record.phase.rawValue,
                record.failureMessage,
                record.createdAt,
                record.updatedAt,
            ])
            try db.exec("COMMIT")
        } catch {
            try? db.exec("ROLLBACK")
            throw error
        }
    }

    func delegation(childSessionId: String) throws -> ACPDelegationRecord? {
        let rows = try db.query(
            "SELECT * FROM delegations WHERE child_session_id = ?",
            bindings: [childSessionId]
        )
        return try rows.first.map(decodeDelegation)
    }

    func parent(childSessionId: String) throws -> ACPDelegationRecord? {
        try delegation(childSessionId: childSessionId)
    }

    func children(parentSessionId: String) throws -> [ACPDelegationRecord] {
        try db.query(
            """
            SELECT * FROM delegations
            WHERE parent_session_id = ?
            ORDER BY created_at ASC, child_session_id ASC
            """,
            bindings: [parentSessionId]
        ).map(decodeDelegation)
    }

    func updateChildWorktree(
        childSessionId: String,
        worktreeId: String,
        phase: ACPDelegationPhase,
        updatedAt: Int64
    ) throws {
        try db.exec("""
        UPDATE delegations
        SET child_worktree_id = ?, phase = ?, updated_at = ?
        WHERE child_session_id = ?
        """, bindings: [worktreeId, phase.rawValue, updatedAt, childSessionId])
    }

    func updatePhase(
        childSessionId: String,
        phase: ACPDelegationPhase,
        failureMessage: String?,
        updatedAt: Int64
    ) throws {
        try db.exec("""
        UPDATE delegations
        SET phase = ?, failure_message = ?, updated_at = ?
        WHERE child_session_id = ?
        """, bindings: [phase.rawValue, failureMessage, updatedAt, childSessionId])
    }

    func clearPendingInitialPrompt(childSessionId: String, updatedAt: Int64) throws {
        try db.exec("""
        UPDATE delegations
        SET pending_initial_prompt = NULL, updated_at = ?
        WHERE child_session_id = ?
        """, bindings: [updatedAt, childSessionId])
    }

    func enqueue(_ message: ACPDelegatedMessage) throws {
        try db.exec("""
        INSERT OR IGNORE INTO delegated_messages (
            id, source_session_id, target_session_id, prompt, created_at
        ) VALUES (?, ?, ?, ?, ?)
        """, bindings: [
            message.id,
            message.sourceSessionId,
            message.targetSessionId,
            message.prompt,
            message.createdAt,
        ])
    }

    func pendingMessages(targetSessionId: String) throws -> [ACPDelegatedMessage] {
        try db.query(
            """
            SELECT * FROM delegated_messages
            WHERE target_session_id = ?
            ORDER BY created_at ASC, rowid ASC
            """,
            bindings: [targetSessionId]
        ).map(decodeMessage)
    }

    func incompleteDelegations() throws -> [ACPDelegationRecord] {
        try db.query(
            "SELECT * FROM delegations WHERE phase IN (?, ?)",
            bindings: [ACPDelegationPhase.creatingWorktree.rawValue, ACPDelegationPhase.starting.rawValue]
        ).map(decodeDelegation)
    }

    func claimMessage(
        id: String,
        instanceId: String,
        token: String,
        now: Int64,
        staleAfter: Int64
    ) throws -> ACPClaimedDelegatedMessage? {
        let expiresAt = now + staleAfter
        try db.exec("BEGIN IMMEDIATE")
        do {
            let changed = try db.execChanges("""
            UPDATE delegated_messages
            SET claim_instance_id = ?, claim_token = ?, claim_expires_at = ?
            WHERE id = ?
              AND (
                claim_token IS NULL
                OR claim_expires_at < ?
                OR (claim_instance_id = ? AND claim_token = ?)
              )
            """, bindings: [instanceId, token, expiresAt, id, now, instanceId, token])
            guard changed == 1,
                  let row = try db.query(
                    "SELECT * FROM delegated_messages WHERE id = ?",
                    bindings: [id]
                  ).first
            else {
                try db.exec("COMMIT")
                return nil
            }
            let message = try decodeMessage(row)
            try db.exec("COMMIT")
            return .init(
                message: message,
                claim: .init(instanceId: instanceId, token: token, expiresAt: expiresAt)
            )
        } catch {
            try? db.exec("ROLLBACK")
            throw error
        }
    }

    func claimedMessage(id: String) throws -> ACPDelegatedMessageClaim? {
        let rows = try db.query(
            """
            SELECT claim_instance_id, claim_token, claim_expires_at
            FROM delegated_messages WHERE id = ?
            """,
            bindings: [id]
        )
        guard let row = rows.first,
              let instanceId = row["claim_instance_id"] as? String,
              let token = row["claim_token"] as? String,
              let expiresAt = row["claim_expires_at"] as? Int64
        else { return nil }
        return .init(instanceId: instanceId, token: token, expiresAt: expiresAt)
    }

    func removeDeliveredMessage(id: String, claim: ACPDelegatedMessageClaim) throws {
        _ = try db.execChanges("""
        DELETE FROM delegated_messages
        WHERE id = ? AND claim_instance_id = ? AND claim_token = ?
        """, bindings: [id, claim.instanceId, claim.token])
    }

    func releaseMessageClaim(id: String, claim: ACPDelegatedMessageClaim) throws {
        _ = try db.execChanges("""
        UPDATE delegated_messages
        SET claim_instance_id = NULL, claim_token = NULL, claim_expires_at = NULL
        WHERE id = ? AND claim_instance_id = ? AND claim_token = ?
        """, bindings: [id, claim.instanceId, claim.token])
    }

    private func migrate() throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS schema_version (
            version INTEGER NOT NULL
        )
        """)
        let current = try currentSchemaVersion()
        if current < 1 { try migrateToV1() }
        if current == 0 {
            try db.exec(
                "INSERT INTO schema_version (version) VALUES (?)",
                bindings: [Int64(Self.targetSchemaVersion)]
            )
        } else if current < Self.targetSchemaVersion {
            try db.exec(
                "UPDATE schema_version SET version = ?",
                bindings: [Int64(Self.targetSchemaVersion)]
            )
        }
    }

    private func migrateToV1() throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS delegations (
            child_session_id     TEXT PRIMARY KEY,
            parent_session_id    TEXT NOT NULL,
            project_id           TEXT NOT NULL,
            parent_worktree_id   TEXT NOT NULL,
            child_worktree_id    TEXT,
            agent_id             TEXT NOT NULL,
            worktree_request     BLOB NOT NULL,
            pending_initial_prompt TEXT,
            phase                TEXT NOT NULL,
            failure_message      TEXT,
            created_at           INTEGER NOT NULL,
            updated_at           INTEGER NOT NULL
        )
        """)
        try db.exec("""
        CREATE INDEX IF NOT EXISTS delegations_parent_idx
        ON delegations(parent_session_id, created_at, child_session_id)
        """)
        try db.exec("""
        CREATE TABLE IF NOT EXISTS delegated_messages (
            id                TEXT PRIMARY KEY,
            source_session_id TEXT NOT NULL,
            target_session_id TEXT NOT NULL,
            prompt            TEXT NOT NULL,
            created_at        INTEGER NOT NULL,
            claim_instance_id TEXT,
            claim_token       TEXT,
            claim_expires_at  INTEGER
        )
        """)
        try db.exec("""
        CREATE INDEX IF NOT EXISTS delegated_messages_target_idx
        ON delegated_messages(target_session_id, created_at, id)
        """)
    }

    private func decodeDelegation(_ row: [String: Any?]) throws -> ACPDelegationRecord {
        guard let requestData = row["worktree_request"] as? Data,
              let request = try? decoder.decode(ACPDelegatedWorktreeRequest.self, from: requestData),
              let phaseRaw = row["phase"] as? String,
              let phase = ACPDelegationPhase(rawValue: phaseRaw)
        else { throw Error.malformedWorktreeRequest }
        return .init(
            childSessionId: row["child_session_id"] as? String ?? "",
            parentSessionId: row["parent_session_id"] as? String ?? "",
            projectId: row["project_id"] as? String ?? "",
            parentWorktreeId: row["parent_worktree_id"] as? String ?? "",
            childWorktreeId: row["child_worktree_id"] as? String,
            agentId: row["agent_id"] as? String ?? "",
            worktreeRequest: request,
            pendingInitialPrompt: row["pending_initial_prompt"] as? String,
            phase: phase,
            failureMessage: row["failure_message"] as? String,
            createdAt: row["created_at"] as? Int64 ?? 0,
            updatedAt: row["updated_at"] as? Int64 ?? 0
        )
    }

    private func decodeMessage(_ row: [String: Any?]) throws -> ACPDelegatedMessage {
        .init(
            id: row["id"] as? String ?? "",
            sourceSessionId: row["source_session_id"] as? String ?? "",
            targetSessionId: row["target_session_id"] as? String ?? "",
            prompt: row["prompt"] as? String ?? "",
            createdAt: row["created_at"] as? Int64 ?? 0
        )
    }
}
