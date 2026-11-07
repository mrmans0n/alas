import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

public final class ACPOrchestrationStore {
    public enum Error: Swift.Error, Equatable, Sendable {
        case duplicateChildSession(String)
        case malformedWorktreeRequest
    }

    public static let targetSchemaVersion = 5

    public let path: String
    public let db: SQLiteDatabase

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private let decoder = JSONDecoder()

    public init(path: String, busyTimeoutMilliseconds: Int32 = 5_000) throws {
        self.path = path
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        self.db = try SQLiteDatabase(path: path, busyTimeoutMilliseconds: busyTimeoutMilliseconds)
        try migrate()
    }

    public func currentSchemaVersion() throws -> Int {
        let rows = try db.query("SELECT version FROM schema_version LIMIT 1")
        return Int((rows.first?["version"] as? Int64) ?? 0)
    }

    public func insert(_ record: ACPDelegationRecord) throws {
        try db.exec("BEGIN IMMEDIATE")
        do {
            if try delegation(childSessionId: record.childSessionId) != nil {
                throw Error.duplicateChildSession(record.childSessionId)
            }
            try db.exec("""
            INSERT INTO delegations (
                child_session_id, parent_session_id, project_id, parent_worktree_id,
                child_worktree_id, agent_id, worktree_request, pending_initial_prompt,
                phase, failure_message, created_at, updated_at,
                requested_model, requested_reasoning, role, peer_server_id, peer_awaiting
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                record.modelSelection?.model,
                record.modelSelection?.reasoning,
                record.role,
                record.peerServerId,
                record.peerAwaiting ? Int64(1) : Int64(0),
            ])
            try db.exec("COMMIT")
        } catch {
            try? db.exec("ROLLBACK")
            throw error
        }
    }

    public func delegation(childSessionId: String) throws -> ACPDelegationRecord? {
        let rows = try db.query(
            "SELECT * FROM delegations WHERE child_session_id = ?",
            bindings: [childSessionId]
        )
        return try rows.first.map(decodeDelegation)
    }

    public func parent(childSessionId: String) throws -> ACPDelegationRecord? {
        try delegation(childSessionId: childSessionId)
    }

    public func children(parentSessionId: String) throws -> [ACPDelegationRecord] {
        try db.query(
            """
            SELECT * FROM delegations
            WHERE parent_session_id = ?
            ORDER BY created_at ASC, child_session_id ASC
            """,
            bindings: [parentSessionId]
        ).map(decodeDelegation)
    }

    public func updateChildWorktree(
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

    public func updateWorktreeRequest(
        childSessionId: String,
        request: ACPDelegatedWorktreeRequest,
        updatedAt: Int64
    ) throws {
        try db.exec("""
        UPDATE delegations
        SET worktree_request = ?, updated_at = ?
        WHERE child_session_id = ?
        """, bindings: [try encoder.encode(request), updatedAt, childSessionId])
    }

    public func updatePhase(
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

    /// Moves a delegation still `.starting` to `.ready`, returning whether it
    /// did. Conditional so a late answer cannot revive a child already failed,
    /// whose parent has been told.
    @discardableResult
    public func markReadyIfStarting(childSessionId: String, updatedAt: Int64) throws -> Bool {
        try db.execChanges("""
        UPDATE delegations
        SET phase = ?, failure_message = NULL, updated_at = ?
        WHERE child_session_id = ? AND phase = ?
        """, bindings: [
            ACPDelegationPhase.ready.rawValue, updatedAt, childSessionId, ACPDelegationPhase.starting.rawValue,
        ]) == 1
    }

    /// Atomically transitions a delegation to `.failed` AND enqueues the
    /// outcome that tells its parent, returning `true` only for the caller
    /// that made the transition.
    ///
    /// Both writes share one transaction on purpose. The conditional
    /// `WHERE phase != 'failed'` (same idiom as `claimMessage` above) means
    /// exactly one of two instances reconciling the same stuck delegation
    /// owns the notification, and committing the outcome row with it closes
    /// the window where a crash between the two leaves the child
    /// permanently `.failed` with no parent notification and no recovery —
    /// a later call would correctly lose the claim, and startup
    /// reconciliation only reloads creating/starting records.
    ///
    /// `discardingHeldMessages` (a child with a model selection) also deletes
    /// the child's inbox rows in the same transaction, except ones another
    /// instance holds a live claim on (claims expire against `updatedAt`, the
    /// clock `claimMessage` uses). `claimMessage` never claims a row for a
    /// selected child that is not ready, so a live claim means the selection
    /// was already applied. Together with `enqueueUnlessTargetEnded`, which
    /// checks the phase under the same write lock, no row can be accepted
    /// for the child once this commits, and none accepted before survives.
    public func claimFailedPhase(
        childSessionId: String,
        failureMessage: String,
        updatedAt: Int64,
        outcome: ACPDelegatedMessage,
        discardingHeldMessages: Bool = false
    ) throws -> Bool {
        try db.exec("BEGIN IMMEDIATE")
        do {
            if discardingHeldMessages {
                _ = try db.execChanges("""
                DELETE FROM delegated_messages
                WHERE target_session_id = ?
                  AND (claim_token IS NULL OR claim_expires_at < ?)
                """, bindings: [childSessionId, updatedAt])
            }
            let changed = try db.execChanges("""
            UPDATE delegations
            SET phase = ?, failure_message = ?, updated_at = ?
            WHERE child_session_id = ? AND phase != ?
            """, bindings: [
                ACPDelegationPhase.failed.rawValue, failureMessage, updatedAt,
                childSessionId, ACPDelegationPhase.failed.rawValue,
            ])
            guard changed == 1 else {
                try db.exec("COMMIT")
                return false
            }
            try enqueue(outcome)
            try db.exec("COMMIT")
            return true
        } catch {
            try? db.exec("ROLLBACK")
            throw error
        }
    }

    public func clearPendingInitialPrompt(childSessionId: String, updatedAt: Int64) throws {
        try db.exec("""
        UPDATE delegations
        SET pending_initial_prompt = NULL, updated_at = ?
        WHERE child_session_id = ?
        """, bindings: [updatedAt, childSessionId])
    }

    public func markParentReport(childSessionId: String, at reportedAt: Int64) throws {
        try db.exec("""
        UPDATE delegations
        SET last_parent_report_at = ?, updated_at = ?
        WHERE child_session_id = ?
        """, bindings: [reportedAt, reportedAt, childSessionId])
    }

    /// Queues a message for its target. A target that is a paired peer's
    /// sentinel parent has no local inbox: the message goes to that peer's
    /// outbox instead, for the peer to collect.
    public func enqueue(_ message: ACPDelegatedMessage) throws {
        if let peerServerId = ACPPeerParent.serverId(from: message.targetSessionId) {
            try db.exec("""
            INSERT OR IGNORE INTO peer_outbox (
                peer_server_id, child_session_id, message_id, prompt, kind, created_at
            ) VALUES (?, ?, ?, ?, ?, ?)
            """, bindings: [
                peerServerId,
                message.sourceSessionId,
                message.id,
                message.prompt,
                message.kind.rawValue,
                message.createdAt,
            ])
            return
        }
        try db.exec("""
        INSERT OR IGNORE INTO delegated_messages (
            id, source_session_id, target_session_id, prompt, created_at, kind
        ) VALUES (?, ?, ?, ?, ?, ?)
        """, bindings: [
            message.id,
            message.sourceSessionId,
            message.targetSessionId,
            message.prompt,
            message.createdAt,
            message.kind.rawValue,
        ])
    }

    /// Enqueues a message unless its target is a delegated child that has
    /// already failed or closed, returning whether it was accepted. The phase
    /// read and the insert share one write transaction, so an instance
    /// failing the same child (`claimFailedPhase`) commits wholly before or
    /// after it. A duplicate id counts as accepted, like `enqueue`.
    public func enqueueUnlessTargetEnded(_ message: ACPDelegatedMessage) throws -> Bool {
        try db.exec("BEGIN IMMEDIATE")
        do {
            let ended = try db.query(
                "SELECT 1 FROM delegations WHERE child_session_id = ? AND phase IN (?, ?) LIMIT 1",
                bindings: [
                    message.targetSessionId,
                    ACPDelegationPhase.failed.rawValue,
                    ACPDelegationPhase.closed.rawValue,
                ]
            )
            guard ended.isEmpty else {
                try db.exec("COMMIT")
                return false
            }
            try enqueue(message)
            try db.exec("COMMIT")
            return true
        } catch {
            try? db.exec("ROLLBACK")
            throw error
        }
    }

    /// A page of a peer's outbox after `after`, at most `maxBytes` of prompt
    /// text but never fewer than one entry, so an oversized outcome still
    /// gets through.
    public func outbox(
        peerServerId: String,
        after: Int64,
        maxBytes: Int
    ) throws -> (entries: [ACPPeerOutboxEntry], hasMore: Bool) {
        let rows = try db.query(
            "SELECT * FROM peer_outbox WHERE peer_server_id = ? AND seq > ? ORDER BY seq ASC",
            bindings: [peerServerId, after]
        )
        var entries: [ACPPeerOutboxEntry] = []
        var bytes = 0
        for row in rows {
            let entry = decodeOutboxEntry(row)
            let size = entry.prompt.utf8.count
            if !entries.isEmpty, size > maxBytes - bytes { break }
            entries.append(entry)
            bytes += size
        }
        return (entries, entries.count < rows.count)
    }

    public func acknowledgeOutbox(peerServerId: String, through: Int64) throws {
        _ = try db.execChanges(
            "DELETE FROM peer_outbox WHERE peer_server_id = ? AND seq <= ?",
            bindings: [peerServerId, through]
        )
    }

    public func deleteOutbox(peerServerId: String) throws {
        _ = try db.execChanges(
            "DELETE FROM peer_outbox WHERE peer_server_id = ?",
            bindings: [peerServerId]
        )
    }

    /// Moves a peer's cursor past `entry` and enqueues its message for the
    /// parent in one transaction. An outcome, of any kind, also ends the wait
    /// for its child. Returns true only for the caller that advanced the
    /// cursor, so concurrent collectors wake the parent once.
    public func collectPeerEntry(
        _ entry: ACPPeerOutboxEntry,
        peerServerId: String,
        parentSessionId: String
    ) throws -> Bool {
        try db.exec("BEGIN IMMEDIATE")
        do {
            try db.exec(
                "INSERT OR IGNORE INTO peer_delegation_cursors (peer_server_id, seq) VALUES (?, 0)",
                bindings: [peerServerId]
            )
            let advanced = try db.execChanges(
                "UPDATE peer_delegation_cursors SET seq = ? WHERE peer_server_id = ? AND seq < ?",
                bindings: [entry.seq, peerServerId, entry.seq]
            ) == 1
            if advanced {
                try enqueue(.init(
                    id: entry.messageId,
                    sourceSessionId: entry.childSessionId,
                    targetSessionId: parentSessionId,
                    prompt: entry.prompt,
                    createdAt: entry.createdAt,
                    kind: entry.kind
                ))
                try endWait(for: entry, peerServerId: peerServerId)
            }
            try db.exec("COMMIT")
            return advanced
        } catch {
            try? db.exec("ROLLBACK")
            throw error
        }
    }

    /// The parent now expects a result from `childSessionId`, for the prompt
    /// the target accepted at `since`, epoch milliseconds by the target's clock.
    /// A turn that started at or after `since` was already collected when the
    /// acknowledgement arrives late, and then nothing is left to wait for.
    public func markPeerAwaiting(childSessionId: String, since: Int64) throws {
        try db.exec("""
        UPDATE delegations
        SET peer_awaiting = 1, peer_awaiting_since = MAX(COALESCE(peer_awaiting_since, 0), ?)
        WHERE child_session_id = ? AND (peer_settled_turn IS NULL OR peer_settled_turn < ?)
        """, bindings: [since, childSessionId, since])
    }

    /// Ends the wait for a child that stopped without a result and enqueues
    /// `outcome`, together, so a crash or a failed insert cannot end the wait
    /// with nothing to wake the parent. True only for the caller that ended it:
    /// any instance sharing the store may be asking.
    /// `awaitingSince` is the wait the caller saw go quiet: a prompt accepted
    /// since starts another, which this must not end.
    public func claimLostPeerTurn(childSessionId: String, awaitingSince: Int64?, outcome: ACPDelegatedMessage) throws -> Bool {
        try db.exec("BEGIN IMMEDIATE")
        do {
            let claimed = try db.execChanges("""
            UPDATE delegations SET peer_awaiting = 0
            WHERE child_session_id = ? AND peer_awaiting = 1 AND phase = ? AND COALESCE(peer_awaiting_since, 0) = ?
            """, bindings: [childSessionId, ACPDelegationPhase.ready.rawValue, awaitingSince ?? 0]) == 1
            if claimed { try enqueue(outcome) }
            try db.exec("COMMIT")
            return claimed
        } catch {
            try? db.exec("ROLLBACK")
            throw error
        }
    }

    private func endWait(for entry: ACPPeerOutboxEntry, peerServerId: String) throws {
        // The ids the target gives outcomes; anything else leaves the child running.
        guard entry.messageId.hasPrefix("outcome-") else { return }
        // A turn that started before the awaited prompt was accepted is an
        // older one, and that prompt's turn is still to come. An outcome with
        // no turn is the child failing, which ends every wait.
        guard let turnStartedAt = entry.turnStartedAt else {
            try db.exec(
                "UPDATE delegations SET peer_awaiting = 0 WHERE child_session_id = ? AND peer_server_id = ?",
                bindings: [entry.childSessionId, peerServerId]
            )
            return
        }
        try db.exec("""
        UPDATE delegations SET peer_settled_turn = MAX(COALESCE(peer_settled_turn, 0), ?)
        WHERE child_session_id = ? AND peer_server_id = ?
        """, bindings: [turnStartedAt, entry.childSessionId, peerServerId])
        try db.exec("""
        UPDATE delegations SET peer_awaiting = 0
        WHERE child_session_id = ? AND peer_server_id = ?
          AND (peer_awaiting_since IS NULL OR peer_awaiting_since <= ?)
        """, bindings: [entry.childSessionId, peerServerId, turnStartedAt])
    }

    /// Moves a peer's cursor forward to `seq` without enqueuing anything, for
    /// an entry nobody here can be woken for. Never moves it back. `settling`
    /// is an entry for one of the peer's children whose parent is gone, which
    /// still ends the wait if it is an outcome.
    @discardableResult
    public func advancePeerCursor(peerServerId: String, to seq: Int64, settling entry: ACPPeerOutboxEntry? = nil) throws -> Bool {
        try db.exec("BEGIN IMMEDIATE")
        do {
            try db.exec(
                "INSERT OR IGNORE INTO peer_delegation_cursors (peer_server_id, seq) VALUES (?, 0)",
                bindings: [peerServerId]
            )
            let advanced = try db.execChanges(
                "UPDATE peer_delegation_cursors SET seq = ? WHERE peer_server_id = ? AND seq < ?",
                bindings: [seq, peerServerId, seq]
            ) == 1
            if advanced, let entry { try endWait(for: entry, peerServerId: peerServerId) }
            try db.exec("COMMIT")
            return advanced
        } catch {
            try? db.exec("ROLLBACK")
            throw error
        }
    }

    public func peerCursor(peerServerId: String) throws -> Int64 {
        try db.query(
            "SELECT seq FROM peer_delegation_cursors WHERE peer_server_id = ?",
            bindings: [peerServerId]
        ).first?["seq"] as? Int64 ?? 0
    }

    public func peerChildren(peerServerId: String) throws -> [ACPDelegationRecord] {
        try db.query(
            """
            SELECT * FROM delegations
            WHERE peer_server_id = ?
            ORDER BY created_at ASC, child_session_id ASC
            """,
            bindings: [peerServerId]
        ).map(decodeDelegation)
    }

    public func pendingMessages(targetSessionId: String) throws -> [ACPDelegatedMessage] {
        try db.query(
            """
            SELECT * FROM delegated_messages
            WHERE target_session_id = ?
            ORDER BY created_at ASC, rowid ASC
            """,
            bindings: [targetSessionId]
        ).map(decodeMessage)
    }

    public func pendingMessageTargetSessionIds() throws -> [String] {
        try db.query("""
        SELECT target_session_id
        FROM delegated_messages
        GROUP BY target_session_id
        ORDER BY MIN(created_at) ASC, MIN(rowid) ASC
        """).compactMap { $0["target_session_id"] as? String }
    }

    /// Child-to-parent links for every delegation ever recorded. The sidebar
    /// needs the whole map up front, and the two id columns are far cheaper to
    /// read than decoding full records.
    public func delegationParents() throws -> [String: String] {
        try db.query("SELECT child_session_id, parent_session_id FROM delegations")
            .reduce(into: [String: String]()) { links, row in
                guard let child = row["child_session_id"] as? String,
                      let parent = row["parent_session_id"] as? String
                else { return }
                links[child] = parent
            }
    }

    public func incompleteDelegations() throws -> [ACPDelegationRecord] {
        try db.query(
            "SELECT * FROM delegations WHERE phase IN (?, ?)",
            bindings: [ACPDelegationPhase.creatingWorktree.rawValue, ACPDelegationPhase.starting.rawValue]
        ).map(decodeDelegation)
    }

    public func readyDelegations() throws -> [ACPDelegationRecord] {
        try db.query(
            "SELECT * FROM delegations WHERE phase = ?",
            bindings: [ACPDelegationPhase.ready.rawValue]
        ).map(decodeDelegation)
    }

    public func claimMessage(
        id: String,
        instanceId: String,
        token: String,
        now: Int64,
        staleAfter: Int64
    ) throws -> ACPClaimedDelegatedMessage? {
        let expiresAt = now + staleAfter
        try db.exec("BEGIN IMMEDIATE")
        do {
            // A child with a model selection takes inbox rows only once it is
            // ready (`ACPSessionOrchestrationPolicy.defersInboxDelivery`).
            // Checked here, under the claim's write lock, so no instance can
            // claim a row that a concurrent failure should discard; a row
            // for a child that failed that way is dropped instead.
            let heldPhase = try db.query("""
            SELECT d.phase FROM delegated_messages m
            JOIN delegations d ON d.child_session_id = m.target_session_id
            WHERE m.id = ? AND d.phase != ?
              AND (d.requested_model IS NOT NULL OR d.requested_reasoning IS NOT NULL)
            """, bindings: [id, ACPDelegationPhase.ready.rawValue]).first?["phase"] as? String
            if let heldPhase {
                if heldPhase == ACPDelegationPhase.failed.rawValue {
                    _ = try db.execChanges("""
                    DELETE FROM delegated_messages
                    WHERE id = ? AND (claim_token IS NULL OR claim_expires_at < ?)
                    """, bindings: [id, now])
                }
                try db.exec("COMMIT")
                return nil
            }
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

    public func claimedMessage(id: String) throws -> ACPDelegatedMessageClaim? {
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

    public func removeDeliveredMessage(id: String, claim: ACPDelegatedMessageClaim) throws {
        _ = try db.execChanges("""
        DELETE FROM delegated_messages
        WHERE id = ? AND claim_instance_id = ? AND claim_token = ?
        """, bindings: [id, claim.instanceId, claim.token])
    }

    public func releaseMessageClaim(id: String, claim: ACPDelegatedMessageClaim) throws {
        _ = try db.execChanges("""
        UPDATE delegated_messages
        SET claim_instance_id = NULL, claim_token = NULL, claim_expires_at = NULL
        WHERE id = ? AND claim_instance_id = ? AND claim_token = ?
        """, bindings: [id, claim.instanceId, claim.token])
    }

    /// Alas supports multiple concurrent instances sharing one on-disk
    /// database (see the claim-based delegated-message inbox above). If two
    /// instances both open a v1 database for the first time, both would
    /// otherwise read `currentSchemaVersion() == 1` and both attempt
    /// `migrateToV2()` — whose `ALTER TABLE ... ADD COLUMN` statements are
    /// NOT idempotent, so the loser fails with a duplicate-column error and
    /// (per `ACPOrchestrationPersistence.openedStore()`, which caches that
    /// failure) is left permanently unable to open its store.
    ///
    /// Wrapping the read-check-migrate-bump sequence in `BEGIN IMMEDIATE`
    /// (same idiom as `insert()`) closes that window: it acquires the write
    /// lock immediately, so a second instance's `BEGIN IMMEDIATE` blocks
    /// until the first instance's migration transaction commits. By the
    /// time the second instance's `currentSchemaVersion()` runs, it observes
    /// the already-migrated version and skips `migrateToV2()` entirely.
    private func migrate() throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS schema_version (
            version INTEGER NOT NULL
        )
        """)
        try db.exec("BEGIN IMMEDIATE")
        do {
            let current = try currentSchemaVersion()
            if current < 1 { try migrateToV1() }
            if current < 2 { try migrateToV2() }
            if current < 3 { try migrateToV3() }
            if current < 4 { try db.exec("ALTER TABLE delegations ADD COLUMN role TEXT") }
            if current < 5 { try migrateToV5() }
            // Builds of this version before the column existed wrote stores at 5.
            try addPeerAwaitingColumnIfMissing()
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
            try db.exec("COMMIT")
        } catch {
            try? db.exec("ROLLBACK")
            throw error
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

    private func migrateToV2() throws {
        try db.exec("ALTER TABLE delegations ADD COLUMN last_parent_report_at INTEGER")
        try db.exec("ALTER TABLE delegated_messages ADD COLUMN kind TEXT NOT NULL DEFAULT 'prompt'")
    }

    private func migrateToV3() throws {
        try db.exec("ALTER TABLE delegations ADD COLUMN requested_model TEXT")
        try db.exec("ALTER TABLE delegations ADD COLUMN requested_reasoning TEXT")
    }

    private func migrateToV5() throws {
        try db.exec("ALTER TABLE delegations ADD COLUMN peer_server_id TEXT")
        try db.exec("""
        CREATE TABLE IF NOT EXISTS peer_outbox (
            seq              INTEGER PRIMARY KEY AUTOINCREMENT,
            peer_server_id   TEXT NOT NULL,
            child_session_id TEXT NOT NULL,
            message_id       TEXT NOT NULL UNIQUE,
            prompt           TEXT NOT NULL,
            kind             TEXT NOT NULL,
            created_at       INTEGER NOT NULL
        )
        """)
        try db.exec("CREATE INDEX IF NOT EXISTS peer_outbox_peer_idx ON peer_outbox(peer_server_id, seq)")
        try db.exec("""
        CREATE TABLE IF NOT EXISTS peer_delegation_cursors (
            peer_server_id TEXT PRIMARY KEY,
            seq            INTEGER NOT NULL
        )
        """)
    }

    private func addPeerAwaitingColumnIfMissing() throws {
        let columns = try db.query("SELECT name FROM pragma_table_info('delegations') WHERE name LIKE 'peer_awaiting%'")
            .compactMap { $0["name"] as? String }
        if !columns.contains("peer_awaiting") {
            try db.exec("ALTER TABLE delegations ADD COLUMN peer_awaiting INTEGER NOT NULL DEFAULT 0")
        }
        if !columns.contains("peer_awaiting_since") {
            try db.exec("ALTER TABLE delegations ADD COLUMN peer_awaiting_since INTEGER")
        }
        let settled = try db.query("SELECT name FROM pragma_table_info('delegations') WHERE name = 'peer_settled_turn'")
        if settled.isEmpty {
            try db.exec("ALTER TABLE delegations ADD COLUMN peer_settled_turn INTEGER")
        }
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
            updatedAt: row["updated_at"] as? Int64 ?? 0,
            lastParentReportAt: row["last_parent_report_at"] as? Int64,
            modelSelection: ACPDelegatedModelSelection(
                model: row["requested_model"] as? String,
                reasoning: row["requested_reasoning"] as? String
            ),
            role: row["role"] as? String,
            peerServerId: row["peer_server_id"] as? String,
            peerAwaiting: (row["peer_awaiting"] as? Int64 ?? 0) != 0,
            peerAwaitingSince: row["peer_awaiting_since"] as? Int64
        )
    }

    private func decodeMessage(_ row: [String: Any?]) throws -> ACPDelegatedMessage {
        .init(
            id: row["id"] as? String ?? "",
            sourceSessionId: row["source_session_id"] as? String ?? "",
            targetSessionId: row["target_session_id"] as? String ?? "",
            prompt: row["prompt"] as? String ?? "",
            createdAt: row["created_at"] as? Int64 ?? 0,
            kind: (row["kind"] as? String).flatMap(ACPDelegatedMessageKind.init(rawValue:)) ?? .prompt
        )
    }

    private func decodeOutboxEntry(_ row: [String: Any?]) -> ACPPeerOutboxEntry {
        .init(
            seq: row["seq"] as? Int64 ?? 0,
            messageId: row["message_id"] as? String ?? "",
            childSessionId: row["child_session_id"] as? String ?? "",
            prompt: row["prompt"] as? String ?? "",
            kind: (row["kind"] as? String).flatMap(ACPDelegatedMessageKind.init(rawValue:)) ?? .prompt,
            createdAt: row["created_at"] as? Int64 ?? 0
        )
    }
}
