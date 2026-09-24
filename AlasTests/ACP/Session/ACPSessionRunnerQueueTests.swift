import Foundation
import Testing
@testable import Alas

private final class DispatchRegistrationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isRegistered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func markRegistered() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

private final class ConnectionCurrentFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool

    init(_ value: Bool) {
        self.value = value
    }

    var isCurrent: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ value: Bool) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
}

@MainActor
@Suite("ACPSessionRunner queue routing")
struct ACPSessionRunnerQueueTests {
    private func mkRunner(
        validateLease: (() async -> Bool)? = nil,
        onPromptWorkChanged: (() -> Void)? = nil,
        isConnectionCurrent: (() -> Bool)? = nil
    ) throws -> (ACPSessionRunner, ACPMockClient, ACPSession, ACPSessionStore) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rn-q-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(
            id: "s", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        let mock = ACPMockClient()
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "wt", title: "t")
        session.agentState = .ready
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: mock),
            store: store,
            sessionId: "s",
            worktreePath: FileManager.default.temporaryDirectory.path,
            onPromptWorkChanged: onPromptWorkChanged,
            isConnectionCurrent: isConnectionCurrent ?? { true },
            validateLease: validateLease)
        return (runner, mock, session, store)
    }

    @Test(".auto while .streaming with empty queue → enqueues; persists; no prompt RPC")
    func enqueuesWhileStreaming() async throws {
        let (runner, mock, session, store) = try mkRunner()
        session.transcript.streamingState = .streaming
        runner.send(blocks: [.text("queued")], intent: .auto)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(session.queue.count == 1)
        #expect(session.queue[0].blocks == [.text("queued")])
        #expect(mock.sent.contains { $0.method == "session/prompt" } == false)
        let persisted = try store.loadQueue(sessionId: "s")
        #expect(persisted == session.queue)
    }

    @Test(".auto while .idle with empty queue → calls session/prompt; queue stays empty")
    func sendsImmediatelyWhenIdle() async throws {
        let (runner, mock, session, _) = try mkRunner()
        mock.script(method: "session/prompt") { _ in Data("null".utf8) }
        runner.send(blocks: [.text("hi")], intent: .auto)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(mock.sent.contains { $0.method == "session/prompt" })
        #expect(session.queue.isEmpty)
    }

    @Test("a prompt awaiting lease validation queues the next prompt")
    func promptAwaitingLeaseValidationQueuesNextPrompt() async throws {
        let leaseGate = LeaseValidationGate()
        let (runner, mock, session, store) = try mkRunner(
            validateLease: { await leaseGate.validate() }
        )
        let probe = StrictSingleFlightPromptProbe()
        mock.scriptAsync(method: "session/prompt") { _ in try await probe.send() }

        let dispatchFlag = DispatchRegistrationFlag()
        runner.sendRegistered(
            text: "first",
            attachments: [],
            intent: .auto,
            onDispatchRegistered: { dispatchFlag.markRegistered() }
        )
        await leaseGate.waitUntilEntered()
        #expect(session.transcript.streamingState == .idle)
        #expect(!dispatchFlag.isRegistered)

        runner.send(blocks: [.text("second")], intent: .auto)
        #expect(session.queue.map(\.blocks) == [[.text("second")]])
        #expect(!mock.sent.contains { $0.method == "session/prompt" })

        await leaseGate.release()
        await probe.waitUntilFirstStarted()
        #expect(dispatchFlag.isRegistered)
        #expect(session.transcript.streamingState == .sending)
        #expect(await probe.callCount == 1)
        await probe.releaseFirst()
        for _ in 0 ..< 100 {
            if await probe.callCount == 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(await probe.callCount == 2)
        #expect(session.queue.isEmpty)
        await runner.flushPersistence()
        #expect(try store.loadQueue(sessionId: "s").isEmpty)
    }

    @Test("scheduled intent persists without sending before its deadline")
    func scheduledIntentWaits() async throws {
        let (runner, mock, session, store) = try mkRunner()
        runner.send(
            blocks: [.text("later")],
            intent: .schedule(Date().addingTimeInterval(60))
        )
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(session.queue.count == 1)
        #expect(session.queue[0].scheduledAt != nil)
        #expect(!mock.sent.contains { $0.method == "session/prompt" })
        #expect(try store.loadQueue(sessionId: "s") == session.queue)
    }

    @Test("moving an uncertain prompt to the front preserves its retry state")
    func promotingUncertainQueueItemPreservesRetryState() async throws {
        let (runner, mock, session, _) = try mkRunner()
        let ordinary = QueuedPrompt(blocks: [.text("ordinary")])
        let uncertain = QueuedPrompt(
            blocks: [.text("possibly already delivered")],
            lastError: QueuedPrompt.deliveryUncertaintyMessage,
            deliveryUncertain: true
        )
        session.restoreQueue([ordinary, uncertain])

        #expect(session.forceQueueItem(id: uncertain.id))
        #expect(session.queue.first?.id == uncertain.id)
        #expect(session.queue.first?.lastError == QueuedPrompt.deliveryUncertaintyMessage)
        #expect(session.queue.first?.deliveryUncertain == true)

        runner.flushQueueIfIdle()
        try await Task.sleep(for: .milliseconds(50))
        #expect(!mock.sent.contains { $0.method == "session/prompt" })

        #expect(session.retryQueueItem(id: uncertain.id))
        #expect(session.queue.first?.lastError == nil)
        #expect(session.queue.first?.deliveryUncertain == false)
        #expect(session.queue.first?.brokerOperationAttempt == 1)
    }

    @Test("force send waits for initial scheduled persistence")
    func forceSendWaitsForInitialScheduledPersistence() async throws {
        let (runner, mock, session, _) = try mkRunner()
        mock.script(method: "session/prompt") { _ in Data("null".utf8) }
        runner.send(blocks: [.text("later")], intent: .schedule(Date().addingTimeInterval(60)))
        let itemId = try #require(session.queue.first?.id)

        runner.forceSendQueuedItem(id: itemId)
        try await Task.sleep(nanoseconds: 150_000_000)

        #expect(session.queue.isEmpty)
        #expect(mock.sent.contains { $0.method == "session/prompt" })
    }

    @Test("failed scheduled persist rollback wins over later snapshots")
    func failedScheduledPersistRollbackWinsOverLaterSnapshots() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rn-scheduled-rollback-\(UUID().uuidString).sqlite")
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(
            id: "s", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        let mock = ACPMockClient()
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "wt", title: "t")
        session.agentState = .ready
        var fenceCalls = 0
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: mock),
            store: store,
            sessionId: "s",
            worktreePath: FileManager.default.temporaryDirectory.path,
            ownerInstanceId: "ME",
            canWrite: { true },
            leaseFenceProvider: {
                fenceCalls += 1
                return fenceCalls == 1
                    ? ACPSessionLeaseFence(sessionId: "s", ownerInstance: "ME", token: "stale")
                    : nil
            })

        runner.send(blocks: [.text("failed")], intent: .schedule(Date().addingTimeInterval(60)))
        runner.send(blocks: [.text("kept")], intent: .schedule(Date().addingTimeInterval(120)))
        await runner.flushPersistence()

        #expect(session.queue.map(\.blocks) == [[.text("kept")]])
        #expect(try store.loadQueue(sessionId: "s").map(\.blocks) == [[.text("kept")]])
    }

    @Test("force send preserves schedules while disconnected")
    func forceSendPreservesScheduleWhileDisconnected() async throws {
        let (runner, mock, session, _) = try mkRunner()
        session.enqueueScheduled(blocks: [.text("later")], scheduledAt: Date().addingTimeInterval(60))
        let itemId = try #require(session.queue.first?.id)
        session.agentState = .disconnected

        runner.forceSendQueuedItem(id: itemId)

        #expect(session.queue.first?.scheduledAt != nil)
        #expect(!mock.sent.contains { $0.method == "session/prompt" })
    }

    @Test("scheduled prompt flushes once its deadline arrives")
    func scheduledPromptFlushesAtDeadline() async throws {
        let (runner, mock, session, _) = try mkRunner()
        mock.script(method: "session/prompt") { _ in Data("null".utf8) }
        runner.send(
            blocks: [.text("soon")],
            intent: .schedule(Date().addingTimeInterval(0.1))
        )

        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(!mock.sent.contains { $0.method == "session/prompt" })

        try await Task.sleep(nanoseconds: 250_000_000)
        #expect(session.queue.isEmpty)
        #expect(mock.sent.contains { $0.method == "session/prompt" })
    }

    @Test("stop cancels a scheduled queue wake")
    func stopCancelsScheduledQueueWake() async throws {
        let (runner, mock, session, _) = try mkRunner()
        mock.script(method: "session/prompt") { _ in Data("null".utf8) }
        runner.send(
            blocks: [.text("soon")],
            intent: .schedule(Date().addingTimeInterval(0.05))
        )

        runner.stop()
        try await Task.sleep(nanoseconds: 150_000_000)

        #expect(session.queue.first?.status == .pending)
        #expect(!mock.sent.contains { $0.method == "session/prompt" })
    }

    @Test("an immediate prompt does not wait behind a scheduled prompt")
    func immediatePromptBypassesScheduledPrompt() async throws {
        let (runner, mock, session, _) = try mkRunner()
        mock.script(method: "session/prompt") { _ in Data("null".utf8) }
        runner.send(
            blocks: [.text("later")],
            intent: .schedule(Date().addingTimeInterval(60))
        )
        runner.send(blocks: [.text("now")], intent: .auto)

        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(mock.sent.contains { $0.method == "session/prompt" })
        #expect(session.queue.count == 1)
        #expect(session.queue[0].blocks == [.text("later")])
    }

    @Test(".auto while .idle with non-empty queue → enqueues (queue is authoritative)")
    func enqueuesWhenIdleAndQueueNonEmpty() async throws {
        let (runner, mock, session, _) = try mkRunner()
        // Pre-seed queue with an item to make queueEmpty == false.
        session.enqueue(blocks: [.text("first")])
        runner.send(blocks: [.text("second")], intent: .auto)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(session.queue.count == 2)
        #expect(session.queue.map { $0.blocks } == [[.text("first")], [.text("second")]])
        #expect(mock.sent.contains { $0.method == "session/prompt" } == false)
    }

    @Test("pending user input queues new prompts until the input resolves")
    func pendingInputBlocksAndThenDrains() async throws {
        let (runner, mock, session, _) = try mkRunner()
        mock.script(method: "session/prompt") { _ in Data("null".utf8) }
        let params = ACPQuestionRequestParams.stub()
        session.transcript.pendingUserInputs = [
            ACPUserInputRequest.cursor(.init(id: .number(1), params: params))
        ]

        runner.send(blocks: [.text("after input")], intent: .auto)
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(session.queue.count == 1)
        #expect(!mock.sent.contains { $0.method == "session/prompt" })

        session.transcript.pendingUserInputs.removeAll()
        runner.flushQueueIfIdle()
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(session.queue.isEmpty)
        #expect(mock.sent.contains { $0.method == "session/prompt" })
    }

    @Test("flushQueueIfIdle annotates a queued image attachment's textOffset from its captured draft")
    func flushQueueAnnotatesImageOffsetFromDraft() async throws {
        let (runner, mock, session, _) = try mkRunner()
        mock.script(method: "session/prompt") { _ in Data("null".utf8) }
        session.transcript.streamingState = .streaming
        let draft = ACPComposerDraft(segments: [
            .text("look at "),
            .image(uri: "file:///tmp/shot.png", mimeType: "image/png"),
            .text(" please")
        ])
        runner.send(
            blocks: [
                .text("look at  please"),
                .image(data: nil, uri: "file:///tmp/shot.png", mimeType: "image/png")
            ],
            intent: .auto,
            draft: draft
        )
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(session.queue.count == 1)

        session.transcript.streamingState = .idle
        runner.flushQueueIfIdle()
        try await Task.sleep(nanoseconds: 100_000_000)

        guard case .user(_, _, _, let attachments, _) = session.transcript.messages.last else {
            Issue.record("expected a recorded user message")
            return
        }
        #expect(attachments.first?.textOffset == 8)
    }

    @Test("flushQueueIfIdle leaves textOffset nil for a queue item with no captured draft")
    func flushQueueLeavesOffsetNilWithoutCapturedDraft() async throws {
        let (runner, mock, session, _) = try mkRunner()
        mock.script(method: "session/prompt") { _ in Data("null".utf8) }
        // No draft captured — mirrors a recovery-path enqueue or a queue
        // item persisted before the draft field existed. `blocks` alone has
        // already flattened the image to the end of the text, so annotating
        // from a heuristic reconstruction of it would invent a wrong offset.
        session.enqueue(blocks: [
            .text("look at  please"),
            .image(data: nil, uri: "file:///tmp/shot.png", mimeType: "image/png")
        ])

        runner.flushQueueIfIdle()
        try await Task.sleep(nanoseconds: 100_000_000)

        guard case .user(_, _, _, let attachments, _) = session.transcript.messages.last else {
            Issue.record("expected a recorded user message")
            return
        }
        #expect(attachments.first?.textOffset == nil)
    }

    @Test("empty blocks → noOp; nothing queued, no RPC, no state change")
    func emptyNoOp() async throws {
        let (runner, mock, session, _) = try mkRunner()
        session.transcript.streamingState = .streaming
        runner.send(blocks: [], intent: .steer)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(session.queue.isEmpty)
        #expect(mock.sent.isEmpty)
        #expect(session.transcript.streamingState == .streaming)
    }

    @Test("flushQueueIfIdle drains head when state is .idle")
    func drainsHeadWhenIdle() async throws {
        let (runner, mock, session, store) = try mkRunner()
        mock.script(method: "session/prompt") { _ in Data("null".utf8) }
        session.enqueue(blocks: [.text("first")])
        session.enqueue(blocks: [.text("second")])
        runner.persistQueue()
        runner.flushQueueIfIdle()
        try await Task.sleep(nanoseconds: 250_000_000)
        // Both items should drain in order; queue ends empty.
        #expect(session.queue.isEmpty)
        let prompts = mock.sent.filter { $0.method == "session/prompt" }
        #expect(prompts.count == 2)
        // Persisted queue is empty after drain.
        #expect(try store.loadQueue(sessionId: "s").isEmpty)
    }

    @Test("flushQueueIfIdle waits for pending queue persistence")
    func waitsForPendingQueuePersistence() async throws {
        let (runner, mock, session, _) = try mkRunner()
        mock.script(method: "session/prompt") { _ in Data("null".utf8) }
        session.enqueue(blocks: [.text("pending durable enqueue")])
        session.pendingQueuePersistenceCount = 1

        runner.flushQueueIfIdle()
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(session.queue.first?.status == .pending)
        #expect(!mock.sent.contains { $0.method == "session/prompt" })

        session.pendingQueuePersistenceCount = 0
        runner.flushQueueIfIdle()
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(session.queue.isEmpty)
        #expect(mock.sent.contains { $0.method == "session/prompt" })
    }

    @Test("queue head is not sent when dispatch provenance cannot be persisted")
    func queueHeadIsNotSentWhenProvenancePersistenceFails() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rn-q-provenance-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(
            id: "s", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        let mock = ACPMockClient()
        mock.script(method: "session/prompt") { _ in Data("null".utf8) }
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "wt", title: "t")
        session.agentState = .ready
        session.enqueue(blocks: [.text("must stay unsent")])
        let originalQueue = session.queue
        try store.upsertQueue(sessionId: "s", items: originalQueue)
        let missingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rn-q-missing-\(UUID())", isDirectory: true)
        let failingPersistence = ACPSessionPersistence(
            path: missingDirectory.appendingPathComponent("queue.sqlite").path
        )
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: mock),
            store: store,
            sessionId: "s",
            worktreePath: FileManager.default.temporaryDirectory.path,
            persistence: failingPersistence
        )

        runner.flushQueueIfIdle()
        await runner.flushPersistence()

        #expect(!mock.sent.contains { $0.method == "session/prompt" })
        #expect(session.queue.first?.status == .pending)
        #expect(session.queue.first?.lastError?.localizedCaseInsensitiveContains("not sent") == true)
        #expect(try store.loadQueue(sessionId: "s") == originalQueue)
    }

    @Test("a superseded queue persistence write does not claim broker dispatch")
    func supersededQueuePersistenceDoesNotClaimBrokerDispatch() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rn-q-superseded-dispatch-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(
            id: "s", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        let mock = ACPMockClient()
        mock.brokerGenerationForTesting = ACPBrokerGeneration(rawValue: 7)
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "wt", title: "t")
        session.agentState = .ready
        session.enqueue(blocks: [.text("not sent")])
        try store.upsertQueue(sessionId: "s", items: session.queue)
        let current = ConnectionCurrentFlag(true)
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: mock),
            store: store,
            sessionId: "s",
            worktreePath: FileManager.default.temporaryDirectory.path,
            isConnectionCurrent: { current.isCurrent }
        )

        try store.db.exec("BEGIN IMMEDIATE")
        runner.flushQueueIfIdle()
        #expect(session.queue.first?.status == .sending)
        #expect(session.queue.first?.dispatchedBrokerGeneration == nil)

        current.set(false)
        runner.stop()
        try store.db.exec("ROLLBACK")
        await runner.flushPersistence()

        let persisted = try store.loadQueue(sessionId: "s")
        #expect(!mock.sent.contains { $0.method == "session/prompt" })
        #expect(persisted.first?.dispatchedBrokerGeneration == nil)
        session.restoreQueue(persisted)
        #expect(!session.markQueuedPromptsUncertain(afterBrokerGeneration: ACPBrokerGeneration(rawValue: 8)))
        #expect(session.queue.first?.deliveryUncertain == false)
    }

    @Test("queue dispatch provenance is durable before broker handoff")
    func queueDispatchProvenanceIsPersistedBeforeHandoff() async throws {
        let (runner, mock, session, store) = try mkRunner()
        let generation = ACPBrokerGeneration(rawValue: 7)
        mock.brokerGenerationForTesting = generation
        let requestStarted = QueueTestGate()
        let responseRelease = QueueTestGate()
        mock.scriptAsync(method: "session/prompt") { _ in
            await requestStarted.open()
            await responseRelease.wait()
            return Data("null".utf8)
        }
        session.enqueue(blocks: [.text("queued")])

        runner.flushQueueIfIdle()
        await requestStarted.wait()

        #expect(session.queue.first?.dispatchedBrokerGeneration == generation)
        #expect(try store.loadQueue(sessionId: "s").first?.dispatchedBrokerGeneration == generation)

        await responseRelease.open()
        for _ in 0 ..< 100 where !session.queue.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        await runner.flushPersistence()
        #expect(session.queue.isEmpty)
    }

    @Test("stale queue persistence failure does not mutate a replacement queue head")
    func staleQueuePersistenceFailureDoesNotMutateReplacementHead() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rn-q-stale-failure-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(
            id: "s", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "wt", title: "t")
        session.agentState = .ready
        session.enqueue(blocks: [.text("old queue head")])
        let current = ConnectionCurrentFlag(true)
        let missingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rn-q-stale-missing-\(UUID())", isDirectory: true)
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: ACPMockClient()),
            store: store,
            sessionId: "s",
            worktreePath: FileManager.default.temporaryDirectory.path,
            isConnectionCurrent: { current.isCurrent },
            persistence: ACPSessionPersistence(path: missingDirectory.appendingPathComponent("queue.sqlite").path)
        )

        runner.flushQueueIfIdle()
        current.set(false)
        runner.stop()
        session.queue.removeAll()
        let replacementId = UUID()
        session.enqueue(id: replacementId, blocks: [.text("replacement queue head")])
        await runner.flushPersistence()

        #expect(session.queue.first?.id == replacementId)
        #expect(session.queue.first?.status == .pending)
        #expect(session.queue.first?.lastError == nil)
    }

    @Test("force send parked by queue persistence is retained")
    func forceSendBlockedByQueuePersistenceIsRetained() async throws {
        let (runner, mock, session, _) = try mkRunner()
        mock.script(method: "session/prompt") { _ in Data("null".utf8) }
        session.enqueueScheduled(blocks: [.text("later")], scheduledAt: Date().addingTimeInterval(60))
        let itemId = try #require(session.queue.first?.id)
        session.pendingQueuePersistenceCount = 1

        runner.forceSendQueuedItem(id: itemId)
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(session.queue.first?.scheduledAt != nil)
        #expect(session.queue.first?.status == .pending)
        #expect(!mock.sent.contains { $0.method == "session/prompt" })
        #expect(runner.hasRetainedCleanupPromptWork)
    }

    @Test("queued prompt completion notifies prompt work changed")
    func queuedPromptCompletionNotifiesPromptWorkChanged() async throws {
        var changeCount = 0
        let (runner, mock, session, _) = try mkRunner(onPromptWorkChanged: {
            changeCount += 1
        })
        mock.script(method: "session/prompt") { _ in Data("null".utf8) }
        session.enqueue(blocks: [.text("queued")])

        runner.flushQueueIfIdle()
        for _ in 0 ..< 20 where changeCount == 0 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        #expect(changeCount > 0)
        #expect(session.queue.isEmpty)
    }

    @Test("flushQueueIfIdle is a no-op while state is .streaming")
    func noopWhileStreaming() async throws {
        let (runner, mock, session, _) = try mkRunner()
        session.transcript.streamingState = .streaming
        session.enqueue(blocks: [.text("nope")])
        runner.flushQueueIfIdle()
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(session.queue.count == 1)
        #expect(mock.sent.contains { $0.method == "session/prompt" } == false)
    }

    @Test("flushQueueIfIdle is a no-op while state is .awaitingPermission")
    func noopAwaitingPermission() async throws {
        let (runner, mock, session, _) = try mkRunner()
        session.transcript.streamingState = .awaitingPermission
        session.enqueue(blocks: [.text("nope")])
        runner.flushQueueIfIdle()
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(session.queue.count == 1)
        #expect(mock.sent.contains { $0.method == "session/prompt" } == false)
    }

    @Test("flushQueueIfIdle is a no-op while state is .awaitingInput")
    func noopAwaitingInput() async throws {
        let (runner, mock, session, _) = try mkRunner()
        session.transcript.streamingState = .awaitingInput
        session.enqueue(blocks: [.text("nope")])
        runner.flushQueueIfIdle()
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(session.queue.count == 1)
        #expect(mock.sent.contains { $0.method == "session/prompt" } == false)
    }

    @Test("flushQueueIfIdle skips a head with lastError; doesn't auto-retry")
    func skipsErroredHead() async throws {
        let (runner, mock, session, _) = try mkRunner()
        session.enqueue(blocks: [.text("broken")])
        session.setQueueHeadError("network")
        runner.persistQueue()
        runner.flushQueueIfIdle()
        try await Task.sleep(nanoseconds: 100_000_000)
        // Head untouched; no RPC made.
        #expect(session.queue.count == 1)
        #expect(session.queue[0].lastError == "network")
        #expect(mock.sent.contains { $0.method == "session/prompt" } == false)
    }

    @Test("flush failure flips head back to .pending with lastError; queue not popped")
    func flushFailureKeepsItem() async throws {
        let (runner, mock, session, store) = try mkRunner()
        mock.script(method: "session/prompt") { _ in
            throw ACPClientError.noScript(method: "session/prompt")  // any throw
        }
        session.enqueue(blocks: [.text("will-fail")])
        let operationKey = session.queue[0].brokerOperationKey
        runner.persistQueue()
        runner.flushQueueIfIdle()
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(session.queue.count == 1)
        #expect(session.queue[0].status == .pending)
        #expect(session.queue[0].lastError != nil)
        #expect(session.queue[0].brokerOperationKey == operationKey)
        let persisted = try store.loadQueue(sessionId: "s")
        #expect(persisted == session.queue)
    }

    @Test("terminal queued failure advances broker operation key before retry")
    func terminalQueuedFailureAdvancesBrokerOperationKey() async throws {
        let (runner, mock, session, _) = try mkRunner()
        mock.script(method: "session/prompt") { _ in
            throw ACPClientError.jsonrpc(.init(code: -32042, message: "terminal", data: nil))
        }
        session.enqueue(blocks: [.text("will-fail-terminally")])
        let operationKey = session.queue[0].brokerOperationKey

        runner.persistQueue()
        runner.flushQueueIfIdle()
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(session.queue.count == 1)
        #expect(session.queue[0].status == .pending)
        #expect(session.queue[0].lastError != nil)
        #expect(session.queue[0].brokerOperationKey != operationKey)
    }

    @Test("superseded prompt success does not consume shared state or finish its callback")
    func supersededPromptSuccessDoesNotFinish() async throws {
        let currentConnection = ConnectionCurrentFlag(true)
        let (runner, mock, session, _) = try mkRunner(
            isConnectionCurrent: { currentConnection.isCurrent }
        )
        let requestStarted = QueueTestGate()
        let responseRelease = QueueTestGate()
        mock.scriptAsync(method: "session/prompt") { _ in
            await requestStarted.open()
            await responseRelease.wait()
            return Data("null".utf8)
        }

        session.pendingMCPPreamble = "keep for the replacement runner"
        var finished: Bool?
        runner.sendNow(
            blocks: [.text("pending")],
            queuedItemId: nil,
            onPromptFinished: { finished = $0 }
        )
        await requestStarted.wait()

        runner.invalidateActivePrompt()
        runner.stop()
        currentConnection.set(false)
        await responseRelease.open()
        try await Task.sleep(for: .milliseconds(100))

        #expect(session.pendingMCPPreamble == "keep for the replacement runner")
        #expect(finished == nil)
    }

    @Test("superseded prompt failure does not finish its callback")
    func supersededPromptFailureDoesNotFinish() async throws {
        let currentConnection = ConnectionCurrentFlag(true)
        let (runner, mock, _, _) = try mkRunner(
            isConnectionCurrent: { currentConnection.isCurrent }
        )
        let requestStarted = QueueTestGate()
        let responseRelease = QueueTestGate()
        mock.scriptAsync(method: "session/prompt") { _ in
            await requestStarted.open()
            await responseRelease.wait()
            throw ACPClientError.jsonrpc(.init(code: -32042, message: "stale failure", data: nil))
        }

        var finished: Bool?
        runner.sendNow(
            blocks: [.text("pending")],
            queuedItemId: nil,
            onPromptFinished: { finished = $0 }
        )
        await requestStarted.wait()

        runner.invalidateActivePrompt()
        runner.stop()
        currentConnection.set(false)
        await responseRelease.open()
        try await Task.sleep(for: .milliseconds(100))

        #expect(finished == nil)
    }

    @Test("superseded prompt lease failure does not finish its callback")
    func supersededPromptLeaseFailureDoesNotFinish() async throws {
        let currentConnection = ConnectionCurrentFlag(true)
        let leaseGate = LeaseValidationGate(result: false)
        let (runner, _, _, _) = try mkRunner(
            validateLease: { await leaseGate.validate() },
            isConnectionCurrent: { currentConnection.isCurrent }
        )

        var finished: Bool?
        runner.sendNow(
            blocks: [.text("pending")],
            queuedItemId: nil,
            onPromptFinished: { finished = $0 }
        )
        await leaseGate.waitUntilEntered()

        runner.invalidateActivePrompt()
        currentConnection.set(false)
        await leaseGate.release()
        try await Task.sleep(for: .milliseconds(100))

        #expect(finished == nil)
    }

    @Test("superseded prompt does not finish after its lease check")
    func supersededPromptDoesNotFinishAfterLeaseCheck() async throws {
        let currentConnection = ConnectionCurrentFlag(true)
        let leaseGate = LeaseValidationGate()
        let (runner, _, _, _) = try mkRunner(
            validateLease: { await leaseGate.validate() },
            isConnectionCurrent: { currentConnection.isCurrent }
        )

        var finished: Bool?
        runner.sendNow(
            blocks: [.text("pending")],
            queuedItemId: nil,
            onPromptFinished: { finished = $0 }
        )
        await leaseGate.waitUntilEntered()

        runner.invalidateActivePrompt()
        currentConnection.set(false)
        await leaseGate.release()
        try await Task.sleep(for: .milliseconds(100))

        #expect(finished == nil)
    }

    @Test("queued prompt response ack waits for durable queue pop and resumes draining")
    func queuedPromptResponseAckWaitsForDurableQueuePopAndResumesDraining() async throws {
        let (runner, mock, session, store) = try mkRunner()
        let acknowledgement = DurableAcknowledgementRecorder()
        mock.scriptResponse(method: "session/prompt") { _ in
            ACPResponse(
                body: Data("null".utf8),
                durableConsumptionAcknowledgement: { acknowledgement.record() }
            )
        }
        session.enqueue(blocks: [.text("ack-after-pop")])
        session.enqueue(blocks: [.text("next")])
        runner.persistQueue()
        await runner.flushPersistence()

        runner.flushQueueIfIdle()
        try await Task.sleep(nanoseconds: 300_000_000)
        await runner.flushPersistence()

        let prompts = mock.sent.filter { $0.method == "session/prompt" }
        #expect(prompts.count == 2)
        #expect(session.queue.isEmpty)
        #expect(try store.loadQueue(sessionId: "s").isEmpty)
        #expect(acknowledgement.recordedCount == 2)
    }

    @Test(".steer while streaming preserves the pending queue")
    func steerPreservesPendingQueue() async throws {
        let (runner, mock, session, store) = try mkRunner()
        mock.script(method: "session/prompt") { _ in Data("null".utf8) }
        session.agentState = .ready
        session.transcript.streamingState = .streaming
        session.enqueue(blocks: [.text("queued-a")])
        session.enqueue(blocks: [.text("queued-b")])
        runner.persistQueue()
        let queued = session.queue

        runner.send(blocks: [.text("redirect")], intent: .steer)

        #expect(session.queue == queued)

        try await Task.sleep(nanoseconds: 250_000_000)

        #expect(mock.sent.contains { $0.method == "session/cancel" })
        #expect(session.queue.isEmpty)
        let prompts = mock.sent.filter { $0.method == "session/prompt" }
        #expect(prompts.count == 3)
        #expect(try store.loadQueue(sessionId: "s").isEmpty)
    }

    @Test("steer waits for the cancelled prompt RPC before sending its replacement")
    func steerWaitsForCancelledPromptToSettle() async throws {
        let (runner, mock, session, _) = try mkRunner()
        let probe = StrictSingleFlightPromptProbe()
        let cancelSent = QueueTestGate()
        mock.scriptNotifyAsync(method: "session/cancel") { _ in
            await cancelSent.open()
        }
        mock.scriptAsync(method: "session/prompt") { _ in
            try await probe.send()
        }

        runner.send(blocks: [.text("running")], intent: .auto)
        await probe.waitUntilFirstStarted()

        runner.send(blocks: [.text("redirect")], intent: .steer)
        await cancelSent.wait()
        for _ in 0 ..< 20 {
            await Task.yield()
        }

        let callsBeforeFirstSettles = await probe.callCount
        #expect(callsBeforeFirstSettles == 1)

        await probe.releaseFirst()
        for _ in 0 ..< 20 {
            if await probe.callCount >= 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let totalCalls = await probe.callCount
        #expect(totalCalls == 2)
        #expect(session.lastError == nil)
    }

    @Test("steer waits for a cancelled recovery prompt before sending its replacement")
    func steerWaitsForCancelledRecoveryPromptToSettle() async throws {
        let (runner, mock, session, _) = try mkRunner()
        let probe = StrictSingleFlightPromptProbe()
        let cancelSent = QueueTestGate()
        mock.scriptNotifyAsync(method: "session/cancel") { _ in
            await cancelSent.open()
        }
        mock.scriptAsync(method: "session/prompt") { _ in
            try await probe.send()
        }

        #expect(runner.sendRecoveryContext("restore"))
        await probe.waitUntilFirstStarted()

        runner.send(blocks: [.text("redirect")], intent: .steer)
        await cancelSent.wait()
        for _ in 0 ..< 20 {
            await Task.yield()
        }

        let callsBeforeRecoverySettles = await probe.callCount
        #expect(callsBeforeRecoverySettles == 1)

        await probe.releaseFirst()
        for _ in 0 ..< 20 {
            if await probe.callCount >= 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let totalCalls = await probe.callCount
        #expect(totalCalls == 2)
        #expect(session.lastError == nil)
    }

    @Test("steer that races a detach skips the redirect on a torn-down session")
    func steerSkipsRedirectAfterDetach() async throws {
        // Regression: the unstructured steer Task survives the runner +
        // connection it was spawned in. If the user closes the tab while
        // we're awaiting `userCancel`, `ACPSessionManager.detach` flips
        // `session.agentState` away from `.ready` and shuts down the
        // connection but doesn't cancel this task. Without a liveness
        // check, the trailing `sendNow` would append the redirect prompt
        // and persist a `lastError` on the detached session.
        let (runner, mock, session, _) = try mkRunner()
        mock.script(method: "session/prompt") { _ in Data("null".utf8) }
        session.agentState = .ready
        session.transcript.streamingState = .streaming

        runner.send(blocks: [.text("redirect")], intent: .steer)
        // Simulate the detach landing while userCancel is still in flight.
        session.agentState = .idle

        try await Task.sleep(nanoseconds: 250_000_000)

        // session/cancel still went out (we started userCancel before the
        // detach was observable), but the redirect prompt was suppressed.
        #expect(mock.sent.contains { $0.method == "session/cancel" })
        let prompts = mock.sent.filter { $0.method == "session/prompt" }
        #expect(prompts.isEmpty)
    }

    @Test("steer skips its redirect when the runner is replaced during cancellation")
    func steerSkipsRedirectAfterRunnerReplacementDuringCancel() async throws {
        let currentConnection = ConnectionCurrentFlag(true)
        let (runner, mock, session, _) = try mkRunner(
            isConnectionCurrent: { currentConnection.isCurrent }
        )
        let promptStarted = QueueTestGate()
        let releasePrompt = QueueTestGate()
        let cancelStarted = QueueTestGate()
        let releaseCancel = QueueTestGate()
        mock.scriptAsync(method: "session/prompt") { _ in
            await promptStarted.open()
            await releasePrompt.wait()
            return Data("null".utf8)
        }
        mock.scriptNotifyAsync(method: "session/cancel") { _ in
            await cancelStarted.open()
            await releaseCancel.wait()
        }
        session.agentState = .ready
        runner.send(blocks: [.text("running")], intent: .auto)
        await promptStarted.wait()

        var promptFinished: Bool?
        runner.send(blocks: [.text("redirect")], intent: .steer) { succeeded in
            promptFinished = succeeded
        }
        await cancelStarted.wait()

        currentConnection.set(false)
        runner.stop()
        session.agentState = .ready
        await releaseCancel.open()
        await releasePrompt.open()
        for _ in 0 ..< 100 where promptFinished == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(promptFinished == false)
        #expect(mock.sent.filter { $0.method == "session/prompt" }.count == 1)
        let userMessages = session.transcript.messages.filter {
            if case .user = $0 { return true }
            return false
        }
        #expect(userMessages.count == 1)
    }

    @Test("steer skips its redirect when the runner is replaced while awaiting the prompt")
    func steerSkipsRedirectAfterRunnerReplacementWhilePromptSettles() async throws {
        let currentConnection = ConnectionCurrentFlag(true)
        let steerPromptWaitStarted = DispatchRegistrationFlag()
        let (runner, mock, session, _) = try mkRunner(
            onPromptWorkChanged: { steerPromptWaitStarted.markRegistered() },
            isConnectionCurrent: { currentConnection.isCurrent }
        )
        let promptStarted = QueueTestGate()
        let releasePrompt = QueueTestGate()
        let cancelFinished = QueueTestGate()
        mock.scriptAsync(method: "session/prompt") { _ in
            await promptStarted.open()
            await releasePrompt.wait()
            return Data("null".utf8)
        }
        mock.scriptNotifyAsync(method: "session/cancel") { _ in
            await cancelFinished.open()
        }
        session.agentState = .ready
        runner.send(blocks: [.text("running")], intent: .auto)
        await promptStarted.wait()

        var promptFinished: Bool?
        runner.send(blocks: [.text("redirect")], intent: .steer) { succeeded in
            promptFinished = succeeded
        }
        await cancelFinished.wait()
        for _ in 0 ..< 100 where !session.transcript.messages.contains(where: {
            if case .systemNotice(_, let text) = $0 { return text == "Interrupted by user." }
            return false
        }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(session.transcript.messages.contains {
            if case .systemNotice(_, let text) = $0 { return text == "Interrupted by user." }
            return false
        })
        for _ in 0 ..< 100 where !steerPromptWaitStarted.isRegistered {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(steerPromptWaitStarted.isRegistered)

        currentConnection.set(false)
        runner.stop()
        session.agentState = .ready
        await releasePrompt.open()
        for _ in 0 ..< 100 where promptFinished == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(promptFinished == false)
        #expect(mock.sent.filter { $0.method == "session/prompt" }.count == 1)
        let userMessages = session.transcript.messages.filter {
            if case .user = $0 { return true }
            return false
        }
        #expect(userMessages.count == 1)
    }

    @Test("forceSendQueuedItem while busy preserves and later drains the rest of the queue")
    func forceSendQueuedItemPreservesAndDrainsRest() async throws {
        let (runner, mock, session, store) = try mkRunner()
        mock.script(method: "session/prompt") { _ in Data("null".utf8) }
        session.agentState = .ready
        session.transcript.streamingState = .streaming
        session.enqueue(blocks: [.text("a")])
        session.enqueue(blocks: [.text("selected")])
        runner.forceSendQueuedItem(id: session.queue[1].id)
        // "a" is left exactly where it was — nothing to undo, nothing
        // discarded.
        #expect(session.queue.map(\.blocks) == [[.text("a")]])

        try await Task.sleep(nanoseconds: 250_000_000)
        // The redirect ("selected") ran first, then the flusher drained
        // the preserved tail ("a") once the agent was idle again.
        #expect(session.queue.isEmpty)
        let prompts = mock.sent.filter { $0.method == "session/prompt" }.count
        #expect(prompts == 2)
        let persisted = try store.loadQueue(sessionId: "s")
        #expect(persisted.isEmpty)
    }

    @Test("queued flush records the user prompt at dispatch (before await)")
    func queuedFlushRecordsBeforeAwait() async throws {
        // Regression for "answer before question" ordering. Streamed
        // session/update notifications can arrive while session/prompt is
        // still in flight; the user prompt must be appended to the
        // transcript at dispatch time. Verified via the failure path:
        // with no script, the RPC throws, and yet the user message is in
        // the transcript afterward — proof that recording happened BEFORE
        // the await rather than inside the success handler.
        let (runner, _, session, _) = try mkRunner()
        // No mock.script for session/prompt → mock.send throws noScript.
        session.enqueue(blocks: [.text("queued-q")])
        runner.persistQueue()
        runner.flushQueueIfIdle()
        try await Task.sleep(nanoseconds: 200_000_000)
        // RPC failed; item back at head with lastError; transcriptRecorded
        // flipped, AND the user message is in the transcript.
        #expect(session.queue.count == 1)
        #expect(session.queue[0].lastError != nil)
        #expect(session.queue[0].transcriptRecorded == true)
        var userTexts: [String] = []
        for msg in session.transcript.messages {
            if case .user(_, _, let text, _, _) = msg { userTexts.append(text) }
        }
        #expect(userTexts == ["queued-q"])
    }

    @Test("queued retry doesn't double-record the user prompt")
    func queuedRetryDoesNotDoubleRecord() async throws {
        let (runner, mock, session, _) = try mkRunner()
        // First attempt fails (no script). User clicks Retry. Second
        // attempt succeeds (script wired below). Verify the transcript
        // contains the user prompt exactly once across both attempts.
        session.enqueue(blocks: [.text("retry-me")])
        runner.persistQueue()
        runner.flushQueueIfIdle()
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(session.queue.count == 1)
        #expect(session.queue[0].lastError != nil)
        #expect(session.queue[0].transcriptRecorded == true)
        var users = session.transcript.messages.filter { if case .user = $0 { return true } else { return false } }
        #expect(users.count == 1)

        // Simulate Retry: wire success script + clear lastError + flush.
        mock.script(method: "session/prompt") { _ in Data("null".utf8) }
        session.queue[0].lastError = nil
        runner.flushQueueIfIdle()
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(session.queue.isEmpty)
        users = session.transcript.messages.filter { if case .user = $0 { return true } else { return false } }
        #expect(users.count == 1)
    }

    @Test("steer drops a .sending head and preserves the pending tail")
    func steerDiscardsSendingHeadAndPreservesPendingTail() async throws {
        // Regression for the race where steer happens while the flusher
        // has already marked the head .sending. The .sending item must
        // be evicted while the pending tail stays queued; otherwise the
        // stale in-flight RPC would settle later and mutate session state.
        let (runner, mock, session, store) = try mkRunner()
        mock.script(method: "session/prompt") { _ in Data("null".utf8) }
        session.agentState = .ready
        // Simulate: flusher already promoted the head to .sending; a
        // pending tail is sitting behind it.
        session.enqueue(blocks: [.text("in-flight")])
        session.markQueueHeadSending()
        session.enqueue(blocks: [.text("tail-pending")])
        runner.persistQueue()
        session.transcript.streamingState = .sending
        let tail = session.queue[1]

        runner.send(blocks: [.text("redirect")], intent: .steer)

        #expect(session.queue == [tail])

        try await Task.sleep(nanoseconds: 250_000_000)

        // The interrupted head is not retried. The redirect runs first,
        // followed by the preserved tail.
        #expect(session.queue.isEmpty)
        #expect(mock.sent.contains { $0.method == "session/cancel" })
        let prompts = mock.sent.filter { $0.method == "session/prompt" }
        #expect(prompts.count == 2)
        #expect(try store.loadQueue(sessionId: "s").isEmpty)
    }

    @Test("force send waits for an in-progress steer to install its redirect")
    func forceSendWaitsForSteer() async throws {
        let (runner, mock, session, _) = try mkRunner()
        let cancelStarted = QueueTestGate()
        let releaseCancel = QueueTestGate()
        mock.scriptNotifyAsync(method: "session/cancel") { _ in
            await cancelStarted.open()
            await releaseCancel.wait()
        }
        mock.script(method: "session/prompt") { _ in Data("null".utf8) }
        session.agentState = .ready
        session.transcript.streamingState = .streaming
        session.enqueue(blocks: [.text("send-now")])
        let queuedID = session.queue[0].id

        runner.send(blocks: [.text("redirect")], intent: .steer)
        await cancelStarted.wait()
        runner.forceSendQueuedItem(id: queuedID)
        try await Task.sleep(nanoseconds: 20_000_000)

        #expect(mock.sent.filter { $0.method == "session/cancel" }.count == 1)

        await releaseCancel.open()
    }

    @Test("forceSendQueuedItem while busy steers with the selected item and preserves the rest of the queue")
    func forceSendQueuedItemWhileBusySteersSelectedItem() async throws {
        let (runner, mock, session, store) = try mkRunner()
        mock.script(method: "session/prompt") { _ in Data("null".utf8) }
        session.agentState = .ready
        session.transcript.streamingState = .streaming
        session.enqueue(blocks: [.text("first")])
        let source = ACPDelegatedPromptSource(sessionId: "parent", messageId: "delegated-message")
        session.enqueue(blocks: [.text("selected")], delegatedSource: source)
        session.enqueue(blocks: [.text("third")])
        let selectedId = session.queue[1].id
        runner.persistQueue()

        runner.forceSendQueuedItem(id: selectedId)
        #expect(runner.hasRetainedCleanupSteerWork)
        // "first" and "third" are left in place immediately — unlike the
        // old discard-and-undo behavior, nothing is removed except the
        // selected item itself.
        #expect(session.queue.map(\.blocks) == [[.text("first")], [.text("third")]])

        try await Task.sleep(nanoseconds: 250_000_000)

        #expect(mock.sent.contains { $0.method == "session/cancel" })
        let prompts = mock.sent.filter { $0.method == "session/prompt" }
        #expect(prompts.count == 3)
        var userTexts: [String] = []
        var delegatedSources: [ACPDelegatedPromptSource?] = []
        for msg in session.transcript.messages {
            if case .user(_, _, let text, _, let delegatedSource) = msg {
                userTexts.append(text)
                delegatedSources.append(delegatedSource)
            }
        }
        #expect(userTexts == ["selected", "first", "third"])
        #expect(delegatedSources == [source, nil, nil])
        #expect(session.queue.isEmpty)
        #expect(try store.loadQueue(sessionId: "s").isEmpty)
    }

    @Test("forceSendQueuedItem while busy does not double-record a failed queued retry")
    func forceSendQueuedItemWhileBusyPreservesRecordedRetry() async throws {
        let (runner, mock, session, _) = try mkRunner()
        mock.script(method: "session/prompt") { _ in Data("null".utf8) }
        session.agentState = .ready
        session.transcript.streamingState = .streaming
        session.recordUserPrompt(text: "selected", attachments: [])
        session.enqueue(blocks: [.text("first")])
        session.enqueue(blocks: [.text("selected")])
        session.queue[1].lastError = "network"
        session.queue[1].transcriptRecorded = true
        let selectedId = session.queue[1].id
        runner.persistQueue()

        runner.forceSendQueuedItem(id: selectedId)
        try await Task.sleep(nanoseconds: 250_000_000)

        // "selected" isn't double-recorded, and the preserved "first" is
        // drained right behind it.
        let prompts = mock.sent.filter { $0.method == "session/prompt" }
        #expect(prompts.count == 2)
        var userTexts: [String] = []
        for msg in session.transcript.messages {
            if case .user(_, _, let text, _, _) = msg { userTexts.append(text) }
        }
        #expect(userTexts == ["selected", "first"])
        #expect(session.queue.isEmpty)
    }

    @Test("userCancel() drains queue after canceling the running turn")
    func cancelThenFlushDrainsQueue() async throws {
        let (runner, mock, session, _) = try mkRunner()
        mock.script(method: "session/prompt") { _ in Data("null".utf8) }
        session.transcript.streamingState = .streaming
        session.enqueue(blocks: [.text("queued-after-esc")])
        await runner.userCancel()
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(session.queue.isEmpty)
        #expect(mock.sent.contains { $0.method == "session/cancel" })
        #expect(mock.sent.contains { $0.method == "session/prompt" })
    }

    @Test("a sendNow cancelled before its Task starts is a complete no-op")
    func sendNowCancelledBeforeTaskStartsIsNoOp() async throws {
        // Regression for the TOCTOU race between flushQueueIfIdle
        // dispatching sendNow and detach/userCancel running their
        // invalidateActivePrompt path before the Task body's first
        // MainActor.run reaches the activePromptID assignment. Without
        // the synchronous registration + early-exit guard, the Task
        // would proceed, eventually fail on a dead connection, and
        // persist a `lastError` on the queue head — defeating the
        // detach-clears-cleanly invariant.
        let (runner, mock, session, _) = try mkRunner()
        // Drive sendNow directly. Immediately after dispatch — before
        // its Task body runs its first MainActor hop — invalidate the
        // active prompt. The Task's stillActive guard must fire and
        // the user prompt must NOT appear in the transcript.
        runner.sendNow(blocks: [.text("doomed")], queuedItemId: nil)
        runner.invalidateActivePrompt()
        try await Task.sleep(nanoseconds: 200_000_000)
        let users = session.transcript.messages.filter { if case .user = $0 { return true } else { return false } }
        #expect(users.isEmpty)
        #expect(mock.sent.contains { $0.method == "session/prompt" } == false)
        #expect(session.transcript.streamingState == .idle)
    }

    @Test("userCancel with no .sending queue head leaves queued items alone")
    func userCancelNoSendingHeadPreservesQueue() async throws {
        // Regression: userCancel used to capture activePromptID + queue
        // state AFTER awaiting connection.cancel. If a natural prompt
        // completion during the await flushed a queued item to .sending,
        // the post-await logic would happily insert that queued item's
        // ID into cancelledPromptIDs and pop it — Stop killing a prompt
        // the user only queued. Capturing the intended target BEFORE
        // the await means a .pending queue head at Stop-time stays put.
        let (runner, _, session, store) = try mkRunner()
        // Pre-state: a direct turn is streaming (no .sending head), with
        // a pending tail waiting in the queue.
        session.transcript.streamingState = .streaming
        session.enqueue(blocks: [.text("untouched")])
        runner.persistQueue()
        // Note: no markQueueHeadSending — the head is .pending.

        await runner.userCancel()
        try await Task.sleep(nanoseconds: 100_000_000)

        // Queue remains intact — Stop targeted the running direct turn,
        // not the queued item.
        #expect(session.queue.count == 1)
        #expect(session.queue[0].blocks == [.text("untouched")])
        #expect(session.queue[0].status == .pending)
        let persisted = try store.loadQueue(sessionId: "s")
        #expect(persisted == session.queue)
    }

    @Test("userCancel pops a .sending queue head so it doesn't stay stuck")
    func userCancelPopsSendingHead() async throws {
        // Regression: when Stop/Esc fires while the flusher is mid-RPC on
        // a queued head, the cancelled sendNow's completion can no
        // longer mutate the queue (it's no longer the active prompt),
        // and flushQueueIfIdle requires `.pending`. Without this fix
        // the head would stay stuck `.sending` forever.
        let (runner, _, session, store) = try mkRunner()
        session.enqueue(blocks: [.text("in-flight")])
        session.enqueue(blocks: [.text("queued-tail")])
        session.markQueueHeadSending()
        session.transcript.streamingState = .sending
        runner.persistQueue()

        await runner.userCancel()
        try await Task.sleep(nanoseconds: 100_000_000)

        // Head popped, tail remains as .pending; persisted state matches.
        #expect(session.queue.count == 1)
        #expect(session.queue[0].blocks == [.text("queued-tail")])
        #expect(session.queue[0].status == .pending)
        let persisted = try store.loadQueue(sessionId: "s")
        #expect(persisted == session.queue)
    }

    @Test("flushQueueIfIdle is a no-op when the runner has lost the lease")
    func flushQueueNoopWhenLeaseLost() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rn-flush-lease-lost-\(UUID().uuidString).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let sid = "s"
        try store.upsertSession(.init(
            id: sid, agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))

        // Seize the lease for a DIFFERENT instance — the runner's ownerInstanceId is "ME".
        let now = Int64(Date().timeIntervalSince1970)
        try store.seizeLease(sessionId: sid, instanceId: "OTHER", pid: Int64(getpid()), now: now)

        let mock = ACPMockClient()
        mock.script(method: "session/prompt") { _ in Data("null".utf8) }
        let session = ACPSession(id: sid, agentId: "claude", worktreeId: "wt", title: "t")
        session.agentState = .ready
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: mock),
            store: store,
            sessionId: sid,
            worktreePath: FileManager.default.temporaryDirectory.path,
            ownerInstanceId: "ME"
        )

        // Pre-condition: session is idle with a pending queue item — normally this would flush.
        session.enqueue(blocks: [.text("should-not-dispatch")])
        #expect(session.queue.count == 1)
        #expect(session.queue[0].status == .pending)

        // Flush must be blocked because "ME" does not hold the lease.
        runner.flushQueueIfIdle()
        try await Task.sleep(nanoseconds: 100_000_000)

        // No prompt was dispatched and the queue is unchanged.
        #expect(mock.sent.filter { $0.method == "session/prompt" }.isEmpty,
                "former writer must not dispatch a queued prompt after losing the lease")
        #expect(session.queue.count == 1,
                "queue must remain unchanged when the lease is held by another instance")
        #expect(session.queue[0].status == .pending,
                "queue head must stay .pending (not flipped to .sending) when lease is lost")
    }

    @Test("flushQueueIfIdle is a no-op while .awaitingPermission, then drains after .idle")
    func awaitingPermissionDefersDrain() async throws {
        let (runner, mock, session, _) = try mkRunner()
        mock.script(method: "session/prompt") { _ in Data("null".utf8) }
        session.transcript.streamingState = .awaitingPermission
        session.enqueue(blocks: [.text("waits")])
        runner.flushQueueIfIdle()
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(session.queue.count == 1)     // still queued; no RPC

        // Permission resolved → state returns to idle through the normal
        // turn-end path. Simulate by flipping state directly.
        session.transcript.streamingState = .idle
        runner.flushQueueIfIdle()
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(session.queue.isEmpty)
        #expect(mock.sent.contains { $0.method == "session/prompt" })
    }

    @Test("uncertain queue head survives restart until explicitly retried")
    func persistenceRoundTrip() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rn-rt-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(
            id: "rt", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))

        // First runner: enqueue, mark sending, persist.
        let mock1 = ACPMockClient()
        let session1 = ACPSession(id: "rt", agentId: "claude", worktreeId: "wt", title: "t")
        let runner1 = ACPSessionRunner(
            session: session1, connection: ACPConnection(client: mock1), store: store,
            sessionId: "rt", worktreePath: FileManager.default.temporaryDirectory.path)
        session1.transcript.streamingState = .streaming
        runner1.send(blocks: [.text("alpha")], intent: .auto)
        runner1.send(blocks: [.text("beta")], intent: .auto)
        try await Task.sleep(nanoseconds: 100_000_000)
        // Simulate the "in-flight head when app quit" case by flipping
        // the head to .sending and persisting. On restore its delivery is
        // uncertain, so it must not be silently sent again.
        session1.markQueueHeadSending()
        runner1.persistQueue()
        await runner1.flushPersistence()
        let persisted = try store.loadQueue(sessionId: "rt")
        #expect(persisted.count == 2)
        #expect(persisted[0].status == .sending)

        // Second runner: fresh session, restored queue, then drain.
        let mock2 = ACPMockClient()
        mock2.script(method: "session/prompt") { _ in Data("null".utf8) }
        let mgr = ACPSessionManager(worktreeId: "wt", worktreePath: FileManager.default.temporaryDirectory.path, store: store)
        let session2 = mgr.placeholderSession(id: "rt")!
        await mgr.hydrateIfNeeded(id: "rt")
        session2.agentState = .ready
        #expect(session2.queue.count == 2)
        // .sending was normalized to .pending on restore.
        #expect(session2.queue[0].status == .pending)
        #expect(session2.queue[0].deliveryUncertain)
        let runner2 = ACPSessionRunner(
            session: session2, connection: ACPConnection(client: mock2), store: store,
            sessionId: "rt", worktreePath: FileManager.default.temporaryDirectory.path)
        runner2.flushQueueIfIdle()
        #expect(mock2.sent.isEmpty)

        runner2.forceSendQueuedItem(id: session2.queue[0].id)
        for _ in 0 ..< 100 where !session2.queue.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(session2.queue.isEmpty)
        let prompts = mock2.sent.filter { $0.method == "session/prompt" }
        #expect(prompts.count == 2)
    }
}

private actor QueueTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

private actor LeaseValidationGate {
    private let entered = QueueTestGate()
    private let releaseGate = QueueTestGate()
    private let result: Bool
    private var blocksFirstValidation = true

    init(result: Bool = true) {
        self.result = result
    }

    func validate() async -> Bool {
        guard blocksFirstValidation else { return true }
        blocksFirstValidation = false
        await entered.open()
        await releaseGate.wait()
        return result
    }

    func waitUntilEntered() async {
        await entered.wait()
    }

    func release() async {
        await releaseGate.open()
    }
}

private actor StrictSingleFlightPromptProbe {
    private let firstStarted = QueueTestGate()
    private let firstRelease = QueueTestGate()
    private var firstRunning = false
    private(set) var callCount = 0

    func send() async throws -> Data {
        callCount += 1
        if callCount == 1 {
            firstRunning = true
            await firstStarted.open()
            await firstRelease.wait()
            firstRunning = false
        } else if firstRunning {
            throw ACPClientError.jsonrpc(.init(
                code: -32003,
                message: "Agent is already processing. Use steer() or followUp() to queue messages, or wait for completion.",
                data: nil
            ))
        }
        return Data("null".utf8)
    }

    func waitUntilFirstStarted() async {
        await firstStarted.wait()
    }

    func releaseFirst() async {
        await firstRelease.open()
    }
}

private final class DurableAcknowledgementRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var recordedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func record() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
