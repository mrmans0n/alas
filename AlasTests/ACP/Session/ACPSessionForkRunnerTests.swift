import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACP session fork context delivery")
struct ACPSessionForkRunnerTests {
    @Test("transcript fork survives relaunch and delivers context on the first prompt")
    func transcriptForkSurvivesRelaunch() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-fork-relaunch-\(UUID()).sqlite").path
        let targetID: String
        let inheritedCount = 2
        do {
            let storeA = try ACPSessionStore(path: path)
            let managerA = ACPSessionManager(
                worktreeId: "wt",
                worktreePath: "/tmp/wt",
                store: storeA
            )
            let source = managerA.createSession(agentId: "claude")
            await managerA.flushPersistence()
            let inherited: [ACPMessage] = [
                .user(id: UUID(), text: "Question", attachments: []),
                .agent(id: UUID(), StreamingText("Answer"))
            ]
            for (index, message) in inherited.enumerated() {
                source.transcript.appendMessage(message)
                try storeA.appendMessage(
                    sessionId: source.id,
                    id: "msg-\(source.id)-\(index)",
                    kind: message.kind,
                    seq: Int64(index),
                    payload: try ACPMessageCodec.encode(message),
                    createdAt: Int64(index)
                )
            }
            let target = try await managerA.createFork(
                sourceSessionID: source.id,
                boundary: .init(stableID: inherited[1].stableId, kind: .agent),
                targetAgentID: "codex",
                autoRunDefault: false
            )
            targetID = target.id
            managerA.shutdownBackgroundTasks()
            await managerA.releaseAllOwnedLeases()
        }

        let storeB = try ACPSessionStore(path: path)
        let mock = ACPMockClient()
        mock.script(method: "initialize") { _ in
            try JSONEncoder().encode(ACPInitializeResult(
                protocolVersion: 1,
                agentCapabilities: .init(),
                authMethods: []
            ))
        }
        mock.script(method: "session/new") { _ in
            try JSONEncoder().encode(ACPSessionNewResult(
                sessionId: "fresh-remote",
                availableModels: [],
                availableModes: [],
                currentModel: nil,
                currentMode: nil,
                promptSuggestions: []
            ))
        }
        mock.script(method: "session/prompt") { _ in Data("null".utf8) }
        let managerB = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: storeB,
            setupEvaluator: { _ in .ready },
            connectionFactory: { _, _, _ in ACPConnection(client: mock) }
        )
        let restored = try #require(managerB.placeholderSession(id: targetID))
        await managerB.hydrateIfNeeded(id: targetID)
        await managerB.awaitBackfill(id: targetID)

        #expect(restored.forkRecord?.mechanism == .transcriptTransfer)
        #expect(restored.forkRecord?.contextDeliveryPending == true)
        #expect(restored.transcript.messages.count == inheritedCount)

        await managerB.attach(to: targetID, freshlyCreated: false)
        let runner = try #require(managerB.runners[targetID])
        runner.sendNow(blocks: [.text("Continue")], queuedItemId: nil)
        try await waitUntil {
            mock.sent.contains { $0.method == "session/prompt" }
                && restored.forkRecord?.contextDeliveryPending == false
        }
        await runner.flushPersistence()

        #expect(try storeB.loadFork(
            targetSessionID: restored.id
        )?.contextDeliveryPending == false)
        #expect(restored.transcript.messages.count == inheritedCount + 1)

        await managerB.detach(sessionId: targetID)
        managerB.shutdownBackgroundTasks()
        await managerB.releaseAllOwnedLeases()
    }

    @Test("fork context serializes the inherited conversation")
    func forkContextSerializesInheritedConversation() {
        let context = ACPTranscriptMarkdown.forkContext(
            sourceAgentID: "claude",
            messages: [
                .user(id: UUID(), text: "Question", attachments: []),
                .agent(id: UUID(), StreamingText("Answer"))
            ]
        )

        #expect(context?.contains("The conversation below was imported from claude.") == true)
        #expect(context?.contains("## You\n\nQuestion") == true)
        #expect(context?.contains("## claude\n\nAnswer") == true)
    }

    @Test("first prompt sends inherited context privately and clears it durably")
    func firstPromptDeliversPrivateContext() async throws {
        let (runner, mock, session, persistence) = try await makeRunner()
        mock.script(method: "session/prompt") { _ in Data("null".utf8) }

        runner.sendNow(blocks: [.text("Continue")], queuedItemId: nil)

        try await waitUntil {
            mock.sent.contains { $0.method == "session/prompt" }
                && session.forkRecord?.contextDeliveryPending == false
        }
        await runner.flushPersistence()

        let request = try #require(mock.sent.first { $0.method == "session/prompt" })
        let promptBlocks = try #require(request.params as? ACPSessionPromptParams).prompt
        #expect(promptBlocks == [
            .text(try #require(ACPTranscriptMarkdown.forkContext(
                sourceAgentID: "claude",
                messages: Array(session.transcript.messages.prefix(2))
            ))),
            .text("Continue")
        ])
        #expect(session.transcript.messages.count == 3)
        #expect(try await persistence.loadFork(targetSessionID: session.id)?.contextDeliveryPending == false)
    }

    @Test("direct first prompt acknowledgement follows durable context delivery")
    func directFirstPromptAcknowledgesAfterContextDeliveryPersistence() async throws {
        let (runner, mock, session, persistence) = try await makeRunner()
        let acknowledgement = ForkPromptAcknowledgementRecorder()
        let path = persistence.path
        let sessionID = session.id
        mock.scriptResponse(method: "session/prompt") { _ in
            ACPResponse(
                body: Data("null".utf8),
                durableConsumptionAcknowledgement: {
                    acknowledgement.recordPersistedForkState(
                        path: path,
                        targetSessionID: sessionID
                    )
                }
            )
        }

        runner.sendNow(blocks: [.text("Continue")], queuedItemId: nil)

        try await waitUntil { acknowledgement.recordedCount == 1 }
        await runner.flushPersistence()

        #expect(acknowledgement.persistedPendingStates == [false])
    }

    @Test("failed fork marker persistence leaves direct prompt unacknowledged")
    func failedForkMarkerPersistenceDoesNotAcknowledgeDirectPrompt() async throws {
        let (runner, mock, session, persistence) = try await makeRunner()
        let acknowledgement = ForkPromptAcknowledgementRecorder()
        let database = try SQLiteDatabase(path: persistence.path)
        try database.exec("DROP TABLE session_forks")
        let path = persistence.path
        let sessionID = session.id
        mock.scriptResponse(method: "session/prompt") { _ in
            ACPResponse(
                body: Data("null".utf8),
                durableConsumptionAcknowledgement: {
                    acknowledgement.recordPersistedForkState(
                        path: path,
                        targetSessionID: sessionID
                    )
                }
            )
        }

        runner.sendNow(blocks: [.text("Continue")], queuedItemId: nil)

        try await waitUntil {
            mock.sent.contains { $0.method == "session/prompt" }
                && session.forkRecord?.contextDeliveryPending == false
        }
        await runner.flushPersistence()

        #expect(acknowledgement.recordedCount == 0)
    }

    @Test("queued first prompt acknowledgement follows context delivery and queue removal")
    func queuedFirstPromptAcknowledgesAfterContextDeliveryAndQueuePersistence() async throws {
        let (runner, mock, session, persistence) = try await makeRunner()
        let acknowledgement = ForkPromptAcknowledgementRecorder()
        let path = persistence.path
        let sessionID = session.id
        mock.scriptResponse(method: "session/prompt") { _ in
            ACPResponse(
                body: Data("null".utf8),
                durableConsumptionAcknowledgement: {
                    acknowledgement.recordPersistedForkAndQueueState(
                        path: path,
                        targetSessionID: sessionID
                    )
                }
            )
        }
        session.enqueue(blocks: [.text("Continue")])
        runner.persistQueue()
        await runner.flushPersistence()

        runner.flushQueueIfIdle()

        try await waitUntil { acknowledgement.recordedCount == 1 }
        await runner.flushPersistence()

        #expect(acknowledgement.persistedPendingStates == [false])
        #expect(acknowledgement.persistedQueueCounts == [0])
    }

    @Test("failed fork marker persistence leaves queued first prompt unacknowledged")
    func failedForkMarkerPersistenceDoesNotAcknowledgeQueuedPrompt() async throws {
        let (runner, mock, session, persistence) = try await makeRunner()
        let acknowledgement = ForkPromptAcknowledgementRecorder()
        session.enqueue(blocks: [.text("Continue")])
        runner.persistQueue()
        await runner.flushPersistence()
        let database = try SQLiteDatabase(path: persistence.path)
        try database.exec("DROP TABLE session_forks")
        let path = persistence.path
        let sessionID = session.id
        mock.scriptResponse(method: "session/prompt") { _ in
            ACPResponse(
                body: Data("null".utf8),
                durableConsumptionAcknowledgement: {
                    acknowledgement.recordPersistedForkAndQueueState(
                        path: path,
                        targetSessionID: sessionID
                    )
                }
            )
        }

        runner.flushQueueIfIdle()

        try await waitUntil { session.queue.isEmpty }
        await runner.flushPersistence()

        #expect(acknowledgement.recordedCount == 0)
    }

    @Test("stale queued completion acknowledges after prior queue removal and context delivery")
    func staleQueuedCompletionAcknowledgesAfterPersistedState() async throws {
        let (runner, mock, session, persistence) = try await makeRunner()
        let acknowledgement = ForkPromptAcknowledgementRecorder()
        let promptStarted = ForkPromptGate()
        let finishPrompt = ForkPromptGate()
        let path = persistence.path
        let sessionID = session.id
        mock.scriptResponse(method: "session/prompt") { _ in
            await promptStarted.open()
            await finishPrompt.wait()
            return ACPResponse(
                body: Data("null".utf8),
                durableConsumptionAcknowledgement: {
                    acknowledgement.recordPersistedForkAndQueueState(
                        path: path,
                        targetSessionID: sessionID
                    )
                }
            )
        }
        session.enqueue(blocks: [.text("Continue")])
        runner.persistQueue()
        await runner.flushPersistence()
        runner.flushQueueIfIdle()
        await promptStarted.wait()

        // Model steer's ordered queue removal and prompt invalidation without
        // starting a successor prompt that would obscure this stale completion.
        session.queue.removeAll()
        runner.persistQueue()
        runner.invalidateActivePrompt()
        await runner.flushPersistence()
        #expect(try await persistence.loadQueue(sessionId: session.id).isEmpty)

        await finishPrompt.open()
        try await waitUntil { session.forkRecord?.contextDeliveryPending == false }
        await runner.flushPersistence()

        #expect(acknowledgement.persistedPendingStates == [false])
        #expect(acknowledgement.persistedQueueCounts == [0])
    }

    @Test("out-of-order prompts each acknowledge captured fork context")
    func outOfOrderPromptsEachAcknowledgeCapturedForkContext() async throws {
        let (runner, mock, session, persistence) = try await makeRunner()
        let acknowledgement = ForkPromptAcknowledgementRecorder()
        let sequence = ForkPromptSequence()
        let firstStarted = ForkPromptGate()
        let secondStarted = ForkPromptGate()
        let finishFirst = ForkPromptGate()
        let finishSecond = ForkPromptGate()
        let path = persistence.path
        let sessionID = session.id
        mock.scriptResponse(method: "session/prompt") { _ in
            switch await sequence.next() {
            case 1:
                await firstStarted.open()
                await finishFirst.wait()
            default:
                await secondStarted.open()
                await finishSecond.wait()
            }
            return ACPResponse(
                body: Data("null".utf8),
                durableConsumptionAcknowledgement: {
                    acknowledgement.recordPersistedForkState(
                        path: path,
                        targetSessionID: sessionID
                    )
                }
            )
        }

        runner.sendNow(blocks: [.text("First")], queuedItemId: nil)
        await firstStarted.wait()
        runner.sendNow(blocks: [.text("Second")], queuedItemId: nil)
        await secondStarted.wait()

        await finishSecond.open()
        try await waitUntil { acknowledgement.recordedCount == 1 }
        await finishFirst.open()
        try await waitUntil { acknowledgement.recordedCount == 2 }
        await runner.flushPersistence()

        #expect(acknowledgement.persistedPendingStates == [false, false])
    }

    @Test("failed first prompt keeps private context pending for a queue retry")
    func failedFirstPromptKeepsContextPending() async throws {
        let (runner, mock, session, persistence) = try await makeRunner()
        mock.script(method: "session/prompt") { _ in throw ACPClientError.notRunning }
        session.enqueue(blocks: [.text("Continue")])
        runner.persistQueue()

        runner.flushQueueIfIdle()
        try await waitUntil { session.queue.first?.lastError != nil }

        #expect(session.forkRecord?.contextDeliveryPending == true)
        #expect(try await persistence.loadFork(targetSessionID: session.id)?.contextDeliveryPending == true)
        #expect(session.transcript.messages.count == 3)
        #expect(session.transcript.messages.allSatisfy {
            ACPTranscriptMarkdown.messageBody($0)?.contains("The conversation below was imported") != true
        })

        mock.script(method: "session/prompt") { _ in Data("null".utf8) }
        session.queue[0].lastError = nil
        runner.flushQueueIfIdle()
        try await waitUntil { session.queue.isEmpty }

        let userMessages = session.transcript.messages.filter {
            if case .user = $0 { return true }
            return false
        }
        #expect(userMessages.count == 2)
    }

    private func makeRunner() async throws -> (
        ACPSessionRunner,
        ACPMockClient,
        ACPSession,
        ACPSessionPersistence
    ) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-fork-runner-\(UUID()).sqlite").path
        let persistence = ACPSessionPersistence(path: path)
        let inherited = [
            ACPMessage.user(id: UUID(), text: "Question", attachments: []),
            ACPMessage.agent(id: UUID(), StreamingText("Answer"))
        ]
        let row = ACPSessionRow(
            id: "target", agentId: "codex", title: "Fork",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false
        )
        let fork = ACPSessionForkRecord(
            targetSessionID: row.id,
            sourceSessionID: "source",
            sourceAgentID: "claude",
            sourceBoundarySequence: 2,
            inheritedMessageCount: 2,
            phase: .ready,
            mechanism: .transcriptTransfer,
            contextDeliveryPending: true
        )
        let stored = try ACPSessionForkSnapshot(
            sourceBoundarySequence: 2,
            messages: [
                .init(role: ACPSessionForkConversationMessage.Role.user, text: "Question"),
                .init(role: ACPSessionForkConversationMessage.Role.agent, text: "Answer")
            ]
        ).copiedMessages(targetSessionID: row.id, createdAt: 0)
        try await persistence.createFork(session: row, messages: stored, record: fork)

        let session = ACPSession(id: row.id, agentId: row.agentId, worktreeId: "wt", title: row.title)
        session.agentState = .ready
        session.forkRecord = fork
        for message in inherited {
            session.transcript.appendMessage(message)
        }
        let mock = ACPMockClient()
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: mock),
            store: nil,
            sessionId: session.id,
            worktreePath: FileManager.default.temporaryDirectory.path,
            persistence: persistence
        )
        return (runner, mock, session, persistence)
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while !condition() {
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                throw TimeoutError()
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private struct TimeoutError: Error {}
}

private actor ForkPromptGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let continuations = waiters
        waiters.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}

private actor ForkPromptSequence {
    private var value = 0

    func next() -> Int {
        value += 1
        return value
    }
}

private final class ForkPromptAcknowledgementRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [Bool?] = []
    private var queueCounts: [Int?] = []

    var recordedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return states.count
    }

    var persistedPendingStates: [Bool?] {
        lock.lock()
        defer { lock.unlock() }
        return states
    }

    var persistedQueueCounts: [Int?] {
        lock.lock()
        defer { lock.unlock() }
        return queueCounts
    }

    func recordPersistedForkState(path: String, targetSessionID: String) {
        let pending: Bool?
        do {
            pending = try ACPSessionStore(path: path)
                .loadFork(targetSessionID: targetSessionID)?
                .contextDeliveryPending
        } catch {
            pending = nil
        }
        lock.lock()
        states.append(pending)
        lock.unlock()
    }

    func recordPersistedForkAndQueueState(path: String, targetSessionID: String) {
        let state: (pending: Bool?, queueCount: Int?)
        do {
            let store = try ACPSessionStore(path: path)
            state = (
                try store.loadFork(targetSessionID: targetSessionID)?.contextDeliveryPending,
                try store.loadQueue(sessionId: targetSessionID).count
            )
        } catch {
            state = (nil, nil)
        }
        lock.lock()
        states.append(state.pending)
        queueCounts.append(state.queueCount)
        lock.unlock()
    }
}
