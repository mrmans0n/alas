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
        var restored: [String: [(message: ACPMessage, createdAt: Date)]] = [:]
        for message in hydrated.subagentMessages {
            restored[message.subagentSessionId, default: []]
                .append((message.wire.toMessage(), message.createdAt))
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
