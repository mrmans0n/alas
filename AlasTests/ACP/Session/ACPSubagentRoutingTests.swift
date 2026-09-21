import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACP subagent routing")
struct ACPSubagentRoutingTests {
    @Test("an update addressed to a known child never reaches the parent transcript")
    func childUpdateIsRoutedToItsChild() async throws {
        let (runner, _, _) = try makeRunner()
        runner.applyIncomingUpdateForTesting(.init(
            sessionId: "remote-parent",
            update: .subagentSpawned(.init(subagentSessionId: "child-1", name: "Explore"))))

        runner.applyIncomingUpdateForTesting(.init(
            sessionId: "child-1",
            update: .agentMessageChunk(.text("child output"))))

        // One row: the subagent row itself. The child's prose is inside it.
        #expect(runner.session.transcript.messages.count == 1)
        #expect(runner.session.subagentRun("child-1")?.messages.count == 1)
    }

    @Test("an update for an unknown session still lands in the parent, as before")
    func unknownSessionKeepsLegacyBehaviour() async throws {
        let (runner, _, _) = try makeRunner()

        // An agent that ignores the capability may address updates with a
        // session id Alas never saw announced. The runner has never
        // filtered on session id, so this must keep working.
        runner.applyIncomingUpdateForTesting(.init(
            sessionId: "some-other-session",
            update: .agentMessageChunk(.text("still mine"))))

        #expect(runner.session.transcript.messages.count == 1)
        guard case .agent(_, _, let buffer) = runner.session.transcript.messages[0] else {
            Issue.record("expected the chunk to land on the parent transcript")
            return
        }
        #expect(buffer.value == "still mine")
        #expect(runner.session.subagents.isEmpty)
    }

    @Test("child transcripts are persisted and restored across a reload")
    func childTranscriptsSurviveReload() async throws {
        let (runner, store, path) = try makeRunner()
        runner.applyIncomingUpdateForTesting(.init(
            sessionId: "remote-parent",
            update: .subagentSpawned(.init(
                subagentSessionId: "child-1",
                name: "Explore",
                task: "Find the router",
                capabilities: .cancellable))))
        runner.applyIncomingUpdateForTesting(.init(
            sessionId: "child-1",
            update: .agentMessageChunk(.text("persisted output"))))
        runner.applyIncomingUpdateForTesting(.init(
            sessionId: "child-1",
            update: .toolCall(.init(
                toolCallId: "t1", title: "Read", kind: "read", status: "completed"))))
        runner.applyIncomingUpdateForTesting(.init(
            sessionId: "remote-parent",
            update: .subagentStateUpdate(.init(subagentSessionId: "child-1", state: .completed))))
        await runner.flushPersistence()

        let stored = try store.loadSubagentMessages(sessionId: "s")
        #expect(stored.count == 2)
        #expect(stored.allSatisfy { $0.subagentSessionId == "child-1" })
        #expect(stored.map(\.kind) == ["agent", "tool_call"])

        // Reload the way a relaunch does: hydrate, then rebuild the runs.
        let hydrated = try await ACPSessionHydrator(path: path).hydrate(sessionId: "s")
        #expect(hydrated.subagentMessages.count == 2)

        let reopened = ACPSession(id: "s", agentId: "claude", worktreeId: "wt", title: "t")
        var rows: [ACPMessage.ToolCall] = []
        for message in hydrated.messages {
            if case .toolCall(let toolCall) = message.wire { rows.append(toolCall) }
        }
        var restored: [String: [(message: ACPMessage, createdAt: Date, seq: Int64)]] = [:]
        for message in hydrated.subagentMessages {
            restored[message.subagentSessionId, default: []]
                .append((message.wire.toMessage(), message.createdAt, message.seq))
        }
        reopened.restoreSubagents(rows: rows, messages: restored)

        let run = try #require(reopened.subagentRun("child-1"))
        #expect(run.name == "Explore")
        #expect(run.task == "Find the router")
        #expect(run.state == .completed)
        #expect(run.capabilities.supportsCancel)
        #expect(run.messages.count == 2)
        guard case .agent(_, _, let buffer) = run.messages[0] else {
            Issue.record("expected the child's restored prose")
            return
        }
        #expect(buffer.value == "persisted output")
    }

    @Test("a child row is rewritten in place rather than appended per chunk")
    func childRowsAreRewrittenInPlace() async throws {
        let (runner, store, _) = try makeRunner()
        runner.applyIncomingUpdateForTesting(.init(
            sessionId: "remote-parent",
            update: .subagentSpawned(.init(subagentSessionId: "child-1"))))
        for chunk in ["a", "b", "c"] {
            runner.applyIncomingUpdateForTesting(.init(
                sessionId: "child-1",
                update: .agentMessageChunk(.text(chunk))))
        }
        await runner.flushPersistence()

        let stored = try store.loadSubagentMessages(sessionId: "s")
        #expect(stored.count == 1)
        let decoded = try #require(try? JSONDecoder().decode(
            StoredText.self, from: stored[0].payload))
        #expect(decoded.text == "abc")
    }

    @Test("a nested collaborator announced on a child session is registered on the root")
    func nestedSpawnIsRegisteredFlat() async throws {
        let (runner, _, _) = try makeRunner()
        runner.applyIncomingUpdateForTesting(.init(
            sessionId: "remote-parent",
            update: .subagentSpawned(.init(subagentSessionId: "child-1", name: "Explore"))))

        // The grandchild is announced on ITS parent, which is our child.
        runner.applyIncomingUpdateForTesting(.init(
            sessionId: "child-1",
            update: .subagentSpawned(.init(subagentSessionId: "grandchild", name: "Deeper"))))
        runner.applyIncomingUpdateForTesting(.init(
            sessionId: "grandchild",
            update: .agentMessageChunk(.text("nested output"))))

        // Two rows on the root, one per subagent, and the nested output
        // went to the grandchild rather than leaking into the parent.
        #expect(runner.session.transcript.messages.count == 2)
        #expect(runner.session.subagentRun("grandchild")?.name == "Deeper")
        #expect(runner.session.subagentRun("grandchild")?.messages.count == 1)
        #expect(runner.session.subagentRun("child-1")?.messages.isEmpty == true)

        runner.applyIncomingUpdateForTesting(.init(
            sessionId: "child-1",
            update: .subagentStateUpdate(.init(
                subagentSessionId: "grandchild", state: .completed))))
        #expect(runner.session.subagentRun("grandchild")?.state == .completed)
    }

    @Test("session/load replay recovers a child chunk that never reached SQLite")
    func replayRecoversUnpersistedChildContent() async throws {
        let (runner, _, _) = try makeRunner()
        runner.session.apply(.subagentSpawned(.init(subagentSessionId: "child-1")))
        // Only the first chunk made it into memory (and, in the real
        // failure this models, to SQLite) before the app quit.
        runner.session.applySubagentUpdate(
            .agentMessageChunk(.init(messageId: "m1", content: .text("hello "))),
            subagentSessionId: "child-1")

        runner.suppressLoadReplay(throughYieldedUpdateCount: 99)

        // `session/load` resends the message from scratch, not just the
        // missing suffix.
        for chunk in ["hello", " world"] {
            runner.applyIncomingUpdateForTesting(.init(
                sessionId: "child-1",
                update: .agentMessageChunk(.init(messageId: "m1", content: .text(chunk)))))
        }

        let run = try #require(runner.session.subagentRun("child-1"))
        #expect(run.messages.count == 1)
        guard case .agent(_, _, let buffer) = run.messages[0] else {
            Issue.record("expected the row to be rebuilt from replay")
            return
        }
        #expect(buffer.value == "hello world")
    }

    @Test("a row recovered after a seq gap never collides with an existing seq")
    func recoveredRowAfterSeqGapDoesNotCollide() async throws {
        let (runner, store, path) = try makeRunner()
        // Seq 1 never made it to disk (its write failed); seq 0 and seq 2
        // did. Insert directly — this is the state persistence can
        // legitimately leave behind, not something the live/replay path
        // produces on its own.
        try store.upsertSubagentMessages([
            .init(
                id: ACPStoredSubagentMessage.rowId(sessionId: "s", subagentSessionId: "child-1", seq: 0),
                sessionId: "s", subagentSessionId: "child-1",
                kind: "agent", seq: 0,
                payload: try ACPMessageCodec.encode(
                    .agent(id: UUID(), messageId: "m0", StreamingText("first"))),
                createdAt: 10),
            .init(
                id: ACPStoredSubagentMessage.rowId(sessionId: "s", subagentSessionId: "child-1", seq: 2),
                sessionId: "s", subagentSessionId: "child-1",
                kind: "agent", seq: 2,
                payload: try ACPMessageCodec.encode(
                    .agent(id: UUID(), messageId: "m2", StreamingText("third"))),
                createdAt: 30)
        ])
        runner.session.apply(.subagentSpawned(.init(subagentSessionId: "child-1")))

        // Hydrate the way a relaunch does, and restore from that snapshot —
        // this is what threads the STORED seq (0, 2) into the run rather
        // than compacted array positions (0, 1).
        let hydrated = try await ACPSessionHydrator(path: path).hydrate(sessionId: "s")
        #expect(hydrated.subagentMessages.map(\.seq).sorted() == [0, 2])
        var restored: [String: [(message: ACPMessage, createdAt: Date, seq: Int64)]] = [:]
        for stored in hydrated.subagentMessages {
            restored[stored.subagentSessionId, default: []]
                .append((stored.wire.toMessage(), stored.createdAt, stored.seq))
        }
        let run = try #require(runner.session.subagentRun("child-1"))
        run.restore(
            messages: restored["child-1"]!.map(\.message),
            createdAts: restored["child-1"]!.map(\.createdAt),
            seqs: restored["child-1"]!.map(\.seq))
        #expect(run.seq(at: 0) == 0)
        #expect(run.seq(at: 1) == 2)

        // `session/load` replays the child's FULL history chronologically —
        // "first" (m0), then the missing "second" (m1), then "third" (m2) —
        // not just the recovered message in isolation.
        runner.suppressLoadReplay(throughYieldedUpdateCount: 99)
        runner.applyIncomingUpdateForTesting(.init(
            sessionId: "child-1",
            update: .agentMessageChunk(.init(messageId: "m0", content: .text("first")))))
        runner.applyIncomingUpdateForTesting(.init(
            sessionId: "child-1",
            update: .agentMessageChunk(.init(messageId: "m1", content: .text("second")))))
        runner.applyIncomingUpdateForTesting(.init(
            sessionId: "child-1",
            update: .agentMessageChunk(.init(messageId: "m2", content: .text("third")))))
        await runner.flushPersistence()

        // The recovered row lands BETWEEN its chronological neighbours —
        // both in memory and in its assigned seq — not always at the tail.
        #expect(run.messages.count == 3)
        guard case .agent(_, "m1", let recovered) = run.messages[1] else {
            Issue.record("expected the recovered row between m0 and m2")
            return
        }
        #expect(recovered.value == "second")
        #expect(run.seq(at: 0) == 0)
        #expect(run.seq(at: 1) == 1)
        #expect(run.seq(at: 2) == 2)

        // The persisted rows must reflect that: seq 2's original content
        // (`m2`/"third") must be untouched, not overwritten by the
        // recovered row, which lands at the gap's own seq (1).
        let rows = try store.loadSubagentMessages(sessionId: "s")
        #expect(rows.map(\.seq).sorted() == [0, 1, 2])
        let seqTwoRow = try #require(rows.first { $0.seq == 2 })
        #expect(String(data: seqTwoRow.payload, encoding: .utf8)?.contains("third") == true)
        let seqOneRow = try #require(rows.first { $0.seq == 1 })
        #expect(String(data: seqOneRow.payload, encoding: .utf8)?.contains("second") == true)
    }

    @Test("a barrier ack is withheld when the preceding write failed for a non-lease reason")
    func barrierWithholdsAckOnUnrelatedPriorFailure() async throws {
        let (runner, store, _) = try makeRunner()

        // Break the PARENT table so the spawn's own write throws instead
        // of merely being rejected by the fence — a failure the barrier's
        // own fence re-check alone cannot see, since the lease is fine.
        try store.db.exec("ALTER TABLE messages RENAME TO messages_broken")
        runner.applyIncomingUpdateForTesting(.init(
            sessionId: "remote-parent",
            update: .subagentSpawned(.init(subagentSessionId: "child-1"))))
        await runner.flushPersistence()
        try store.db.exec("ALTER TABLE messages_broken RENAME TO messages")

        // The trailing half of the SAME batch: a `running` state against a
        // run that already starts `.running`, so `dirty` is empty and this
        // reaches the barrier. Its OWN fence check succeeds (nothing about
        // the lease changed), so only the carried-forward prior outcome
        // can withhold the ack.
        let acknowledged = Acknowledged()
        runner.applyIncomingUpdateForTesting(.init(
            sessionId: "remote-parent",
            update: .subagentStateUpdate(.init(subagentSessionId: "child-1", state: .running)),
            durableConsumptionAcknowledgement: { acknowledged.value = true }))
        await runner.flushPersistence()

        #expect(acknowledged.value == false)
    }

    @Test("a replayed OpenCode-style trailing no-op waits behind its spawn's write")
    func replayEmptyDirtyRootUpdateWaitsBehindSpawn() async throws {
        let (runner, store, _) = try makeRunner()

        // Break the parent table so the SPAWN's write throws. The spawn
        // itself carries no ack (mirroring `ACPOpenCodeChildUpdate`'s own
        // shape), so nothing acks it directly — the only signal is what
        // the TRAILING update below does with it. Left broken (not
        // restored) until after both updates are sent: persistence is
        // queued asynchronously, so restoring earlier would let the
        // spawn's write land successfully once the queue finally drains.
        try store.db.exec("ALTER TABLE messages RENAME TO messages_broken")
        runner.suppressLoadReplay(throughYieldedUpdateCount: 99)
        runner.applyIncomingUpdateForTesting(.init(
            sessionId: "remote-parent",
            update: .subagentSpawned(.init(subagentSessionId: "child-1"))))

        // The trailing `running` state matches what a freshly-registered
        // run already defaults to, so it produces NO dirty rows and
        // reaches the empty-dirty branch directly — the exact path that
        // used to acknowledge immediately, unconditionally, regardless of
        // whether the spawn it followed ever made it to disk.
        let acknowledged = Acknowledged()
        runner.applyIncomingUpdateForTesting(.init(
            sessionId: "remote-parent",
            update: .subagentStateUpdate(.init(subagentSessionId: "child-1", state: .running)),
            durableConsumptionAcknowledgement: { acknowledged.value = true }))
        await runner.flushPersistence()

        #expect(acknowledged.value == false)
    }

    @Test("a replayed root-level spawn is not acknowledged unless it persists")
    func replayRootSpawnAckRequiresPersistence() async throws {
        let (runner, store, _) = try makeRunner()

        // Break the parent table so the recovered row's write throws.
        // Before the fix, `applySuppressedReplaySideEffects`'s dirty
        // result was discarded (`_ = ...`) and the durable event was
        // acknowledged unconditionally right after — this proves the two
        // are now coupled the same way the live path already couples them.
        try store.db.exec("ALTER TABLE messages RENAME TO messages_broken")
        runner.suppressLoadReplay(throughYieldedUpdateCount: 99)

        let acknowledged = Acknowledged()
        runner.applyIncomingUpdateForTesting(.init(
            sessionId: "remote-parent",
            update: .subagentSpawned(.init(subagentSessionId: "child-1", name: "Explore")),
            durableConsumptionAcknowledgement: { acknowledged.value = true }))
        await runner.flushPersistence()

        #expect(acknowledged.value == false)
    }

    @Test("a replayed root-level spawn is persisted before it is acknowledged")
    func replayRootSpawnPersistsBeforeAck() async throws {
        let (runner, store, _) = try makeRunner()
        runner.suppressLoadReplay(throughYieldedUpdateCount: 99)

        let acknowledged = Acknowledged()
        runner.applyIncomingUpdateForTesting(.init(
            sessionId: "remote-parent",
            update: .subagentSpawned(.init(subagentSessionId: "child-1", name: "Explore")),
            durableConsumptionAcknowledgement: { acknowledged.value = true }))
        await runner.flushPersistence()

        let rows = try store.loadMessages(sessionId: "s")
        #expect(rows.contains { $0.kind == "tool_call" })
        #expect(acknowledged.value == true)
    }

    @Test("a replayed nested lifecycle update is reconciled, its content is not")
    func replayReconcilesNestedLifecycleOnly() async throws {
        let (runner, _, _) = try makeRunner()
        runner.applyIncomingUpdateForTesting(.init(
            sessionId: "remote-parent",
            update: .subagentSpawned(.init(subagentSessionId: "child-1"))))
        runner.applyIncomingUpdateForTesting(.init(
            sessionId: "child-1",
            update: .subagentSpawned(.init(subagentSessionId: "grandchild"))))
        runner.applyIncomingUpdateForTesting(.init(
            sessionId: "grandchild",
            update: .agentMessageChunk(.text("restored output"))))

        runner.suppressLoadReplay(throughYieldedUpdateCount: 99)

        // Replayed content is dropped — the child transcript already came
        // back from SQLite — but the lifecycle state is the one thing the
        // replay may hold that the store does not.
        runner.applyIncomingUpdateForTesting(.init(
            sessionId: "grandchild",
            update: .agentMessageChunk(.text("duplicate"))))
        runner.applyIncomingUpdateForTesting(.init(
            sessionId: "child-1",
            update: .subagentStateUpdate(.init(
                subagentSessionId: "grandchild", state: .completed))))

        #expect(runner.session.subagentRun("grandchild")?.messages.count == 1)
        #expect(runner.session.subagentRun("grandchild")?.state == .completed)
    }

    @Test("tearing the runner down stops running children and records it")
    func stopMarksChildrenDisconnected() async throws {
        let (runner, store, _) = try makeRunner()
        runner.applyIncomingUpdateForTesting(.init(
            sessionId: "remote-parent",
            update: .subagentSpawned(.init(subagentSessionId: "child-1", name: "Explore"))))

        runner.stop()
        await runner.flushPersistence()

        #expect(runner.session.subagentRun("child-1")?.state == .disconnected)
        let rows = try store.loadMessages(sessionId: "s")
        let toolCall = try #require(rows.compactMap {
            try? JSONDecoder().decode(ACPMessage.ToolCall.self, from: $0.payload)
        }.first)
        let descriptor = try #require(ACPSubagentRowDescriptor(toolCall: toolCall))
        #expect(descriptor.state == .disconnected)
        #expect(toolCall.status == "failed")
    }

    @Test("a child write rejected by the lease fence is not acknowledged")
    func rejectedChildWriteIsNotAcknowledged() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("subagent-fence-\(UUID().uuidString).sqlite")
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(
            id: "s", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        let now = Int64(Date().timeIntervalSince1970)
        try store.seizeLease(sessionId: "s", instanceId: "ME", pid: Int64(getpid()), now: now)
        let ourLease = try #require(try store.loadLease(sessionId: "s"))

        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "wt", title: "t")
        session.remoteSessionId = "remote-parent"
        session.agentState = .ready
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: ACPMockClient()),
            store: store,
            sessionId: "s",
            worktreePath: FileManager.default.temporaryDirectory.path,
            ownerInstanceId: "ME",
            canWrite: { true },
            leaseFenceProvider: {
                .init(sessionId: "s", ownerInstance: "ME", token: ourLease.token)
            })
        runner.applyIncomingUpdateForTesting(.init(
            sessionId: "remote-parent",
            update: .subagentSpawned(.init(subagentSessionId: "child-1"))))

        // Ownership moves: the cached `canWrite` still admits the write, but
        // the persistence actor sees a stale token and stores nothing. The
        // durable update must stay unacknowledged so the new writer replays
        // it rather than losing the child's output.
        try store.seizeLease(sessionId: "s", instanceId: "OTHER", pid: Int64(getpid()), now: now)
        let acknowledged = Acknowledged()
        runner.applyIncomingUpdateForTesting(.init(
            sessionId: "child-1",
            update: .agentMessageChunk(.text("dropped")),
            durableConsumptionAcknowledgement: { acknowledged.value = true }))
        await runner.flushPersistence()

        #expect(try store.loadSubagentMessages(sessionId: "s").isEmpty)
        #expect(acknowledged.value == false)
    }

    /// Box so the acknowledgement closure can report back without capturing
    /// a `var` across the `@Sendable` boundary.
    private final class Acknowledged: @unchecked Sendable {
        var value = false
    }

    @Test("a transient failure does not permanently block later, unrelated acknowledgements")
    func transientFailureDoesNotPoisonFutureBatches() async throws {
        let (runner, store, _) = try makeRunner()

        // A one-off, TERMINAL failure (it carries its own ack — a solo
        // spawn, not paired with a trailing update): break the table, take
        // one write through it, restore the table. This write's own ack
        // decision is fully made and communicated right here — nothing
        // about it should still be "pending" for the future.
        try store.db.exec("ALTER TABLE messages RENAME TO messages_broken")
        let firstAcknowledged = Acknowledged()
        runner.applyIncomingUpdateForTesting(.init(
            sessionId: "remote-parent",
            update: .subagentSpawned(.init(subagentSessionId: "stale-failure")),
            durableConsumptionAcknowledgement: { firstAcknowledged.value = true }))
        await runner.flushPersistence()
        try store.db.exec("ALTER TABLE messages_broken RENAME TO messages")
        #expect(firstAcknowledged.value == false)

        // A LATER, fully independent batch: its own spawn write succeeds
        // outright, so its ack must fire regardless of the earlier,
        // unrelated failure — before the fix, the stuck flag would have
        // silently withheld this one too, forever, for the rest of the
        // runner's lifetime.
        let secondAcknowledged = Acknowledged()
        runner.applyIncomingUpdateForTesting(.init(
            sessionId: "remote-parent",
            update: .subagentSpawned(.init(subagentSessionId: "unrelated")),
            durableConsumptionAcknowledgement: { secondAcknowledged.value = true }))
        await runner.flushPersistence()

        #expect(secondAcknowledged.value == true)
    }

    @Test("a spawn's failure is not erased by the child write that follows it")
    func spawnFailureSurvivesSuccessfulChildWrite() async throws {
        let (runner, store, _) = try makeRunner()

        // Break the PARENT table so the spawn's own write throws — a
        // failure unrelated to the lease, exactly like
        // `barrierWithholdsAckOnUnrelatedPriorFailure`, but this time
        // followed by a CHILD write that succeeds on its own.
        try store.db.exec("ALTER TABLE messages RENAME TO messages_broken")
        runner.applyIncomingUpdateForTesting(.init(
            sessionId: "remote-parent",
            update: .subagentSpawned(.init(subagentSessionId: "child-1"))))
        await runner.flushPersistence()
        try store.db.exec("ALTER TABLE messages_broken RENAME TO messages")

        // The child's own table is intact, so THIS write succeeds — but it
        // must not acknowledge on its own success alone, since the batch's
        // earlier spawn write never landed and the orphaned child
        // transcript has no parent row to render.
        let acknowledged = Acknowledged()
        runner.applyIncomingUpdateForTesting(.init(
            sessionId: "child-1",
            update: .agentMessageChunk(.text("orphaned output")),
            durableConsumptionAcknowledgement: { acknowledged.value = true }))
        await runner.flushPersistence()

        // The child row DOES get written (its own write succeeded) — only
        // the acknowledgement is withheld, which is the whole point: the
        // broker must redeliver so a later attempt can recover the spawn.
        #expect(!(try store.loadSubagentMessages(sessionId: "s")).isEmpty)
        #expect(acknowledged.value == false)
    }

    @Test("a no-op update rejected by the lease fence is not acknowledged either")
    func rejectedNoOpUpdateIsNotAcknowledged() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("subagent-fence-noop-\(UUID().uuidString).sqlite")
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(
            id: "s", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        let now = Int64(Date().timeIntervalSince1970)
        try store.seizeLease(sessionId: "s", instanceId: "ME", pid: Int64(getpid()), now: now)
        let ourLease = try #require(try store.loadLease(sessionId: "s"))

        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "wt", title: "t")
        session.remoteSessionId = "remote-parent"
        session.agentState = .ready
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: ACPMockClient()),
            store: store,
            sessionId: "s",
            worktreePath: FileManager.default.temporaryDirectory.path,
            ownerInstanceId: "ME",
            canWrite: { true },
            leaseFenceProvider: {
                .init(sessionId: "s", ownerInstance: "ME", token: ourLease.token)
            })
        runner.applyIncomingUpdateForTesting(.init(
            sessionId: "remote-parent",
            update: .subagentSpawned(.init(subagentSessionId: "child-1", name: "Explore"))))
        await runner.flushPersistence()

        // Ownership moves. A repeated, identical spawn changes nothing
        // (`dirty` is empty), so it takes the barrier path rather than a
        // real write — that path must still refuse to acknowledge once the
        // fence it re-checks no longer matches the live lease.
        try store.seizeLease(sessionId: "s", instanceId: "OTHER", pid: Int64(getpid()), now: now)
        let acknowledged = Acknowledged()
        runner.applyIncomingUpdateForTesting(.init(
            sessionId: "remote-parent",
            update: .subagentSpawned(.init(subagentSessionId: "child-1", name: "Explore")),
            durableConsumptionAcknowledgement: { acknowledged.value = true }))
        await runner.flushPersistence()

        #expect(acknowledged.value == false)
    }

    @Test("cancel is a no-op unless the child advertised it and is still running")
    func cancelRequiresCapabilityAndLiveChild() async throws {
        let (runner, _, _) = try makeRunner()
        runner.applyIncomingUpdateForTesting(.init(
            sessionId: "remote-parent",
            update: .subagentSpawned(.init(subagentSessionId: "plain"))))
        runner.applyIncomingUpdateForTesting(.init(
            sessionId: "remote-parent",
            update: .subagentSpawned(.init(
                subagentSessionId: "cancellable", capabilities: .cancellable))))
        runner.applyIncomingUpdateForTesting(.init(
            sessionId: "remote-parent",
            update: .subagentStateUpdate(.init(
                subagentSessionId: "cancellable", state: .completed))))

        // Neither is eligible: one never advertised cancel, the other has
        // already finished. Both must leave the agent alone.
        await runner.cancelSubagent(subagentSessionId: "plain")
        await runner.cancelSubagent(subagentSessionId: "cancellable")
        await runner.cancelSubagent(subagentSessionId: "ghost")

        #expect(runner.session.subagentRun("cancellable")?.state == .completed)
    }

    @Test("a live cancellable child sends session/cancel addressed to the child")
    func cancelAddressesTheChildSession() async throws {
        let (runner, _, _) = try makeRunner()
        let mock = try #require(runner.connection.client as? ACPMockClient)
        runner.applyIncomingUpdateForTesting(.init(
            sessionId: "remote-parent",
            update: .subagentSpawned(.init(
                subagentSessionId: "child-1", capabilities: .cancellable))))

        await runner.cancelSubagent(subagentSessionId: "child-1")

        let cancels = mock.sent.filter { $0.method == "session/cancel" }
        #expect(cancels.count == 1)
        let params = try #require(cancels.first?.params as? ACPSessionCancelParams)
        #expect(params.sessionId == "child-1")
    }

    private struct StoredText: Decodable {
        let text: String
    }

    private func makeRunner() throws -> (ACPSessionRunner, ACPSessionStore, String) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("subagent-\(UUID().uuidString).sqlite")
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(
            id: "s", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "wt", title: "t")
        session.remoteSessionId = "remote-parent"
        session.agentState = .ready
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: ACPMockClient()),
            store: store,
            sessionId: "s",
            worktreePath: FileManager.default.temporaryDirectory.path)
        return (runner, store, url.path)
    }
}
