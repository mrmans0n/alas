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
        agentID: String = "claude",
        validateLease: (() async -> Bool)? = nil,
        onPromptWorkChanged: (() -> Void)? = nil,
        onPersist: (() -> Void)? = nil,
        isConnectionCurrent: (() -> Bool)? = nil,
        incomingUpdateCoalesceNanos: UInt64 = 16_000_000,
        onSuccessfulTurn: @escaping @MainActor (NextPromptCompletedTurn) -> Void = { _ in },
        autoResumeAfterUsageLimit: @escaping @MainActor () -> Bool = { true },
        pluginContext: (@MainActor (String) async -> [String])? = nil,
        onCheckpointCapture: (@MainActor (String, Bool) async -> CheckpointID?)? = nil
    ) throws -> (ACPSessionRunner, ACPMockClient, ACPSession, ACPSessionStore) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rn-q-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(
            id: "s", agentId: agentID, title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        let mock = ACPMockClient()
        let session = ACPSession(id: "s", agentId: agentID, worktreeId: "wt", title: "t")
        session.agentState = .ready
        session.supportsCodexSteeringCompletion = true
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: mock),
            store: store,
            sessionId: "s",
            worktreePath: FileManager.default.temporaryDirectory.path,
            onPersist: onPersist,
            onPromptWorkChanged: onPromptWorkChanged,
            onSuccessfulTurn: onSuccessfulTurn,
            autoResumeAfterUsageLimit: autoResumeAfterUsageLimit,
            onCheckpointCapture: onCheckpointCapture,
            pluginContext: pluginContext,
            isConnectionCurrent: isConnectionCurrent ?? { true },
            incomingUpdateCoalesceNanos: incomingUpdateCoalesceNanos,
            validateLease: validateLease)
        return (runner, mock, session, store)
    }

    private func rejectWakeDeliveryWrites(in store: ACPSessionStore) throws {
        try store.db.exec("""
        CREATE TRIGGER reject_wake_delivery BEFORE UPDATE OF payload ON messages
        WHEN CAST(NEW.payload AS TEXT) LIKE '%"wakeDelivered":true%'
        BEGIN SELECT RAISE(ABORT, 'delivery write failed'); END;
        """)
    }

    private static func codexLimitError(_ message: String) -> ACPClientError {
        .jsonrpc(.init(code: -32603, message: "Internal error", data: AnyCodable([
            "message": AnyCodable(message),
            "codexErrorInfo": AnyCodable("usageLimitExceeded"),
        ])))
    }

    @Test("a usage-limited turn confirms its prompt and schedules a resume without losing a failed wake confirmation", arguments: [(false, true), (true, true), (true, false)])
    func usageLimitSchedulesResumeAtReset(backgroundWake: Bool, committed: Bool) async throws {
        let (runner, mock, session, store) = try mkRunner(agentID: backgroundWake ? "codex" : "claude")
        // The parser reads local time and ignores resets more than 8 days out.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, yyyy h:mm a"
        let reset = formatter.string(from: Date().addingTimeInterval(2 * 3600))
        mock.script(method: "session/prompt") { _ in
            throw Self.codexLimitError("You've hit your usage limit. Try again at \(reset).")
        }
        if backgroundWake {
            session.transcript.streamingState = .awaitingPermission
            session.applyBackgroundTask(.init(sessionUpdate: "async_task_state_update", asyncTaskId: "job",
                state: "completed"), ownerSessionId: "s")
            await runner.reconcileBackgroundTasks(adapterSurvived: true, previousTaskIds: [])
            await runner.flushPersistence()
            session.transcript.streamingState = .idle
            if !committed { try rejectWakeDeliveryWrites(in: store) }
        } else {
            session.enqueue(blocks: [.text("first")])
        }
        session.enqueue(blocks: [.text("second")])
        runner.persistQueue()
        runner.flushQueueIfIdle()
        try await waitUntil { session.usageLimit != nil }
        await runner.flushPersistence()

        let limit = try #require(session.usageLimit)
        #expect(limit.resetSource == .parsed)
        #expect(session.lastError == nil)
        if backgroundWake {
            #expect(session.backgroundTasks[0].wakeDelivered == committed)
            #expect(try store.loadQueue(sessionId: "s") == session.queue)
            let row = try #require(store.loadMessages(sessionId: "s").first)
            let task = try #require(ACPBackgroundTask(toolCall: JSONDecoder().decode(ACPMessage.ToolCall.self, from: row.payload)))
            #expect(task.wakeDelivered == committed)
            let queuedIDs = session.queue.map(\.id)
            await runner.reconcileBackgroundTasks(adapterSurvived: true, previousTaskIds: [])
            await runner.flushPersistence()
            #expect(session.queue.map(\.id) == queuedIDs)
            #expect(mock.sent.filter { $0.method == "session/prompt" }.count == 1)
            if !committed {
                #expect(session.queue.count == 3)
                #expect(session.queue[0].backgroundTaskWake != nil && session.queue[0].deliveryUncertain)
                #expect(session.queue[0].lastError != nil)
                #expect(session.queue[1].usageLimit == limit)
                return
            }
        }
        // "first" was delivered (its text is in the agent's history); the
        // resume item now heads the queue, ahead of "second".
        #expect(session.queue.count == 2)
        #expect(session.queue[0].usageLimit == limit)
        #expect(session.queue[0].scheduledAt == limit.resetsAt.map { $0 + 60 })
        #expect(session.queue[0].lastError == nil)
        #expect(session.queue[1].blocks == [.text("second")])
        if backgroundWake {
            mock.script(method: "session/prompt") { _ in Data("{}".utf8) }
            session.queue[0].scheduledAt = Date()
            runner.flushQueueIfIdle()
            try await waitUntil { session.queue.isEmpty }
            await runner.flushPersistence()
            await runner.reconcileBackgroundTasks(adapterSurvived: true, previousTaskIds: [])
            await runner.flushPersistence()
            #expect(session.queue.isEmpty)
            #expect(mock.sent.filter { $0.method == "session/prompt" }.count == 3)
        }
    }

    @Test("a resume that succeeds clears the Limited state and the queue drains")
    func usageLimitResumeSucceeds() async throws {
        let (runner, mock, session, _) = try mkRunner()
        mock.script(method: "session/prompt") { _ in
            throw Self.codexLimitError("You've hit your usage limit.")
        }
        session.enqueue(blocks: [.text("first")])
        session.enqueue(blocks: [.text("second")])
        runner.persistQueue()
        runner.flushQueueIfIdle()
        try await waitUntil { session.usageLimitResumeItem != nil }

        mock.script(method: "session/prompt") { _ in Data("null".utf8) }
        session.queue[0].scheduledAt = Date()
        runner.flushQueueIfIdle()
        try await waitUntil { session.queue.isEmpty }
        #expect(session.usageLimit == nil)
    }

    @Test("a resume that hits the limit again backs off and keeps the episode start")
    func usageLimitResumeHitsLimitAgain() async throws {
        let (runner, mock, session, _) = try mkRunner()
        mock.script(method: "session/prompt") { _ in
            throw Self.codexLimitError("You've hit your usage limit.")
        }
        session.enqueue(blocks: [.text("first")])
        runner.persistQueue()
        runner.flushQueueIfIdle()
        try await waitUntil { session.usageLimitResumeItem != nil }
        let firstDetection = try #require(session.usageLimit).detectedAt

        session.queue[0].scheduledAt = Date()
        runner.flushQueueIfIdle()
        try await waitUntil { session.usageLimit?.probeAttempt == 1 }

        #expect(session.usageLimit?.detectedAt == firstDetection)
        #expect(session.queue.count == 1)
        let next = try #require(session.queue[0].scheduledAt)
        #expect(next > Date().addingTimeInterval(29 * 60))
    }

    private static func sentPromptTexts(_ mock: ACPMockClient) -> [String] {
        mock.sent.compactMap { request in
            guard request.method == "session/prompt",
                  let params = request.params as? ACPSessionPromptParams else { return nil }
            return params.prompt.compactMap { block -> String? in
                if case .text(let text) = block { return text }
                return nil
            }.joined()
        }
    }

    @Test("a message sent while Limited goes first, clears the limit, and the held queue drains after it",
          arguments: [true, false])
    func manualSuccessClearsLimitAndResumeItem(autoResume: Bool) async throws {
        let (runner, mock, session, _) = try mkRunner(autoResumeAfterUsageLimit: { autoResume })
        mock.script(method: "session/prompt") { _ in
            throw Self.codexLimitError("You've hit your usage limit.")
        }
        session.enqueue(blocks: [.text("first")])
        session.enqueue(blocks: [.text("queued before limit")])
        runner.persistQueue()
        runner.flushQueueIfIdle()
        try await waitUntil { session.usageLimit != nil }

        mock.script(method: "session/prompt") { _ in Data("null".utf8) }
        session.enqueue(blocks: [.text("typed while limited")])
        runner.persistQueue()
        runner.flushQueueIfIdle()
        try await waitUntil { session.queue.isEmpty }
        #expect(session.usageLimit == nil)
        #expect(Self.sentPromptTexts(mock) == ["first", "typed while limited", "queued before limit"])
    }

    @Test("with auto-resume off a limit shows Limited and holds the rest of the queue")
    func usageLimitWithoutAutoResume() async throws {
        let (runner, mock, session, _) = try mkRunner(autoResumeAfterUsageLimit: { false })
        mock.script(method: "session/prompt") { _ in
            throw Self.codexLimitError("You've hit your usage limit.")
        }
        session.enqueue(blocks: [.text("first")])
        session.enqueue(blocks: [.text("second")])
        runner.persistQueue()
        runner.flushQueueIfIdle()
        try await waitUntil { session.usageLimit != nil }

        runner.flushQueueIfIdle()
        #expect(session.usageLimitResumeItem == nil)
        #expect(session.queue.map(\.blocks) == [[.text("second")]])
        #expect(session.queue.map(\.status) == [.pending])
        #expect(Self.sentPromptTexts(mock) == ["first"])
    }

    @Test("a Claude limit is detected across flushed and buffered agent text", arguments: [nil, "You've hit your ", "An ordinary answer. "] as [String?])
    func bufferedClaudeLimitTextIsDetected(flushedText: String?) async throws {
        let (runner, mock, session, _) = try mkRunner(incomingUpdateCoalesceNanos: 30_000_000_000)
        runner.start()
        defer { runner.stop() }
        mock.scriptAsync(method: "session/prompt") { _ in
            // Claude's error_during_execution path builds the error from
            // `errors`, so the limit text arrives only as an agent chunk.
            if let flushedText {
                await MainActor.run {
                    _ = session.apply(.agentMessageChunk(.text(flushedText)))
                }
            }
            mock.emit(.init(sessionId: "s", update: .agentMessageChunk(.text(
                flushedText == "You've hit your " ? "limit · resets 3pm (Europe/Madrid)" : "You've hit your limit · resets 3pm (Europe/Madrid)"
            ))))
            // Keep this chunk buffered so the split-message case cannot pass
            // merely because the coalescer happened to flush before the RPC failed.
            if flushedText != nil {
                try await waitUntil { runner.pendingIncomingUpdateCountForTesting == 1 }
            }
            throw ACPClientError.jsonrpc(.init(code: -32603, message: "Internal error: error_during_execution", data: nil))
        }
        session.enqueue(blocks: [.text("first")])
        runner.persistQueue()
        runner.flushQueueIfIdle()
        try await waitUntil { session.usageLimit != nil || session.queue.first?.lastError != nil }
        #expect(session.usageLimit != nil)
    }

    @Test("a limit with no resume item survives close and reopen and keeps the pre-limit queue held")
    func usageLimitWithoutResumeItemSurvivesReopen() async throws {
        let (runner, mock, session, store) = try mkRunner(autoResumeAfterUsageLimit: { false })
        mock.script(method: "session/prompt") { _ in
            throw Self.codexLimitError("You've hit your usage limit.")
        }
        session.enqueue(blocks: [.text("first")])
        session.enqueue(blocks: [.text("second")])
        runner.persistQueue()
        runner.flushQueueIfIdle()
        try await waitUntil { session.usageLimit != nil }
        let limit = try #require(session.usageLimit)
        // Persistence is FIFO and the limit is written before the queue.
        try await waitUntil { (try? store.loadQueue(sessionId: "s"))?.map(\.blocks) == [[.text("second")]] }

        let manager = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp", store: store)
        defer { manager.shutdownBackgroundTasks() }
        let reopened = try #require(manager.placeholderSession(id: "s"))
        await manager.hydrateIfNeeded(id: "s")
        #expect(reopened.usageLimit == limit)
        #expect(reopened.queue.map(\.blocks) == [[.text("second")]])
        #expect(reopened.queue.first?.isHeld(by: reopened.usageLimit) == true)
    }

    @Test("a direct prompt stopped by a usage limit is reported as delivered, so the composer keeps it cleared")
    func directPromptAtUsageLimitReportsDelivered() async throws {
        let (runner, mock, session, _) = try mkRunner()
        mock.script(method: "session/prompt") { _ in
            throw Self.codexLimitError("You've hit your usage limit.")
        }
        var reported: Bool?
        runner.send(blocks: [.text("direct")], intent: .auto, onPromptFinished: { reported = $0 })
        try await waitUntil { reported != nil }
        #expect(reported == true)
        #expect(session.usageLimit != nil)
    }

    @Test("cancelling auto-resume leaves the session Limited with the queue held")
    func cancelAutoResumeHoldsQueue() async throws {
        let (runner, mock, session, _) = try mkRunner()
        mock.script(method: "session/prompt") { _ in
            throw Self.codexLimitError("You've hit your usage limit.")
        }
        session.enqueue(blocks: [.text("first")])
        session.enqueue(blocks: [.text("second")])
        runner.persistQueue()
        runner.flushQueueIfIdle()
        try await waitUntil { session.usageLimitResumeItem != nil }

        #expect(session.removeUsageLimitResume())
        runner.persistQueue()
        runner.flushQueueIfIdle()
        #expect(session.usageLimit != nil)
        #expect(session.queue.map(\.blocks) == [[.text("second")]])
        #expect(session.queue.map(\.status) == [.pending])
        #expect(Self.sentPromptTexts(mock) == ["first"])
    }

    @Test("native steering prepends fresh plugin context without recording it", arguments: ["injected", "promptRequired"])
    func nativeSteeringIncludesFreshPluginContext(outcome: String) async throws {
        var requests = 0
        let (runner, mock, session, _) = try mkRunner(pluginContext: { sessionID in
            #expect(sessionID == "s")
            requests += 1
            return ["context \(requests)"]
        })
        session.supportsSteering = true
        session.transcript.streamingState = .streaming
        mock.script(method: "_session/steering") { request in
            #expect((request.params as? ACPSteeringParams)?.prompt == [.text("context 1"), .text("redirect")])
            return Data("{\"outcome\":\"\(outcome)\"}".utf8)
        }
        mock.script(method: "session/prompt") { request in
            #expect((request.params as? ACPSessionPromptParams)?.prompt == [.text("context 2"), .text("redirect")])
            return Data("{}".utf8)
        }
        defer { runner.stop() }
        let accepted = await withCheckedContinuation { continuation in
            runner.send(blocks: [.text("redirect")], intent: .steer) { continuation.resume(returning: $0) }
        }
        #expect(accepted)
        #expect(requests == (outcome == "injected" ? 1 : 2))
        #expect(session.transcript.messages.count == 1)
        guard case .user(_, _, let text, _, _) = session.transcript.messages.first else {
            Issue.record("Missing user prompt")
            return
        }
        #expect(text == "redirect")
    }

    @Test("native steering preserves the running prompt and queued tail", arguments: [true, false])
    func nativeSteeringPreservesRunningPrompt(queuedOriginal: Bool) async throws {
        let preparing = QueueTestGate()
        let releasePreparation = QueueTestGate()
        var holdPreparation = true
        let (runner, mock, session, store) = try mkRunner(pluginContext: { _ in
            if holdPreparation {
                holdPreparation = false
                await preparing.open()
                await releasePreparation.wait()
            }
            return []
        })
        session.supportsSteering = true
        let started = QueueTestGate()
        let finish = QueueTestGate()
        mock.scriptAsync(method: "session/prompt") { request in
            if (request.params as? ACPSessionPromptParams)?.prompt == [.text("running")] {
                await started.open()
                await finish.wait()
            }
            return Data("{}".utf8)
        }
        mock.script(method: "_session/steering") { _ in Data(#"{"outcome":"injected"}"#.utf8) }
        defer { runner.stop()
        Task { await finish.open() } }
        if queuedOriginal {
            session.transcript.streamingState = .streaming
            runner.send(blocks: [.text("running")], intent: .auto)
            await runner.flushPersistence()
            session.transcript.streamingState = .idle
            runner.flushQueueIfIdle()
        } else {
            runner.send(blocks: [.text("running")], intent: .auto)
        }
        await preparing.wait()
        #expect(!session.canSteerRunningTurn)
        await releasePreparation.open()
        await started.wait()
        try await waitUntil { session.canSteerRunningTurn }
        #expect(session.canSteerRunningTurn)
        runner.applyIncomingUpdateForTesting(.init(sessionId: "s", update: .agentMessageChunk(.init(
            messageId: "shared", content: .text("before")))))
        runner.send(blocks: [.text("tail")], intent: .auto)
        var accepted: Bool?
        runner.send(blocks: [.text("redirect")], intent: .steer) { accepted = $0 }
        try await waitUntil { accepted != nil || mock.sent.contains { $0.method == "session/cancel" } }
        #expect(accepted == true)
        #expect(!mock.sent.contains { $0.method == "session/cancel" })
        #expect(mock.sent.filter { $0.method == "session/prompt" }.count == 1)
        #expect(session.transcript.streamingState == .streaming)
        runner.applyIncomingUpdateForTesting(.init(sessionId: "s", update: .agentMessageChunk(.init(
            messageId: "shared", content: .text("after")))))
        runner.applyIncomingUpdateForTesting(.init(sessionId: "s", update: .agentMessageChunk(.init(
            messageId: "shared", content: .text(" continued")))))
        #expect(session.queue.map(\.blocks) == (queuedOriginal ? [[.text("running")], [.text("tail")]] : [[.text("tail")]]))
        await runner.flushPersistence()
        #expect(try store.loadQueue(sessionId: "s") == session.queue)
        await finish.open()
        try await waitUntil { mock.sent.filter { $0.method == "session/prompt" }.count == 2 && session.queue.isEmpty }
        #expect(mock.sent.compactMap { ($0.params as? ACPSessionPromptParams)?.prompt } == [[.text("running")], [.text("tail")]])
        let users = session.transcript.messages.compactMap { message -> String? in
            if case .user(_, _, let text, _, _) = message { return text }
            return nil
        }
        #expect(users == ["running", "redirect", "tail"])
        func timeline(_ messages: [ACPMessage]) -> [String] {
            messages.compactMap {
                switch $0 {
                case .user(_, _, let text, _, _): "user:\(text)"
                case .agent(_, _, let text): "agent:\(text.value)"
                default: nil
                }
            }
        }
        let expected = ["user:running", "agent:before", "user:redirect", "agent:after continued", "user:tail"]
        #expect(timeline(session.transcript.messages) == expected)
        await runner.flushPersistence()
        let restored = try store.loadMessages(sessionId: "s").map {
            try ACPMessageCodec.decode(kind: $0.kind, payload: $0.payload)
        }
        #expect(timeline(restored) == expected)
    }

    @Test("injection into an adapter-owned turn leaves completion with the adapter")
    func injectionWithoutOwnedPromptDoesNotRetainQueue() async throws {
        let (runner, mock, session, _) = try mkRunner()
        defer { runner.stop() }
        session.supportsSteering = true
        session.transcript.streamingState = .streaming
        mock.script(method: "_session/steering") { _ in Data(#"{"outcome":"injected"}"#.utf8) }
        mock.script(method: "session/prompt") { _ in Data("{}".utf8) }
        var accepted: Bool?
        runner.send(blocks: [.text("redirect")], intent: .steer) { accepted = $0 }
        try await waitUntil { accepted != nil }
        runner.send(blocks: [.text("tail")], intent: .auto)
        await runner.flushPersistence()
        // Reattachment and adapter-owned turns finish through broker events.
        session.transcript.streamingState = .idle
        runner.flushQueueIfIdle()
        try await waitUntil { session.queue.isEmpty }
        #expect(accepted == true)
        #expect(mock.sent.compactMap { ($0.params as? ACPSessionPromptParams)?.prompt } == [[.text("tail")]])
    }

    @Test("native steering owns a completion race before draining the queue", arguments: [
        ("promptRequired", false), ("startedNewTurn", false), ("startedNewTurn", true)
    ])
    func nativeSteeringOwnsCompletionRace(outcome: String, completedBeforeAck: Bool) async throws {
        let (runner, mock, session, _) = try mkRunner()
        session.supportsSteering = true
        let started = QueueTestGate()
        let finishOriginal = QueueTestGate()
        let finishSteering = QueueTestGate()
        let finishContinuation = QueueTestGate()
        mock.scriptAsync(method: "session/prompt") { request in
            switch (request.params as? ACPSessionPromptParams)?.prompt {
            case [.text("running")]:
                await started.open()
                await finishOriginal.wait()
            case [.text("redirect")]:
                await finishContinuation.wait()
            default: break
            }
            return Data("{}".utf8)
        }
        mock.scriptAsync(method: "_session/steering") { _ in
            await finishSteering.wait()
            return Data("{\"outcome\":\"\(outcome)\"}".utf8)
        }
        defer {
            runner.stop()
            Task { await finishOriginal.open()
            await finishSteering.open()
            await finishContinuation.open() }
        }
        runner.send(blocks: [.text("running")], intent: .auto)
        await started.wait()
        session.transcript.streamingState = .streaming
        runner.send(blocks: [.text("tail")], intent: .auto)
        var accepted: Bool?
        runner.send(blocks: [.text("redirect")], intent: .steer) { accepted = $0 }
        try await waitUntil { mock.sent.contains { ["_session/steering", "session/cancel"].contains($0.method) } }
        await finishOriginal.open()
        try await waitUntil { session.queue.first?.status == .pending }
        #expect(!mock.sent.contains { $0.method == "session/cancel" })
        #expect(mock.sent.filter { $0.method == "session/prompt" }.count == 1)
        if completedBeforeAck {
            for status in ["idle", "active", "idle"] {
                let info = try JSONDecoder().decode(ACPSessionInfoUpdate.self, from: Data("{\"_meta\":{\"codex\":{\"threadStatus\":{\"type\":\"\(status)\"}}}}".utf8))
                runner.applyIncomingUpdateForTesting(.init(sessionId: "s", update: .sessionInfoUpdate(info)))
            }
            #expect(mock.sent.filter { $0.method == "session/prompt" }.count == 1)
        }
        await finishSteering.open()
        if outcome == "promptRequired" {
            try await waitUntil { mock.sent.filter { $0.method == "session/prompt" }.count == 2 }
            #expect(mock.sent.compactMap { ($0.params as? ACPSessionPromptParams)?.prompt } == [[.text("running")], [.text("redirect")]])
            await finishContinuation.open()
        } else {
            try await waitUntil { accepted != nil }
            if !completedBeforeAck {
                #expect(session.transcript.streamingState != .idle)
                for status in ["active", "idle"] {
                    let info = try JSONDecoder().decode(ACPSessionInfoUpdate.self, from: Data("{\"_meta\":{\"codex\":{\"threadStatus\":{\"type\":\"\(status)\"}}}}".utf8))
                    runner.applyIncomingUpdateForTesting(.init(sessionId: "s", update: .sessionInfoUpdate(info)))
                }
            }
        }
        try await waitUntil { accepted == true && session.queue.isEmpty }
        #expect(mock.sent.compactMap { ($0.params as? ACPSessionPromptParams)?.prompt }.last == [.text("tail")])
        #expect(session.transcript.messages.filter { if case .user(_, _, "redirect", _, _) = $0 { return true }
        return false }.count == 1)
    }

    @Test("Stop leaves steering recovery behind queued prompts retryable", arguments: ["preparation", "request"])
    func stoppingSteeringKeepsTrailingRecoveryRetryable(stage: String) async throws {
        let entered = QueueTestGate()
        let release = QueueTestGate()
        var preparationHeld = false
        let (runner, mock, session, _) = try mkRunner(pluginContext: { _ in
            if stage == "preparation", !preparationHeld {
                preparationHeld = true
                await entered.open()
                await release.wait()
            }
            return []
        })
        defer { runner.stop()
        Task { await release.open() } }
        session.supportsSteering = true
        session.transcript.streamingState = .streaming
        session.enqueue(blocks: [.text("tail")])
        mock.scriptAsync(method: "_session/steering") { _ in
            if stage == "request" {
                await entered.open()
                await release.wait()
            }
            return Data(#"{"outcome":"injected"}"#.utf8)
        }
        mock.script(method: "session/prompt") { _ in Data("{}".utf8) }
        var accepted: Bool?
        runner.send(blocks: [.text("redirect")], intent: .steer) { accepted = $0 }
        await entered.wait()
        let recoveryID = try #require(session.queue.last?.id)
        await runner.userCancel()
        try await waitUntil { mock.sent.contains { ($0.params as? ACPSessionPromptParams)?.prompt == [.text("tail")] } }
        try await waitUntil { session.queue.first?.id == recoveryID }
        #expect(session.queue.first?.status == .pending)
        #expect(session.queue.first?.deliveryUncertain == true)
        await release.open()
        try await waitUntil { accepted != nil }
        #expect(session.retryQueueItem(id: recoveryID))
        runner.flushQueueIfIdle()
        try await waitUntil { session.queue.isEmpty }
        #expect(mock.sent.compactMap { ($0.params as? ACPSessionPromptParams)?.prompt } == [[.text("tail")], [.text("redirect")]])
    }

    @Test("an unsupported detached steering lifecycle retains recovery without holding streaming")
    func unknownDetachedSteeringLifecycleFailsExplicitly() async throws {
        let (runner, mock, session, store) = try mkRunner()
        defer { runner.stop() }
        session.supportsSteering = true
        session.supportsCodexSteeringCompletion = false
        session.transcript.streamingState = .streaming
        mock.script(method: "_session/steering") { _ in Data(#"{"outcome":"startedNewTurn"}"#.utf8) }
        var accepted: Bool?
        runner.send(blocks: [.text("redirect")], intent: .steer) { accepted = $0 }
        try await waitUntil { accepted != nil }
        await runner.flushPersistence()
        #expect(accepted == true)
        #expect(session.transcript.streamingState == .awaitingInput)
        guard case .failed = session.agentState else {
            Issue.record("expected an explicit unsupported completion failure")
            return
        }
        #expect(!session.supportsSteering)
        #expect(try store.loadQueue(sessionId: "s").first?.deliveryUncertain == true)
        #expect(!mock.sent.contains { $0.method == "session/prompt" })
    }

    @Test("repeated steering waits for the new continuation's active boundary", arguments: ["injected", "startedNewTurn"])
    func repeatedSteeringWaitsForNewActiveBoundary(outcome: String) async throws {
        let (runner, mock, session, _) = try mkRunner()
        session.supportsSteering = true
        let started = QueueTestGate()
        let finishOriginal = QueueTestGate()
        let firstAcknowledgement = QueueTestGate()
        let secondAcknowledgement = QueueTestGate()
        var originalFinished = false
        mock.scriptAsync(method: "session/prompt") { request in
            if (request.params as? ACPSessionPromptParams)?.prompt == [.text("running")] {
                await started.open()
                await finishOriginal.wait()
            }
            return Data("{}".utf8)
        }
        mock.scriptAsync(method: "_session/steering") { request in
            if (request.params as? ACPSteeringParams)?.prompt == [.text("first")] {
                await firstAcknowledgement.wait()
                return Data(#"{"outcome":"startedNewTurn"}"#.utf8)
            }
            await secondAcknowledgement.wait()
            return Data("{\"outcome\":\"\(outcome)\"}".utf8)
        }
        defer {
            runner.stop()
            Task { await finishOriginal.open()
            await firstAcknowledgement.open()
            await secondAcknowledgement.open() }
        }
        func observe(_ status: String) throws {
            let info = try JSONDecoder().decode(ACPSessionInfoUpdate.self, from: Data("{\"_meta\":{\"codex\":{\"threadStatus\":{\"type\":\"\(status)\"}}}}".utf8))
            runner.applyIncomingUpdateForTesting(.init(sessionId: "s", update: .sessionInfoUpdate(info)))
        }
        runner.send(blocks: [.text("running")], intent: .auto) { originalFinished = $0 }
        await started.wait()
        session.transcript.streamingState = .streaming
        runner.send(blocks: [.text("tail")], intent: .auto)
        var firstAccepted: Bool?
        runner.send(blocks: [.text("first")], intent: .steer) { firstAccepted = $0 }
        try await waitUntil { mock.sent.contains { $0.method == "_session/steering" } }
        await finishOriginal.open()
        try await waitUntil { originalFinished }
        try observe("idle")
        await firstAcknowledgement.open()
        try await waitUntil { firstAccepted == true }
        try observe("active")

        var secondAccepted: Bool?
        runner.send(blocks: [.text("second")], intent: .steer) { secondAccepted = $0 }
        try await waitUntil { mock.sent.filter { $0.method == "_session/steering" }.count == 2 }
        try observe("idle")
        await secondAcknowledgement.open()
        try await waitUntil { secondAccepted == true }
        if outcome == "startedNewTurn" {
            #expect(session.queue.map(\.status) == [.pending])
            #expect(mock.sent.filter { $0.method == "session/prompt" }.count == 1)
            try observe("active")
            try observe("idle")
        }
        try await waitUntil { session.queue.isEmpty }
        #expect(mock.sent.compactMap { ($0.params as? ACPSessionPromptParams)?.prompt } == [[.text("running")], [.text("tail")]])
    }

    @Test("steering chunks stay after the follow-up while its row save is paused", arguments: [false, true])
    func steeringBoundaryPrecedesPausedRowSave(thought: Bool) async throws {
        let saving = QueueTestGate()
        let release = QueueTestGate()
        let (runner, mock, session, store) = try mkRunner()
        defer { runner.stop()
        Task { await release.open() } }
        session.supportsSteering = true
        session.transcript.streamingState = .streaming
        session.allowsStreamingBoundaryCrossing = true
        let text = StreamingText("before")
        session.transcript.appendMessage(thought
            ? .thought(id: UUID(), messageId: "shared", text)
            : .agent(id: UUID(), messageId: "shared", text))
        var paused = false
        runner.beforePersistenceForTesting = {
            if !paused, session.transcript.messages.contains(where: { $0.kind == "user" }) {
                paused = true
                await saving.open()
                await release.wait()
            }
        }
        mock.script(method: "_session/steering") { _ in Data(#"{"outcome":"injected"}"#.utf8) }
        var accepted: Bool?
        runner.send(blocks: [.text("redirect")], intent: .steer) { accepted = $0 }
        await saving.wait()
        let chunk = ACPTextChunk(messageId: "shared", content: .text("after"))
        runner.applyIncomingUpdateForTesting(.init(sessionId: "s", update: thought ? .agentThoughtChunk(chunk) : .agentMessageChunk(chunk)))
        await release.open()
        try await waitUntil { accepted != nil }
        await runner.flushPersistence()
        #expect(text.value == "before")
        #expect(session.transcript.messages.map(\.kind) == [thought ? "thought" : "agent", "user", thought ? "thought" : "agent"])
        #expect(try store.loadMessages(sessionId: "s").map(\.kind) == [thought ? "thought" : "agent", "user", thought ? "thought" : "agent"])
    }

    @Test("forced steering keeps the saved prompt when recovery persistence fails")
    func forcedSteeringKeepsSavedPromptUntilRecoveryCommit() async throws {
        let (runner, mock, session, store) = try mkRunner()
        defer { runner.stop() }
        session.supportsSteering = true
        session.transcript.streamingState = .streaming
        session.enqueue(blocks: [.text("redirect")])
        let id = try #require(session.queue.first?.id)
        try store.upsertQueue(sessionId: "s", items: session.queue)
        try store.db.exec("""
            CREATE TRIGGER fail_recovery_insert BEFORE INSERT ON session_queue
            BEGIN SELECT RAISE(ABORT, 'recovery write failed'); END;
            """)
        let persistenceStarted = QueueTestGate()
        runner.beforePersistenceForTesting = { await persistenceStarted.open() }
        runner.forceSendQueuedItem(id: id)
        await persistenceStarted.wait()
        await runner.flushPersistence()
        #expect(try store.loadQueue(sessionId: "s").first?.id == id)
        #expect(!mock.sent.contains { $0.method == "_session/steering" })
    }

    @Test("a failed steering confirmation save holds dispatch and retains its acknowledgement")
    func failedSteeringConfirmationSaveRetainsAcknowledgement() async throws {
        let (runner, mock, session, store) = try mkRunner()
        defer { runner.stop() }
        session.supportsSteering = true
        session.transcript.streamingState = .streaming
        let acknowledgement = DurableAcknowledgementRecorder()
        mock.scriptResponse(method: "_session/steering") { _ in
            try store.db.exec("""
                CREATE TRIGGER fail_confirmation_delete BEFORE DELETE ON session_queue
                BEGIN SELECT RAISE(ABORT, 'confirmation write failed'); END;
                """)
            return ACPResponse(body: Data(#"{"outcome":"injected"}"#.utf8),
                               durableConsumptionAcknowledgement: { acknowledgement.record() })
        }
        mock.script(method: "session/prompt") { _ in Data("{}".utf8) }
        var accepted: Bool?
        runner.send(blocks: [.text("redirect")], intent: .steer) { accepted = $0 }
        try await waitUntil { accepted != nil }
        await runner.flushPersistence()
        #expect(accepted == true)
        #expect(acknowledgement.recordedCount == 0)
        session.transcript.streamingState = .idle
        session.enqueue(blocks: [.text("tail")])
        runner.flushQueueIfIdle()
        await runner.flushPersistence()
        #expect(!mock.sent.contains { $0.method == "session/prompt" })
        try store.db.exec("DROP TRIGGER fail_confirmation_delete")
        runner.persistQueue()
        try await waitUntil { acknowledgement.recordedCount == 1 && session.queue.isEmpty }
        #expect(mock.sent.compactMap { ($0.params as? ACPSessionPromptParams)?.prompt } == [[.text("tail")]])
    }

    @Test("steering acknowledgement observes durable delivery or recovery", arguments: ["injected", "startedNewTurn", "unknown", "malformed"])
    func steeringAcknowledgementWaitsForDurableQueueRemoval(outcome: String) async throws {
        let (runner, mock, session, store) = try mkRunner()
        session.supportsSteering = true
        session.transcript.streamingState = .streaming
        let acknowledgement = DurableAcknowledgementRecorder()
        let databasePath = store.path
        mock.scriptResponse(method: "_session/steering") { _ in
            let body = outcome == "malformed" ? Data("{".utf8) : Data("{\"outcome\":\"\(outcome)\"}".utf8)
            return ACPResponse(body: body, durableConsumptionAcknowledgement: {
                let queue = try? ACPSessionStore(path: databasePath).loadQueue(sessionId: "s")
                if outcome == "injected" || outcome == "startedNewTurn" {
                    #expect(queue?.isEmpty == true)
                } else {
                    #expect(queue?.count == 1)
                    #expect(queue?.first?.status == .pending)
                    #expect(queue?.first?.deliveryUncertain == true)
                }
                acknowledgement.record()
            })
        }
        defer { runner.stop() }
        var accepted: Bool?
        runner.send(blocks: [.text("redirect")], intent: .steer) { accepted = $0 }
        try await waitUntil { accepted != nil && acknowledgement.recordedCount > 0 }
        #expect(accepted == true)
        #expect(acknowledgement.recordedCount == 1)
    }

    @Test("native steering refusal preserves the original turn", arguments: ["failed", "unknown"])
    func nativeSteeringRefusalPreservesOriginalTurn(outcome: String) async throws {
        let (runner, mock, session, _) = try mkRunner()
        session.supportsSteering = true
        let started = QueueTestGate()
        let finish = QueueTestGate()
        mock.scriptAsync(method: "session/prompt") { _ in
            await started.open()
            await finish.wait()
            return Data("{}".utf8)
        }
        mock.script(method: "_session/steering") { _ in Data("{\"outcome\":\"\(outcome)\"}".utf8) }
        defer { runner.stop()
        Task { await finish.open() } }
        runner.send(blocks: [.text("running")], intent: .auto)
        await started.wait()
        session.transcript.streamingState = .streaming
        var accepted: Bool?
        runner.send(blocks: [.text("redirect")], intent: .steer) { accepted = $0 }
        try await waitUntil { accepted != nil || mock.sent.contains { $0.method == "session/cancel" } }
        #expect(accepted == true)
        #expect(session.queue.count == 1)
        #expect(session.queue.first?.deliveryUncertain == true)
        #expect(!mock.sent.contains { $0.method == "session/cancel" })
        #expect(session.transcript.streamingState == .streaming)
        #expect(session.lastError != nil)
    }

    @Test("force-sent native steering failures retain a retryable queued prompt", arguments: ["failed", "unknown", "promptRequired"])
    func forceSentSteeringFailureRetainsQueueItem(outcome: String) async throws {
        let (runner, mock, session, store) = try mkRunner()
        session.supportsSteering = true
        let started = QueueTestGate()
        let finish = QueueTestGate()
        var originalFinished = false
        var promptCalls = 0
        mock.scriptAsync(method: "session/prompt") { _ in
            promptCalls += 1
            if promptCalls == 2, outcome == "promptRequired" {
                throw ACPClientError.jsonrpc(.init(code: -32000, message: "refused", data: nil))
            }
            await started.open()
            await finish.wait()
            return Data("{}".utf8)
        }
        mock.script(method: "_session/steering") { _ in Data("{\"outcome\":\"\(outcome)\"}".utf8) }
        defer { runner.stop()
        Task { await finish.open() } }
        runner.send(blocks: [.text("running")], intent: .auto) { originalFinished = $0 }
        await started.wait()
        session.transcript.streamingState = .streaming
        runner.send(blocks: [.text("selected")], intent: .auto)
        runner.send(blocks: [.text("tail")], intent: .auto)
        await runner.flushPersistence()
        let selected = try #require(session.queue.first)
        let tailID = try #require(session.queue.last?.id)
        runner.forceSendQueuedItem(id: selected.id)
        try await waitUntil { mock.sent.contains { $0.method == "_session/steering" } }
        if outcome == "promptRequired" { await finish.open() }
        try await waitUntil { session.queue.contains { $0.id == selected.id && $0.status == .pending && $0.lastError != nil } }
        #expect(session.queue.map(\.id) == [selected.id, tailID])
        let retained = try #require(session.queue.first(where: { $0.id == selected.id }))
        #expect(retained.blocks == selected.blocks)
        #expect(retained.status == .pending)
        #expect(retained.transcriptRecorded)
        #expect(retained.deliveryUncertain == (outcome != "promptRequired"))
        await runner.flushPersistence()
        #expect(try store.loadQueue(sessionId: "s").first?.id == selected.id)
        await finish.open()
        try await waitUntil { originalFinished }
        #expect(mock.sent.filter { $0.method == "session/prompt" }.count == (outcome == "promptRequired" ? 2 : 1))
        _ = session.retryQueueItem(id: selected.id)
        runner.flushQueueIfIdle()
        try await waitUntil { session.queue.isEmpty }
        #expect(session.transcript.streamingState == .idle)
        #expect(session.transcript.messages.filter {
            if case .user(_, _, "selected", _, _) = $0 { return true }
            return false
        }.count == 1)
    }

    @Test("unacknowledged native follow-ups survive detach without automatic resend", arguments: [false, true])
    func unacknowledgedNativeFollowupSurvivesDetach(forcedQueueItem: Bool) async throws {
        let current = ConnectionCurrentFlag(true)
        let (runner, mock, session, store) = try mkRunner(isConnectionCurrent: { current.isCurrent })
        session.supportsSteering = true
        session.transcript.streamingState = .streaming
        let response = QueueTestGate()
        mock.scriptAsync(method: "_session/steering") { _ in
            await response.wait()
            return Data(#"{"outcome":"promptRequired"}"#.utf8)
        }
        var completed = false
        if forcedQueueItem {
            runner.send(blocks: [.text("redirect")], intent: .auto)
            await runner.flushPersistence()
            runner.forceSendQueuedItem(id: try #require(session.queue.first?.id))
        } else {
            runner.send(blocks: [.text("redirect")], intent: .steer) { _ in completed = true }
        }
        defer { runner.stop()
        Task { await response.open() } }
        try await waitUntil { mock.sent.contains { $0.method == "_session/steering" } }
        await runner.flushPersistence()
        let recovered = try #require(store.loadQueue(sessionId: "s").first)
        #expect(recovered.blocks == [.text("redirect")])
        #expect(recovered.deliveryUncertain)
        #expect(recovered.transcriptRecorded)
        current.set(false)
        runner.stop()
        session.restoreQueue([recovered])
        session.transcript.streamingState = .idle
        let replacementMock = ACPMockClient()
        replacementMock.script(method: "session/prompt") { _ in Data("{}".utf8) }
        let replacement = ACPSessionRunner(session: session, connection: ACPConnection(client: replacementMock),
                                          store: store, sessionId: "s", worktreePath: FileManager.default.temporaryDirectory.path)
        defer { replacement.stop() }
        replacement.flushQueueIfIdle()
        #expect(replacementMock.sent.isEmpty)
        await response.open()
        if !forcedQueueItem { try await waitUntil { completed } }
        #expect(try store.loadQueue(sessionId: "s").first?.id == recovered.id)
        #expect(session.retryQueueItem(id: recovered.id))
        replacement.flushQueueIfIdle()
        try await waitUntil { session.queue.isEmpty }
        #expect(replacementMock.sent.filter { $0.method == "session/prompt" }.count == 1)
        #expect(session.transcript.messages.count == 1)
    }

    @Test("steering recovery binds the recorded row before preparation suspends", arguments: ["checkpoint", "plugin"])
    func steeringRecoveryBindsRowBeforePreparation(stage: String) async throws {
        let preparing = QueueTestGate()
        let release = QueueTestGate()
        let current = ConnectionCurrentFlag(true)
        let (runner, mock, session, store) = try mkRunner(
            isConnectionCurrent: { current.isCurrent },
            pluginContext: { _ in
                if stage == "plugin" { await preparing.open()
                await release.wait() }
                return []
            },
            onCheckpointCapture: { _, _ in
                if stage == "checkpoint" { await preparing.open()
                await release.wait() }
                return nil
            })
        session.supportsSteering = true
        session.transcript.streamingState = .streaming
        var accepted: Bool?
        runner.send(blocks: [.text("redirect")], intent: .steer) { accepted = $0 }
        defer { runner.stop()
        Task { await release.open() } }
        await preparing.wait()
        await runner.flushPersistence()
        let recovered = try #require(store.loadQueue(sessionId: "s").first)
        #expect(recovered.transcriptRecorded)
        #expect(try store.loadMessages(sessionId: "s").filter { $0.kind == "user" }.count == 1)
        #expect(mock.sent.isEmpty)
        current.set(false)
        runner.stop()
        session.restoreQueue([recovered])
        session.transcript.streamingState = .idle
        let replacementMock = ACPMockClient()
        replacementMock.script(method: "session/prompt") { _ in Data("{}".utf8) }
        let replacement = ACPSessionRunner(session: session, connection: ACPConnection(client: replacementMock),
                                          store: store, sessionId: "s", worktreePath: FileManager.default.temporaryDirectory.path)
        defer { replacement.stop() }
        await release.open()
        try await waitUntil { accepted != nil }
        #expect(accepted == true)
        #expect(session.retryQueueItem(id: recovered.id))
        replacement.flushQueueIfIdle()
        try await waitUntil { session.queue.isEmpty }
        await replacement.flushPersistence()
        #expect(try store.loadMessages(sessionId: "s").filter { $0.kind == "user" }.count == 1)
        #expect(session.transcript.messages.count == 1)
    }

    @Test("steering persists a held replay row and its following user row")
    func steeringPersistsUserAfterHeldReplayCandidate() async throws {
        let (runner, mock, session, store) = try mkRunner()
        defer { runner.stop() }
        session.supportsSteering = true
        session.transcript.streamingState = .streaming
        session.transcript.appendMessage(.agent(id: UUID(), messageId: "old", StreamingText("hello there")))
        session.allowsStreamingBoundaryCrossing = false
        session.apply(.agentMessageChunk(.init(messageId: "replay", content: .text("hello"))))
        #expect(session.transcript.messages.count == 1)
        mock.script(method: "_session/steering") { _ in Data(#"{"outcome":"injected"}"#.utf8) }
        var accepted: Bool?
        runner.send(blocks: [.text("redirect")], intent: .steer) { accepted = $0 }
        try await waitUntil { accepted != nil }
        await runner.flushPersistence()
        #expect(accepted == true)
        let rows = try store.loadMessages(sessionId: "s")
        #expect(rows.map(\.kind) == ["agent", "agent", "user"])
        let user = try #require(rows.last)
        guard case .user(_, _, let text, _, _) = try ACPMessageCodec.decode(kind: user.kind, payload: user.payload) else {
            Issue.record("expected the persisted steering user row")
            return
        }
        #expect(text == "redirect")
        #expect(user.seq == 2)
    }

    @Test("a failed steering row transaction preserves replay output and one retryable submission", arguments: [(false, false), (true, false), (false, true)])
    func failedSteeringRowTransactionDoesNotDuplicateRetry(heldReplay: Bool, cancelled: Bool) async throws {
        let (runner, mock, session, store) = try mkRunner()
        let saving = QueueTestGate()
        let release = QueueTestGate()
        defer { runner.stop()
        Task { await release.open() } }
        var paused = false
        runner.beforePersistenceForTesting = {
            if cancelled, !paused, session.transcript.messages.contains(where: { $0.kind == "user" }) {
                paused = true
                await saving.open()
                await release.wait()
            }
        }
        session.supportsSteering = true
        session.transcript.streamingState = .streaming
        let text = StreamingText("working")
        session.transcript.appendMessage(.agent(id: UUID(), messageId: "live", text))
        if heldReplay {
            session.allowsStreamingBoundaryCrossing = false
            session.apply(.agentMessageChunk(.init(messageId: "replay", content: .text("work"))))
        }
        try store.db.exec("""
            CREATE TRIGGER fail_steering_user BEFORE INSERT ON messages
            WHEN NEW.kind = 'user'
            BEGIN SELECT RAISE(ABORT, 'transient row failure'); END;
            """)
        var accepted: Bool?
        runner.send(blocks: [.text("redirect")], intent: .steer) { accepted = $0 }
        if cancelled {
            await saving.wait()
            await runner.userCancel()
            await release.open()
        }
        try await waitUntil { accepted != nil }
        await runner.flushPersistence()
        #expect(accepted == true)
        #expect(session.transcript.messages.filter { $0.kind == "agent" }.count == (heldReplay ? 2 : 1))
        #expect(session.transcript.messages.filter { $0.kind == "user" }.isEmpty)
        #expect(text.metadata == nil)
        let retry = try #require(session.queue.first)
        #expect(!retry.transcriptRecorded)
        #expect(!mock.sent.contains { $0.method == "_session/steering" || $0.method == "session/prompt" })
        #expect(try store.loadMessages(sessionId: "s").filter { $0.kind == "user" }.isEmpty)
        if heldReplay {
            let rows = try store.loadMessages(sessionId: "s")
            let replay = try #require(rows.first { $0.seq == 1 })
            guard case .agent(_, _, let text) = try ACPMessageCodec.decode(kind: replay.kind, payload: replay.payload) else {
                Issue.record("expected the preserved replay output")
                return
            }
            #expect(text.value == "work")
        }
        try store.db.exec("DROP TRIGGER fail_steering_user")
        mock.script(method: "_session/steering") { _ in Data(#"{"outcome":"injected"}"#.utf8) }
        mock.script(method: "session/prompt") { _ in Data("{}".utf8) }
        runner.forceSendQueuedItem(id: retry.id)
        try await waitUntil { session.queue.isEmpty }
        await runner.flushPersistence()
        #expect(session.transcript.messages.filter { $0.kind == "user" }.count == 1)
        #expect(try store.loadMessages(sessionId: "s").filter { $0.kind == "user" }.count == 1)
    }

    @Test("retrying a recorded follow-up requires its steering boundary to be durable")
    func recordedFollowupRequiresDurableSteeringBoundary() async throws {
        let (runner, mock, session, store) = try mkRunner()
        let saving = QueueTestGate()
        let release = QueueTestGate()
        defer { runner.stop()
        Task { await release.open() } }
        session.supportsSteering = true
        session.transcript.streamingState = .streaming
        let previous = StreamingText("earlier")
        session.transcript.appendMessage(.agent(id: UUID(), messageId: "old", previous))
        session.recordUserPrompt(text: "redirect", attachments: [])
        let text = StreamingText("working")
        session.transcript.appendMessage(.agent(id: UUID(), messageId: "live", text))
        runner.persistIndices(Set(session.transcript.messages.indices))
        session.enqueue(blocks: [.text("redirect")])
        session.queue[0].transcriptRecorded = true
        let id = try #require(session.queue.first?.id)
        runner.persistQueue()
        await runner.flushPersistence()
        try store.db.exec("""
            CREATE TRIGGER fail_steering_boundary BEFORE UPDATE ON messages
            WHEN NEW.kind = 'agent'
            BEGIN SELECT RAISE(ABORT, 'boundary save failed'); END;
            """)
        session.allowsStreamingBoundaryCrossing = false
        var paused = false
        runner.beforePersistenceForTesting = {
            if !paused, text.metadata != nil {
                paused = true
                await saving.open()
                await release.wait()
            }
        }
        mock.script(method: "_session/steering") { _ in Data(#"{"outcome":"injected"}"#.utf8) }
        runner.forceSendQueuedItem(id: id)
        await saving.wait()
        runner.applyIncomingUpdateForTesting(.init(sessionId: "s", update: .agentMessageChunk(.init(
            messageId: "old", content: .text(" replay")))))
        await release.open()
        await runner.flushPersistence()
        try await waitUntil { session.queue.isEmpty || session.queue.first?.status == .pending }
        await runner.flushPersistence()
        #expect(!mock.sent.contains { $0.method == "_session/steering" })
        #expect(text.metadata == nil)
        #expect(!session.allowsStreamingBoundaryCrossing)
        #expect(previous.value == "earlier")
        let retry = try #require(session.queue.first)
        #expect(retry.id == id && retry.transcriptRecorded)
        #expect(try store.loadQueue(sessionId: "s").first?.id == id)
        try store.db.exec("DROP TRIGGER fail_steering_boundary")
        runner.forceSendQueuedItem(id: id)
        try await waitUntil { session.queue.isEmpty }
        await runner.flushPersistence()
        #expect(mock.sent.filter { $0.method == "_session/steering" }.count == 1)
        #expect(session.transcript.messages.filter { $0.kind == "user" }.count == 1)
        let row = try #require(store.loadMessages(sessionId: "s").last)
        guard case .agent(_, _, let saved) = try ACPMessageCodec.decode(kind: row.kind, payload: row.payload) else {
            Issue.record("Missing persisted output boundary")
            return
        }
        #expect(saved.metadata != nil)
    }

    @Test("native steering keeps selection ordering through the consuming handoff", arguments: ["injected", "promptRequired", "methodNotFound"])
    func steeringRegistrationFollowsConsumingHandoff(outcome: String) async throws {
        let requested = QueueTestGate()
        let releaseResponse = QueueTestGate()
        let preparing = QueueTestGate()
        let releasePreparation = QueueTestGate()
        let prompted = QueueTestGate()
        let finishPrompt = QueueTestGate()
        var contextCalls = 0
        let (runner, mock, session, _) = try mkRunner(pluginContext: { _ in
            contextCalls += 1
            if contextCalls == 2 {
                await preparing.open()
                await releasePreparation.wait()
            }
            return []
        })
        defer { runner.stop()
        Task { await releaseResponse.open()
        await releasePreparation.open()
        await finishPrompt.open() } }
        session.supportsSteering = true
        session.transcript.streamingState = .streaming
        mock.scriptAsync(method: "_session/steering") { _ in
            await requested.open()
            await releaseResponse.wait()
            if outcome == "methodNotFound" {
                throw ACPClientError.jsonrpc(.init(code: -32601, message: "unsupported", data: nil))
            }
            return Data("{\"outcome\":\"\(outcome)\"}".utf8)
        }
        mock.scriptAsync(method: "session/prompt") { _ in
            await prompted.open()
            await finishPrompt.wait()
            return Data("{}".utf8)
        }
        let registration = DispatchRegistrationFlag()
        runner.sendRegistered(text: "redirect", attachments: [], intent: .steer,
                              onDispatchRegistered: { registration.markRegistered() })
        await requested.wait()
        #expect(!registration.isRegistered)
        await releaseResponse.open()
        if outcome != "injected" {
            await preparing.wait()
            #expect(!registration.isRegistered)
            await releasePreparation.open()
            await prompted.wait()
        }
        try await waitUntil { registration.isRegistered }
        #expect(mock.sent.filter { $0.method == "session/prompt" }.count == (outcome == "injected" ? 0 : 1))
    }

    @Test("a second steer stays queued until the owned continuation reaches handoff")
    func secondSteerWaitsForContinuationHandoff() async throws {
        var steeringReturned = false
        var continuationChecks = 0
        let preparing = QueueTestGate()
        let releaseLease = QueueTestGate()
        let releasePrompt = QueueTestGate()
        let (runner, mock, session, _) = try mkRunner(validateLease: {
            if steeringReturned {
                continuationChecks += 1
                if continuationChecks == 3 {
                    await preparing.open()
                    await releaseLease.wait()
                }
            }
            return true
        })
        session.supportsSteering = true
        session.transcript.streamingState = .streaming
        mock.script(method: "_session/steering") { _ in
            steeringReturned = true
            return Data(#"{"outcome":"promptRequired"}"#.utf8)
        }
        mock.scriptAsync(method: "session/prompt") { _ in
            await releasePrompt.wait()
            return Data("{}".utf8)
        }
        defer { runner.stop()
        Task { await releaseLease.open()
        await releasePrompt.open() } }
        runner.send(blocks: [.text("first")], intent: .steer)
        await preparing.wait()
        var secondAccepted: Bool?
        runner.send(blocks: [.text("second")], intent: .steer) { secondAccepted = $0 }
        try await waitUntil { secondAccepted == true || mock.sent.filter { $0.method == "_session/steering" }.count > 1 }
        #expect(mock.sent.filter { $0.method == "_session/steering" }.count == 1)
        #expect(secondAccepted == true)
        await releaseLease.open()
        await releasePrompt.open()
        try await waitUntil { session.queue.isEmpty }
        #expect(mock.sent.compactMap { ($0.params as? ACPSessionPromptParams)?.prompt } == [[.text("first")], [.text("second")]])
    }

    @Test("a late steering response cannot restart a stopped runner")
    func lateSteeringResponseCannotRestartStoppedRunner() async throws {
        let (runner, mock, session, _) = try mkRunner()
        session.supportsSteering = true
        let started = QueueTestGate()
        let finishOriginal = QueueTestGate()
        let finishSteering = QueueTestGate()
        mock.scriptAsync(method: "session/prompt") { _ in
            await started.open()
            await finishOriginal.wait()
            return Data("{}".utf8)
        }
        mock.scriptAsync(method: "_session/steering") { _ in
            await finishSteering.wait()
            return Data(#"{"outcome":"promptRequired"}"#.utf8)
        }
        defer { runner.stop()
        Task { await finishOriginal.open()
        await finishSteering.open() } }
        runner.send(blocks: [.text("running")], intent: .auto)
        await started.wait()
        session.transcript.streamingState = .streaming
        var accepted: Bool?
        runner.send(blocks: [.text("redirect")], intent: .steer) { accepted = $0 }
        try await waitUntil { mock.sent.contains { $0.method == "_session/steering" } }
        runner.invalidateActivePrompt()
        runner.stop()
        await finishSteering.open()
        try await waitUntil { accepted != nil }
        #expect(accepted == true)
        #expect(session.queue.first?.deliveryUncertain == true)
        #expect(mock.sent.filter { $0.method == "session/prompt" }.count == 1)
        #expect(session.lastError == nil)
    }

    @Test("method-not-found falls back without duplicating the follow-up")
    func unsupportedSteeringFallsBackWithoutDuplicateUserRow() async throws {
        let (runner, mock, session, _) = try mkRunner()
        session.supportsSteering = true
        let started = QueueTestGate()
        let finishOriginal = QueueTestGate()
        mock.scriptAsync(method: "session/prompt") { request in
            if (request.params as? ACPSessionPromptParams)?.prompt == [.text("running")] {
                await started.open()
                await finishOriginal.wait()
            }
            return Data("{}".utf8)
        }
        mock.scriptNotifyAsync(method: "session/cancel") { _ in await finishOriginal.open() }
        mock.script(method: "_session/steering") { _ in
            throw ACPClientError.jsonrpc(.init(code: -32601, message: "Method not found", data: nil))
        }
        defer { runner.stop()
        Task { await finishOriginal.open() } }
        runner.send(blocks: [.text("running")], intent: .auto)
        await started.wait()
        session.transcript.streamingState = .streaming
        runner.send(blocks: [.text("tail")], intent: .auto)
        await runner.flushPersistence()
        var accepted: Bool?
        runner.send(blocks: [.text("redirect")], intent: .steer) { accepted = $0 }
        try await waitUntil { accepted != nil }
        #expect(accepted == true)
        try await waitUntil { session.queue.isEmpty }
        #expect(!session.supportsSteering)
        #expect(mock.sent.contains { $0.method == "session/cancel" })
        #expect(mock.sent.compactMap { ($0.params as? ACPSessionPromptParams)?.prompt } == [[.text("running")], [.text("redirect")], [.text("tail")]])
        #expect(session.transcript.messages.filter { if case .user(_, _, "redirect", _, _) = $0 { return true }
        return false }.count == 1)
    }

    @Test("Send now during native steering takes priority over the queued tail")
    func forceSendDuringNativeSteeringPrecedesQueuedTail() async throws {
        let (runner, mock, session, _) = try mkRunner()
        session.supportsSteering = true
        let started = QueueTestGate()
        let finishOriginal = QueueTestGate()
        let finishSteering = QueueTestGate()
        var originalFinished = false
        mock.scriptAsync(method: "session/prompt") { request in
            if (request.params as? ACPSessionPromptParams)?.prompt == [.text("running")] {
                await started.open()
                await finishOriginal.wait()
            }
            return Data("{}".utf8)
        }
        mock.scriptAsync(method: "_session/steering") { request in
            if (request.params as? ACPSteeringParams)?.prompt == [.text("redirect")] {
                await finishSteering.wait()
                return Data(#"{"outcome":"injected"}"#.utf8)
            }
            return Data(#"{"outcome":"promptRequired"}"#.utf8)
        }
        defer { runner.stop()
        Task { await finishOriginal.open()
        await finishSteering.open() } }
        runner.send(blocks: [.text("running")], intent: .auto) { originalFinished = $0 }
        await started.wait()
        session.transcript.streamingState = .streaming
        runner.send(blocks: [.text("tail")], intent: .auto)
        runner.send(blocks: [.text("selected")], intent: .auto)
        await runner.flushPersistence()
        let selectedID = try #require(session.queue.last?.id)
        runner.send(blocks: [.text("redirect")], intent: .steer)
        try await waitUntil { mock.sent.contains { $0.method == "_session/steering" } }
        runner.forceSendQueuedItem(id: selectedID)
        await finishOriginal.open()
        try await waitUntil { originalFinished }
        await finishSteering.open()
        try await waitUntil { session.queue.isEmpty && mock.sent.filter { $0.method == "session/prompt" }.count >= 2 }
        #expect(mock.sent.compactMap { ($0.params as? ACPSessionPromptParams)?.prompt } == [[.text("running")], [.text("selected")], [.text("tail")]])
        #expect(!mock.sent.contains { $0.method == "session/cancel" })
    }

    @Test("idle Stop reaches a child-owned background task without cancelling a foreground turn", arguments: ["true", "false", "error", "lease-denied"])
    func idleBackgroundStop(result: String) async throws {
        let (runner, mock, session, _) = try mkRunner(validateLease: { result != "lease-denied" })
        session.remoteSessionId = "remote-root"
        session.backgroundTaskStopSupported = true
        session.applyBackgroundTask(.init(sessionUpdate: "async_task_spawned", asyncTaskId: "job",
            name: "Monitor", canStop: true), ownerSessionId: "native-child")
        mock.script(method: "_session/async_task/stop") { request in
            guard let requestParams = request.params else { throw CocoaError(.coderInvalidValue) }
            let data = try JSONEncoder().encode(requestParams)
            let params = try JSONSerialization.jsonObject(with: data) as? [String: String]
            #expect(params == ["sessionId": "remote-root", "asyncTaskId": "job"])
            if result == "error" { throw ACPClientError.notRunning }
            return Data("{\"stopped\":\(result)}".utf8)
        }
        #expect(await runner.userCancel() == ["true", "false"].contains(result))
        await runner.flushPersistence()
        #expect(mock.sent.map(\.method) == (result == "lease-denied" ? [] : ["_session/async_task/stop"]))
        #expect(session.backgroundTasks[0].isActive == (result != "true"))
        #expect((session.backgroundTasks[0].stopError != nil) == ["false", "error"].contains(result))
        #expect(session.transcript.streamingState == .idle)
    }

    @Test("background completion wakes precede future schedules without overtaking ordinary prompts", arguments: [false, true])
    func backgroundWakesPrecedeScheduledPrompts(ordinaryPrompt: Bool) async throws {
        let (runner, mock, session, store) = try mkRunner(agentID: "codex")
        defer { runner.stop() }
        session.transcript.streamingState = .awaitingPermission
        let scheduledID = session.enqueueScheduled(blocks: [.text("Scheduled")], scheduledAt: Date().addingTimeInterval(3600))
        let ordinaryID = UUID()
        if ordinaryPrompt { session.enqueue(id: ordinaryID, blocks: [.text("Ordinary")]) }
        mock.script(method: "session/prompt") { _ in Data("{}".utf8) }
        runner.applyIncomingUpdateForTesting(.init(sessionId: "s", update: .asyncTask(.init(
            sessionUpdate: "async_task_state_update", asyncTaskId: "job", state: "completed"))))
        await runner.flushPersistence()
        let wake = try #require(session.queue.first(where: { $0.backgroundTaskWake != nil }))
        let expectedIDs = (ordinaryPrompt ? [ordinaryID] : []) + [wake.id, scheduledID]
        try #require(session.queue.map(\.id) == expectedIDs)
        #expect(try store.loadQueue(sessionId: "s") == session.queue)
        session.transcript.streamingState = .idle
        runner.flushQueueIfIdle()
        try await waitUntil { session.backgroundTasks[0].wakeDelivered }
        await runner.flushPersistence()
        #expect(session.queue.map(\.id) == [scheduledID])
        #expect(try store.loadQueue(sessionId: "s") == session.queue)
        let prompts = mock.sent.compactMap { ($0.params as? ACPSessionPromptParams)?.prompt }
        #expect(prompts == (ordinaryPrompt ? [[.text("Ordinary")]] : []) + [wake.blocks])
    }

    @Test("Codex completion enriches pending wakes and delivers corrected results once after prior delivery", arguments: [("completed", "summary"), ("failed", "state"), ("completed", "output")])
    func backgroundCompletionQueue(finalState: String, correction: String) async throws {
        let (runner, mock, session, store) = try mkRunner(agentID: "codex")
        session.transcript.streamingState = .awaitingPermission
        mock.script(method: "session/prompt") { _ in Data("{}".utf8) }
        runner.start()
        defer { runner.stop() }
        let spawn = ACPAsyncTaskUpdate(sessionUpdate: "async_task_spawned", asyncTaskId: "job", name: "Tests", canStop: true)
        let done = ACPAsyncTaskUpdate(sessionUpdate: "async_task_state_update", asyncTaskId: "job", state: "completed", summary: "Passed")
        mock.emit(.init(sessionId: "s", update: .asyncTask(spawn)))
        mock.emit(.init(sessionId: "s", update: .asyncTask(done)))
        mock.emit(.init(sessionId: "s", update: .asyncTask(done)))
        try await waitUntil { session.queue.count == 1 }
        await runner.flushPersistence()
        #expect(mock.sent.isEmpty)
        #expect(!session.queue[0].isShownToUser)
        #expect(try store.loadQueue(sessionId: "s") == session.queue)
        let queuedID = session.queue[0].id
        let enqueuedAt = session.queue[0].enqueuedAt
        let corrected = ACPAsyncTaskUpdate(sessionUpdate: "async_task_state_update", asyncTaskId: "job",
            state: finalState, summary: "Final result")
        mock.emit(.init(sessionId: "s", update: .asyncTask(corrected)))
        try await waitUntil { session.backgroundTasks.first?.summary == "Final result" }
        await runner.flushPersistence()
        #expect(session.queue[0].id == queuedID)
        #expect(session.queue[0].enqueuedAt == enqueuedAt)
        guard case .text(let pendingText) = session.queue[0].blocks.first else { throw CocoaError(.coderInvalidValue) }
        let facts = try JSONDecoder().decode(ACPBackgroundTask.self, from: Data(try #require(pendingText.split(separator: "\n").last).utf8))
        #expect(facts.state == finalState)
        #expect(facts.summary == "Final result")
        #expect(try store.loadQueue(sessionId: "s") == session.queue)
        session.transcript.streamingState = .idle
        runner.flushQueueIfIdle()
        try await waitUntil { session.backgroundTasks.first?.wakeDelivered == true && session.queue.isEmpty }
        await runner.flushPersistence()
        #expect(mock.sent.filter { $0.method == "session/prompt" }.count == 1)
        #expect(mock.sent.compactMap { ($0.params as? ACPSessionPromptParams)?.prompt } == [[.text(pendingText)]])
        #expect(session.transcript.messages.count == 1)
        let restored = ACPSession(id: "s", agentId: "codex", worktreeId: "wt", title: "t")
        let persisted = try #require(store.loadMessages(sessionId: "s").first)
        restored.restoreBackgroundTasks(rows: [try JSONDecoder().decode(ACPMessage.ToolCall.self, from: persisted.payload)])
        #expect(restored.backgroundTasks.first?.wakeDelivered == true)
        session.applyBackgroundTask(spawn, ownerSessionId: "s")
        session.applyBackgroundTask(corrected, ownerSessionId: "s")
        await runner.reconcileBackgroundTasks(adapterSurvived: true, previousTaskIds: [])
        await runner.flushPersistence()
        #expect(session.queue.isEmpty)
        #expect(mock.sent.count == 1)

        session.transcript.streamingState = .awaitingPermission
        var amendment = ACPAsyncTaskUpdate(sessionUpdate: "async_task_state_update", asyncTaskId: "job")
        switch correction {
        case "state": amendment.state = "completed"
        case "summary": amendment.summary = "Amended result"
        default: amendment.outputFilePath = "/tmp/amended-output"
        }
        let params = ACPSessionUpdateParams(sessionId: "s", update: .asyncTask(amendment))
        runner.applyIncomingUpdateForTesting(params)
        await runner.flushPersistence()
        let correctionID = try #require(session.backgroundTasks[0].wakeId)
        #expect(correctionID != queuedID)
        #expect(session.backgroundTasks[0].needsWake)
        #expect(session.queue.map(\.id) == [correctionID])
        #expect(try store.loadQueue(sessionId: "s") == session.queue)
        let pendingTask = session.backgroundTasks[0]
        let correctionEnqueuedAt = session.queue.first?.enqueuedAt
        runner.applyIncomingUpdateForTesting(params)
        await runner.flushPersistence()
        #expect(session.backgroundTasks[0] == pendingTask)
        #expect(session.queue.map(\.id) == [correctionID])
        #expect(session.queue.first?.enqueuedAt == correctionEnqueuedAt)
        #expect(mock.sent.count == 1)
        session.transcript.streamingState = .idle
        runner.flushQueueIfIdle()
        try await waitUntil { session.queue.isEmpty && session.backgroundTasks[0].wakeDelivered }
        await runner.flushPersistence()
        #expect(mock.sent.filter { $0.method == "session/prompt" }.count == 2)
        runner.applyIncomingUpdateForTesting(params)
        await runner.flushPersistence()
        #expect(session.backgroundTasks[0].wakeId == correctionID)
        #expect(session.queue.isEmpty)
        #expect(mock.sent.filter { $0.method == "session/prompt" }.count == 2)
    }

    @Test("unchanged task replay repairs a failed write before acknowledgement", arguments: [false, true])
    func backgroundReplayRepairsFailedWrite(repairBeforeReplay: Bool) async throws {
        let (runner, _, session, store) = try mkRunner(agentID: "codex")
        session.transcript.streamingState = .awaitingPermission
        runner.applyIncomingUpdateForTesting(.init(sessionId: "s", update: .asyncTask(.init(
            sessionUpdate: "async_task_spawned", asyncTaskId: "job", name: "Tests"))))
        await runner.flushPersistence()
        try store.db.exec("""
        CREATE TRIGGER reject_background_state BEFORE UPDATE OF payload ON messages
        WHEN CAST(NEW.payload AS TEXT) LIKE '%"state":"completed"%'
        BEGIN SELECT RAISE(ABORT, 'task write failed'); END;
        """)
        let acknowledgement = DurableAcknowledgementRecorder()
        let done = ACPSessionUpdateParams(sessionId: "s", update: .asyncTask(.init(
            sessionUpdate: "async_task_state_update", asyncTaskId: "job", state: "completed", summary: "Passed")),
            durableConsumptionAcknowledgement: { acknowledgement.record() })
        runner.applyIncomingUpdateForTesting(done)
        await runner.flushPersistence()
        #expect(acknowledgement.recordedCount == 0)
        #expect(session.queue.isEmpty)
        let wakeID = try #require(session.backgroundTasks.first?.wakeId)
        if repairBeforeReplay { try store.db.exec("DROP TRIGGER reject_background_state") }
        runner.applyIncomingUpdateForTesting(done)
        await runner.flushPersistence()
        if !repairBeforeReplay {
            #expect(acknowledgement.recordedCount == 0)
            #expect(session.queue.isEmpty)
            let row = try #require(store.loadMessages(sessionId: "s").first)
            let task = try #require(ACPBackgroundTask(toolCall: JSONDecoder().decode(ACPMessage.ToolCall.self, from: row.payload)))
            #expect(task.state == "running")
            try store.db.exec("DROP TRIGGER reject_background_state")
            runner.applyIncomingUpdateForTesting(done)
            await runner.flushPersistence()
        }
        #expect(acknowledgement.recordedCount == 1)
        #expect(session.queue.map(\.id) == [wakeID])
        #expect(try store.loadQueue(sessionId: "s") == session.queue)
        let row = try #require(store.loadMessages(sessionId: "s").first)
        let restoredTask = try #require(ACPBackgroundTask(toolCall: JSONDecoder().decode(ACPMessage.ToolCall.self, from: row.payload)))
        #expect(restoredTask.state == "completed" && restoredTask.wakeId == wakeID && restoredTask.needsWake)
        runner.applyIncomingUpdateForTesting(done)
        await runner.flushPersistence()
        #expect(acknowledgement.recordedCount == 2)
        #expect(session.queue.map(\.id) == [wakeID])
    }

    @Test("force-sent background wakes confirm delivery atomically through steering and fallback", arguments: [("injected", true), ("startedNewTurn", true), ("promptRequired", true), ("unsupported", true), ("fallback", true), ("injected", false), ("promptRequired", false), ("fallback", false)])
    func forcedBackgroundWakeConfirmsDelivery(outcome: String, committed: Bool) async throws {
        let (runner, mock, session, store) = try mkRunner(agentID: "codex")
        session.transcript.streamingState = .awaitingPermission
        session.applyBackgroundTask(.init(sessionUpdate: "async_task_state_update", asyncTaskId: "job",
            state: "completed", summary: "Result"), ownerSessionId: "s")
        runner.start()
        defer { runner.stop() }
        await runner.reconcileBackgroundTasks(adapterSurvived: true, previousTaskIds: [])
        await runner.flushPersistence()
        let wakeID = try #require(session.queue.first?.id)
        session.queue[0].lastError = "Retry required"
        session.queue[0].deliveryUncertain = true
        session.supportsSteering = outcome != "fallback"
        session.transcript.streamingState = .streaming
        let acknowledgement = DurableAcknowledgementRecorder()
        mock.scriptResponse(method: "_session/steering") { _ in
            if outcome == "unsupported" {
                throw ACPClientError.jsonrpc(.init(code: -32601, message: "Method not found", data: nil))
            }
            return ACPResponse(body: Data("{\"outcome\":\"\(outcome)\"}".utf8),
                               durableConsumptionAcknowledgement: { acknowledgement.record() })
        }
        mock.scriptResponse(method: "session/prompt") { _ in
            ACPResponse(body: Data("{}".utf8), durableConsumptionAcknowledgement: { acknowledgement.record() })
        }
        if !committed { try rejectWakeDeliveryWrites(in: store) }
        runner.forceSendQueuedItem(id: wakeID)
        try await waitUntil {
            if committed { return !session.queue.contains { $0.id == wakeID } }
            return session.queue.first?.lastError?.contains("save background work delivery confirmation") == true
        }
        await runner.flushPersistence()
        #expect(session.backgroundTasks[0].wakeDelivered == committed)
        #expect(try store.loadQueue(sessionId: "s") == session.queue)
        #expect(acknowledgement.recordedCount == (committed ? (outcome == "promptRequired" ? 2 : 1) : 0))
        let restored = ACPSession(id: "s", agentId: "codex", worktreeId: "wt", title: "t")
        restored.restoreBackgroundTasks(rows: try store.loadMessages(sessionId: "s").compactMap {
            try? JSONDecoder().decode(ACPMessage.ToolCall.self, from: $0.payload)
        })
        #expect(restored.backgroundTasks.first?.wakeDelivered == committed)
        let queueBeforeReplay = session.queue
        let requestsBeforeReplay = mock.sent.count
        await runner.reconcileBackgroundTasks(adapterSurvived: true, previousTaskIds: [])
        await runner.flushPersistence()
        #expect(session.queue == queueBeforeReplay)
        #expect(mock.sent.count == requestsBeforeReplay)
    }

    @Test("fallback steering confirms an interrupted background wake or retains its failed confirmation", arguments: [(false, false), (true, false), (false, true), (true, true)])
    func fallbackSteeringRetainsInterruptedBackgroundWake(committed: Bool, nativeUnsupported: Bool) async throws {
        let (runner, mock, session, store) = try mkRunner(agentID: "codex")
        session.transcript.streamingState = .awaitingPermission
        session.supportsSteering = nativeUnsupported
        session.applyBackgroundTask(.init(sessionUpdate: "async_task_state_update", asyncTaskId: "job",
            state: "completed", summary: "Result"), ownerSessionId: "s")
        let probe = StrictSingleFlightPromptProbe()
        mock.scriptAsync(method: "session/prompt") { _ in try await probe.send() }
        mock.scriptNotifyAsync(method: "session/cancel") { _ in await probe.releaseFirst() }
        mock.script(method: "_session/steering") { _ in
            throw ACPClientError.jsonrpc(.init(code: -32601, message: "Method not found", data: nil))
        }
        runner.start()
        defer {
            runner.stop()
            Task { await probe.releaseFirst() }
        }
        await runner.reconcileBackgroundTasks(adapterSurvived: true, previousTaskIds: [])
        await runner.flushPersistence()
        let wakeID = try #require(session.queue.first?.id)
        if !committed { try rejectWakeDeliveryWrites(in: store) }
        session.transcript.streamingState = .idle
        runner.flushQueueIfIdle()
        await probe.waitUntilFirstStarted()
        session.transcript.streamingState = .streaming
        session.enqueue(blocks: [.text("Selected prompt")])
        let selectedID = try #require(session.queue.last?.id)
        runner.persistQueue()
        await runner.flushPersistence()
        runner.forceSendQueuedItem(id: selectedID)
        try await waitUntil {
            mock.sent.filter { $0.method == "session/prompt" }.count == 2
                && session.transcript.streamingState == .idle
        }
        await runner.flushPersistence()
        #expect(mock.sent.filter { $0.method == "_session/steering" }.count == (nativeUnsupported ? 1 : 0))
        #expect(session.backgroundTasks[0].wakeDelivered == committed)
        #expect(try store.loadQueue(sessionId: "s") == session.queue)
        let row = try #require(store.loadMessages(sessionId: "s").first)
        let task = try #require(ACPBackgroundTask(toolCall: JSONDecoder().decode(ACPMessage.ToolCall.self, from: row.payload)))
        #expect(task.wakeDelivered == committed)
        if committed {
            #expect(session.queue.isEmpty)
        } else {
            let held = try #require(session.queue.first)
            #expect(session.queue.count == 1 && held.id == wakeID)
            #expect(held.status == .pending && held.lastError != nil && held.deliveryUncertain)
        }
        #expect(session.transcript.messages.compactMap { message -> String? in
            if case .user(_, _, let text, _, _) = message { return text }
            return nil
        } == ["Selected prompt"])
        let beforeReplay = session.queue
        await runner.reconcileBackgroundTasks(adapterSurvived: true, previousTaskIds: [])
        await runner.flushPersistence()
        #expect(session.queue == beforeReplay)
        #expect(await probe.callCount == 2)
    }

    @Test("a failed delivery transaction retains a visible background wake without automatic replay", arguments: ["completed", "cancelled", "cancelDuringConfirmation", "corrected"])
    func backgroundDeliveryPersistenceFailure(outcome: String) async throws {
        let (runner, mock, session, store) = try mkRunner(agentID: "codex")
        session.transcript.streamingState = .awaitingPermission
        let probe = StrictSingleFlightPromptProbe()
        let confirmationStarted = QueueTestGate()
        let releaseConfirmation = QueueTestGate()
        var heldConfirmation = false
        runner.beforePersistenceForTesting = {
            if outcome == "cancelDuringConfirmation", !heldConfirmation, session.backgroundTasks.first?.wakeDelivered == true {
                heldConfirmation = true
                await confirmationStarted.open()
                await releaseConfirmation.wait()
            }
        }
        mock.scriptAsync(method: "session/prompt") { _ in try await probe.send() }
        session.applyBackgroundTask(.init(sessionUpdate: "async_task_state_update", asyncTaskId: "job",
            state: "completed", summary: "Result"), ownerSessionId: "s")
        runner.start()
        defer { runner.stop() }
        await runner.reconcileBackgroundTasks(adapterSurvived: true, previousTaskIds: [])
        await runner.flushPersistence()
        let wakeID = try #require(session.queue.first?.id)
        if outcome == "corrected" {
            try store.db.exec("""
            CREATE TRIGGER reject_wake_delivery BEFORE UPDATE OF payload ON messages
            WHEN CAST(NEW.payload AS TEXT) LIKE '%"state":"failed"%'
            BEGIN SELECT RAISE(ABORT, 'correction write failed'); END;
            """)
        } else {
            try rejectWakeDeliveryWrites(in: store)
        }
        session.transcript.streamingState = .idle
        runner.flushQueueIfIdle()
        await probe.waitUntilFirstStarted()
        if outcome == "corrected" {
            runner.applyIncomingUpdateForTesting(.init(sessionId: "s", update: .asyncTask(.init(
                sessionUpdate: "async_task_state_update", asyncTaskId: "job", state: "failed", summary: "Correction"))))
            await runner.flushPersistence()
            #expect(session.backgroundTasks[0].wakeId != wakeID)
        }
        if outcome == "cancelled" { await runner.userCancel() }
        await probe.releaseFirst()
        if outcome == "cancelDuringConfirmation" {
            await confirmationStarted.wait()
            await runner.userCancel()
            await releaseConfirmation.open()
        }
        try await waitUntil { session.transcript.streamingState == .idle }
        await runner.flushPersistence()
        #expect(session.backgroundTasks[0].needsWake)
        let held = try #require(session.queue.first)
        #expect(held.id == wakeID)
        #expect(held.status == .pending)
        #expect(held.lastError != nil && held.deliveryUncertain && held.isShownToUser)
        #expect(try store.loadQueue(sessionId: "s") == [held])
        try store.db.exec("DROP TRIGGER reject_wake_delivery")
        runner.persistQueue()
        await runner.reconcileBackgroundTasks(adapterSurvived: true, previousTaskIds: [])
        await runner.flushPersistence()
        #expect(session.queue.first == held)
        #expect(session.queue.count == (outcome == "corrected" ? 2 : 1))
        #expect(try store.loadQueue(sessionId: "s") == session.queue)
        #expect(await probe.callCount == 1)
    }

    @Test("queue snapshots behind wake confirmation preserve its outcome and later prompts", arguments: [(true, "queued"), (false, "queued"), (true, "scheduled"), (false, "scheduled"), (true, "stopped"), (false, "stopped"), (true, "callback")])
    func backgroundConfirmationPreservesLaterQueueSnapshots(committed: Bool, action: String) async throws {
        var enqueueDuringConfirmation: (() -> Void)?
        let (runner, mock, session, store) = try mkRunner(agentID: "codex", onPersist: { enqueueDuringConfirmation?() })
        session.transcript.streamingState = .awaitingPermission
        session.applyBackgroundTask(.init(sessionUpdate: "async_task_state_update", asyncTaskId: "job",
            state: "completed"), ownerSessionId: "s")
        mock.script(method: "session/prompt") { _ in Data("{}".utf8) }
        let confirmationStarted = QueueTestGate()
        let releaseConfirmation = QueueTestGate()
        var heldConfirmation = false
        runner.beforePersistenceForTesting = {
            if !heldConfirmation, session.backgroundTasks[0].wakeDelivered {
                heldConfirmation = true
                await confirmationStarted.open()
                await releaseConfirmation.wait()
            }
        }
        runner.start()
        defer {
            runner.stop()
            Task { await releaseConfirmation.open() }
        }
        await runner.reconcileBackgroundTasks(adapterSurvived: true, previousTaskIds: [])
        await runner.flushPersistence()
        let wakeID = try #require(session.queue.first?.id)
        if !committed { try rejectWakeDeliveryWrites(in: store) }
        session.transcript.streamingState = .idle
        runner.flushQueueIfIdle()
        await confirmationStarted.wait()
        session.transcript.streamingState = .awaitingPermission
        var laterID: UUID?
        let enqueueLater = {
            runner.send(blocks: [.text("Later prompt")], intent: action == "scheduled"
                ? .schedule(Date().addingTimeInterval(3600)) : .auto)
            laterID = session.queue.last?.id
        }
        if action == "callback" {
            enqueueDuringConfirmation = {
                enqueueDuringConfirmation = nil
                enqueueLater()
            }
        } else {
            enqueueLater()
        }
        if action == "stopped" { runner.stop() }
        await releaseConfirmation.open()
        await runner.flushPersistence()
        let savedLaterID = try #require(laterID)
        #expect(savedLaterID != wakeID)
        #expect(session.backgroundTasks[0].wakeDelivered == committed)
        #expect(session.queue.map(\.id) == (committed ? [savedLaterID] : [wakeID, savedLaterID]))
        #expect(try store.loadQueue(sessionId: "s") == session.queue)
        if !committed {
            #expect(session.queue[0].status == .pending && session.queue[0].deliveryUncertain)
            #expect(session.queue[0].lastError != nil)
        }
        #expect(mock.sent.filter { $0.method == "session/prompt" }.count == 1)
    }

    @Test("wake confirmation reconciles teardown without consuming a newer retry", arguments: [(true, "stopped"), (true, "replaced"), (true, "retried"), (false, "stopped"), (false, "replaced")])
    func backgroundConfirmationReconcilesTeardown(committed: Bool, outcome: String) async throws {
        let current = ConnectionCurrentFlag(true)
        let (runner, mock, session, store) = try mkRunner(agentID: "codex", isConnectionCurrent: { current.isCurrent })
        let acknowledgement = DurableAcknowledgementRecorder()
        mock.scriptResponse(method: "session/prompt") { _ in
            ACPResponse(body: Data("null".utf8), durableConsumptionAcknowledgement: { acknowledgement.record() })
        }
        session.transcript.streamingState = .awaitingPermission
        session.applyBackgroundTask(.init(sessionUpdate: "async_task_state_update", asyncTaskId: "job", state: "completed"), ownerSessionId: "s")
        let confirmationStarted = QueueTestGate()
        let releaseConfirmation = QueueTestGate()
        var heldConfirmation = false
        runner.beforePersistenceForTesting = {
            if !heldConfirmation, session.backgroundTasks.first?.wakeDelivered == true {
                heldConfirmation = true
                await confirmationStarted.open()
                await releaseConfirmation.wait()
            }
        }
        runner.start()
        defer { runner.stop() }
        await runner.reconcileBackgroundTasks(adapterSurvived: true, previousTaskIds: [])
        await runner.flushPersistence()
        if !committed {
            try rejectWakeDeliveryWrites(in: store)
        }
        session.transcript.streamingState = .idle
        runner.flushQueueIfIdle()
        await confirmationStarted.wait()
        if outcome == "replaced" { current.set(false) } else { runner.stop() }
        session.restoreQueue(session.queue, markLegacySendingUncertain: true)
        if outcome == "retried" { session.queue[0].brokerOperationAttempt += 1 }
        let restoredQueue = session.queue
        await releaseConfirmation.open()
        await runner.flushPersistence()
        #expect(acknowledgement.recordedCount == (committed ? 1 : 0))
        #expect(try store.loadQueue(sessionId: "s").isEmpty == committed)
        if committed {
            #expect(session.queue == (outcome == "retried" ? restoredQueue : []))
        } else {
            #expect(session.backgroundTasks[0].needsWake)
            #expect(session.queue.first?.lastError?.contains("save") == true)
            #expect(session.queue.first?.deliveryUncertain == true)
        }
        #expect(mock.sent.filter { $0.method == "session/prompt" }.count == 1)
    }

    @Test("task corrections preserve dispatched and retry-held notification snapshots", arguments: ["sending", "failed", "uncertain"])
    func backgroundCorrectionPreservesDeliverySnapshot(delivery: String) async throws {
        let (runner, mock, session, store) = try mkRunner(agentID: "codex")
        session.transcript.streamingState = .awaitingPermission
        session.applyBackgroundTask(.init(sessionUpdate: "async_task_state_update", asyncTaskId: "job",
            state: "completed", summary: "Original result"), ownerSessionId: "s")
        runner.start()
        let probe = StrictSingleFlightPromptProbe()
        mock.scriptAsync(method: "session/prompt") { _ in try await probe.send() }
        defer {
            runner.stop()
            Task { await probe.releaseFirst() }
        }
        await runner.reconcileBackgroundTasks(adapterSurvived: true, previousTaskIds: [])
        await runner.flushPersistence()
        if delivery == "sending" {
            session.transcript.streamingState = .idle
            runner.flushQueueIfIdle()
            await probe.waitUntilFirstStarted()
        } else {
            session.queue[0].lastError = delivery == "failed" ? "Retry required" : nil
            if delivery == "uncertain" { session.queue[0].markDeliveryUncertain() }
            runner.persistQueue()
        }
        await runner.flushPersistence()
        let original = session.queue[0]
        mock.emit(.init(sessionId: "s", update: .asyncTask(.init(
            sessionUpdate: "async_task_state_update", asyncTaskId: "job", state: "failed", summary: "Corrected result"))))
        try await waitUntil { session.backgroundTasks.first?.summary == "Corrected result" }
        await runner.flushPersistence()
        #expect(session.queue.first == original)
        #expect(session.queue.count == 2)
        #expect(session.backgroundTasks[0].wakeId != original.id)
        #expect(try store.loadQueue(sessionId: "s") == session.queue)
        if delivery == "sending" {
            await probe.releaseFirst()
            try await waitUntil { session.queue.isEmpty && session.backgroundTasks[0].wakeDelivered }
            await runner.flushPersistence()
            #expect(await probe.callCount == 2)
            let sentStates = try mock.sent.compactMap { request -> String? in
                guard let params = request.params as? ACPSessionPromptParams,
                      case .text(let text) = params.prompt.first else { return nil }
                let facts = Data(try #require(text.split(separator: "\n").last).utf8)
                return try JSONDecoder().decode(ACPBackgroundTask.self, from: facts).state
            }
            #expect(sentStates == ["completed", "failed"])
        } else {
            #expect(mock.sent.isEmpty)
        }
    }

    @Test("reobserved work retires clean pending loss wakes and preserves retry-held snapshots", arguments: [("async_task_spawned", "pending"), ("async_task_progress", "pending"), ("async_task_progress", "failed"), ("async_task_progress", "uncertain")])
    func reobservationRetiresPendingLossWake(update: String, delivery: String) async throws {
        let (runner, mock, session, store) = try mkRunner(agentID: "codex")
        session.transcript.streamingState = .awaitingPermission
        var task = ACPBackgroundTask(ownerSessionId: "s", asyncTaskId: "watch", name: "Watch")
        task.loseObservation()
        session.saveBackgroundTask(task)
        runner.start()
        defer { runner.stop() }
        await runner.reconcileBackgroundTasks(adapterSurvived: true, previousTaskIds: [])
        await runner.flushPersistence()
        session.queue[0].lastError = delivery == "failed" ? "Retry required" : nil
        if delivery == "uncertain" { session.queue[0].markDeliveryUncertain() }
        let loss = session.queue[0]
        runner.persistQueue()
        await runner.flushPersistence()
        mock.emit(.init(sessionId: "s", update: .asyncTask(.init(
            sessionUpdate: update, asyncTaskId: "watch"))))
        try await waitUntil { session.backgroundTasks[0].isActive }
        await runner.flushPersistence()
        #expect(!session.backgroundTasks[0].needsWake)
        #expect(session.queue == (delivery == "pending" ? [] : [loss]))
        #expect(try store.loadQueue(sessionId: "s") == session.queue)
        if delivery == "pending" {
            session.queue = [loss]
            runner.persistQueue()
            await runner.flushPersistence()
        }
        await runner.reconcileBackgroundTasks(adapterSurvived: true, previousTaskIds: [])
        await runner.flushPersistence()
        #expect(session.queue == (delivery == "pending" ? [] : [loss]))
        session.transcript.streamingState = .idle
        runner.flushQueueIfIdle()
        await runner.flushPersistence()
        #expect(mock.sent.isEmpty)
        session.transcript.streamingState = .awaitingPermission
        mock.emit(.init(sessionId: "s", update: .asyncTask(.init(
            sessionUpdate: "async_task_state_update", asyncTaskId: "watch", state: "completed"))))
        try await waitUntil { session.backgroundTasks[0].state == "completed" }
        await runner.flushPersistence()
        let completion = try #require(session.queue.last)
        #expect(completion.id != loss.id)
        #expect(session.queue.count == (delivery == "pending" ? 1 : 2))
        #expect(try store.loadQueue(sessionId: "s") == session.queue)
    }

    @Test("an in-flight loss notification cannot consume a later completion notification", arguments: ["none", "async_task_spawned", "async_task_progress"])
    func completionWhileLossNotificationIsSending(reannouncement: String) async throws {
        let (runner, mock, session, _) = try mkRunner(agentID: "codex")
        var task = ACPBackgroundTask(ownerSessionId: "s", asyncTaskId: "watch", name: "Watch")
        task.loseObservation()
        session.saveBackgroundTask(task)
        let probe = StrictSingleFlightPromptProbe()
        mock.scriptAsync(method: "session/prompt") { _ in try await probe.send() }
        runner.start()
        defer { runner.stop()
        Task { await probe.releaseFirst() } }
        await runner.reconcileBackgroundTasks(adapterSurvived: true, previousTaskIds: [])
        await probe.waitUntilFirstStarted()
        if reannouncement != "none" {
            mock.emit(.init(sessionId: "s", update: .asyncTask(.init(
                sessionUpdate: reannouncement, asyncTaskId: "watch", name: "Watch"))))
            try await waitUntil { session.backgroundTasks[0].state == "running" }
            #expect(session.backgroundTasks[0].finishedAt == nil && session.backgroundTasks[0].summary == nil)
        }
        mock.emit(.init(sessionId: "s", update: .asyncTask(.init(
            sessionUpdate: "async_task_state_update", asyncTaskId: "watch", state: "completed"))))
        try await waitUntil { session.backgroundTasks[0].state == "completed" }
        await runner.flushPersistence()
        let states = try session.queue.map { item -> String? in
            guard case .text(let text) = item.blocks.first else { throw CocoaError(.coderInvalidValue) }
            let facts = Data(try #require(text.split(separator: "\n").last).utf8)
            return (try JSONSerialization.jsonObject(with: facts) as? [String: Any])?["state"] as? String
        }
        #expect(states == ["lost", "completed"])
        #expect(Set(session.queue.map(\.id)).count == 2)
        await probe.releaseFirst()
        try await waitUntil { session.queue.isEmpty && session.backgroundTasks[0].wakeDelivered }
        await runner.flushPersistence()
        #expect(await probe.callCount == 2)
    }

    @Test("recovery preserves surviving or reannounced tasks and reports loss only after replacement", arguments: [(true, false), (false, false), (false, true)])
    func backgroundRecovery(adapterSurvived: Bool, reannounced: Bool) async throws {
        let (runner, mock, session, store) = try mkRunner()
        session.transcript.streamingState = .awaitingInput
        session.applyBackgroundTask(.init(sessionUpdate: "async_task_spawned", asyncTaskId: "watch", name: "Watch"), ownerSessionId: "s")
        if reannounced {
            mock.emit(.init(sessionId: "s", update: .asyncTask(.init(
                sessionUpdate: "async_task_spawned", asyncTaskId: "watch", name: "Watch"))))
        }
        runner.start()
        defer { runner.stop() }
        await runner.reconcileBackgroundTasks(adapterSurvived: adapterSurvived, previousTaskIds: Set(session.backgroundTasks.map(\.id)))
        await runner.flushPersistence()
        let shouldReportLoss = !adapterSurvived && !reannounced
        #expect(session.backgroundTasks[0].state == (shouldReportLoss ? "lost" : "running"))
        #expect(session.queue.count == (shouldReportLoss ? 1 : 0))
        #expect(mock.sent.isEmpty)
        if shouldReportLoss {
            #expect(session.queue[0].blocks.description.contains("watch"))
            #expect(try store.loadQueue(sessionId: "s") == session.queue)
            let id = session.queue[0].id
            await runner.reconcileBackgroundTasks(adapterSurvived: false, previousTaskIds: Set(session.backgroundTasks.map(\.id)))
            await runner.flushPersistence()
            #expect(session.queue.map(\.id) == [id])
        }
    }

    @Test("queued user turn publishes only after the queue head is removed")
    func queuedUserTurnPublishesAfterQueueReconciliation() async throws {
        let observed = QueueTestGate()
        var turn: NextPromptCompletedTurn?
        var queueWasEmptyAtCallback = false
        var observedSession: ACPSession?
        let (runner, mock, session, _) = try mkRunner(onSuccessfulTurn: {
            turn = $0
            queueWasEmptyAtCallback = observedSession?.queue.isEmpty == true
            Task { await observed.open() }
        })
        observedSession = session
        mock.script(method: "session/prompt") { _ in Data("{}".utf8) }
        session.transcript.streamingState = .streaming
        runner.send(blocks: [.text("queued")], intent: .auto)
        await runner.flushPersistence()
        session.transcript.streamingState = .idle
        runner.flushQueueIfIdle()
        await observed.wait()
        #expect(queueWasEmptyAtCallback)
        #expect(turn?.sessionID == session.id)
        #expect(turn?.incarnation == session.incarnation)
        if case .some(.user(let userID, _, _, _, _)) = session.transcript.messages.first {
            #expect(turn?.userMessageID == userID)
        } else {
            Issue.record("expected queued user row")
        }
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
        try await waitUntil { session.transcript.streamingState == .streaming }
        #expect(session.transcript.streamingState == .streaming)
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

    @Test("queue dispatch provenance is durable before broker handoff", arguments: ["queued", "promptRequired", "methodNotFound"])
    func queueDispatchProvenanceIsPersistedBeforeHandoff(route: String) async throws {
        let (runner, mock, session, store) = try mkRunner()
        let generation = ACPBrokerGeneration(rawValue: 7)
        mock.brokerGenerationForTesting = generation
        let requestStarted = QueueTestGate()
        let responseRelease = QueueTestGate()
        mock.scriptAsync(method: "session/prompt") { request in
            let operationKey = try store.loadQueue(sessionId: "s").first?.brokerOperationKey
            #expect(request.brokerOperationKey != nil)
            #expect(request.brokerOperationKey == operationKey)
            await requestStarted.open()
            await responseRelease.wait()
            return Data("null".utf8)
        }
        if route != "queued" {
            session.supportsSteering = true
            session.transcript.streamingState = .streaming
            mock.script(method: "_session/steering") { _ in
                if route == "methodNotFound" {
                    throw ACPClientError.jsonrpc(.init(code: -32601, message: "Method not found", data: nil))
                }
                return Data(#"{"outcome":"promptRequired"}"#.utf8)
            }
            runner.send(blocks: [.text("queued")], intent: .steer)
        } else {
            session.enqueue(blocks: [.text("queued")])
            runner.flushQueueIfIdle()
        }
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

    @Test("unsupported steering waits for cancellation before resending")
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

    @Test("queued retry publishes the original user row once after success")
    func queuedRetryDoesNotDoubleRecord() async throws {
        var turns: [NextPromptCompletedTurn] = []
        let (runner, mock, session, _) = try mkRunner(onSuccessfulTurn: { turns.append($0) })
        // First attempt fails (no script). User clicks Retry. Second
        // attempt succeeds (script wired below). Verify the transcript
        // contains the user prompt exactly once across both attempts.
        session.transcript.streamingState = .streaming
        runner.send(blocks: [.text("retry-me")], intent: .auto)
        await runner.flushPersistence()
        session.transcript.streamingState = .idle
        runner.flushQueueIfIdle()
        try await waitUntil { session.queue.first?.lastError != nil }
        #expect(session.queue.count == 1)
        #expect(session.queue[0].transcriptRecorded == true)
        var users = session.transcript.messages.filter { if case .user = $0 { return true } else { return false } }
        #expect(users.count == 1)
        guard case .user(let originalUserID, _, _, _, _) = users[0] else {
            Issue.record("expected original queued user row")
            return
        }
        #expect(turns.isEmpty)

        // Simulate Retry: wire success script + clear lastError + flush.
        mock.script(method: "session/prompt") { _ in Data("null".utf8) }
        session.queue[0].lastError = nil
        runner.flushQueueIfIdle()
        try await waitUntil { turns.count == 1 }
        #expect(session.queue.isEmpty)
        users = session.transcript.messages.filter { if case .user = $0 { return true } else { return false } }
        #expect(users.count == 1)
        #expect(turns[0].userMessageID == originalUserID)
        #expect(turns[0].promptID == 1)
    }

    @Test("force-sent queued retry keeps the original user row")
    func forceSentQueuedRetryKeepsOriginalUserRow() async throws {
        var turns: [NextPromptCompletedTurn] = []
        let (runner, mock, session, _) = try mkRunner(onSuccessfulTurn: { turns.append($0) })
        session.transcript.streamingState = .streaming
        runner.send(blocks: [.text("retry-me")], intent: .auto)
        await runner.flushPersistence()
        session.transcript.streamingState = .idle
        runner.flushQueueIfIdle()
        try await waitUntil { session.queue.first?.lastError != nil }
        guard case .some(.user(let userID, _, _, _, _)) = session.transcript.messages.first,
              let queueID = session.queue.first?.id else {
            Issue.record("expected failed queued user row")
            return
        }

        mock.script(method: "session/prompt") { _ in Data("{}".utf8) }
        session.queue[0].lastError = nil
        session.transcript.streamingState = .streaming
        runner.forceSendQueuedItem(id: queueID)
        try await waitUntil { turns.count == 1 }
        #expect(turns[0].userMessageID == userID)
        #expect(turns[0].promptID == 1)
        let users = session.transcript.messages.filter { if case .user = $0 { return true } else { return false } }
        #expect(users.count == 1)
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        while !condition(), DispatchTime.now().uptimeNanoseconds < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(condition())
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

    @Test("foreground cancellation drains the queue while preserving background work", arguments: [false, true])
    func cancelThenFlushDrainsQueue(withBackgroundWork: Bool) async throws {
        let (runner, mock, session, _) = try mkRunner()
        mock.script(method: "session/prompt") { _ in Data("null".utf8) }
        if withBackgroundWork {
            session.backgroundTaskStopSupported = true
            session.applyBackgroundTask(.init(sessionUpdate: "async_task_spawned", asyncTaskId: "watch",
                name: "Watch", canStop: true), ownerSessionId: "s")
            session.apply(.subagentSpawned(.init(subagentSessionId: "child", capabilities: .cancellable)))
            mock.script(method: "_session/async_task/stop") { _ in Data(#"{"stopped":true}"#.utf8) }
        }
        session.transcript.streamingState = .streaming
        session.enqueue(blocks: [.text("queued-after-esc")])
        await runner.userCancel()
        try await waitUntil { session.queue.isEmpty }
        #expect(session.queue.isEmpty)
        #expect(mock.sent.filter { $0.method == "session/cancel" }
            .compactMap { ($0.params as? ACPSessionCancelParams)?.sessionId } == ["s"])
        #expect(!mock.sent.contains { $0.method == "_session/async_task/stop" })
        #expect(mock.sent.contains { $0.method == "session/prompt" })
        if withBackgroundWork {
            #expect(session.backgroundTasks[0].isActive)
            #expect(session.subagentRun("child")?.isRunning == true)
        }
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
        var restoredTurns: [NextPromptCompletedTurn] = []
        let runner2 = ACPSessionRunner(
            session: session2, connection: ACPConnection(client: mock2), store: store,
            sessionId: "rt", worktreePath: FileManager.default.temporaryDirectory.path,
            onSuccessfulTurn: { restoredTurns.append($0) })
        runner2.flushQueueIfIdle()
        #expect(mock2.sent.isEmpty)

        runner2.forceSendQueuedItem(id: session2.queue[0].id)
        try await waitUntil { session2.queue.isEmpty && session2.transcript.streamingState == .idle }
        await runner2.flushPersistence()
        #expect(session2.queue.isEmpty)
        #expect(restoredTurns.isEmpty)
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
