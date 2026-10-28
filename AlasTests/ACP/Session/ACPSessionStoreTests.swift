import Foundation
import Testing
@testable import Alas

@Suite("ACPSessionStore — schema + migrations")
struct ACPSessionStoreSchemaTests {
    private func tmpStore() throws -> ACPSessionStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("acp-store-\(UUID()).sqlite")
        return try ACPSessionStore(path: url.path)
    }

    @Test func legacyBrokerDescriptorSurvivesContextMigration() throws {
        let original = try tmpStore()
        try original.upsertSession(.init(id: "legacy", agentId: "fixture", title: "Saved", autoRun: false,
            acpBrokerId: "broker", acpBrokerGeneration: 7, acpBrokerAcknowledgedCursor: 4,
            createdAt: 1, updatedAt: 1, lastOpenedAt: 1, archived: false))
        if try original.db.query("PRAGMA table_info(sessions)").contains(where: { ($0["name"] as? String) == "acp_broker_wire_context" }) {
            try original.db.exec("ALTER TABLE sessions DROP COLUMN acp_broker_wire_context")
        }
        try original.db.exec("UPDATE schema_version SET version = 29")
        let migrated = try ACPSessionStore(path: original.path)
        let saved = try #require(try migrated.loadSession(id: "legacy"))
        let descriptor = try #require(try ACPBrokerRestorePolicy.resolve(row: saved, supportedVersions: [.v1]))
        #expect(descriptor.wireContext == .legacyV1)
        #expect(descriptor.generation?.rawValue == 7)
        #expect(descriptor.acknowledgedCursor.rawValue == 4)
        #expect(saved.acpBrokerWireContextJSON == nil)
        #expect(try migrated.currentSchemaVersion() == ACPSessionStore.targetSchemaVersion)
        #expect(try ACPSessionStore(path: original.path).loadSession(id: "legacy") == saved)
    }

    @Test func goalDraftSurvivesReopeningWithoutCrossingSessions() throws {
        let store = try tmpStore()
        for id in ["first", "second"] {
            try store.upsertSession(.init(id: id, agentId: "codex", title: id,
                autoRun: false, createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        }
        try store.setGoalDraft(sessionId: "first", objective: " half written\n")
        let reopened = try ACPSessionStore(path: store.path)
        #expect(try reopened.loadSession(id: "first")?.goalDraft == " half written\n")
        #expect(try reopened.loadSession(id: "second")?.goalDraft == "")
        var row = try #require(try reopened.loadSession(id: "first"))
        row.title = "Renamed"
        try reopened.upsertSession(row)
        #expect(try store.loadSession(id: "first")?.goalDraft == " half written\n")
    }

    @Test(arguments: ["submitted", "newer draft"])
    func clearingSubmittedDraftPreservesNewerText(currentText: String) throws {
        let store = try tmpStore()
        try store.upsertSession(.init(id: "session", agentId: "codex", title: "Goal",
            autoRun: false, createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        try store.setGoalDraft(sessionId: "session", objective: currentText)
        try store.clearGoalDraft(sessionId: "session", matching: "submitted")
        #expect(try store.loadSession(id: "session")?.goalDraft == (currentText == "submitted" ? "" : "newer draft"))
    }

    @Test("opens a fresh DB at the target schema version")
    func freshSchema() throws {
        let store = try tmpStore()
        #expect(try store.currentSchemaVersion() == ACPSessionStore.targetSchemaVersion)
    }

    @Test("round-trips session config option values")
    func configOptionValuesRoundTrip() throws {
        let store = try tmpStore()
        let values: [String: ACPConfigValue] = [
            "effort": .string("high"),
            "autoApprove": .boolean(true),
        ]
        try store.upsertSession(.init(
            id: "configured",
            agentId: "omp",
            title: "Configured",
            currentModel: "gpt-5",
            currentMode: "plan",
            configOptionValues: values,
            autoRun: false,
            createdAt: 0,
            updatedAt: 0,
            lastOpenedAt: 0,
            archived: false
        ))

        #expect(try store.loadSession(id: "configured")?.configOptionValues == values)
    }

    @Test("native subagent policy, session instructions, and session hooks are captured once and survive later upserts")
    func capturedSessionPoliciesAreWriteOnce() throws {
        let store = try tmpStore()
        func row(_ policy: Bool?, _ instructions: String?, _ hooks: String? = nil) -> ACPSessionRow {
            .init(
                id: "policy", agentId: "claude", title: "Policy",
                currentModel: nil, currentMode: nil,
                nativeSubagentsDisabled: policy,
                sessionInstructions: instructions,
                sessionHooks: hooks,
                autoRun: false, createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false
            )
        }
        try store.upsertSession(row(true, "Review migrations.", "{\"Stop\":[]}"))
        // Rows rebuilt without the field, or with a different value, never
        // change the policy the session started with.
        try store.upsertSession(row(nil, nil))
        try store.upsertSession(row(false, "Edited default.", "{\"SessionStart\":[]}"))
        #expect(try store.loadSession(id: "policy")?.nativeSubagentsDisabled == true)
        #expect(try store.loadSession(id: "policy")?.sessionInstructions == "Review migrations.")
        #expect(try store.loadSession(id: "policy")?.sessionHooks == "{\"Stop\":[]}")

        try store.upsertSession(.init(
            id: "legacy", agentId: "codex", title: "Legacy",
            currentModel: nil, currentMode: nil,
            autoRun: false, createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false
        ))
        #expect(try store.loadSession(id: "legacy")?.nativeSubagentsDisabled == nil)
        #expect(try store.loadSession(id: "legacy")?.sessionInstructions == nil)
        #expect(try store.loadSession(id: "legacy")?.sessionHooks == nil)
    }

    @Test("a conditional rename applies only while the stored title and source still match")
    func conditionalRename() throws {
        let store = try tmpStore()
        try store.upsertSession(.init(
            id: "s", agentId: "claude", title: "Mine", titleSource: .manual,
            currentModel: nil, currentMode: nil, autoRun: false, createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false
        ))
        #expect(try !store.renameSession(id: "s", title: "Old", titleSource: .provider, updatedAt: 1,
                                         ifStillTitled: "Other", source: .manual))
        #expect(try store.loadSession(id: "s")?.title == "Mine")
        #expect(try store.renameSession(id: "s", title: "Old", titleSource: .provider, updatedAt: 1,
                                        ifStillTitled: "Mine", source: .manual))
        #expect(try store.loadSession(id: "s")?.title == "Old")
        #expect(try store.loadSession(id: "s")?.titleSource == .provider)
    }

    @Test("agent prompt suggestions round-trip and a nil rewrite keeps the stored list")
    func promptSuggestionsRoundTrip() throws {
        let store = try tmpStore()
        let suggestions = [
            ACPPromptSuggestion(command: "/review", description: "Review", hint: nil),
            ACPPromptSuggestion(command: "/$brainstorming", description: "Ideas", hint: "[topic]"),
        ]
        try store.upsertSession(.init(
            id: "skilled", agentId: "claude", title: "Skilled",
            currentModel: nil, currentMode: nil,
            promptSuggestions: suggestions,
            autoRun: false, createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false
        ))
        #expect(try store.loadSession(id: "skilled")?.promptSuggestions == suggestions)

        // Rows rebuilt without the field (an older process upserting) keep
        // the stored list instead of erasing it.
        try store.setPromptSuggestions(sessionId: "other", suggestions: nil)
        try store.upsertSession(.init(
            id: "skilled", agentId: "claude", title: "Skilled",
            currentModel: nil, currentMode: nil,
            autoRun: false, createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false
        ))
        #expect(try store.loadSession(id: "skilled")?.promptSuggestions == suggestions)

        try store.setPromptSuggestions(sessionId: "skilled", suggestions: nil)
        #expect(try store.loadSession(id: "skilled")?.promptSuggestions == nil)
    }

    @Test("side-question forks stay out of history until promoted")
    func ephemeralForkHiddenUntilPromoted() throws {
        let store = try tmpStore()
        func row(ephemeralParentId: String?) -> ACPSessionRow {
            .init(
                id: "side", agentId: "claude", title: "/btw: why?",
                currentModel: nil, currentMode: nil,
                ephemeralParentId: ephemeralParentId,
                autoRun: false, createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false
            )
        }
        try store.createFork(
            session: row(ephemeralParentId: "parent"),
            messages: [],
            record: .init(
                targetSessionID: "side", sourceSessionID: "parent", sourceAgentID: "claude",
                sourceBoundarySequence: 0, inheritedMessageCount: 0,
                phase: .ready, mechanism: .transcriptTransfer, contextDeliveryPending: false,
                via: .btw
            )
        )
        // A runner rebuilding the row without the flag must not unhide it.
        try store.upsertSession(row(ephemeralParentId: nil))
        #expect(try store.recentSessions().isEmpty)

        #expect(try store.promoteEphemeralSession(id: "side"))
        #expect(try store.promoteEphemeralSession(id: "side") == false)
        #expect(try store.recentSessions().map(\.id) == ["side"])
        #expect(try store.loadFork(targetSessionID: "side")?.via == .btw)
    }

    enum SideSessionLease: Sendable {
        case none, live, stale, deadOwner
    }

    @Test(
        "purging side sessions deletes only those nobody is driving",
        arguments: [
            (SideSessionLease.none, Int64(100), true),
            (.none, 0, false),
            (.live, 100, false),
            (.stale, 100, true),
            (.deadOwner, 100, true),
            (.deadOwner, 0, true),
            (.live, 0, false),
        ]
    )
    func purgesOrphanedEphemeralSessions(lease: SideSessionLease, idleSeconds: Int64, orphaned: Bool) throws {
        let store = try tmpStore()
        let now = Int64(Date().timeIntervalSince1970)
        for (id, parent) in [("side", "parent" as String?), ("visible", nil)] {
            try store.upsertSession(.init(
                id: id, agentId: "claude", title: id,
                currentModel: nil, currentMode: nil,
                ephemeralParentId: parent,
                autoRun: false, createdAt: now - idleSeconds, updatedAt: now - idleSeconds,
                lastOpenedAt: now - idleSeconds, archived: false
            ))
        }
        let livePid = Int64(ProcessInfo.processInfo.processIdentifier)
        let leaseRow: (pid: Int64, heartbeatAt: Int64)? = switch lease {
        case .none: nil
        case .live: (livePid, now)
        case .stale: (livePid, now - 100)
        case .deadOwner: (-1, now)
        }
        if let leaseRow {
            try store.db.exec("""
            INSERT INTO session_leases (session_id, owner_instance, pid, heartbeat_at, status, lease_token)
            VALUES ('side', 'other', ?, ?, 'busy', 'token')
            """, bindings: [leaseRow.pid, leaseRow.heartbeatAt])
        }

        let candidates = try store.orphanedEphemeralSessions(now: now, staleAfter: 15)
        #expect(candidates.map(\.id) == (orphaned ? ["side"] : []))
        #expect(try store.loadSession(id: "side") != nil)
        #expect(try store.deleteOrphanedEphemeralSession(id: "side", now: now, staleAfter: 15) == orphaned)
        #expect(try (store.loadSession(id: "side") == nil) == orphaned)
        #expect(try store.loadSession(id: "visible") != nil)
    }

    @Test("dismissal cleanup is immediate without deleting a live or promoted side session",
          arguments: SideSessionLeaseCases.allCases, [false, true])
    func pendingSideCleanupPreservesOwnershipAndPromotion(lease: SideSessionLeaseCases, promoted: Bool) throws {
        let store = try tmpStore()
        let now = Int64(Date().timeIntervalSince1970)
        let row = ACPSessionRow(id: "side", agentId: "claude", title: "Side",
            currentModel: nil, currentMode: nil, ephemeralParentId: "parent", autoRun: false,
            createdAt: now, updatedAt: now, lastOpenedAt: now, archived: false)
        try store.upsertSession(row)
        try #require(try store.markEphemeralCleanupPending(id: row.id))
        try store.upsertSession(row)
        let loaded = try #require(try store.loadSession(id: row.id))
        #expect(loaded.ephemeralCleanupPending)
        #expect(loaded.updatedAt == now)
        #expect(loaded.lastOpenedAt == now)
        if lease == .live {
            _ = try store.claimLease(sessionId: row.id, instanceId: "writer",
                pid: Int64(getpid()), now: now, staleAfter: 15)
        }
        if promoted { try #require(try store.promoteEphemeralSession(id: row.id)) }
        let eligible = lease == .none && !promoted
        #expect(try store.orphanedEphemeralSessions(now: now, staleAfter: 15).map(\.id) == (eligible ? ["side"] : []))
        #expect(try store.deleteOrphanedEphemeralSession(id: row.id, now: now, staleAfter: 15) == eligible)
        #expect(try (store.loadSession(id: row.id) == nil) == eligible)
    }

    enum SideSessionLeaseCases: CaseIterable, Sendable { case none, live }

    @Test("a pre-locator database upgrades without losing retained conversation history")
    func recoveryLocatorMigrationRetainsHistory() async throws {
        let store = try tmpStore()
        try store.upsertSession(.init(id: "session", agentId: "claude", title: "Original",
            remoteSessionId: "original", currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 1, updatedAt: 2, lastOpenedAt: 3, archived: false))
        let payload = try await MainActor.run { try ACPMessageCodec.encode(.agent(id: UUID(), StreamingText("Retained reply"))) }
        try store.appendMessage(sessionId: "session", id: "message", kind: "agent", seq: 0, payload: payload, createdAt: 1)
        try store.db.exec("ALTER TABLE sessions DROP COLUMN recovery_proc_id")
        try store.db.exec("ALTER TABLE sessions DROP COLUMN ephemeral_cleanup_pending")
        try store.db.exec("UPDATE schema_version SET version=22")
        let upgraded = try ACPSessionStore(path: store.path)
        #expect(try upgraded.loadSession(id: "session")?.remoteSessionId == "original")
        let persistence = ACPSessionPersistence(path: store.path)
        _ = try await persistence.seizeLease(sessionId: "session", instanceId: "writer", pid: 1, now: 100, leaseToken: "recovery")
        try #require(try await persistence.prepareRemoteContextRecovery(
            fence: .init(sessionId: "session", ownerInstance: "writer", token: "recovery"), procId: "recovery-proc"))
        let restarted = try ACPSessionStore(path: store.path)
        let recovered = try #require(try restarted.loadSession(id: "session"))
        #expect(recovered.remoteSessionId == nil)
        #expect(recovered.recoveryProcId == "recovery-proc")
        #expect(try restarted.loadMessages(sessionId: "session").map(\.payload) == [payload])
    }

    @Test("orphan deletion rechecks local ownership and promotion after enumeration", arguments: [false, true])
    func orphanDeletionRechecksEligibility(promoted: Bool) throws {
        let store = try tmpStore()
        let now: Int64 = 100
        try store.upsertSession(.init(
            id: "side", agentId: "claude", title: "Side", currentModel: nil, currentMode: nil,
            ephemeralParentId: "parent", autoRun: false, createdAt: 1, updatedAt: 1, lastOpenedAt: 1, archived: false
        ))
        #expect(try store.orphanedEphemeralSessions(now: now, staleAfter: 15).map(\.id) == ["side"])
        if promoted {
            #expect(try store.promoteEphemeralSession(id: "side"))
        } else {
            #expect(try store.claimLease(
                sessionId: "side", instanceId: "active", pid: Int64(ProcessInfo.processInfo.processIdentifier),
                now: now, staleAfter: 15, leaseToken: "active-token"
            ))
        }

        #expect(try store.deleteOrphanedEphemeralSession(id: "side", now: now, staleAfter: 15) == false)
        #expect(try store.loadSession(id: "side") != nil)
    }

    @Test("native cleanup cannot delete a promoted side session or one whose local reservation changed",
          arguments: [false, true])
    func orphanDeletionRechecksReservation(promoted: Bool) throws {
        let store = try tmpStore()
        let now: Int64 = 100
        try store.upsertSession(.init(
            id: "side", agentId: "claude", title: "Side", currentModel: nil, currentMode: nil,
            ephemeralParentId: "parent", autoRun: false, createdAt: 1, updatedAt: 1, lastOpenedAt: 1, archived: false
        ))
        let pid = Int64(ProcessInfo.processInfo.processIdentifier)
        #expect(try store.claimLease(
            sessionId: "side", instanceId: "cleanup", pid: pid, now: now, staleAfter: 15, leaseToken: "cleanup-token"
        ))
        let fence = ACPSessionLeaseFence(sessionId: "side", ownerInstance: "cleanup", token: "cleanup-token")
        if promoted {
            #expect(try store.promoteEphemeralSession(id: "side"))
        } else {
            try store.seizeLease(sessionId: "side", instanceId: "active", pid: pid, now: now, leaseToken: "active-token")
        }

        #expect(try store.deleteOrphanedEphemeralSession(id: "side", now: now, staleAfter: 15, fence: fence) == false)
        #expect(try store.loadSession(id: "side") != nil)
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
        #expect(sessionColumns.contains { ($0["name"] as? String) == "config_option_values" })
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

    @Test("counts active writer leases across processes")
    func activeLeaseCountCountsLiveRows() throws {
        let store = try tmpStore()
        let now = Int64(Date().timeIntervalSince1970)
        try store.upsertSession(.init(
            id: "live",
            agentId: "codex",
            title: "Live",
            currentModel: nil,
            currentMode: nil,
            autoRun: false,
            createdAt: now,
            updatedAt: now,
            lastOpenedAt: now,
            archived: false
        ))
        try store.upsertSession(.init(
            id: "dead",
            agentId: "codex",
            title: "Dead",
            currentModel: nil,
            currentMode: nil,
            autoRun: false,
            createdAt: now,
            updatedAt: now,
            lastOpenedAt: now,
            archived: false
        ))
        try store.db.exec("""
        INSERT INTO session_leases (session_id, owner_instance, pid, heartbeat_at, status, lease_token)
        VALUES (?, ?, ?, ?, ?, ?)
        """, bindings: [
            "live",
            "other",
            Int64(ProcessInfo.processInfo.processIdentifier),
            now,
            "busy",
            "token",
        ])
        try store.db.exec("""
        INSERT INTO session_leases (session_id, owner_instance, pid, heartbeat_at, status, lease_token)
        VALUES (?, ?, ?, ?, ?, ?)
        """, bindings: [
            "dead",
            "other",
            Int64(-1),
            now - 100,
            "busy",
            "token-2",
        ])

        #expect(try store.activeLeaseCount(now: now, staleAfter: 15) == 1)
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

    @Test("usage limit round-trips and survives upsert")
    func usageLimitRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-usage-limit-\(UUID().uuidString).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let session = ACPSessionRow(id: "s", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false)
        try store.upsertSession(session)
        let limit = ACPUsageLimit(detectedAt: Date(), resetsAt: Date().addingTimeInterval(600),
                                  resetSource: .parsed, probeAttempt: 1, resettable: true)

        try store.setUsageLimit(sessionId: "s", limit: limit)
        // Runtime upserts carry rows that never saw the limit.
        try store.upsertSession(session)
        #expect(try store.loadSession(id: "s")?.usageLimit == limit)

        try store.setUsageLimit(sessionId: "s", limit: nil)
        #expect(try store.loadSession(id: "s")?.usageLimit == nil)
    }

    private func seedSession(_ store: ACPSessionStore, id: String = "s") throws {
        try store.upsertSession(.init(id: id, agentId: "codex", title: id,
            autoRun: false, createdAt: 0, updatedAt: 7, lastOpenedAt: 0, archived: false))
    }

    private func sampleStoredSummary(hash: String = "hash", model: String = "model") -> StoredSessionSummary {
        .init(inputHash: hash, modelID: model, summary: .init(
            goal: "Ship it", completed: ["a", "b"], blockers: ["c"], nextAction: "Merge", isPartial: true),
            createdAt: 42)
    }

    @Test("a saved summary loads only under the same input hash and model")
    func sessionSummaryRoundTrip() throws {
        let store = try tmpStore()
        try seedSession(store)
        let stored = sampleStoredSummary()
        try store.saveSessionSummary(sessionId: "s", stored)
        #expect(try store.loadSessionSummary(sessionId: "s", inputHash: "hash", modelID: "model") == stored.summary)
    }

    @Test("a summary is not returned for a different input hash or model", arguments: [("other", "model"), ("hash", "other")])
    func sessionSummaryKeyMismatch(hash: String, model: String) throws {
        let store = try tmpStore()
        try seedSession(store)
        try store.saveSessionSummary(sessionId: "s", sampleStoredSummary())
        #expect(try store.loadSessionSummary(sessionId: "s", inputHash: hash, modelID: model) == nil)
    }

    @Test("deleting a session cascades to its summary")
    func sessionSummaryCascadesOnDelete() throws {
        let store = try tmpStore()
        try seedSession(store)
        try store.saveSessionSummary(sessionId: "s", sampleStoredSummary())
        try store.deleteSession(id: "s")
        try seedSession(store)
        #expect(try store.loadSessionSummary(sessionId: "s", inputHash: "hash", modelID: "model") == nil)
        let rows = try store.db.query("SELECT COUNT(*) AS n FROM session_summaries")
        #expect(rows.first?["n"] as? Int64 == 0)
    }

    @Test("deleteAllSessionSummaries clears every stored summary")
    func deleteAllSessionSummaries() throws {
        let store = try tmpStore()
        try seedSession(store, id: "a")
        try seedSession(store, id: "b")
        try store.saveSessionSummary(sessionId: "a", sampleStoredSummary())
        try store.saveSessionSummary(sessionId: "b", sampleStoredSummary())
        try store.deleteAllSessionSummaries()
        #expect(try store.loadSessionSummary(sessionId: "a", inputHash: "hash", modelID: "model") == nil)
        #expect(try store.loadSessionSummary(sessionId: "b", inputHash: "hash", modelID: "model") == nil)
    }

    @Test("clearing summaries by path needs no open store and skips databases without them")
    func deleteAllSessionSummariesAtPath() throws {
        let store = try tmpStore()
        try seedSession(store)
        try store.saveSessionSummary(sessionId: "s", sampleStoredSummary())
        try ACPSessionStore.deleteAllSessionSummaries(path: store.path)
        #expect(try store.loadSessionSummary(sessionId: "s", inputHash: "hash", modelID: "model") == nil)

        let directory = FileManager.default.temporaryDirectory
        let missing = directory.appendingPathComponent("acp-missing-\(UUID()).sqlite").path
        try ACPSessionStore.deleteAllSessionSummaries(path: missing)
        #expect(!FileManager.default.fileExists(atPath: missing))
        let bare = directory.appendingPathComponent("acp-bare-\(UUID()).sqlite").path
        _ = try SQLiteDatabase(path: bare)
        try ACPSessionStore.deleteAllSessionSummaries(path: bare)
    }

    @Test("the summary source snapshot reports turns and idleness from stored rows")
    func summarySourceSnapshot() throws {
        let store = try tmpStore()
        try seedSession(store)
        try store.appendMessage(sessionId: "s", id: "m0", kind: "user", seq: 0,
            payload: Data(#"{"text":"Do the thing","attachments":[]}"#.utf8), createdAt: 1)
        try store.appendMessage(sessionId: "s", id: "m1", kind: "agent", seq: 1,
            payload: Data(#"{"text":"Done"}"#.utf8), createdAt: 2)
        try store.appendMessage(sessionId: "s", id: "m2", kind: "agent", seq: 2,
            payload: Data("not json".utf8), createdAt: 3)
        let idle = try #require(try store.loadSummarySourceSnapshot(sessionId: "s"))
        #expect(idle.source.turns == [.init(user: "Do the thing", assistant: "Done")])
        #expect(idle.source.goal == nil)
        #expect(idle.isIdle)
        #expect(idle.updatedAt == 7)
        try store.setDirectTurnInFlight(sessionId: "s", inFlight: true)
        #expect(try store.loadSummarySourceSnapshot(sessionId: "s")?.isIdle == false)
        #expect(try store.loadSummarySourceSnapshot(sessionId: "missing") == nil)
    }

    @Test("last_seen_at is nil until stamped and survives session upserts")
    func lastSeenAt() throws {
        let store = try tmpStore()
        try seedSession(store)
        #expect(try store.loadLastSeenAt(id: "s") == nil)
        try store.setLastSeenAt(id: "s", at: 99)
        var row = try #require(try store.loadSession(id: "s"))
        row.title = "Renamed"
        try store.upsertSession(row)
        #expect(try store.loadLastSeenAt(id: "s") == 99)
        #expect(try store.loadSummarySourceSnapshot(sessionId: "s")?.lastSeenAt == 99)
    }
}
