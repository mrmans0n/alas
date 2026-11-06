import Foundation
import SQLite3
import Testing
@testable import Alas

@Suite("ACP orchestration store")
struct ACPOrchestrationStoreTests {
    private func temporaryPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-orchestration-\(UUID().uuidString).sqlite")
            .path
    }

    private func newRecord(
        childSessionId: String = "child",
        parentSessionId: String = "parent",
        request: ACPDelegatedWorktreeRequest = .current(worktreeId: "parent-worktree")
    ) -> ACPDelegationRecord {
        .init(
            childSessionId: childSessionId,
            parentSessionId: parentSessionId,
            projectId: "project",
            parentWorktreeId: "parent-worktree",
            childWorktreeId: request.worktreeId,
            agentId: "codex",
            worktreeRequest: request,
            pendingInitialPrompt: "Investigate the parser.",
            phase: .starting,
            failureMessage: nil,
            createdAt: 100,
            updatedAt: 100
        )
    }

    @Test("creates schema and preserves delegation records across reopen")
    func persistsDelegationAcrossReopen() throws {
        let path = temporaryPath()
        var record = newRecord()
        record.modelSelection = ACPDelegatedModelSelection(model: "gpt-5.2", reasoning: "high")
        record.role = "reviewer"

        do {
            let store = try ACPOrchestrationStore(path: path)
            #expect(try store.currentSchemaVersion() == ACPOrchestrationStore.targetSchemaVersion)
            try store.insert(record)
            #expect(try store.delegation(childSessionId: "child") == record)
            #expect(try store.children(parentSessionId: "parent") == [record])
            #expect(try store.parent(childSessionId: "child") == record)
        }

        let reopened = try ACPOrchestrationStore(path: path)
        #expect(try reopened.delegation(childSessionId: "child") == record)
    }

    @Test("round trips every worktree request")
    func roundTripsWorktreeRequests() throws {
        let path = temporaryPath()
        let store = try ACPOrchestrationStore(path: path)
        let requests: [ACPDelegatedWorktreeRequest] = [
            .current(worktreeId: "current"),
            .existing(worktreeId: "existing"),
            .new(
                branch: "delegate/parser",
                base: "origin/main",
                destinationPath: "/tmp/alas-delegate-parser",
                optimisticId: "optimistic"
            ),
        ]

        for (index, request) in requests.enumerated() {
            let record = newRecord(
                childSessionId: "child-\(index)",
                request: request
            )
            try store.insert(record)
            #expect(try store.delegation(childSessionId: record.childSessionId) == record)
        }
    }

    @Test("updates creation phase, worktree, failure, and pending prompt")
    func updatesDelegationLifecycle() throws {
        let path = temporaryPath()
        let store = try ACPOrchestrationStore(path: path)
        try store.insert(newRecord(request: .new(
            branch: "delegate/parser",
            base: nil,
            destinationPath: "/tmp/alas-delegate-parser",
            optimisticId: "optimistic"
        )))

        try store.updateChildWorktree(
            childSessionId: "child",
            worktreeId: "real-worktree",
            phase: .starting,
            updatedAt: 110
        )
        try store.updatePhase(
            childSessionId: "child",
            phase: .failed,
            failureMessage: "Could not create worktree.",
            updatedAt: 120
        )
        try store.clearPendingInitialPrompt(childSessionId: "child", updatedAt: 130)

        let record = try #require(try store.delegation(childSessionId: "child"))
        #expect(record.childWorktreeId == "real-worktree")
        #expect(record.phase == .failed)
        #expect(record.failureMessage == "Could not create worktree.")
        #expect(record.pendingInitialPrompt == nil)
        #expect(record.updatedAt == 130)
    }

    @Test("reports every child-to-parent link regardless of phase")
    func returnsAllDelegationParents() throws {
        let store = try ACPOrchestrationStore(path: temporaryPath())
        try store.insert(newRecord(childSessionId: "child-a", parentSessionId: "parent-1"))
        try store.insert(newRecord(childSessionId: "child-b", parentSessionId: "parent-1"))
        try store.insert(newRecord(childSessionId: "child-c", parentSessionId: "parent-2"))
        try store.updatePhase(
            childSessionId: "child-c",
            phase: .closed,
            failureMessage: nil,
            updatedAt: 140
        )

        #expect(try store.delegationParents() == [
            "child-a": "parent-1",
            "child-b": "parent-1",
            "child-c": "parent-2",
        ])
    }

    @Test("returns no delegation parents for an empty store")
    func returnsNoDelegationParentsWhenEmpty() throws {
        let store = try ACPOrchestrationStore(path: temporaryPath())

        #expect(try store.delegationParents().isEmpty)
    }

    @Test("rejects a duplicate child session id")
    func rejectsDuplicateChild() throws {
        let store = try ACPOrchestrationStore(path: temporaryPath())
        try store.insert(newRecord())

        #expect(throws: ACPOrchestrationStore.Error.duplicateChildSession("child")) {
            try store.insert(newRecord(parentSessionId: "different-parent"))
        }
    }

    @Test("stores and atomically claims a delegated message")
    func claimsMessageOnceAcrossHandles() throws {
        let path = temporaryPath()
        let a = try ACPOrchestrationStore(path: path)
        let b = try ACPOrchestrationStore(path: path)
        let message = ACPDelegatedMessage(
            id: "message",
            sourceSessionId: "parent",
            targetSessionId: "child",
            prompt: "Please check malformed UTF-8.",
            createdAt: 100
        )
        try a.enqueue(message)

        let claimedByA = try a.claimMessage(
            id: "message",
            instanceId: "instance-a",
            token: "token-a",
            now: 110,
            staleAfter: 30
        )
        let claimedByB = try b.claimMessage(
            id: "message",
            instanceId: "instance-b",
            token: "token-b",
            now: 110,
            staleAfter: 30
        )

        #expect(claimedByA?.message == message)
        #expect(claimedByB == nil)
        #expect(try b.claimedMessage(id: "message")?.instanceId == "instance-a")
    }

    @Test("messages with the same timestamp preserve insertion order")
    func messagesWithSameTimestampPreserveInsertionOrder() throws {
        let store = try ACPOrchestrationStore(path: temporaryPath())
        try store.enqueue(.init(
            id: "z-message",
            sourceSessionId: "parent",
            targetSessionId: "child",
            prompt: "first",
            createdAt: 100
        ))
        try store.enqueue(.init(
            id: "a-message",
            sourceSessionId: "parent",
            targetSessionId: "child",
            prompt: "second",
            createdAt: 100
        ))

        #expect(try store.pendingMessages(targetSessionId: "child").map(\.id) == ["z-message", "a-message"])
    }

    @Test("pending message targets are returned once in first-message order")
    func pendingMessageTargetsAreDistinctAndOrdered() throws {
        let store = try ACPOrchestrationStore(path: temporaryPath())
        try store.enqueue(.init(
            id: "child-2-first",
            sourceSessionId: "parent",
            targetSessionId: "child-2",
            prompt: "second target",
            createdAt: 110
        ))
        try store.enqueue(.init(
            id: "child-1-first",
            sourceSessionId: "parent",
            targetSessionId: "child-1",
            prompt: "first target",
            createdAt: 100
        ))
        try store.enqueue(.init(
            id: "child-1-second",
            sourceSessionId: "parent",
            targetSessionId: "child-1",
            prompt: "same target",
            createdAt: 120
        ))

        #expect(try store.pendingMessageTargetSessionIds() == ["child-1", "child-2"])
    }

    @Test("released inbox claim can be immediately reclaimed")
    func releasesMessageClaim() throws {
        let store = try ACPOrchestrationStore(path: temporaryPath())
        let message = ACPDelegatedMessage(
            id: "message",
            sourceSessionId: "parent",
            targetSessionId: "child",
            prompt: "Please retry delivery.",
            createdAt: 100
        )
        try store.enqueue(message)
        let claim = try #require(try store.claimMessage(
            id: "message",
            instanceId: "mirror-instance",
            token: "mirror-token",
            now: 110,
            staleAfter: 60
        ))

        try store.releaseMessageClaim(id: message.id, claim: claim.claim)

        #expect(try store.claimMessage(
            id: "message",
            instanceId: "writer-instance",
            token: "writer-token",
            now: 110,
            staleAfter: 60
        )?.message == message)
    }

    @Test("expired inbox claim can be reclaimed and delivery removes message")
    func reclaimsExpiredMessageAndRemovesItAfterDelivery() throws {
        let store = try ACPOrchestrationStore(path: temporaryPath())
        let message = ACPDelegatedMessage(
            id: "message",
            sourceSessionId: "child",
            targetSessionId: "parent",
            prompt: "The parser accepts malformed UTF-8.",
            createdAt: 100
        )
        try store.enqueue(message)
        _ = try store.claimMessage(
            id: "message",
            instanceId: "stale-instance",
            token: "stale-token",
            now: 100,
            staleAfter: 10
        )

        let claim = try #require(try store.claimMessage(
            id: "message",
            instanceId: "new-instance",
            token: "new-token",
            now: 111,
            staleAfter: 10
        ))
        try store.removeDeliveredMessage(id: "message", claim: claim.claim)

        #expect(try store.pendingMessages(targetSessionId: "parent") == [])
    }

    @Test("migrates a v1 database to the current schema, decoding old messages as prompts and old delegations without a model selection")
    func migratesV1ToCurrent() throws {
        let path = temporaryPath()
        do {
            let db = try SQLiteDatabase(path: path, busyTimeoutMilliseconds: 5_000)
            try db.exec("CREATE TABLE schema_version (version INTEGER NOT NULL)")
            try db.exec("INSERT INTO schema_version (version) VALUES (1)")
            try db.exec("""
            CREATE TABLE delegations (
                child_session_id TEXT PRIMARY KEY, parent_session_id TEXT NOT NULL,
                project_id TEXT NOT NULL, parent_worktree_id TEXT NOT NULL,
                child_worktree_id TEXT, agent_id TEXT NOT NULL, worktree_request BLOB NOT NULL,
                pending_initial_prompt TEXT, phase TEXT NOT NULL, failure_message TEXT,
                created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
            )
            """)
            try db.exec("""
            CREATE TABLE delegated_messages (
                id TEXT PRIMARY KEY, source_session_id TEXT NOT NULL,
                target_session_id TEXT NOT NULL, prompt TEXT NOT NULL,
                created_at INTEGER NOT NULL, claim_instance_id TEXT,
                claim_token TEXT, claim_expires_at INTEGER
            )
            """)
            try db.exec("""
            INSERT INTO delegated_messages (id, source_session_id, target_session_id, prompt, created_at)
            VALUES ('m1', 'child', 'parent', 'hello', 5)
            """)
            try db.exec("""
            INSERT INTO delegations (
                child_session_id, parent_session_id, project_id, parent_worktree_id, agent_id,
                worktree_request, pending_initial_prompt, phase, created_at, updated_at
            ) VALUES ('child', 'parent', 'project', 'w', 'codex', ?, 'Task', 'starting', 1, 1)
            """, bindings: [try JSONEncoder().encode(ACPDelegatedWorktreeRequest.current(worktreeId: "w"))])
        }

        let store = try ACPOrchestrationStore(path: path)
        #expect(try store.currentSchemaVersion() == ACPOrchestrationStore.targetSchemaVersion)
        let legacy = try #require(try store.delegation(childSessionId: "child"))
        #expect(legacy.modelSelection == nil)
        #expect(legacy.role == nil)
        #expect(legacy.pendingInitialPrompt == "Task")
        let pending = try store.pendingMessages(targetSessionId: "parent")
        #expect(pending.count == 1)
        #expect(pending.first?.kind == .prompt)
        #expect(pending.first?.prompt == "hello")
    }

    @Test("two instances opening the same v1 database back-to-back both migrate cleanly")
    func concurrentV1ToV2MigrationDoesNotWedgeSecondInstance() throws {
        // Simulates two Alas instances racing to open a freshly-shipped
        // v1 database for the first time. `migrateToV2()`'s `ALTER TABLE
        // ... ADD COLUMN` statements aren't idempotent, so without
        // `migrate()` wrapping its read-check-migrate sequence in a
        // transaction, the second instance to construct a store here would
        // read schema version 1, attempt `migrateToV2()` again, and throw a
        // duplicate-column error — permanently wedging its delegation store
        // (per `ACPOrchestrationPersistence.openedStore()`'s failure cache).
        let path = temporaryPath()
        do {
            let db = try SQLiteDatabase(path: path, busyTimeoutMilliseconds: 5_000)
            try db.exec("CREATE TABLE schema_version (version INTEGER NOT NULL)")
            try db.exec("INSERT INTO schema_version (version) VALUES (1)")
            try db.exec("""
            CREATE TABLE delegations (
                child_session_id TEXT PRIMARY KEY, parent_session_id TEXT NOT NULL,
                project_id TEXT NOT NULL, parent_worktree_id TEXT NOT NULL,
                child_worktree_id TEXT, agent_id TEXT NOT NULL, worktree_request BLOB NOT NULL,
                pending_initial_prompt TEXT, phase TEXT NOT NULL, failure_message TEXT,
                created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
            )
            """)
            try db.exec("""
            CREATE TABLE delegated_messages (
                id TEXT PRIMARY KEY, source_session_id TEXT NOT NULL,
                target_session_id TEXT NOT NULL, prompt TEXT NOT NULL,
                created_at INTEGER NOT NULL, claim_instance_id TEXT,
                claim_token TEXT, claim_expires_at INTEGER
            )
            """)
        }

        // Both instances construct against the SAME on-disk file. With the
        // transactional fix, the second construction's `BEGIN IMMEDIATE`
        // blocks until the first's migration commits, then observes schema
        // version 2 already and no-ops instead of erroring.
        let first = try ACPOrchestrationStore(path: path)
        let second = try ACPOrchestrationStore(path: path)

        #expect(try first.currentSchemaVersion() == ACPOrchestrationStore.targetSchemaVersion)
        #expect(try second.currentSchemaVersion() == ACPOrchestrationStore.targetSchemaVersion)
    }

    @Test("round-trips message kind")
    func roundTripsMessageKind() throws {
        let store = try ACPOrchestrationStore(path: temporaryPath())
        try store.enqueue(.init(
            id: "n1", sourceSessionId: "child", targetSessionId: "parent",
            prompt: "Delegated session child (codex) finished its turn.", createdAt: 7, kind: .notice
        ))
        try store.enqueue(.init(
            id: "p1", sourceSessionId: "child", targetSessionId: "parent",
            prompt: "wake", createdAt: 8
        ))
        let pending = try store.pendingMessages(targetSessionId: "parent")
        #expect(pending.map(\.kind) == [.notice, .prompt])
    }

    @Test("records and reads last parent report time")
    func marksParentReport() throws {
        let store = try ACPOrchestrationStore(path: temporaryPath())
        try store.insert(newRecord())
        #expect(try store.delegation(childSessionId: "child")?.lastParentReportAt == nil)
        try store.markParentReport(childSessionId: "child", at: 640)
        #expect(try store.delegation(childSessionId: "child")?.lastParentReportAt == 640)
    }

    private func failureOutcome() -> ACPDelegatedMessage {
        .init(
            id: "outcome-child-failed",
            sourceSessionId: "child",
            targetSessionId: "parent",
            prompt: "[alas system] Delegated session child (codex) failed: boom.",
            createdAt: 700,
            kind: .prompt
        )
    }

    @Test("claiming the failed phase commits the parent's outcome with it")
    func claimFailedPhaseCommitsOutcomeTogether() throws {
        let store = try ACPOrchestrationStore(path: temporaryPath())
        try store.insert(newRecord())

        #expect(try store.claimFailedPhase(
            childSessionId: "child", failureMessage: "boom", updatedAt: 700, outcome: failureOutcome()
        ))

        let record = try #require(try store.delegation(childSessionId: "child"))
        #expect(record.phase == .failed)
        #expect(record.failureMessage == "boom")
        let pending = try store.pendingMessages(targetSessionId: "parent")
        #expect(pending.map(\.id) == ["outcome-child-failed"])
        #expect(pending.first?.kind == .prompt)
    }

    @Test("a losing failed-phase claim writes no second outcome")
    func claimFailedPhaseLoserEnqueuesNothing() throws {
        let store = try ACPOrchestrationStore(path: temporaryPath())
        try store.insert(newRecord())
        #expect(try store.claimFailedPhase(
            childSessionId: "child", failureMessage: "boom", updatedAt: 700, outcome: failureOutcome()
        ))
        // Simulate the first outcome having been delivered and removed, which
        // is what previously let a fixed id be re-inserted and wake twice.
        let claim = try #require(try store.claimMessage(
            id: "outcome-child-failed", instanceId: "i", token: "t", now: 700, staleAfter: 60
        ))
        try store.removeDeliveredMessage(id: "outcome-child-failed", claim: claim.claim)
        #expect(try store.pendingMessages(targetSessionId: "parent").isEmpty)

        #expect(try store.claimFailedPhase(
            childSessionId: "child", failureMessage: "boom again", updatedAt: 800, outcome: failureOutcome()
        ) == false)

        #expect(try store.pendingMessages(targetSessionId: "parent").isEmpty)
        // The losing caller must not overwrite the recorded reason either.
        #expect(try store.delegation(childSessionId: "child")?.failureMessage == "boom")
    }

    /// Two instances sharing one database: one fails a selected child while
    /// the other queues a message for it. Either commit order must leave the
    /// failed child with no inbox row, and a message sent after the failure
    /// must be refused rather than reported as queued. A row another instance
    /// is delivering under a live claim is left to it.
    @Test("failing a selected child and queueing a message for it serialize across instances", arguments: [true, false])
    func failedPhaseAndEnqueueSerialize(failFirst: Bool) throws {
        let path = temporaryPath()
        let failing = try ACPOrchestrationStore(path: path)
        let sending = try ACPOrchestrationStore(path: path)
        try failing.insert(newRecord())
        try sending.enqueue(.init(
            id: "claimed", sourceSessionId: "parent", targetSessionId: "child", prompt: "In flight.", createdAt: 690
        ))
        _ = try #require(try sending.claimMessage(id: "claimed", instanceId: "b", token: "t", now: 690, staleAfter: 60))
        let message = ACPDelegatedMessage(
            id: "late", sourceSessionId: "parent", targetSessionId: "child", prompt: "Also check the lexer.", createdAt: 700
        )
        func fail() throws {
            #expect(try failing.claimFailedPhase(
                childSessionId: "child", failureMessage: "Model opus is not offered.", updatedAt: 700,
                outcome: failureOutcome(), discardingHeldMessages: true
            ))
        }

        if failFirst {
            try fail()
            #expect(try sending.enqueueUnlessTargetEnded(message) == false)
        } else {
            #expect(try sending.enqueueUnlessTargetEnded(message))
            try fail()
        }

        #expect(try sending.pendingMessages(targetSessionId: "child").map(\.id) == ["claimed"])
    }

    @Test("a selected child's inbox rows are claimable only once it is ready, and dropped once it failed", arguments: [
        (ACPDelegationPhase.starting, false, true), (.ready, true, true), (.failed, false, false),
    ])
    func selectedChildInboxClaims(phase: ACPDelegationPhase, claimable: Bool, rowKept: Bool) throws {
        let store = try ACPOrchestrationStore(path: temporaryPath())
        var record = newRecord()
        record.phase = phase
        record.modelSelection = ACPDelegatedModelSelection(model: "opus", reasoning: nil)
        try store.insert(record)
        try store.enqueue(.init(
            id: "held", sourceSessionId: "parent", targetSessionId: "child", prompt: "Also check the lexer.", createdAt: 700
        ))

        let claim = try store.claimMessage(id: "held", instanceId: "i", token: "t", now: 700, staleAfter: 60)

        #expect((claim != nil) == claimable)
        #expect(try store.pendingMessages(targetSessionId: "child").isEmpty == !rowKept)
    }

    // MARK: Peer delegation outbox

    private func peerMessage(id: String, target: String, prompt: String = "done") -> ACPDelegatedMessage {
        .init(id: id, sourceSessionId: "child", targetSessionId: target, prompt: prompt, createdAt: 800, kind: .prompt)
    }

    private func outboxEntry(seq: Int64) -> ACPPeerOutboxEntry {
        .init(seq: seq, messageId: "outcome-\(seq)", childSessionId: "child", prompt: "done", kind: .prompt, createdAt: 800)
    }

    @Test("an outcome for a peer parent goes to the outbox, not the inbox")
    func outcomeForPeerParentGoesToOutboxNotInbox() throws {
        let store = try ACPOrchestrationStore(path: temporaryPath())
        let sentinel = ACPPeerParent.sentinel(serverId: "s1")
        try store.enqueue(peerMessage(id: "m1", target: sentinel))
        try store.enqueue(peerMessage(id: "m1", target: sentinel))

        let page = try store.outbox(peerServerId: "s1", after: 0, maxBytes: .max)
        #expect(page.entries.map(\.messageId) == ["m1"])
        #expect(page.entries.first?.childSessionId == "child")
        #expect(try store.pendingMessages(targetSessionId: sentinel).isEmpty)
        #expect(try store.outbox(peerServerId: "other", after: 0, maxBytes: .max).entries.isEmpty)
    }

    @Test("failing a peer child writes the outbox row in the same transaction")
    func failedTransitionForPeerParentWritesOutboxInSameTransaction() throws {
        let store = try ACPOrchestrationStore(path: temporaryPath())
        let sentinel = ACPPeerParent.sentinel(serverId: "s1")
        var record = newRecord(parentSessionId: sentinel)
        record.peerServerId = "s1"
        try store.insert(record)
        var another = newRecord(childSessionId: "another", parentSessionId: ACPPeerParent.sentinel(serverId: "s2"))
        another.peerServerId = "s2"
        try store.insert(another)

        #expect(try store.claimFailedPhase(
            childSessionId: "child", failureMessage: "boom", updatedAt: 700,
            outcome: peerMessage(id: "outcome-child-failed", target: sentinel)
        ))

        #expect(try store.delegation(childSessionId: "child")?.phase == .failed)
        #expect(try store.outbox(peerServerId: "s1", after: 0, maxBytes: .max).entries.map(\.messageId) == ["outcome-child-failed"])
        #expect(try store.peerChildren(peerServerId: "s1") == [try #require(try store.delegation(childSessionId: "child"))])
    }

    /// Earlier builds of this schema version wrote stores without the column.
    @Test func aVersion5StoreWithoutTheAwaitedColumnGainsIt() throws {
        let path = temporaryPath()
        do {
            let store = try ACPOrchestrationStore(path: path)
            #expect(try store.currentSchemaVersion() == 5)
        }
        var db: OpaquePointer?
        #expect(sqlite3_open(path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "ALTER TABLE delegations DROP COLUMN peer_awaiting", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(db, "ALTER TABLE delegations DROP COLUMN peer_awaiting_since", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(db, "ALTER TABLE delegations DROP COLUMN peer_settled_turn", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let store = try ACPOrchestrationStore(path: path)
        var record = newRecord()
        record.peerAwaiting = true
        try store.insert(record)

        try store.markPeerAwaiting(childSessionId: "child", since: 5)

        #expect(try store.delegation(childSessionId: "child")?.peerAwaiting == true)
    }

    private func lostTurn(_ store: ACPOrchestrationStore) throws -> Bool {
        try store.claimLostPeerTurn(childSessionId: "child", outcome: .init(
            id: "lost", sourceSessionId: "child", targetSessionId: "parent", prompt: "Stopped", createdAt: 1
        ))
    }

    /// Instances sharing a store may both see the child stop: one wakes its parent.
    @Test func onlyOneCallerClaimsALostPeerTurn() throws {
        let store = try ACPOrchestrationStore(path: temporaryPath())
        var record = newRecord()
        record.peerServerId = "s1"
        record.peerAwaiting = true
        record.phase = .ready
        try store.insert(record)

        #expect(try lostTurn(store))
        #expect(try lostTurn(store) == false)

        #expect(try store.delegation(childSessionId: "child")?.peerAwaiting == false)
        #expect(try store.pendingMessages(targetSessionId: "parent").map(\.id) == ["lost"])
    }

    /// A wake that cannot be stored leaves the child awaited, for a later poll.
    @Test func aLostPeerTurnThatCannotEnqueueStaysAwaited() throws {
        let path = temporaryPath()
        let store = try ACPOrchestrationStore(path: path)
        var record = newRecord()
        record.peerServerId = "s1"
        record.peerAwaiting = true
        record.phase = .ready
        try store.insert(record)
        var db: OpaquePointer?
        #expect(sqlite3_open(path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "ALTER TABLE delegated_messages RENAME TO hidden", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        #expect(throws: (any Error).self) { try lostTurn(store) }

        #expect(try store.delegation(childSessionId: "child")?.peerAwaiting == true)
    }

    /// An acknowledgement can arrive after the turn it started was collected,
    /// by this instance or another on the store, and must not revive the wait.
    @Test(arguments: [(1000, false), (1100, false), (1101, true)] as [(Int64, Bool)])
    func aLateAcknowledgementDoesNotReviveASettledWait(acceptedAt: Int64, stillAwaited: Bool) throws {
        let store = try ACPOrchestrationStore(path: temporaryPath())
        var record = newRecord()
        record.peerServerId = "s1"
        record.peerAwaiting = true
        try store.insert(record)
        let entry = ACPPeerOutboxEntry(seq: 1, messageId: "outcome-child-1100", childSessionId: "child", prompt: "Done", kind: .prompt, createdAt: 1)
        #expect(try store.collectPeerEntry(entry, peerServerId: "s1", parentSessionId: "parent"))

        try store.markPeerAwaiting(childSessionId: "child", since: acceptedAt)

        #expect(try store.delegation(childSessionId: "child")?.peerAwaiting == stillAwaited)
    }

    @Test("an outbox page respects the byte limit and always returns one entry")
    func outboxPageRespectsByteLimitAndAlwaysReturnsOneEntry() throws {
        let store = try ACPOrchestrationStore(path: temporaryPath())
        let sentinel = ACPPeerParent.sentinel(serverId: "s1")
        let big = String(repeating: "x", count: 10_000)
        try store.enqueue(peerMessage(id: "m1", target: sentinel, prompt: big))
        try store.enqueue(peerMessage(id: "m2", target: sentinel, prompt: big))

        let first = try store.outbox(peerServerId: "s1", after: 0, maxBytes: 1_000)
        #expect(first.entries.map(\.messageId) == ["m1"])
        #expect(first.hasMore)
        let second = try store.outbox(peerServerId: "s1", after: first.entries[0].seq, maxBytes: 1_000)
        #expect(second.entries.map(\.messageId) == ["m2"])
        #expect(second.hasMore == false)
    }

    @Test("acknowledging and deleting trim only the named peer's outbox")
    func acknowledgeAndDeleteOutbox() throws {
        let store = try ACPOrchestrationStore(path: temporaryPath())
        for id in ["a1", "a2", "a3"] { try store.enqueue(peerMessage(id: id, target: ACPPeerParent.sentinel(serverId: "s1"))) }
        try store.enqueue(peerMessage(id: "b1", target: ACPPeerParent.sentinel(serverId: "s2")))

        let all = try store.outbox(peerServerId: "s1", after: 0, maxBytes: .max).entries
        try store.acknowledgeOutbox(peerServerId: "s1", through: all[1].seq)
        #expect(try store.outbox(peerServerId: "s1", after: 0, maxBytes: .max).entries.map(\.messageId) == ["a3"])

        try store.deleteOutbox(peerServerId: "s1")
        #expect(try store.outbox(peerServerId: "s1", after: 0, maxBytes: .max).entries.isEmpty)
        #expect(try store.outbox(peerServerId: "s2", after: 0, maxBytes: .max).entries.map(\.messageId) == ["b1"])
    }

    @Test("only one collector advances the cursor")
    func onlyOneCollectorAdvancesTheCursor() throws {
        let store = try ACPOrchestrationStore(path: temporaryPath())
        #expect(try store.peerCursor(peerServerId: "s1") == 0)
        let entry = outboxEntry(seq: 1)
        #expect(try store.collectPeerEntry(entry, peerServerId: "s1", parentSessionId: "p"))
        #expect(try store.collectPeerEntry(entry, peerServerId: "s1", parentSessionId: "p") == false)
        #expect(try store.pendingMessages(targetSessionId: "p").map(\.id) == ["outcome-1"])
        #expect(try store.peerCursor(peerServerId: "s1") == 1)
        #expect(try store.collectPeerEntry(outboxEntry(seq: 2), peerServerId: "s1", parentSessionId: "p"))
        #expect(try store.collectPeerEntry(outboxEntry(seq: 1), peerServerId: "s1", parentSessionId: "p") == false)
    }

    @Test("advancing the cursor without an entry moves it forward only")
    func advancingCursorMovesForwardOnly() throws {
        let store = try ACPOrchestrationStore(path: temporaryPath())
        #expect(try store.advancePeerCursor(peerServerId: "s1", to: 3))
        #expect(try store.advancePeerCursor(peerServerId: "s1", to: 2) == false)
        #expect(try store.peerCursor(peerServerId: "s1") == 3)
        #expect(try store.collectPeerEntry(outboxEntry(seq: 3), peerServerId: "s1", parentSessionId: "p") == false)
        #expect(try store.pendingMessages(targetSessionId: "p").isEmpty)
    }

    @Test("migrates a version 4 database keeping its rows")
    func migratesFromVersion4KeepingRows() throws {
        let path = temporaryPath()
        do {
            let db = try SQLiteDatabase(path: path, busyTimeoutMilliseconds: 5_000)
            try db.exec("CREATE TABLE schema_version (version INTEGER NOT NULL)")
            try db.exec("INSERT INTO schema_version (version) VALUES (4)")
            try db.exec("""
            CREATE TABLE delegations (
                child_session_id TEXT PRIMARY KEY, parent_session_id TEXT NOT NULL,
                project_id TEXT NOT NULL, parent_worktree_id TEXT NOT NULL,
                child_worktree_id TEXT, agent_id TEXT NOT NULL, worktree_request BLOB NOT NULL,
                pending_initial_prompt TEXT, phase TEXT NOT NULL, failure_message TEXT,
                created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
                last_parent_report_at INTEGER, requested_model TEXT, requested_reasoning TEXT, role TEXT
            )
            """)
            try db.exec("""
            CREATE TABLE delegated_messages (
                id TEXT PRIMARY KEY, source_session_id TEXT NOT NULL,
                target_session_id TEXT NOT NULL, prompt TEXT NOT NULL,
                created_at INTEGER NOT NULL, claim_instance_id TEXT,
                claim_token TEXT, claim_expires_at INTEGER, kind TEXT NOT NULL DEFAULT 'prompt'
            )
            """)
            try db.exec("""
            INSERT INTO delegated_messages (id, source_session_id, target_session_id, prompt, created_at)
            VALUES ('m1', 'child', 'parent', 'hello', 5)
            """)
            try db.exec("""
            INSERT INTO delegations (
                child_session_id, parent_session_id, project_id, parent_worktree_id, agent_id,
                worktree_request, phase, created_at, updated_at, role
            ) VALUES ('child', 'parent', 'project', 'w', 'codex', ?, 'starting', 1, 1, 'reviewer')
            """, bindings: [try JSONEncoder().encode(ACPDelegatedWorktreeRequest.current(worktreeId: "w"))])
        }

        let store = try ACPOrchestrationStore(path: path)
        #expect(ACPOrchestrationStore.targetSchemaVersion == 5)
        #expect(try store.currentSchemaVersion() == 5)
        let record = try #require(try store.delegation(childSessionId: "child"))
        #expect(record.peerServerId == nil)
        #expect(record.peerAwaiting == false)
        #expect(record.role == "reviewer")
        #expect(try store.pendingMessages(targetSessionId: "parent").map(\.id) == ["m1"])
        #expect(try store.peerCursor(peerServerId: "s1") == 0)
    }
}
