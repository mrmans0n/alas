import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACPSessionRunner")
struct ACPSessionRunnerTests {
    @Test("send reports failed completion when session prompt fails")
    func sendReportsFailedCompletionWhenPromptFails() async throws {
        let (runner, _) = try makeRunner()

        let succeeded = await withCheckedContinuation { continuation in
            runner.send(text: "hello", attachments: []) { succeeded in
                continuation.resume(returning: succeeded)
            }
        }

        #expect(succeeded == false)
        #expect(runner.session.lastError?.contains("prompt failed") == true)
        #expect(runner.session.transcript.streamingState == .idle)
    }

    @Test("auth prompt failure enters needsAuth while preserving direct prompt error")
    func authPromptFailureEntersNeedsAuth() async throws {
        let (runner, mock) = try makeRunner()
        let method = ACPInitializeResult.ACPAuthMethod(
            id: "claude-login",
            name: "Claude Login",
            kind: .terminal
        )
        runner.session.authMethods = [method]
        mock.script(method: "session/prompt") { _ in
            throw JSONRPCError(
                code: -32000,
                message: "Internal error: invalid authentication credentials",
                data: nil
            )
        }

        let succeeded = await withCheckedContinuation { continuation in
            runner.send(text: "hello", attachments: []) { succeeded in
                continuation.resume(returning: succeeded)
            }
        }

        #expect(succeeded == false)
        #expect(runner.session.setupState == .needsAuth(
            methods: [method],
            reason: "invalid authentication credentials"
        ))
        #expect(runner.session.agentState == .failed("invalid authentication credentials"))
        #expect(runner.session.lastError?.contains("invalid authentication credentials") == true)
        #expect(runner.session.transcript.streamingState == .idle)
    }

    @Test("send reports successful completion when session prompt succeeds")
    func sendReportsSuccessfulCompletionWhenPromptSucceeds() async throws {
        let (runner, mock) = try makeRunner()
        mock.script(method: "session/prompt") { _ in Data("{}".utf8) }
        let retry = AnyCodable(["codex": AnyCodable(["error": AnyCodable([
            "willRetry": AnyCodable(true), "message": AnyCodable("Retrying")
        ])])])
        runner.session.apply(.sessionInfoUpdate(.init(title: nil, metadata: retry)))

        let succeeded = await withCheckedContinuation { continuation in
            runner.send(text: "hello", attachments: []) { succeeded in
                continuation.resume(returning: succeeded)
            }
        }

        #expect(succeeded == true)
        #expect(runner.session.lastError == nil)
        #expect(runner.session.retryStatus == nil)
        #expect(runner.session.transcript.streamingState == .idle)
    }

    @Test("user cancellation clears retryable Codex status")
    func userCancellationClearsRetryStatus() async throws {
        let (runner, _) = try makeRunner()
        let retry = AnyCodable(["codex": AnyCodable(["error": AnyCodable([
            "willRetry": AnyCodable(true), "message": AnyCodable("Retrying")
        ])])])
        runner.session.apply(.sessionInfoUpdate(.init(title: nil, metadata: retry)))

        await runner.userCancel()

        #expect(runner.session.retryStatus == nil)
    }

    @Test("permanent prompt failure clears retryable Codex status")
    func promptFailureClearsRetryStatus() async throws {
        let (runner, _) = try makeRunner()
        let retry = AnyCodable(["codex": AnyCodable(["error": AnyCodable([
            "willRetry": AnyCodable(true), "message": AnyCodable("Retrying")
        ])])])
        runner.session.apply(.sessionInfoUpdate(.init(title: nil, metadata: retry)))

        let succeeded = await withCheckedContinuation { continuation in
            runner.send(text: "hello", attachments: []) { succeeded in
                continuation.resume(returning: succeeded)
            }
        }

        #expect(succeeded == false)
        #expect(runner.session.retryStatus == nil)
    }

    @Test("recording a submitted prompt keeps the suspended composer draft until prompt completion")
    func recordingPromptKeepsSuspendedDraftUntilPromptCompletion() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rn-recorded-draft-\(UUID().uuidString).sqlite")
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(id: "s", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        let submitted = ACPComposerDraft(segments: [.text("hello")])
        try store.upsertComposerDraft(
            sessionId: "s",
            draft: submitted,
            updatedAt: 1,
            submittedRecovery: true
        )
        let client = StreamingBatchACPClient()
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "wt", title: "t")
        session.agentState = .ready
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: client),
            store: store,
            sessionId: "s",
            worktreePath: FileManager.default.temporaryDirectory.path
        )

        var completion: Bool?
        runner.send(
            text: "hello",
            attachments: [],
            intent: .auto,
            draft: submitted
        ) { succeeded in
            completion = succeeded
        }

        try await waitUntil {
            session.transcript.messages.contains(where: {
                if case .user(_, _, "hello", _, _) = $0 { return true }
                return false
            })
        }
        #expect(try store.loadComposerDraft(sessionId: "s") == submitted)
        #expect(completion == nil)

        await client.finishPrompt()
        try await waitUntil { completion == true }
        #expect(try store.loadComposerDraft(sessionId: "s") == submitted)
    }

    @Test("prompt completion waits for yielded updates before marking output boundary")
    func promptCompletionWaitsForYieldedUpdatesBeforeBoundary() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-runner-boundary-\(UUID().uuidString).sqlite")
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(id: "s", agentId: "codex", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        let client = BoundaryRaceClient()
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "wt", title: "t")
        session.agentState = .ready
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: client),
            store: store,
            sessionId: "s",
            worktreePath: FileManager.default.temporaryDirectory.path
        )
        runner.start()

        var completion: Bool?
        runner.send(text: "hello", attachments: []) { succeeded in
            completion = succeeded
        }

        try await waitUntil { completion == true }
        #expect(session.transcript.completedOutputBoundaryMessageIds.isEmpty)

        client.emitReserved(.agentMessageChunk(.text(" second")))
        try await waitUntil {
            guard session.transcript.messages.count == 2,
                  case .agent(_, _, let buffer) = session.transcript.messages[1]
            else { return false }
            return buffer.value == "first second"
                && session.transcript.completedOutputBoundaryMessageIds == [session.transcript.messages[1].stableId]
        }

        client.emitFresh(.agentMessageChunk(.text("next task")))
        try await waitUntil { session.transcript.messages.count == 3 }
        if case .agent(_, _, let first) = session.transcript.messages[1],
           case .agent(_, _, let second) = session.transcript.messages[2] {
            #expect(first.value == "first second")
            #expect(second.value == "next task")
        } else {
            Issue.record("expected completed output and next output in separate agent messages")
        }
    }

    @Test("submits queue while completed output boundary is waiting for updates")
    func submitQueuesWhileCompletedBoundaryWaitsForUpdates() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-runner-boundary-submit-\(UUID().uuidString).sqlite")
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(id: "s", agentId: "codex", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        let client = BoundaryRaceClient()
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "wt", title: "t")
        session.agentState = .ready
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: client),
            store: store,
            sessionId: "s",
            worktreePath: FileManager.default.temporaryDirectory.path
        )
        runner.start()

        var firstCompletion: Bool?
        runner.send(text: "hello", attachments: []) { succeeded in
            firstCompletion = succeeded
        }
        try await waitUntil { firstCompletion == true }
        #expect(session.transcript.streamingState == .sending)

        var secondAccepted: Bool?
        runner.send(blocks: [.text("next")], intent: .auto) { succeeded in
            secondAccepted = succeeded
        }
        try await waitUntil { secondAccepted == true }
        #expect(session.queue.count == 1)
        #expect(client.sent.filter { $0.method == "session/prompt" }.count == 1)

        client.emitReserved(.agentMessageChunk(.text(" second")))
        try await waitUntil {
            client.sent.filter { $0.method == "session/prompt" }.count == 2
                && session.transcript.messages.count >= 3
        }

        if case .user(_, _, let firstUser, _, _) = session.transcript.messages[0],
           case .agent(_, _, let firstAnswer) = session.transcript.messages[1],
           case .user(_, _, let secondUser, _, _) = session.transcript.messages[2] {
            #expect(firstUser == "hello")
            #expect(firstAnswer.value == "first second")
            #expect(secondUser == "next")
        } else {
            Issue.record("expected delayed chunk to land before the queued next prompt")
        }
    }

    @Test("update stream end flush leaves queued prompt for next attach")
    func updateStreamEndFlushLeavesQueuedPromptForNextAttach() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-runner-boundary-disconnect-\(UUID().uuidString).sqlite")
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(id: "s", agentId: "codex", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        let client = BoundaryRaceClient()
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "wt", title: "t")
        session.agentState = .ready
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: client),
            store: store,
            sessionId: "s",
            worktreePath: FileManager.default.temporaryDirectory.path,
            incomingUpdateCoalesceNanos: 500_000_000
        )
        runner.start()
        defer { runner.stop() }

        var firstCompletion: Bool?
        runner.send(text: "hello", attachments: []) { succeeded in
            firstCompletion = succeeded
        }
        try await waitUntil { firstCompletion == true }
        #expect(session.transcript.streamingState == .sending)

        var secondAccepted: Bool?
        runner.send(blocks: [.text("next")], intent: .auto) { succeeded in
            secondAccepted = succeeded
        }
        try await waitUntil { secondAccepted == true }
        #expect(session.queue.count == 1)
        #expect(client.sent.filter { $0.method == "session/prompt" }.count == 1)

        client.emitReserved(.agentMessageChunk(.text(" second")))
        await client.shutdown()

        try await waitUntil {
            session.agentState == .disconnected
                && session.transcript.messages.count >= 3
        }

        #expect(client.sent.filter { $0.method == "session/prompt" }.count == 1)
        #expect(session.queue.count == 1)
        #expect(session.queue.first?.status == .pending)
        if case .agent(_, _, let answer) = session.transcript.messages[1],
           case .systemNotice(_, let text) = session.transcript.messages[2] {
            #expect(answer.value == "first second")
            #expect(text == "Agent disconnected.")
        } else {
            Issue.record("expected completed answer and disconnect notice without draining queue")
        }
    }

    @Test("stop flush leaves queued prompt for next attach")
    func stopFlushLeavesQueuedPromptForNextAttach() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-runner-boundary-stop-\(UUID().uuidString).sqlite")
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(id: "s", agentId: "codex", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        let client = BoundaryRaceClient()
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "wt", title: "t")
        session.agentState = .ready
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: client),
            store: store,
            sessionId: "s",
            worktreePath: FileManager.default.temporaryDirectory.path,
            incomingUpdateCoalesceNanos: 500_000_000
        )
        runner.start()

        var firstCompletion: Bool?
        runner.send(text: "hello", attachments: []) { succeeded in
            firstCompletion = succeeded
        }
        try await waitUntil { firstCompletion == true }

        var secondAccepted: Bool?
        runner.send(blocks: [.text("next")], intent: .auto) { succeeded in
            secondAccepted = succeeded
        }
        try await waitUntil { secondAccepted == true }
        #expect(session.queue.count == 1)
        #expect(client.sent.filter { $0.method == "session/prompt" }.count == 1)

        client.emitReserved(.agentMessageChunk(.text(" second")))
        try await Task.sleep(nanoseconds: 50_000_000)
        runner.stop()
        await client.shutdown()

        #expect(client.sent.filter { $0.method == "session/prompt" }.count == 1)
        #expect(session.queue.count == 1)
        #expect(session.queue.first?.status == .pending)
        if case .agent(_, _, let answer) = session.transcript.messages[1] {
            #expect(answer.value == "first second")
        } else {
            Issue.record("expected completed answer without draining queue")
        }
    }

    @Test("stale completed boundary does not idle active steer replacement")
    func staleCompletedBoundaryDoesNotIdleActiveSteerReplacement() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-runner-boundary-steer-\(UUID().uuidString).sqlite")
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(id: "s", agentId: "codex", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        let client = BoundaryRaceClient()
        let replacementGate = AsyncGate()
        client.holdSecondPrompt(until: replacementGate)
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "wt", title: "t")
        session.agentState = .ready
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: client),
            store: store,
            sessionId: "s",
            worktreePath: FileManager.default.temporaryDirectory.path
        )
        runner.start()

        var firstCompletion: Bool?
        runner.send(text: "hello", attachments: []) { succeeded in
            firstCompletion = succeeded
        }
        try await waitUntil { firstCompletion == true }
        #expect(session.transcript.streamingState == .sending)

        runner.send(blocks: [.text("replacement")], intent: .steer)
        try await waitUntil {
            client.sent.filter { $0.method == "session/prompt" }.count == 2
                && session.transcript.streamingState == .sending
        }

        client.emitReserved(.agentMessageChunk(.text(" old-tail")))
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(session.transcript.streamingState == .sending)

        await replacementGate.open()
        client.emitReserved(.agentMessageChunk(.text(" replacement-tail")))
        try await waitUntil { session.transcript.streamingState == .idle }
    }

    @Test("send treats user-cancelled prompt errors as accepted completion")
    func sendTreatsCancelledPromptErrorsAsAcceptedCompletion() async throws {
        let (runner, mock) = try makeRunner()
        let promptStarted = AsyncGate()
        let finishPrompt = AsyncGate()
        mock.scriptAsync(method: "session/prompt") { _ in
            await promptStarted.open()
            await finishPrompt.wait()
            throw ACPClientError.noScript(method: "session/prompt")
        }

        var completion: Bool?
        runner.send(text: "hello", attachments: []) { succeeded in
            completion = succeeded
        }
        await promptStarted.wait()

        await runner.userCancel()
        await finishPrompt.open()

        for _ in 0..<20 where completion == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(completion == true)
        #expect(runner.session.lastError == nil)
        #expect(runner.session.transcript.streamingState == .idle)
        #expect(mock.sent.contains { $0.method == "session/cancel" })
    }

    @Test("user cancel invokes the pending input cancellation hook")
    func userCancelInvokesInputCancellation() async throws {
        var didCancelInput = false
        let (runner, _) = try makeRunner {
            didCancelInput = true
        }

        await runner.userCancel()

        #expect(didCancelInput)
    }

    @Test("cancelled prompt completion does not idle a newer prompt")
    func cancelledPromptCompletionDoesNotIdleNewerPrompt() async throws {
        let (runner, mock) = try makeRunner()
        let promptCounter = AsyncCounter()
        let firstStarted = AsyncGate()
        let finishFirst = AsyncGate()
        let secondStarted = AsyncGate()
        let finishSecond = AsyncGate()
        mock.scriptAsync(method: "session/prompt") { _ in
            let promptNumber = await promptCounter.next()
            if promptNumber == 1 {
                await firstStarted.open()
                await finishFirst.wait()
                throw ACPClientError.noScript(method: "session/prompt")
            }
            await secondStarted.open()
            await finishSecond.wait()
            return Data("{}".utf8)
        }

        var firstCompletion: Bool?
        var secondCompletion: Bool?
        runner.send(text: "first", attachments: []) { succeeded in
            firstCompletion = succeeded
        }
        await firstStarted.wait()
        await runner.userCancel()

        runner.send(text: "second", attachments: []) { succeeded in
            secondCompletion = succeeded
        }
        await secondStarted.wait()
        await finishFirst.open()

        for _ in 0..<20 where firstCompletion == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(firstCompletion == nil)
        #expect(secondCompletion == nil)
        #expect(runner.session.transcript.streamingState == .sending)

        await finishSecond.open()
        for _ in 0..<20 where secondCompletion == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(secondCompletion == true)
        #expect(runner.session.transcript.streamingState == .idle)
    }

    @Test("cancelled prompt success does not complete over a newer prompt")
    func cancelledPromptSuccessDoesNotCompleteOverNewerPrompt() async throws {
        let (runner, mock) = try makeRunner()
        let promptCounter = AsyncCounter()
        let firstStarted = AsyncGate()
        let finishFirst = AsyncGate()
        let secondStarted = AsyncGate()
        let finishSecond = AsyncGate()
        mock.scriptAsync(method: "session/prompt") { _ in
            let promptNumber = await promptCounter.next()
            if promptNumber == 1 {
                await firstStarted.open()
                await finishFirst.wait()
                return Data("{}".utf8)
            }
            await secondStarted.open()
            await finishSecond.wait()
            return Data("{}".utf8)
        }

        var firstCompletion: Bool?
        var secondCompletion: Bool?
        runner.send(text: "first", attachments: []) { succeeded in
            firstCompletion = succeeded
        }
        await firstStarted.wait()
        await runner.userCancel()

        runner.send(text: "second", attachments: []) { succeeded in
            secondCompletion = succeeded
        }
        await secondStarted.wait()
        await finishFirst.open()

        for _ in 0..<20 where runner.session.transcript.streamingState != .sending {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(firstCompletion == nil)
        #expect(secondCompletion == nil)
        #expect(runner.session.transcript.streamingState == .sending)

        await finishSecond.open()
        for _ in 0..<20 where secondCompletion == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(secondCompletion == true)
        #expect(runner.session.transcript.streamingState == .idle)
    }

    @Test("emitted session/update lands on the session and persists a message row")
    func runnerWiresUpdates() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rn-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(id: "s", agentId: "claude", title: "t",
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
            worktreePath: FileManager.default.temporaryDirectory.path
        )
        runner.start()

        mock.emit(.init(sessionId: "s", update: .agentMessageChunk(.text("hello"))))
        // Allow the actor hop
        try await Task.sleep(nanoseconds: 50_000_000)

        let inMemoryAgentMessages = session.transcript.messages.filter {
            if case .agent = $0 { return true }
            return false
        }
        #expect(inMemoryAgentMessages.count == 1)
        let rows = try store.loadMessages(sessionId: "s")
        #expect(rows.count == 1)
        #expect(rows[0].kind == "agent")
    }

    @Test("session_info_update updates live session and persistence")
    func sessionInfoUpdateRenamesGeneratedSession() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rn-title-\(UUID().uuidString).sqlite")
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(
            id: "s",
            agentId: "claude",
            title: "Old generated",
            titleSource: .generated,
            currentModel: nil,
            currentMode: nil,
            autoRun: false,
            createdAt: 1,
            updatedAt: 2,
            lastOpenedAt: 3,
            archived: false
        ))

        var callbackTitles: [String] = []
        let mock = ACPMockClient()
        let session = ACPSession(
            id: "s",
            agentId: "claude",
            worktreeId: "wt",
            title: "Old generated",
            titleSource: .generated
        )
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: mock),
            store: store,
            sessionId: "s",
            worktreePath: FileManager.default.temporaryDirectory.path,
            onSessionTitleUpdated: { callbackTitles.append($0) }
        )
        runner.start()
        defer { runner.stop() }

        mock.emit(.init(
            sessionId: "s",
            update: .sessionInfoUpdate(.init(title: "  Adapter Title  ", updatedAt: "2026-06-25T12:34:56Z"))
        ))

        try await waitUntil {
            session.title == "Adapter Title"
                && session.titleSource == .generated
                && callbackTitles == ["Adapter Title"]
        }

        let row = try #require(try store.loadSession(id: "s"))
        #expect(row.title == "Adapter Title")
        #expect(row.titleSource == .generated)
    }

    @Test("session_info_update metadata updates live goal")
    func sessionInfoUpdateMetadataUpdatesLiveGoal() async throws {
        let (runner, mock) = try makeRunner()
        runner.start()
        defer { runner.stop() }

        mock.emit(.init(
            sessionId: "s",
            update: .sessionInfoUpdate(.init(
                title: .absent,
                metadata: AnyCodable([
                    "codex": AnyCodable([
                        "goal": AnyCodable([
                            "objective": AnyCodable("Surface richer ACP events"),
                            "status": AnyCodable("in_progress"),
                            "tokenBudget": AnyCodable(12_000)
                        ])
                    ])
                ])
            ))
        ))

        try await waitUntil {
            runner.session.currentGoal?.objective == "Surface richer ACP events"
        }
        let goal = try #require(runner.session.currentGoal)
        #expect(goal.status == "in_progress")
        #expect(goal.tokenBudget == 12_000)
    }

    @Test("session_info_update preserves manual title")
    func sessionInfoUpdatePreservesManualTitle() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rn-title-manual-\(UUID().uuidString).sqlite")
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(
            id: "s",
            agentId: "claude",
            title: "User Title",
            titleSource: .manual,
            currentModel: nil,
            currentMode: nil,
            autoRun: false,
            createdAt: 1,
            updatedAt: 2,
            lastOpenedAt: 3,
            archived: false
        ))

        var callbackTitles: [String] = []
        let mock = ACPMockClient()
        let session = ACPSession(
            id: "s",
            agentId: "claude",
            worktreeId: "wt",
            title: "User Title",
            titleSource: .manual
        )
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: mock),
            store: store,
            sessionId: "s",
            worktreePath: FileManager.default.temporaryDirectory.path,
            onSessionTitleUpdated: { callbackTitles.append($0) }
        )
        runner.start()
        defer { runner.stop() }

        mock.emit(.init(
            sessionId: "s",
            update: .sessionInfoUpdate(.init(title: "Adapter Title", updatedAt: nil))
        ))

        try await Task.sleep(nanoseconds: 50_000_000)

        let row = try #require(try store.loadSession(id: "s"))
        #expect(session.title == "User Title")
        #expect(session.titleSource == .manual)
        #expect(row.title == "User Title")
        #expect(row.titleSource == .manual)
        #expect(callbackTitles.isEmpty)
    }

    @Test("session_info_update ignores empty title")
    func sessionInfoUpdateIgnoresEmptyTitle() async throws {
        let (runner, mock) = try makeRunner()
        runner.start()
        defer { runner.stop() }

        mock.emit(.init(
            sessionId: "s",
            update: .sessionInfoUpdate(.init(title: "   \n ", updatedAt: nil))
        ))

        try await Task.sleep(nanoseconds: 50_000_000)

        await runner.flushPersistence()
        let row = try #require(try await runner.persistence.loadSession(id: "s"))
        #expect(runner.session.title == "t")
        #expect(row.title == "t")
    }

    @Test("session_info_update null title clears generated title")
    func sessionInfoUpdateNullTitleClearsGeneratedTitle() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rn-title-clear-\(UUID().uuidString).sqlite")
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(
            id: "s",
            agentId: "claude",
            title: "Generated title",
            titleSource: .generated,
            currentModel: nil,
            currentMode: nil,
            autoRun: false,
            createdAt: 1,
            updatedAt: 2,
            lastOpenedAt: 3,
            archived: false
        ))

        var callbackTitles: [String] = []
        let mock = ACPMockClient()
        let session = ACPSession(
            id: "s",
            agentId: "claude",
            worktreeId: "wt",
            title: "Generated title",
            titleSource: .generated
        )
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: mock),
            store: store,
            sessionId: "s",
            worktreePath: FileManager.default.temporaryDirectory.path,
            onSessionTitleUpdated: { callbackTitles.append($0) }
        )
        runner.start()
        defer { runner.stop() }

        mock.emit(.init(
            sessionId: "s",
            update: .sessionInfoUpdate(.init(title: .null, updatedAt: nil))
        ))

        try await waitUntil {
            session.title == "New session"
                && session.titleSource == .placeholder
                && callbackTitles == ["New session"]
        }

        let row = try #require(try store.loadSession(id: "s"))
        #expect(row.title == "New session")
        #expect(row.titleSource == .placeholder)
    }

    @Test("session_info_update applies during load replay suppression")
    func sessionInfoUpdateAppliesDuringLoadReplaySuppression() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rn-title-replay-\(UUID().uuidString).sqlite")
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(
            id: "s",
            agentId: "claude",
            title: "Old generated",
            titleSource: .generated,
            currentModel: nil,
            currentMode: nil,
            autoRun: false,
            createdAt: 1,
            updatedAt: 2,
            lastOpenedAt: 3,
            archived: false
        ))

        var callbackTitles: [String] = []
        let mock = ACPMockClient()
        let session = ACPSession(
            id: "s",
            agentId: "claude",
            worktreeId: "wt",
            title: "Old generated",
            titleSource: .generated
        )
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: mock),
            store: store,
            sessionId: "s",
            worktreePath: FileManager.default.temporaryDirectory.path,
            suppressingLoadReplay: true,
            onSessionTitleUpdated: { callbackTitles.append($0) }
        )
        runner.start()
        defer { runner.stop() }

        mock.emit(.init(
            sessionId: "s",
            update: .sessionInfoUpdate(.init(title: "Replayed Adapter Title", updatedAt: nil))
        ))
        mock.emit(.init(sessionId: "s", update: .agentMessageChunk(.text("replayed"))))

        try await waitUntil {
            session.title == "Replayed Adapter Title"
                && session.titleSource == .generated
                && callbackTitles == ["Replayed Adapter Title"]
        }

        let row = try #require(try store.loadSession(id: "s"))
        #expect(row.title == "Replayed Adapter Title")
        #expect(row.titleSource == .generated)
        #expect(session.transcript.messages.isEmpty)
    }

    @Test("suppressed retry history does not affect live retry status")
    func suppressedRetryHistoryDoesNotAffectLiveStatus() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rn-retry-replay-\(UUID().uuidString).sqlite")
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(
            id: "s", agentId: "codex", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 1, updatedAt: 2, lastOpenedAt: 3, archived: false
        ))
        let retry = AnyCodable(["codex": AnyCodable(["error": AnyCodable([
            "willRetry": AnyCodable(true), "message": AnyCodable("Temporary")
        ])])])
        let mock = ACPMockClient()
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "wt", title: "t")
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: mock),
            store: store,
            sessionId: "s",
            worktreePath: FileManager.default.temporaryDirectory.path,
            suppressingLoadReplay: true
        )
        runner.start()
        defer { runner.stop() }

        mock.emit(.init(sessionId: "s", update: .sessionInfoUpdate(.init(
            title: "Replayed title", metadata: retry))))
        mock.emit(.init(sessionId: "s", update: .agentMessageChunk(.text("replayed"))))
        try await waitUntil { session.title == "Replayed title" }
        #expect(session.retryStatus == nil)

        runner.finishSuppressingLoadReplay(throughYieldedUpdateCount: mock.yieldedUpdateCount)
        mock.emit(.init(sessionId: "s", update: .sessionInfoUpdate(.init(title: nil, metadata: retry))))
        try await waitUntil { session.retryStatus != nil }
        mock.emit(.init(sessionId: "s", update: .agentMessageChunk(.text("resumed"))))
        try await waitUntil { session.retryStatus == nil }
    }

    @Test("delayed load replay finish keeps active prompt boundary crossing")
    func delayedLoadReplayFinishKeepsActivePromptBoundaryCrossing() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rn-replay-boundary-\(UUID().uuidString).sqlite")
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(
            id: "s",
            agentId: "claude",
            title: "t",
            currentModel: nil,
            currentMode: nil,
            autoRun: false,
            createdAt: 1,
            updatedAt: 2,
            lastOpenedAt: 3,
            archived: false
        ))

        let mock = ACPMockClient()
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "wt", title: "t")
        session.agentState = .ready
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: mock),
            store: store,
            sessionId: "s",
            worktreePath: FileManager.default.temporaryDirectory.path,
            suppressingLoadReplay: true,
            incomingUpdateCoalesceNanos: 100_000_000
        )
        runner.start()
        defer { runner.stop() }

        mock.emit(.init(sessionId: "s", update: .agentMessageChunk(.text("replayed"))))
        try await Task.sleep(nanoseconds: 20_000_000)
        runner.finishSuppressingLoadReplay(throughYieldedUpdateCount: mock.yieldedUpdateCount)

        let promptStarted = AsyncGate()
        let finishPrompt = AsyncGate()
        mock.scriptAsync(method: "session/prompt") { _ in
            await promptStarted.open()
            await finishPrompt.wait()
            return Data("{}".utf8)
        }

        let completed = Task {
            await withCheckedContinuation { continuation in
                runner.send(text: "live prompt", attachments: []) { succeeded in
                    continuation.resume(returning: succeeded)
                }
            }
        }
        await promptStarted.wait()
        #expect(session.allowsStreamingBoundaryCrossing)

        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(session.allowsStreamingBoundaryCrossing)
        #expect(session.transcript.messages.contains {
            if case .user = $0 { return true }
            return false
        })

        await finishPrompt.open()
        #expect(await completed.value)
    }

    @Test("tool metadata side effects apply during load replay suppression")
    func toolMetadataSideEffectsApplyDuringLoadReplaySuppression() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rn-tool-replay-\(UUID().uuidString).sqlite")
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(
            id: "s",
            agentId: "claude",
            title: "t",
            currentModel: nil,
            currentMode: nil,
            autoRun: false,
            createdAt: 1,
            updatedAt: 2,
            lastOpenedAt: 3,
            archived: false
        ))

        let mock = ACPMockClient()
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "wt", title: "t")
        session.apply(.toolCall(.init(
            toolCallId: "tc-replay",
            title: "Run command",
            kind: "execute",
            status: "in_progress",
            content: nil,
            locations: nil,
            rawInput: nil,
            rawOutput: nil)))
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: mock),
            store: store,
            sessionId: "s",
            worktreePath: FileManager.default.temporaryDirectory.path,
            suppressingLoadReplay: true
        )
        runner.start()
        defer { runner.stop() }

        mock.emit(.init(
            sessionId: "s",
            update: .toolCallUpdate(.init(
                toolCallId: "tc-replay",
                metadata: AnyCodable([
                    "terminal_output_delta": AnyCodable([
                        "terminal_id": AnyCodable("term-replay"),
                        "data": AnyCodable("replayed output\n")
                    ])
                ])))))
        mock.emit(.init(sessionId: "s", update: .agentMessageChunk(.text("suppressed replay"))))

        try await waitUntil {
            session.terminalHost.terminal(id: "term-replay")?.snapshot(byteLimit: 1024).text == "replayed output\n"
        }

        #expect(session.transcript.messages.count == 1)
        if case .toolCall(let tc) = session.transcript.messages[0] {
            #expect(tc.terminalIds == ["term-replay"])
        } else {
            Issue.record("expected restored toolCall message")
        }
    }

    @Test("tool image enrichments apply during load replay suppression")
    func toolImageEnrichmentsApplyDuringLoadReplaySuppression() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rn-tool-image-replay-\(UUID().uuidString).sqlite")
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(
            id: "s",
            agentId: "codex",
            title: "t",
            currentModel: nil,
            currentMode: nil,
            autoRun: false,
            createdAt: 1,
            updatedAt: 2,
            lastOpenedAt: 3,
            archived: false
        ))

        let mock = ACPMockClient()
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "wt", title: "t")
        session.apply(.toolCall(.init(
            toolCallId: "tc-image-replay",
            title: "Image generation",
            kind: "other",
            status: "in_progress",
            content: nil,
            locations: nil,
            rawInput: nil,
            rawOutput: nil)))
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: mock),
            store: store,
            sessionId: "s",
            worktreePath: FileManager.default.temporaryDirectory.path,
            suppressingLoadReplay: true
        )
        runner.start()
        defer { runner.stop() }

        mock.emit(.init(
            sessionId: "s",
            update: .toolCallUpdate(.init(
                toolCallId: "tc-image-replay",
                status: "completed",
                content: [
                    .content(.image(data: "content-image-data", uri: nil, mimeType: "image/png"))
                ],
                rawOutput: AnyCodable([
                    "data": AnyCodable([
                        AnyCodable([
                            "b64_json": AnyCodable("raw-output-data")
                        ])
                    ])
                ])))))
        mock.emit(.init(sessionId: "s", update: .agentMessageChunk(.text("suppressed replay"))))

        try await waitUntil {
            guard case .toolCall(let tc) = session.transcript.messages.first else { return false }
            return tc.status == "completed"
                && tc.assets.contains(.image(data: "content-image-data", mimeType: "image/png"))
                && tc.assets.contains(.image(data: "raw-output-data", mimeType: "image/png"))
        }

        #expect(session.transcript.messages.count == 1)
        if case .toolCall(let tc) = session.transcript.messages[0] {
            #expect(tc.content == "")
            #expect(tc.rawOutput?.contains(#""b64_json":"raw-output-data""#) == true)
            #expect(tc.assets == [
                ACPMessage.ToolCallAsset.image(data: "content-image-data", mimeType: "image/png"),
                ACPMessage.ToolCallAsset.image(data: "raw-output-data", mimeType: "image/png")
            ])
        } else {
            Issue.record("expected restored toolCall message")
        }
    }

    @Test("initial tool image enrichments apply in memory during load replay suppression")
    func initialToolImageEnrichmentsApplyDuringLoadReplaySuppression() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rn-tool-initial-image-replay-\(UUID().uuidString).sqlite")
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(
            id: "s",
            agentId: "codex",
            title: "t",
            currentModel: nil,
            currentMode: nil,
            autoRun: false,
            createdAt: 1,
            updatedAt: 2,
            lastOpenedAt: 3,
            archived: false
        ))

        let mock = ACPMockClient()
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "wt", title: "t")
        session.apply(.toolCall(.init(
            toolCallId: "tc-initial-image-replay",
            title: "Image generation",
            kind: "other",
            status: "in_progress",
            content: nil,
            locations: nil,
            rawInput: nil,
            rawOutput: nil)))
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: mock),
            store: store,
            sessionId: "s",
            worktreePath: FileManager.default.temporaryDirectory.path,
            suppressingLoadReplay: true
        )
        runner.applyIncomingUpdateForTesting(.init(
            sessionId: "s",
            update: .toolCall(.init(
                toolCallId: "tc-initial-image-replay",
                title: "Image generation",
                kind: "other",
                status: "completed",
                content: [
                    .content(.image(data: "content-image-data", uri: nil, mimeType: "image/png"))
                ],
                locations: nil,
                rawInput: nil,
                rawOutput: AnyCodable([
                    "data": AnyCodable([
                        AnyCodable([
                            "b64_json": AnyCodable("raw-output-data")
                        ])
                    ])
                ])))))
        runner.applyIncomingUpdateForTesting(.init(sessionId: "s", update: .agentMessageChunk(.text("suppressed replay"))))

        #expect(session.transcript.messages.count == 1)
        if case .toolCall(let tc) = session.transcript.messages[0] {
            #expect(tc.content == "")
            #expect(tc.rawOutput?.contains(#""b64_json":"raw-output-data""#) == true)
            #expect(tc.assets == [
                ACPMessage.ToolCallAsset.image(data: "content-image-data", mimeType: "image/png"),
                ACPMessage.ToolCallAsset.image(data: "raw-output-data", mimeType: "image/png")
            ])
        } else {
            Issue.record("expected restored toolCall message")
        }

        #expect(try store.loadMessages(sessionId: "s").isEmpty)
    }

    @Test("streaming chunks are persisted in a batch when streaming ends")
    func streamingChunksPersistAsBatchOnIdle() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rn-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(id: "s", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))

        let acknowledgement = DurableAcknowledgementRecorder()
        let mock = StreamingBatchACPClient(chunkAcknowledgementRecorder: acknowledgement)
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "wt", title: "t")
        session.agentState = .ready
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: mock),
            store: store,
            sessionId: "s",
            worktreePath: FileManager.default.temporaryDirectory.path,
            streamingPersistDebounceNanos: 5_000_000_000
        )
        runner.start()
        defer { runner.stop() }

        let completed = Task {
            await withCheckedContinuation { continuation in
                runner.send(text: "start", attachments: []) { succeeded in
                    continuation.resume(returning: succeeded)
                }
            }
        }

        await mock.waitForChunks()
        try await Task.sleep(nanoseconds: 50_000_000)

        let inMemoryAgentMessages = session.transcript.messages.filter {
            if case .agent = $0 { return true }
            return false
        }
        #expect(inMemoryAgentMessages.count == 1)
        let rowsBeforeCompletion = try store.loadMessages(sessionId: "s")
        #expect(!rowsBeforeCompletion.contains { $0.kind == "agent" })
        #expect(acknowledgement.recordedCount == 0)

        await mock.finishPrompt()
        #expect(await completed.value)
        await runner.flushPersistence()

        let rows = try store.loadMessages(sessionId: "s")
        #expect(acknowledgement.recordedCount == 2)
        let agentRow = try #require(rows.first(where: { $0.kind == "agent" }))
        let decoded = try ACPMessageCodec.decode(kind: agentRow.kind, payload: agentRow.payload)
        guard case .agent(_, _, let text) = decoded else {
            Issue.record("expected persisted agent message")
            return
        }
        #expect(text.value == "hello world")
    }

    @Test("incoming update is acknowledged only after message persistence")
    func incomingUpdateAcknowledgesAfterPersistence() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rn-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(id: "s", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "wt", title: "t")
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: ACPMockClient()),
            store: store,
            sessionId: "s",
            worktreePath: FileManager.default.temporaryDirectory.path
        )
        let acknowledgement = DurableAcknowledgementRecorder()

        runner.applyIncomingUpdateForTesting(.init(
            sessionId: "s",
            update: .agentMessageChunk(.text("durable")),
            durableConsumptionAcknowledgement: { acknowledgement.record() }
        ))

        #expect(!acknowledgement.wasRecorded)
        await runner.flushPersistence()
        #expect(acknowledgement.wasRecorded)
        #expect(try store.loadMessages(sessionId: "s").contains { $0.kind == "agent" })
    }

    @Test("incoming streaming chunks are coalesced before applying")
    func incomingStreamingChunksCoalesceBeforeApplying() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rn-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(id: "s", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))

        let mock = StreamingBatchACPClient()
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "wt", title: "t")
        session.agentState = .ready
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: mock),
            store: store,
            sessionId: "s",
            worktreePath: FileManager.default.temporaryDirectory.path,
            streamingPersistDebounceNanos: 5_000_000_000,
            incomingUpdateCoalesceNanos: 100_000_000
        )
        runner.start()
        defer { runner.stop() }

        let completed = Task {
            await withCheckedContinuation { continuation in
                runner.send(text: "start", attachments: []) { succeeded in
                    continuation.resume(returning: succeeded)
                }
            }
        }

        await mock.waitForChunks()
        try await Task.sleep(nanoseconds: 20_000_000)
        let agentMessagesBeforeFlush = session.transcript.messages.filter {
            if case .agent = $0 { return true }
            return false
        }
        #expect(agentMessagesBeforeFlush.isEmpty)

        try await waitUntil(timeoutNanoseconds: 500_000_000) {
            guard let message = session.transcript.messages.first(where: {
                if case .agent = $0 { return true }
                return false
            }), case .agent(_, _, let text) = message else {
                return false
            }
            return text.value == "hello world"
        }

        await mock.finishPrompt()
        #expect(await completed.value)
    }

    @Test("file requests flush buffered updates before appending transcript cards")
    func fileRequestsFlushBufferedUpdatesBeforeAppendingTranscriptCards() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rn-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(id: "s", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))

        let worktree = FileManager.default.temporaryDirectory
            .appendingPathComponent("rn-worktree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        let file = worktree.appendingPathComponent("edited.txt")
        try "old\n".write(to: file, atomically: true, encoding: .utf8)

        let mock = ACPMockClient()
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "wt", title: "t")
        session.agentState = .ready
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: mock),
            store: store,
            sessionId: "s",
            worktreePath: worktree.path,
            incomingUpdateCoalesceNanos: 100_000_000
        )
        runner.start()
        defer { runner.stop() }

        mock.emit(.init(sessionId: "s", update: .agentMessageChunk(.text("before edit"))))
        try await Task.sleep(nanoseconds: 20_000_000)
        mock.emitFile(.write(
            id: .number(7),
            params: .init(sessionId: "s", path: file.path, content: "new\n")
        ))

        try await waitUntil {
            mock.fileResponses[.number(7)] != nil
                && session.transcript.messages.count >= 2
        }

        guard case .agent(_, _, let text) = session.transcript.messages[0],
              case .fileEdit = session.transcript.messages[1]
        else {
            Issue.record("expected buffered agent text before file-edit card")
            return
        }
        #expect(text.value == "before edit")
    }

    @Test("permission requests flush buffered updates before responding")
    func permissionRequestsFlushBufferedUpdatesBeforeResponding() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rn-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(id: "s", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))

        let mock = PermissionOrderingClient()
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "wt", title: "t")
        session.agentState = .ready
        session.autoRunEnabled = true
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: mock),
            store: store,
            sessionId: "s",
            worktreePath: FileManager.default.temporaryDirectory.path,
            incomingUpdateCoalesceNanos: 100_000_000
        )
        runner.start()
        defer { runner.stop() }

        mock.emit(.toolCall(.init(
            toolCallId: "tc-permission",
            title: "Run command",
            kind: "execute",
            status: "in_progress",
            content: nil,
            locations: nil,
            rawInput: nil,
            rawOutput: nil
        )))
        try await Task.sleep(nanoseconds: 20_000_000)
        mock.emitPermission()

        try await waitUntil {
            mock.permissionResponses[.number(11)] != nil
        }
        guard case .toolCall(let toolCall) = session.transcript.messages.first else {
            Issue.record("expected buffered tool call before permission response")
            return
        }
        #expect(toolCall.toolCallId == "tc-permission")
        #expect(mock.permissionResponses[.number(11)]?.outcome == .selected(optionId: "allow"))
    }

    @Test("user cancel flushes buffered updates before appending interruption notice")
    func userCancelFlushesBufferedUpdatesBeforeAppendingInterruptionNotice() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rn-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(id: "s", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))

        let mock = ACPMockClient()
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "wt", title: "t")
        session.agentState = .ready
        session.transcript.streamingState = .streaming
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: mock),
            store: store,
            sessionId: "s",
            worktreePath: FileManager.default.temporaryDirectory.path,
            incomingUpdateCoalesceNanos: 100_000_000
        )
        runner.start()
        defer { runner.stop() }

        mock.emit(.init(sessionId: "s", update: .agentMessageChunk(.text("before cancel"))))
        try await Task.sleep(nanoseconds: 20_000_000)

        await runner.userCancel()

        try await waitUntil {
            session.transcript.messages.count >= 2
        }
        guard case .agent(_, _, let text) = session.transcript.messages[0],
              case .systemNotice(_, let notice) = session.transcript.messages[1]
        else {
            Issue.record("expected buffered agent text before interruption notice")
            return
        }
        #expect(text.value == "before cancel")
        #expect(notice.contains("Interrupted by user."))
    }

    @Test("send flushes buffered updates before recording the next prompt")
    func sendFlushesBufferedUpdatesBeforeRecordingNextPrompt() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rn-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(id: "s", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))

        let mock = ACPMockClient()
        mock.script(method: "session/prompt") { _ in Data("{}".utf8) }
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "wt", title: "t")
        session.agentState = .ready
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: mock),
            store: store,
            sessionId: "s",
            worktreePath: FileManager.default.temporaryDirectory.path,
            incomingUpdateCoalesceNanos: 100_000_000
        )
        runner.start()
        defer { runner.stop() }

        mock.emit(.init(sessionId: "s", update: .agentMessageChunk(.text("old turn"))))
        try await Task.sleep(nanoseconds: 20_000_000)

        let completed = await withCheckedContinuation { continuation in
            runner.send(text: "next prompt", attachments: []) { succeeded in
                continuation.resume(returning: succeeded)
            }
        }

        #expect(completed)
        try await waitUntil {
            session.transcript.messages.count >= 2
        }
        guard case .agent(_, _, let text) = session.transcript.messages[0],
              case .user(_, _, let prompt, _, _) = session.transcript.messages[1]
        else {
            Issue.record("expected buffered agent text before the next user prompt")
            return
        }
        #expect(text.value == "old turn")
        #expect(prompt == "next prompt")
    }

    @Test("user cancel does not cancel queued successor started by pending boundary flush")
    func userCancelDoesNotCancelQueuedSuccessorStartedByPendingBoundaryFlush() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rn-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(id: "s", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))

        let mock = ACPMockClient()
        let promptCounter = AsyncCounter()
        let firstChunksEmitted = AsyncGate()
        let finishFirstPrompt = AsyncGate()
        let secondStarted = AsyncGate()
        let finishSecondPrompt = AsyncGate()
        mock.scriptAsync(method: "session/prompt") { _ in
            let promptNumber = await promptCounter.next()
            if promptNumber == 1 {
                mock.emit(.init(sessionId: "s", update: .agentMessageChunk(.text("final"))))
                await firstChunksEmitted.open()
                await finishFirstPrompt.wait()
                return Data("{}".utf8)
            }
            await secondStarted.open()
            await finishSecondPrompt.wait()
            return Data("{}".utf8)
        }

        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "wt", title: "t")
        session.agentState = .ready
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: mock),
            store: store,
            sessionId: "s",
            worktreePath: FileManager.default.temporaryDirectory.path,
            incomingUpdateCoalesceNanos: 500_000_000
        )
        runner.start()
        defer { runner.stop() }

        let firstCompleted = Task {
            await withCheckedContinuation { continuation in
                runner.send(text: "first", attachments: []) { succeeded in
                    continuation.resume(returning: succeeded)
                }
            }
        }
        await firstChunksEmitted.wait()
        runner.send(text: "queued", attachments: [])
        try await waitUntil {
            session.queue.count == 1 && session.queue[0].status == .pending
        }

        await finishFirstPrompt.open()
        #expect(await firstCompleted.value)

        await runner.userCancel()
        await secondStarted.wait()
        #expect(session.queue.count == 1)
        #expect(session.queue.first?.status == .sending)
        #expect(session.queue.first?.blocks == [.text("queued")])

        await finishSecondPrompt.open()
        try await waitUntil {
            session.queue.isEmpty
        }
    }

    @Test("streaming chunks flush periodically before the stream goes quiet")
    func streamingChunksPersistBeforeQuietPeriod() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rn-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(id: "s", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))

        let mock = StreamingBatchACPClient()
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "wt", title: "t")
        session.agentState = .ready
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: mock),
            store: store,
            sessionId: "s",
            worktreePath: FileManager.default.temporaryDirectory.path,
            streamingPersistDebounceNanos: 100_000_000
        )
        runner.start()
        defer { runner.stop() }

        let completed = Task {
            await withCheckedContinuation { continuation in
                runner.send(text: "start", attachments: []) { succeeded in
                    continuation.resume(returning: succeeded)
                }
            }
        }

        await mock.waitForChunks()
        let emitter = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 40_000_000)
                mock.emitAgentChunk("x")
            }
        }
        defer { emitter.cancel() }

        try await waitUntil(timeoutNanoseconds: 600_000_000) {
            ((try? store.loadMessages(sessionId: "s").contains { $0.kind == "agent" }) ?? false)
        }

        await mock.finishPrompt()
        #expect(await completed.value)
    }

    @Test("stop flushes pending streamed chunks during takeover")
    func stopFlushesPendingStreamingChunksDuringTakeover() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rn-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let sid = "s"
        try store.upsertSession(.init(id: sid, agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        let now = Int64(Date().timeIntervalSince1970)
        try store.seizeLease(sessionId: sid, instanceId: "ME", pid: Int64(getpid()), now: now)

        let mock = StreamingBatchACPClient()
        let session = ACPSession(id: sid, agentId: "claude", worktreeId: "wt", title: "t")
        session.agentState = .ready
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: mock),
            store: store,
            sessionId: sid,
            worktreePath: FileManager.default.temporaryDirectory.path,
            streamingPersistDebounceNanos: 5_000_000_000,
            incomingUpdateCoalesceNanos: 500_000_000,
            ownerInstanceId: "ME"
        )
        runner.start()

        let completed = Task {
            await withCheckedContinuation { continuation in
                runner.send(text: "start", attachments: []) { succeeded in
                    continuation.resume(returning: succeeded)
                }
            }
        }

        await mock.waitForChunks()
        try await Task.sleep(nanoseconds: 50_000_000)
        let rowsBeforeTakeover = try store.loadMessages(sessionId: sid)
        #expect(!rowsBeforeTakeover.contains { $0.kind == "agent" })

        try store.seizeLease(sessionId: sid, instanceId: "OTHER", pid: Int64(getpid()), now: now)
        mock.emitUsageUpdate()
        try await Task.sleep(nanoseconds: 50_000_000)
        runner.stop()
        await runner.flushPersistence()
        await mock.finishPrompt()
        _ = await completed.value

        let rows = try store.loadMessages(sessionId: sid)
        let agentRow = try #require(rows.first(where: { $0.kind == "agent" }))
        let decoded = try ACPMessageCodec.decode(kind: agentRow.kind, payload: agentRow.payload)
        guard case .agent(_, _, let text) = decoded else {
            Issue.record("expected persisted agent message")
            return
        }
        #expect(text.value == "hello world")
    }

    @Test("takeover flush preserves completed chunks still awaiting coalesced apply")
    func takeoverFlushPreservesCompletedChunksAwaitingCoalescedApply() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rn-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let sid = "s"
        try store.upsertSession(.init(id: sid, agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        let now = Int64(Date().timeIntervalSince1970)
        try store.seizeLease(sessionId: sid, instanceId: "ME", pid: Int64(getpid()), now: now)

        let mock = StreamingBatchACPClient()
        let session = ACPSession(id: sid, agentId: "claude", worktreeId: "wt", title: "t")
        session.agentState = .ready
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: mock),
            store: store,
            sessionId: sid,
            worktreePath: FileManager.default.temporaryDirectory.path,
            streamingPersistDebounceNanos: 5_000_000_000,
            incomingUpdateCoalesceNanos: 500_000_000,
            ownerInstanceId: "ME"
        )
        runner.start()

        let completed = Task {
            await withCheckedContinuation { continuation in
                runner.send(text: "start", attachments: []) { succeeded in
                    continuation.resume(returning: succeeded)
                }
            }
        }

        await mock.waitForChunks()
        let rowsBeforeCompletion = try store.loadMessages(sessionId: sid)
        #expect(!rowsBeforeCompletion.contains { $0.kind == "agent" })

        await mock.finishPrompt()
        #expect(await completed.value)
        try store.seizeLease(sessionId: sid, instanceId: "OTHER", pid: Int64(getpid()), now: now)
        try await Task.sleep(nanoseconds: 250_000_000)
        runner.stop()
        await runner.flushPersistence()

        let rows = try store.loadMessages(sessionId: sid)
        let agentRow = try #require(rows.first(where: { $0.kind == "agent" }))
        let decoded = try ACPMessageCodec.decode(kind: agentRow.kind, payload: agentRow.payload)
        guard case .agent(_, _, let text) = decoded else {
            Issue.record("expected persisted agent message")
            return
        }
        #expect(text.value == "hello world")
    }

    @Test("takeover flush preserves active chunks still awaiting coalesced apply")
    func takeoverFlushPreservesActiveChunksAwaitingCoalescedApply() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rn-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let sid = "s"
        try store.upsertSession(.init(id: sid, agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        let now = Int64(Date().timeIntervalSince1970)
        try store.seizeLease(sessionId: sid, instanceId: "ME", pid: Int64(getpid()), now: now)

        let mock = StreamingBatchACPClient()
        let session = ACPSession(id: sid, agentId: "claude", worktreeId: "wt", title: "t")
        session.agentState = .ready
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: mock),
            store: store,
            sessionId: sid,
            worktreePath: FileManager.default.temporaryDirectory.path,
            streamingPersistDebounceNanos: 5_000_000_000,
            incomingUpdateCoalesceNanos: 200_000_000,
            ownerInstanceId: "ME"
        )
        runner.start()

        let completed = Task {
            await withCheckedContinuation { continuation in
                runner.send(text: "start", attachments: []) { succeeded in
                    continuation.resume(returning: succeeded)
                }
            }
        }

        await mock.waitForChunks()
        try await Task.sleep(nanoseconds: 50_000_000)
        try store.seizeLease(sessionId: sid, instanceId: "OTHER", pid: Int64(getpid()), now: now)
        try await Task.sleep(nanoseconds: 550_000_000)
        runner.stop()
        await mock.finishPrompt()
        _ = await completed.value
        await runner.flushPersistence()

        let rows = try store.loadMessages(sessionId: sid)
        let agentRow = try #require(rows.first(where: { $0.kind == "agent" }))
        let decoded = try ACPMessageCodec.decode(kind: agentRow.kind, payload: agentRow.payload)
        guard case .agent(_, _, let text) = decoded else {
            Issue.record("expected persisted agent message")
            return
        }
        #expect(text.value.hasPrefix("hello "))
    }

    @Test("takeover stop preserves active chunks after prompt invalidation")
    func takeoverStopPreservesActiveChunksAfterPromptInvalidation() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rn-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let sid = "s"
        try store.upsertSession(.init(id: sid, agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        let now = Int64(Date().timeIntervalSince1970)
        try store.seizeLease(sessionId: sid, instanceId: "ME", pid: Int64(getpid()), now: now)

        let mock = ACPMockClient()
        let chunkEmitted = AsyncGate()
        let finishPrompt = AsyncGate()
        mock.scriptAsync(method: "session/prompt") { _ in
            mock.emit(.init(sessionId: sid, update: .agentMessageChunk(.text("tail"))))
            await chunkEmitted.open()
            await finishPrompt.wait()
            return Data("{}".utf8)
        }

        let session = ACPSession(id: sid, agentId: "claude", worktreeId: "wt", title: "t")
        session.agentState = .ready
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: mock),
            store: store,
            sessionId: sid,
            worktreePath: FileManager.default.temporaryDirectory.path,
            streamingPersistDebounceNanos: 5_000_000_000,
            incomingUpdateCoalesceNanos: 500_000_000,
            ownerInstanceId: "ME"
        )
        runner.start()

        runner.send(text: "start", attachments: [])
        await chunkEmitted.wait()
        try await Task.sleep(nanoseconds: 20_000_000)
        try store.seizeLease(sessionId: sid, instanceId: "OTHER", pid: Int64(getpid()), now: now)

        runner.invalidateActivePrompt()
        runner.stop()
        await runner.flushPersistence()
        await finishPrompt.open()

        let rows = try store.loadMessages(sessionId: sid)
        let agentRow = try #require(rows.first(where: { $0.kind == "agent" }))
        let decoded = try ACPMessageCodec.decode(kind: agentRow.kind, payload: agentRow.payload)
        guard case .agent(_, _, let text) = decoded else {
            Issue.record("expected persisted agent message")
            return
        }
        #expect(text.value == "tail")
    }

    @Test("takeover snapshot preserves stored full tool content")
    func takeoverSnapshotPreservesStoredFullToolContent() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rn-takeover-tool-snapshot-\(UUID().uuidString).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let sid = "s"
        try store.upsertSession(.init(id: sid, agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        let now = Int64(Date().timeIntervalSince1970)
        try store.seizeLease(sessionId: sid, instanceId: "ME", pid: Int64(getpid()), now: now)

        let mock = StreamingBatchACPClient()
        let session = ACPSession(id: sid, agentId: "claude", worktreeId: "wt", title: "t")
        session.agentState = .ready
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: mock),
            store: store,
            sessionId: sid,
            worktreePath: FileManager.default.temporaryDirectory.path,
            streamingPersistDebounceNanos: 5_000_000_000,
            incomingUpdateCoalesceNanos: 500_000_000,
            ownerInstanceId: "ME"
        )

        let fullContent = String(repeating: "full-content-line\n", count: 400)
        let original = ACPMessage.toolCall(.init(
            toolCallId: "tool-1",
            title: "Run",
            kind: "execute",
            status: "completed",
            content: fullContent
        ))
        session.replaceTranscriptMessages([original])
        runner.persistIndices([0])
        session.transcript.setVisibleHead(1)
        guard case .toolCall(let truncated) = session.transcript.messages[0] else {
            Issue.record("expected tool call")
            return
        }
        #expect(truncated.isContentTruncated)
        #expect(truncated.content.count < fullContent.count)

        runner.start()
        let completed = Task {
            await withCheckedContinuation { continuation in
                runner.send(text: "start", attachments: []) { succeeded in
                    continuation.resume(returning: succeeded)
                }
            }
        }

        await mock.waitForChunks()
        mock.emitToolCallUpdate(.init(
            toolCallId: "tool-1",
            metadata: AnyCodable([
                "terminal_output_delta": AnyCodable([
                    "terminal_id": AnyCodable("term-1"),
                    "data": AnyCodable("tail\n")
                ])
            ])
        ))
        try await Task.sleep(nanoseconds: 50_000_000)
        try store.seizeLease(sessionId: sid, instanceId: "OTHER", pid: Int64(getpid()), now: now)
        mock.emitUsageUpdate()
        try await Task.sleep(nanoseconds: 50_000_000)
        runner.stop()
        await runner.flushPersistence()
        await mock.finishPrompt()
        _ = await completed.value

        let rows = try store.loadMessages(sessionId: sid)
        let row = try #require(rows.first(where: { $0.kind == "tool_call" }))
        let decoded = try ACPMessageCodec.decode(kind: row.kind, payload: row.payload)
        guard case .toolCall(let persisted) = decoded else {
            Issue.record("expected persisted tool call")
            return
        }
        #expect(persisted.content == fullContent)
        #expect(persisted.terminalIds == ["term-1"])
    }

    @Test("stop() resolves a parked permission continuation as cancelled")
    func stopResolvesParkedPermission() async throws {
        let (runner, _) = try makeRunner()

        // Park a permission decision: autoRun is off and nothing is logged,
        // so evaluate() binds to the UI and suspends on its continuation.
        let toolCall = ACPPermissionToolCall(
            toolCallId: "call_1", title: nil, kind: nil, status: nil,
            content: nil, locations: nil, rawInput: nil, rawOutput: nil)
        let params = ACPPermissionRequestParams(
            sessionId: "s",
            toolCall: toolCall,
            options: [ACPPermissionOption(optionId: "allow", name: "Allow", kind: "allow_once"),
                      ACPPermissionOption(optionId: "reject", name: "Reject", kind: "reject_once")])
        async let decision = runner.policy.evaluate(
            scopeKey: "scope",
            options: params.options,
            params: params)

        // Give evaluate() a beat to register its continuation.
        try? await Task.sleep(for: .milliseconds(100))

        runner.stop()

        let response = await decision
        #expect(response.outcome == .cancelled)
    }

    @Test("takeover flush excludes chunks received after lease loss")
    func takeoverFlushExcludesChunksReceivedAfterLeaseLoss() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rn-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let sid = "s"
        try store.upsertSession(.init(id: sid, agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        let now = Int64(Date().timeIntervalSince1970)
        try store.seizeLease(sessionId: sid, instanceId: "ME", pid: Int64(getpid()), now: now)

        let mock = StreamingBatchACPClient()
        let session = ACPSession(id: sid, agentId: "claude", worktreeId: "wt", title: "t")
        session.agentState = .ready
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: mock),
            store: store,
            sessionId: sid,
            worktreePath: FileManager.default.temporaryDirectory.path,
            streamingPersistDebounceNanos: 5_000_000_000,
            incomingUpdateCoalesceNanos: 500_000_000,
            ownerInstanceId: "ME"
        )
        runner.start()

        let completed = Task {
            await withCheckedContinuation { continuation in
                runner.send(text: "start", attachments: []) { succeeded in
                    continuation.resume(returning: succeeded)
                }
            }
        }

        await mock.waitForChunks()
        try await Task.sleep(nanoseconds: 50_000_000)
        try store.seizeLease(sessionId: sid, instanceId: "OTHER", pid: Int64(getpid()), now: now)
        mock.emitAgentChunk(" after")
        mock.emitUsageUpdate()
        try await Task.sleep(nanoseconds: 50_000_000)
        runner.invalidateActivePrompt()
        runner.stop()
        await mock.finishPrompt()
        _ = await completed.value
        await runner.flushPersistence()

        let rows = try store.loadMessages(sessionId: sid)
        let agentRow = try #require(rows.first(where: { $0.kind == "agent" }))
        let decoded = try ACPMessageCodec.decode(kind: agentRow.kind, payload: agentRow.payload)
        guard case .agent(_, _, let text) = decoded else {
            Issue.record("expected persisted agent message")
            return
        }
        #expect(text.value == "hello world")
    }

    @Test("takeover flush does not overwrite rows changed by new writer")
    func takeoverFlushDoesNotOverwriteRowsChangedByNewWriter() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rn-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let sid = "s"
        try store.upsertSession(.init(id: sid, agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        let now = Int64(Date().timeIntervalSince1970)
        try store.seizeLease(sessionId: sid, instanceId: "ME", pid: Int64(getpid()), now: now)

        let mock = StreamingBatchACPClient()
        let session = ACPSession(id: sid, agentId: "claude", worktreeId: "wt", title: "t")
        session.agentState = .ready
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: mock),
            store: store,
            sessionId: sid,
            worktreePath: FileManager.default.temporaryDirectory.path,
            streamingPersistDebounceNanos: 5_000_000_000,
            ownerInstanceId: "ME"
        )
        runner.start()

        let completed = Task {
            await withCheckedContinuation { continuation in
                runner.send(text: "start", attachments: []) { succeeded in
                    continuation.resume(returning: succeeded)
                }
            }
        }

        await mock.waitForChunks()
        try await Task.sleep(nanoseconds: 50_000_000)
        runner.persistIndices([1])

        mock.emitAgentChunk(" before")
        try await Task.sleep(nanoseconds: 50_000_000)
        try store.seizeLease(sessionId: sid, instanceId: "OTHER", pid: Int64(getpid()), now: now)
        let newWriterPayload = try ACPMessageCodec.encode(.agent(id: UUID(), StreamingText("new writer")))
        try store.updateMessagePayload(id: "msg-\(sid)-1", payload: newWriterPayload)
        mock.emitUsageUpdate()
        try await Task.sleep(nanoseconds: 50_000_000)
        runner.stop()
        await runner.flushPersistence()
        await mock.finishPrompt()
        _ = await completed.value

        let rows = try store.loadMessages(sessionId: sid)
        let agentRow = try #require(rows.first(where: { $0.kind == "agent" }))
        let decoded = try ACPMessageCodec.decode(kind: agentRow.kind, payload: agentRow.payload)
        guard case .agent(_, _, let text) = decoded else {
            Issue.record("expected persisted agent message")
            return
        }
        #expect(text.value == "new writer")
    }

    @Test("takeover flush skips a dirtied row this runner never persisted")
    func takeoverFlushSkipsRowWithoutCachedBase() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rn-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let sid = "s"
        try store.upsertSession(.init(id: sid, agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        let now = Int64(Date().timeIntervalSince1970)
        try store.seizeLease(sessionId: sid, instanceId: "ME", pid: Int64(getpid()), now: now)

        // A tool row persisted by a *previous* session load: it counts toward
        // persistedMessageCount, but this runner never wrote it, so it has no
        // entry in lastPersistedPayloads.
        let tool = ACPMessage.toolCall(.init(
            toolCallId: "tool-x", title: "Run", kind: "execute",
            status: "in_progress", content: "base"))
        try store.appendMessage(
            sessionId: sid, id: "msg-\(sid)-0", kind: "tool_call",
            seq: 0, payload: try ACPMessageCodec.encode(tool), createdAt: now)

        let mock = StreamingBatchACPClient()
        let session = ACPSession(id: sid, agentId: "claude", worktreeId: "wt", title: "t")
        session.agentState = .ready
        session.replaceTranscriptMessages([tool])
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: mock),
            store: store,
            sessionId: sid,
            worktreePath: FileManager.default.temporaryDirectory.path,
            streamingPersistDebounceNanos: 5_000_000_000,
            ownerInstanceId: "ME"
        )
        runner.start()

        let completed = Task {
            await withCheckedContinuation { continuation in
                runner.send(text: "start", attachments: []) { succeeded in
                    continuation.resume(returning: succeeded)
                }
            }
        }

        await mock.waitForChunks()
        // Dirty the pre-existing tool row mid-stream: it enters the persist
        // buffer without a CAS base captured while we held the lease.
        mock.emitToolCallUpdate(.init(
            toolCallId: "tool-x",
            status: "completed",
            content: [.content(.text("mine"))]))
        try await Task.sleep(nanoseconds: 50_000_000)

        // Takeover, then the new owner rewrites that same row.
        try store.seizeLease(sessionId: sid, instanceId: "OTHER", pid: Int64(getpid()), now: now)
        let newOwnerPayload = try ACPMessageCodec.encode(.toolCall(.init(
            toolCallId: "tool-x", title: "Run", kind: "execute",
            status: "completed", content: "new owner")))
        try store.updateMessagePayload(id: "msg-\(sid)-0", payload: newOwnerPayload)
        mock.emitUsageUpdate()
        try await Task.sleep(nanoseconds: 50_000_000)
        runner.stop()
        await runner.flushPersistence()
        await mock.finishPrompt()
        _ = await completed.value

        // Without a base captured under our lease, reading the row now would
        // pick up the new owner's payload and let the CAS clobber it — so the
        // row must be skipped entirely.
        let rows = try store.loadMessages(sessionId: sid)
        let toolRow = try #require(rows.first(where: { $0.id == "msg-\(sid)-0" }))
        guard case .toolCall(let persisted) =
                try ACPMessageCodec.decode(kind: toolRow.kind, payload: toolRow.payload) else {
            Issue.record("expected persisted tool call")
            return
        }
        #expect(persisted.content == "new owner")
    }

    @Test("takeover flush does not capture persisted row base after lease loss")
    func takeoverFlushDoesNotCapturePersistedRowBaseAfterLeaseLoss() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rn-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let sid = "s"
        try store.upsertSession(.init(id: sid, agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        let now = Int64(Date().timeIntervalSince1970)
        try store.seizeLease(sessionId: sid, instanceId: "ME", pid: Int64(getpid()), now: now)

        let tool = ACPMessage.toolCall(.init(
            toolCallId: "tool-x", title: "Run", kind: "execute",
            status: "in_progress", content: "base"))
        try store.appendMessage(
            sessionId: sid, id: "msg-\(sid)-0", kind: "tool_call",
            seq: 0, payload: try ACPMessageCodec.encode(tool), createdAt: now)

        let mock = StreamingBatchACPClient()
        let session = ACPSession(id: sid, agentId: "claude", worktreeId: "wt", title: "t")
        session.agentState = .ready
        session.replaceTranscriptMessages([tool])
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: mock),
            store: store,
            sessionId: sid,
            worktreePath: FileManager.default.temporaryDirectory.path,
            streamingPersistDebounceNanos: 5_000_000_000,
            incomingUpdateCoalesceNanos: 500_000_000,
            ownerInstanceId: "ME"
        )
        runner.start()

        let completed = Task {
            await withCheckedContinuation { continuation in
                runner.send(text: "start", attachments: []) { succeeded in
                    continuation.resume(returning: succeeded)
                }
            }
        }

        await mock.waitForChunks()
        mock.emitToolCallUpdate(.init(
            toolCallId: "tool-x",
            status: "completed",
            content: [.content(.text("mine"))]))
        try await Task.sleep(nanoseconds: 50_000_000)

        try store.seizeLease(sessionId: sid, instanceId: "OTHER", pid: Int64(getpid()), now: now)
        let newOwnerPayload = try ACPMessageCodec.encode(.toolCall(.init(
            toolCallId: "tool-x", title: "Run", kind: "execute",
            status: "completed", content: "new owner")))
        try store.updateMessagePayload(id: "msg-\(sid)-0", payload: newOwnerPayload)

        try await Task.sleep(nanoseconds: 600_000_000)
        runner.stop()
        await mock.finishPrompt()
        _ = await completed.value

        let rows = try store.loadMessages(sessionId: sid)
        let toolRow = try #require(rows.first(where: { $0.id == "msg-\(sid)-0" }))
        guard case .toolCall(let persisted) =
                try ACPMessageCodec.decode(kind: toolRow.kind, payload: toolRow.payload) else {
            Issue.record("expected persisted tool call")
            return
        }
        #expect(persisted.content == "new owner")
    }

    @Test("takeover flush persists an under-lease update to a loaded row the new owner left alone")
    func takeoverFlushPersistsUnderLeaseUpdateToLoadedRow() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rn-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let sid = "s"
        try store.upsertSession(.init(id: sid, agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        let now = Int64(Date().timeIntervalSince1970)
        try store.seizeLease(sessionId: sid, instanceId: "ME", pid: Int64(getpid()), now: now)

        // A tool row persisted by a previous session load — no cache entry.
        let tool = ACPMessage.toolCall(.init(
            toolCallId: "tool-x", title: "Run", kind: "execute",
            status: "in_progress", content: "base"))
        try store.appendMessage(
            sessionId: sid, id: "msg-\(sid)-0", kind: "tool_call",
            seq: 0, payload: try ACPMessageCodec.encode(tool), createdAt: now)

        let mock = StreamingBatchACPClient()
        let session = ACPSession(id: sid, agentId: "claude", worktreeId: "wt", title: "t")
        session.agentState = .ready
        session.replaceTranscriptMessages([tool])
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: mock),
            store: store,
            sessionId: sid,
            worktreePath: FileManager.default.temporaryDirectory.path,
            streamingPersistDebounceNanos: 5_000_000_000,
            incomingUpdateCoalesceNanos: 500_000_000,
            ownerInstanceId: "ME"
        )
        runner.start()

        let completed = Task {
            await withCheckedContinuation { continuation in
                runner.send(text: "start", attachments: []) { succeeded in
                    continuation.resume(returning: succeeded)
                }
            }
        }

        await mock.waitForChunks()
        // Update the loaded row while we still hold the lease. The CAS base is
        // captured when the update is enqueued, against the on-disk "base"
        // payload, before the coalesced apply runs.
        mock.emitToolCallUpdate(.init(
            toolCallId: "tool-x",
            status: "completed",
            content: [.content(.text("mine"))]))
        try await Task.sleep(nanoseconds: 50_000_000)

        // Takeover before the coalesced flush, but the new owner never touches
        // this row.
        try store.seizeLease(sessionId: sid, instanceId: "OTHER", pid: Int64(getpid()), now: now)
        mock.emitUsageUpdate()
        try await Task.sleep(nanoseconds: 50_000_000)
        runner.stop()
        await runner.flushPersistence()
        await mock.finishPrompt()
        _ = await completed.value

        // The row still matches the base we captured under the lease, so the
        // CAS succeeds and our under-lease update is not silently dropped.
        let rows = try store.loadMessages(sessionId: sid)
        let toolRow = try #require(rows.first(where: { $0.id == "msg-\(sid)-0" }))
        guard case .toolCall(let persisted) =
                try ACPMessageCodec.decode(kind: toolRow.kind, payload: toolRow.payload) else {
            Issue.record("expected persisted tool call")
            return
        }
        #expect(persisted.content == "mine")
        #expect(persisted.status == "completed")
    }

    @Test("stop persists buffered streamed chunks while the lease is still held")
    func stopPersistsBufferedStreamingChunksWhileLeaseHeld() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rn-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let sid = "s"
        try store.upsertSession(.init(id: sid, agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        let now = Int64(Date().timeIntervalSince1970)
        try store.seizeLease(sessionId: sid, instanceId: "ME", pid: Int64(getpid()), now: now)

        let mock = StreamingBatchACPClient()
        let session = ACPSession(id: sid, agentId: "claude", worktreeId: "wt", title: "t")
        session.agentState = .ready
        // A debounce long enough that no periodic flush fires: the only write
        // must come from stop()'s stand-down flush, which — since the lease is
        // still held — persists the live transcript rather than per-chunk
        // snapshots. This is the path the per-chunk-encode removal reworked.
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: mock),
            store: store,
            sessionId: sid,
            worktreePath: FileManager.default.temporaryDirectory.path,
            streamingPersistDebounceNanos: 5_000_000_000,
            ownerInstanceId: "ME"
        )
        runner.start()

        let completed = Task {
            await withCheckedContinuation { continuation in
                runner.send(text: "start", attachments: []) { succeeded in
                    continuation.resume(returning: succeeded)
                }
            }
        }

        await mock.waitForChunks()
        // A chunk beyond the mock's initial two — it must be included in the
        // stand-down flush, proving stop() reads the live transcript and does
        // not rely on a snapshot captured per chunk.
        mock.emitAgentChunk(" and more")
        try await Task.sleep(nanoseconds: 50_000_000)

        // Nothing persisted yet: the debounce has not fired.
        let rowsBeforeStop = try store.loadMessages(sessionId: sid)
        #expect(!rowsBeforeStop.contains { $0.kind == "agent" })

        runner.stop()
        await mock.finishPrompt()
        _ = await completed.value
        await runner.flushPersistence()

        let rows = try store.loadMessages(sessionId: sid)
        let agentRow = try #require(rows.first(where: { $0.kind == "agent" }))
        let decoded = try ACPMessageCodec.decode(kind: agentRow.kind, payload: agentRow.payload)
        guard case .agent(_, _, let text) = decoded else {
            Issue.record("expected persisted agent message")
            return
        }
        #expect(text.value == "hello world and more")
    }

    @Test("fenced streaming write failure preserves the pending tail for takeover salvage")
    func fencedStreamingWriteFailurePreservesPendingTail() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rn-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let sid = "s"
        try store.upsertSession(.init(id: sid, agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        let now = Int64(Date().timeIntervalSince1970)
        try store.seizeLease(sessionId: sid, instanceId: "ME", pid: Int64(getpid()), now: now)
        let oldLease = try #require(try store.loadLease(sessionId: sid))

        let mock = StreamingBatchACPClient()
        let session = ACPSession(id: sid, agentId: "claude", worktreeId: "wt", title: "t")
        session.agentState = .ready
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: mock),
            store: store,
            sessionId: sid,
            worktreePath: FileManager.default.temporaryDirectory.path,
            streamingPersistDebounceNanos: 5_000_000_000,
            ownerInstanceId: "ME",
            canWrite: { true },
            leaseFenceProvider: {
                .init(sessionId: sid, ownerInstance: "ME", token: oldLease.token)
            }
        )
        runner.start()

        let completed = Task {
            await withCheckedContinuation { continuation in
                runner.send(text: "start", attachments: []) { succeeded in
                    continuation.resume(returning: succeeded)
                }
            }
        }

        await mock.waitForChunks()
        try await Task.sleep(nanoseconds: 50_000_000)
        try store.seizeLease(sessionId: sid, instanceId: "OTHER", pid: Int64(getpid()), now: now)

        // The cached canWrite closure still allows the enqueue, but the
        // persistence actor observes the old token and rejects the write.
        runner.stop()
        await runner.flushPersistence()
        await mock.finishPrompt()
        _ = await completed.value

        let rows = try store.loadMessages(sessionId: sid)
        let agentRow = try #require(rows.first(where: { $0.kind == "agent" }))
        guard case .agent(_, _, let text) = try ACPMessageCodec.decode(kind: agentRow.kind, payload: agentRow.payload) else {
            Issue.record("expected persisted agent message")
            return
        }
        #expect(text.value == "hello world")
    }

    @Test("in-place plan update persists to disk even when plan is not the trailing message")
    func planUpdatePersistsWhenNotTrailingMessage() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rn-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(id: "s", agentId: "claude", title: "t",
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
            worktreePath: FileManager.default.temporaryDirectory.path
        )
        runner.start()

        // Initial plan: 3 pending. Lands as messages[0].
        mock.emit(.init(sessionId: "s", update: .plan([
            .init(content: "a", priority: nil, status: "pending"),
            .init(content: "b", priority: nil, status: "pending"),
            .init(content: "c", priority: nil, status: "pending"),
        ])))
        // Agent text follows so the plan is no longer the trailing message.
        mock.emit(.init(sessionId: "s", update: .agentMessageChunk(.text("working..."))))
        // Plan status update: first item now completed. apply() overwrites
        // messages[0] in place — the trailing message stays the agent row.
        mock.emit(.init(sessionId: "s", update: .plan([
            .init(content: "a", priority: nil, status: "completed"),
            .init(content: "b", priority: nil, status: "in_progress"),
            .init(content: "c", priority: nil, status: "pending"),
        ])))

        try await Task.sleep(nanoseconds: 100_000_000)

        // In-memory plan is correct.
        if case .plan(_, let items) = session.transcript.messages[0] {
            #expect(items[0].status == "completed")
        } else {
            Issue.record("expected plan at messages[0]")
        }

        // Persisted plan row must reflect the latest update — otherwise a
        // hydrated session shows 0/N until the agent re-emits the plan.
        let rows = try store.loadMessages(sessionId: "s")
        let planRow = try #require(rows.first(where: { $0.kind == "plan" }))
        let decoded = try ACPMessageWire.decode(kind: planRow.kind, payload: planRow.payload)
        guard case .plan(let storedItems) = decoded else {
            Issue.record("expected plan wire variant")
            return
        }
        #expect(storedItems[0].status == "completed")
        #expect(storedItems[1].status == "in_progress")
        #expect(storedItems[2].status == "pending")
    }

    @Test("sending a prompt resumes transcript tail following")
    func sendResumesTranscriptTailFollowing() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rn-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(id: "s", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))

        let mock = ACPMockClient()
        mock.script(method: "session/prompt") { _ in Data("{}".utf8) }
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "wt", title: "t")
        session.followsTranscriptTail = false
        var didResumeTail = false
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: mock),
            store: store,
            sessionId: "s",
            worktreePath: FileManager.default.temporaryDirectory.path,
            onResumeTranscriptTail: {
                didResumeTail = true
            }
        )

        runner.send(text: "new turn", attachments: [])
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(session.followsTranscriptTail)
        #expect(didResumeTail)
        #expect(session.transcript.messages.count == 1)
        #expect(mock.sent.contains { $0.method == "session/prompt" })
    }

    @Test("sliceLines honours line + limit parameters")
    func sliceLinesRange() {
        let full = "one\ntwo\nthree\nfour\nfive"

        // Both nil → whole file.
        #expect(ACPSessionRunner.sliceLines(full, line: nil, limit: nil) == full)

        // Bounded slice from the middle.
        #expect(ACPSessionRunner.sliceLines(full, line: 2, limit: 2) == "two\nthree")

        // `line` past the end clamps cleanly.
        #expect(ACPSessionRunner.sliceLines(full, line: 99, limit: 5) == "")

        // `limit` exceeding remaining lines returns the tail.
        #expect(ACPSessionRunner.sliceLines(full, line: 4, limit: 99) == "four\nfive")
    }

    @Test("serveRead reads from disk and slices the requested range")
    func serveReadFromDisk() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sr-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("read.txt")
        try "one\ntwo\nthree\nfour".write(to: file, atomically: true, encoding: .utf8)

        let outcome = await ACPSessionRunner.serveRead(
            target: file, liveBuffer: nil, line: 2, limit: 2
        )
        guard case .success(let body) = outcome else {
            Issue.record("expected success outcome")
            return
        }
        let decoded = try JSONDecoder().decode(ACPFsReadResult.self, from: body)
        #expect(decoded.content == "two\nthree")
    }

    @Test("serveRead refuses an unbounded range that would return the whole file")
    func serveReadRefusesRangeThatDoesNotBound() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sr-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("huge.txt")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(ACPSessionRunner.maxWholeFileReadBytes) + 1)
        try handle.close()

        // `sliceLines` runs to end of file unless `limit` is present and
        // positive, so each of these asks for the whole file while looking
        // like a range. Exempting them was a limit anyone could step around.
        for (line, limit) in [(1, nil as Int?), (nil, 0), (2, -1)] {
            let outcome = await ACPSessionRunner.serveRead(
                target: file, liveBuffer: nil, line: line, limit: limit
            )
            guard case .failure = outcome else {
                Issue.record("line: \(String(describing: line)), limit: \(String(describing: limit)) should be refused")
                return
            }
        }
    }

    @Test("serveRead refuses a whole-file read past the limit and names the way out")
    func serveReadRefusesOversizedWholeFileRead() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sr-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("huge.txt")
        // Sparse, so this costs no disk and nothing is ever read: the point is
        // that the refusal happens on the reported size alone.
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(ACPSessionRunner.maxWholeFileReadBytes) + 1)
        try handle.close()

        let outcome = await ACPSessionRunner.serveRead(
            target: file, liveBuffer: nil, line: nil, limit: nil
        )
        guard case .failure(let message) = outcome else {
            Issue.record("expected an oversized whole-file read to be refused")
            return
        }
        // The adapter has to be able to act on this, not merely see it fail.
        #expect(message.contains("line"))
        #expect(message.contains("limit"))
    }

    @Test("serveRead still serves a ranged read of a file past the whole-file limit")
    func serveReadAllowsRangedReadOfLargeFile() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sr-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("ranged.txt")
        try "alpha\nbeta\ngamma".write(to: file, atomically: true, encoding: .utf8)

        // The limit must not leak into ranged reads, which return a bounded
        // slice however large the file is.
        let outcome = await ACPSessionRunner.serveRead(
            target: file, liveBuffer: nil, line: 2, limit: 1
        )
        guard case .success(let body) = outcome else {
            Issue.record("expected a ranged read to succeed")
            return
        }
        let decoded = try JSONDecoder().decode(ACPFsReadResult.self, from: body)
        #expect(decoded.content == "beta")
    }

    @Test("serveRead prefers the live buffer snapshot over disk")
    func serveReadPrefersLiveBuffer() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sr-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("read.txt")
        try "stale\ndisk".write(to: file, atomically: true, encoding: .utf8)

        let outcome = await ACPSessionRunner.serveRead(
            target: file, liveBuffer: "fresh\nbuffer", line: nil, limit: nil
        )
        guard case .success(let body) = outcome else {
            Issue.record("expected success outcome")
            return
        }
        let decoded = try JSONDecoder().decode(ACPFsReadResult.self, from: body)
        #expect(decoded.content == "fresh\nbuffer")
    }

    @Test("serveRead returns a failure message for a missing file")
    func serveReadMissingFile() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID()).txt")
        let outcome = await ACPSessionRunner.serveRead(
            target: missing, liveBuffer: nil, line: nil, limit: nil
        )
        guard case .failure = outcome else {
            Issue.record("expected failure outcome for missing file")
            return
        }
    }

    private func makeRunner(
        onUserCancel: (() -> Void)? = nil
    ) throws -> (ACPSessionRunner, ACPMockClient) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rn-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(id: "s", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))

        let mock = ACPMockClient()
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "wt", title: "t")
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: mock),
            store: store,
            sessionId: "s",
            worktreePath: FileManager.default.temporaryDirectory.path,
            onUserCancel: onUserCancel
        )
        return (runner, mock)
    }

    // MARK: - onPersist callback tests

    @Test("onPersist fires after persistFromIndex writes a message")
    func onPersistFiresAfterPersistFromIndex() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rn-onpersist-\(UUID().uuidString).sqlite")
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(id: "s", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))

        var posts = 0
        var observedStoredMessage = false
        let mock = ACPMockClient()
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "wt", title: "t")
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: mock),
            store: store,
            sessionId: "s",
            worktreePath: FileManager.default.temporaryDirectory.path,
            onPersist: {
                posts += 1
                observedStoredMessage = (try? store.loadMessages(sessionId: "s").isEmpty == false) == true
            }
        )

        session.appendSystemNotice("hello")
        runner.persistFromIndex(0)
        await runner.flushPersistence()
        #expect(posts >= 1)
        #expect(observedStoredMessage)
    }

    @Test("onPersist fires after persistIndices writes a message")
    func onPersistFiresAfterPersistIndices() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rn-onpersist-idx-\(UUID().uuidString).sqlite")
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(id: "s", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))

        var posts = 0
        let mock = ACPMockClient()
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "wt", title: "t")
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: mock),
            store: store,
            sessionId: "s",
            worktreePath: FileManager.default.temporaryDirectory.path,
            onPersist: { posts += 1 }
        )

        session.appendSystemNotice("hello")
        runner.persistIndices([0])
        await runner.flushPersistence()
        #expect(posts >= 1)
    }

    @Test("persistIndices preserves stored full tool content after metadata-only update")
    func persistIndicesPreservesStoredFullToolContentAfterMetadataOnlyUpdate() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rn-persist-truncated-tool-\(UUID().uuidString).sqlite")
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(id: "s", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))

        let mock = ACPMockClient()
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "wt", title: "t")
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: mock),
            store: store,
            sessionId: "s",
            worktreePath: FileManager.default.temporaryDirectory.path
        )

        let fullContent = String(repeating: "full-content-line\n", count: 400)
        let original = ACPMessage.toolCall(.init(
            toolCallId: "tool-1",
            title: "Run",
            kind: "execute",
            status: "completed",
            content: fullContent
        ))
        session.replaceTranscriptMessages([original])
        runner.persistIndices([0])

        session.transcript.setVisibleHead(1)
        guard case .toolCall(let truncated) = session.transcript.messages[0] else {
            Issue.record("expected tool call")
            return
        }
        #expect(truncated.isContentTruncated)
        #expect(truncated.content.count < fullContent.count)

        let dirty = session.apply(.toolCallUpdate(.init(
            toolCallId: "tool-1",
            metadata: AnyCodable([
                "terminal_output_delta": AnyCodable([
                    "terminal_id": AnyCodable("term-1"),
                    "data": AnyCodable("tail\n")
                ])
            ])
        )))
        runner.persistIndices(dirty)
        await runner.flushPersistence()

        let rows = try store.loadMessages(sessionId: "s")
        let row = try #require(rows.first(where: { $0.kind == "tool_call" }))
        let decoded = try ACPMessageCodec.decode(kind: row.kind, payload: row.payload)
        guard case .toolCall(let persisted) = decoded else {
            Issue.record("expected persisted tool call")
            return
        }
        #expect(persisted.content == fullContent)
        #expect(persisted.terminalIds == ["term-1"])
    }

    @Test("persistIndices stores replacement tool content after truncation")
    func persistIndicesStoresReplacementToolContentAfterTruncation() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rn-persist-replacement-tool-\(UUID().uuidString).sqlite")
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(id: "s", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))

        let mock = ACPMockClient()
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "wt", title: "t")
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: mock),
            store: store,
            sessionId: "s",
            worktreePath: FileManager.default.temporaryDirectory.path
        )

        let originalContent = String(repeating: "old-content-line\n", count: 400)
        let replacementContent = String(repeating: "new-content-line\n", count: 350)
        let original = ACPMessage.toolCall(.init(
            toolCallId: "tool-1",
            title: "Run",
            kind: "execute",
            status: "completed",
            content: originalContent
        ))
        session.replaceTranscriptMessages([original])
        runner.persistIndices([0])

        session.transcript.setVisibleHead(1)
        let dirty = session.apply(.toolCallUpdate(.init(
            toolCallId: "tool-1",
            status: "completed",
            content: [.content(.text(replacementContent))]
        )))
        runner.persistIndices(dirty)
        await runner.flushPersistence()

        let rows = try store.loadMessages(sessionId: "s")
        let row = try #require(rows.first(where: { $0.kind == "tool_call" }))
        let decoded = try ACPMessageCodec.decode(kind: row.kind, payload: row.payload)
        guard case .toolCall(let persisted) = decoded else {
            Issue.record("expected persisted tool call")
            return
        }
        #expect(persisted.content == replacementContent)
        #expect(persisted.isContentTruncated == false)
    }

    @Test("persistIndices updates deterministic row kind that appeared after runner initialization")
    func persistIndicesUpdatesLateDeterministicRowCollisionKind() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rn-persist-collision-\(UUID().uuidString).sqlite")
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(id: "s", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))

        let mock = ACPMockClient()
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "wt", title: "t")
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: mock),
            store: store,
            sessionId: "s",
            worktreePath: FileManager.default.temporaryDirectory.path
        )

        let stale = ACPMessage.agent(id: UUID(), StreamingText("stale"))
        try store.appendMessage(
            sessionId: "s",
            id: "msg-s-0",
            kind: stale.kind,
            seq: 0,
            payload: ACPMessageCodec.encode(stale),
            createdAt: 0
        )

        session.appendSystemNotice("fresh")
        runner.persistIndices([0])
        await runner.flushPersistence()

        let rows = try store.loadMessages(sessionId: "s")
        let row = try #require(rows.first(where: { $0.id == "msg-s-0" }))
        #expect(row.kind == "system")
        let decoded = try ACPMessageCodec.decode(kind: row.kind, payload: row.payload)
        guard case .systemNotice(_, let text) = decoded else {
            Issue.record("expected system notice")
            return
        }
        #expect(text == "fresh")
    }

    @Test("onPersist fires on stop()")
    func onPersistFiresOnStop() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rn-onpersist-stop-\(UUID().uuidString).sqlite")
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(id: "s", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))

        var posts = 0
        let mock = ACPMockClient()
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "wt", title: "t")
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: mock),
            store: store,
            sessionId: "s",
            worktreePath: FileManager.default.temporaryDirectory.path,
            onPersist: { posts += 1 }
        )

        runner.stop()
        #expect(posts >= 1)
    }

    @Test("runner does not persist when it has lost the session lease")
    func persistSkippedWhenLeaseLost() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rn-lease-lost-\(UUID().uuidString).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let sid = "s"
        try store.upsertSession(.init(id: sid, agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))

        // Seize the lease for a DIFFERENT instance than the runner's ownerInstanceId.
        let now = Int64(Date().timeIntervalSince1970)
        try store.seizeLease(sessionId: sid, instanceId: "OTHER", pid: Int64(getpid()), now: now)

        let mock = ACPMockClient()
        let session = ACPSession(id: sid, agentId: "claude", worktreeId: "wt", title: "t")
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: mock),
            store: store,
            sessionId: sid,
            worktreePath: FileManager.default.temporaryDirectory.path,
            ownerInstanceId: "ME"
        )

        // Put one message in the transcript, then attempt to persist.
        session.appendSystemNotice("should not land")
        runner.persistFromIndex(0)
        await runner.flushPersistence()

        // Nothing should have been written — the lease is held by "OTHER", not "ME".
        #expect(try store.messageCount(sessionId: sid) == 0)
    }

    @Test("runner persists when it holds the session lease")
    func persistProceedsWhenLeaseHeld() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rn-lease-held-\(UUID().uuidString).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let sid = "s"
        try store.upsertSession(.init(id: sid, agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))

        // Seize the lease for "ME" — same as the runner's ownerInstanceId.
        let now = Int64(Date().timeIntervalSince1970)
        try store.seizeLease(sessionId: sid, instanceId: "ME", pid: Int64(getpid()), now: now)

        let mock = ACPMockClient()
        let session = ACPSession(id: sid, agentId: "claude", worktreeId: "wt", title: "t")
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: mock),
            store: store,
            sessionId: sid,
            worktreePath: FileManager.default.temporaryDirectory.path,
            ownerInstanceId: "ME"
        )

        session.appendSystemNotice("should land")
        runner.persistFromIndex(0)
        await runner.flushPersistence()

        // The lease owner matches, so the message must be written.
        #expect(try store.messageCount(sessionId: sid) == 1)
    }

    @Test("persistQueue skipped when lease is held by another instance")
    func persistQueueSkippedWhenLeaseHeldByOther() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rn-queue-lease-lost-\(UUID().uuidString).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let sid = "s"
        try store.upsertSession(.init(id: sid, agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))

        // Seize the lease for a DIFFERENT instance.
        let now = Int64(Date().timeIntervalSince1970)
        try store.seizeLease(sessionId: sid, instanceId: "OTHER", pid: Int64(getpid()), now: now)

        let mock = ACPMockClient()
        let session = ACPSession(id: sid, agentId: "claude", worktreeId: "wt", title: "t")
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: mock),
            store: store,
            sessionId: sid,
            worktreePath: FileManager.default.temporaryDirectory.path,
            ownerInstanceId: "ME"
        )

        // Enqueue a prompt item on the in-memory session and attempt to persist it.
        session.queue.append(QueuedPrompt(id: UUID(), blocks: [], status: .pending))
        runner.persistQueue()

        // The lease is held by "OTHER", so nothing must have been written.
        #expect(try store.loadQueue(sessionId: sid).isEmpty)
    }

    // MARK: - Fix 3 (P2): Terminal-create lease gate

    @Test("terminal create requires an authoritative lease check")
    func terminalCreateDeniedWhenAuthoritativeLeaseCheckFails() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rn-terminal-lease-\(UUID().uuidString).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let sid = "s"
        try store.upsertSession(.init(id: sid, agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))

        // The cache still says this runner owns the lease, but the authoritative
        // check represents a takeover that landed before the side effect.
        let now = Int64(Date().timeIntervalSince1970)
        try store.seizeLease(sessionId: sid, instanceId: "ME", pid: Int64(getpid()), now: now)

        let mock = ACPMockClient()
        let session = ACPSession(id: sid, agentId: "claude", worktreeId: "wt", title: "t")
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: mock),
            store: store,
            sessionId: sid,
            worktreePath: FileManager.default.temporaryDirectory.path,
            ownerInstanceId: "ME",
            canWrite: { true },
            validateLease: { false }
        )
        runner.start()
        defer { runner.stop() }

        // Request a terminal/create after the authoritative check has rejected
        // the stale cached authority.
        let params = ACPTerminalCreateParams(
            sessionId: sid, command: "/bin/echo",
            args: ["hi"], env: nil, cwd: nil, outputByteLimit: nil)
        mock.emitTerminal(.create(id: .number(99), params: params))

        // Wait for a response.
        for _ in 0..<50 {
            if mock.terminalResponses[.number(99)] != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard case .failure(let err)? = mock.terminalResponses[.number(99)] else {
            Issue.record("expected a failure response from the terminal-create gate")
            return
        }
        // Must be denied with the lease-lost error code, not a spawn error.
        #expect(err.code == -32003,
                "terminal create must respond with code -32003 (lease lost) not a spawn error")
        // No terminal must have been created on the host.
        #expect(runner.session.terminalHost.terminals.isEmpty,
                "no terminal must be created when the lease is held by another instance")
    }

    // MARK: - Fix 2 (P2): cancel RPC gated on lease

    @Test("userCancel does not send session/cancel when lease is held by another instance")
    func userCancelSkipsCancelRPCWhenLeaseLost() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rn-cancel-gate-\(UUID().uuidString).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let sid = "s"
        try store.upsertSession(.init(id: sid, agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))

        // Seize the lease for a DIFFERENT instance than the runner's ownerInstanceId.
        let now = Int64(Date().timeIntervalSince1970)
        try store.seizeLease(sessionId: sid, instanceId: "OTHER", pid: Int64(getpid()), now: now)

        let mock = ACPMockClient()
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
        runner.start()
        defer { runner.stop() }

        // userCancel must return without sending session/cancel.
        await runner.userCancel()

        // No session/cancel must have been sent.
        #expect(!mock.sent.contains { $0.method == "session/cancel" },
                "userCancel must not send session/cancel when the lease is held by another instance")
    }

    @Test("persistSessionRow skipped when lease is held by another instance")
    func persistSessionRowSkippedWhenLeaseHeldByOther() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rn-session-row-lease-lost-\(UUID().uuidString).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let sid = "s"
        let seedTitle = "original-title"
        try store.upsertSession(.init(id: sid, agentId: "claude", title: seedTitle,
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))

        // Seize the lease for a DIFFERENT instance.
        let now = Int64(Date().timeIntervalSince1970)
        try store.seizeLease(sessionId: sid, instanceId: "OTHER", pid: Int64(getpid()), now: now)

        let mock = ACPMockClient()
        let session = ACPSession(id: sid, agentId: "claude", worktreeId: "wt", title: seedTitle)
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: mock),
            store: store,
            sessionId: sid,
            worktreePath: FileManager.default.temporaryDirectory.path,
            ownerInstanceId: "ME"
        )

        // Mutate the in-memory title and attempt to flush it to the store.
        session.title = "new-title-should-not-land"
        runner.persistSessionRow()

        // The stored row must still have the original title.
        let row = try store.loadSession(id: sid)
        #expect(row?.title == seedTitle)
    }

    @Test("generated prompt title does not overwrite stored manual title")
    func generatedPromptTitleDoesNotOverwriteStoredManualTitle() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rn-generated-title-preserve-\(UUID().uuidString).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let sid = "s"
        try store.upsertSession(.init(id: sid, agentId: "claude", title: "Remote Title",
            titleSource: .manual,
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))

        let mock = ACPMockClient()
        mock.script(method: "session/prompt") { _ in Data("{}".utf8) }
        let session = ACPSession(id: sid, agentId: "claude", worktreeId: "wt", title: "New session")
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: mock),
            store: store,
            sessionId: sid,
            worktreePath: FileManager.default.temporaryDirectory.path
        )

        let succeeded = await withCheckedContinuation { continuation in
            runner.send(text: "Generated from stale writer", attachments: []) { succeeded in
                continuation.resume(returning: succeeded)
            }
        }

        #expect(succeeded)
        await runner.flushPersistence()
        let row = try #require(try store.loadSession(id: sid))
        #expect(row.title == "Remote Title")
        #expect(row.titleSource == .manual)
        #expect(session.title == "Remote Title")
        #expect(session.titleSource == .manual)
    }

    @Test("first prompt prepends pending MCP preamble wire-only and clears it")
    func firstPromptPrependsPreamble() async throws {
        let (runner, mock) = try makeRunner()
        runner.session.pendingMCPPreamble = "<alas-workspace-context>ctx</alas-workspace-context>"
        mock.script(method: "session/prompt") { _ in Data("{}".utf8) }

        let ok = await withCheckedContinuation { c in
            runner.send(text: "hello", attachments: []) { c.resume(returning: $0) }
        }
        #expect(ok == true)

        let params = try #require(
            mock.sent.first { $0.method == "session/prompt" }?.params as? ACPSessionPromptParams)
        #expect(params.prompt.count == 2)
        guard case let .text(first) = params.prompt[0] else {
            Issue.record("expected leading text block")
            return
        }
        #expect(first == "<alas-workspace-context>ctx</alas-workspace-context>")
        guard case let .text(second) = params.prompt[1] else {
            Issue.record("expected user text block")
            return
        }
        #expect(second == "hello")

        // Cleared + marked sent; transcript shows only the typed text.
        #expect(runner.session.pendingMCPPreamble == nil)
        #expect(runner.session.mcpPreambleSent == true)
        #expect(runner.session.transcript.messages.contains {
            if case .user(_, _, let text, _, _) = $0 {
                return text.contains("alas-workspace-context")
            }
            return false
        } == false)
    }

    @Test("second prompt does not re-send the MCP preamble")
    func secondPromptOmitsPreamble() async throws {
        let (runner, mock) = try makeRunner()
        runner.session.pendingMCPPreamble = "<ctx>"
        mock.script(method: "session/prompt") { _ in Data("{}".utf8) }

        for text in ["one", "two"] {
            _ = await withCheckedContinuation { c in
                runner.send(text: text, attachments: []) { c.resume(returning: $0) }
            }
        }
        let prompts = mock.sent.filter { $0.method == "session/prompt" }
            .compactMap { $0.params as? ACPSessionPromptParams }
        #expect(prompts.count == 2)
        #expect(prompts[0].prompt.count == 2)
        #expect(prompts[1].prompt.count == 1)
    }

    @Test("failed prompt keeps the MCP preamble pending")
    func failedPromptKeepsPreamblePending() async throws {
        let (runner, _) = try makeRunner() // no session/prompt script → send fails
        runner.session.pendingMCPPreamble = "<ctx>"

        let ok = await withCheckedContinuation { c in
            runner.send(text: "hello", attachments: []) { c.resume(returning: $0) }
        }
        #expect(ok == false)
        #expect(runner.session.pendingMCPPreamble == "<ctx>")
        #expect(runner.session.mcpPreambleSent == false)
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while !condition() {
            if DispatchTime.now().uptimeNanoseconds >= deadline { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(condition())
    }
}

private final class PermissionOrderingClient: ACPClient {
    private let updatesCont: AsyncStream<ACPSessionUpdateParams>.Continuation
    private let permissionsCont: AsyncStream<(id: JSONRPCID, params: ACPPermissionRequestParams)>.Continuation
    private let updateCountLock = NSLock()
    private var _yieldedUpdateCount = 0
    private(set) var permissionResponses: [JSONRPCID: ACPPermissionResponse] = [:]

    let incomingUpdates: AsyncStream<ACPSessionUpdateParams>
    let permissionRequests: AsyncStream<(id: JSONRPCID, params: ACPPermissionRequestParams)>
    let fileRequests = AsyncStream<ACPFileRequest> { $0.finish() }
    let terminalRequests = AsyncStream<ACPTerminalRequest> { $0.finish() }
    let questionRequests = AsyncStream<ACPQuestionRequest> { $0.finish() }

    var yieldedUpdateCount: Int {
        updateCountLock.lock()
        defer { updateCountLock.unlock() }
        return _yieldedUpdateCount
    }

    init() {
        var updatesCont: AsyncStream<ACPSessionUpdateParams>.Continuation!
        incomingUpdates = AsyncStream { updatesCont = $0 }
        self.updatesCont = updatesCont

        var permissionsCont: AsyncStream<(id: JSONRPCID, params: ACPPermissionRequestParams)>.Continuation!
        permissionRequests = AsyncStream { permissionsCont = $0 }
        self.permissionsCont = permissionsCont
    }

    func emit(_ update: ACPSessionUpdate) {
        updateCountLock.lock()
        _yieldedUpdateCount += 1
        updateCountLock.unlock()
        updatesCont.yield(.init(sessionId: "s", update: update))
    }

    func emitPermission() {
        let params = ACPPermissionRequestParams(
            sessionId: "s",
            toolCall: .init(
                toolCallId: "tc-permission",
                title: "Run command",
                kind: "execute",
                status: "pending",
                content: nil,
                locations: nil,
                rawInput: nil,
                rawOutput: nil
            ),
            options: [
                .init(optionId: "allow", name: "Allow", kind: "allow_once"),
                .init(optionId: "reject", name: "Reject", kind: "reject_once")
            ]
        )
        permissionsCont.yield((id: .number(11), params: params))
    }

    func send(_ request: ACPRequest) async throws -> ACPResponse {
        throw ACPClientError.noScript(method: request.method)
    }

    func notify(_ request: ACPRequest) async throws {}
    func respondToPermission(id: JSONRPCID, response: ACPPermissionResponse) {
        permissionResponses[id] = response
    }
    func respondToFileRequest(id: JSONRPCID, result: Result<Data, JSONRPCError>) {}
    func respondToTerminalRequest(id: JSONRPCID, result: Result<Data, JSONRPCError>) {}
    func respondToQuestion(id: JSONRPCID, response: ACPQuestionResponse) {}

    func shutdown() async {
        updatesCont.finish()
        permissionsCont.finish()
    }
}

private final class BoundaryRaceClient: ACPClient, @unchecked Sendable {
    private let updatesCont: AsyncStream<ACPSessionUpdateParams>.Continuation
    private let updateCountLock = NSLock()
    private var _yieldedUpdateCount = 0
    private var promptCount = 0
    private var secondPromptGate: AsyncGate?
    private(set) var sent: [ACPRequest] = []

    let incomingUpdates: AsyncStream<ACPSessionUpdateParams>
    let permissionRequests = AsyncStream<(id: JSONRPCID, params: ACPPermissionRequestParams)> { $0.finish() }
    let fileRequests = AsyncStream<ACPFileRequest> { $0.finish() }
    let terminalRequests = AsyncStream<ACPTerminalRequest> { $0.finish() }
    let questionRequests = AsyncStream<ACPQuestionRequest> { $0.finish() }

    var yieldedUpdateCount: Int {
        updateCountLock.lock()
        defer { updateCountLock.unlock() }
        return _yieldedUpdateCount
    }

    init() {
        var updatesCont: AsyncStream<ACPSessionUpdateParams>.Continuation!
        incomingUpdates = AsyncStream { updatesCont = $0 }
        self.updatesCont = updatesCont
    }

    func send(_ request: ACPRequest) async throws -> ACPResponse {
        sent.append(request)
        guard request.method == "session/prompt" else {
            throw ACPClientError.noScript(method: request.method)
        }
        updateCountLock.lock()
        promptCount += 1
        let currentPromptCount = promptCount
        _yieldedUpdateCount += 2
        let secondPromptGate = self.secondPromptGate
        updateCountLock.unlock()
        updatesCont.yield(.init(sessionId: "s", update: .agentMessageChunk(.text("first"))))
        if currentPromptCount == 2 {
            await secondPromptGate?.wait()
        }
        return ACPResponse(body: Data("{}".utf8))
    }

    func notify(_ request: ACPRequest) async throws {
        sent.append(request)
    }

    func emitReserved(_ update: ACPSessionUpdate) {
        updatesCont.yield(.init(sessionId: "s", update: update))
    }

    func emitFresh(_ update: ACPSessionUpdate) {
        updateCountLock.lock()
        _yieldedUpdateCount += 1
        updateCountLock.unlock()
        updatesCont.yield(.init(sessionId: "s", update: update))
    }

    func holdSecondPrompt(until gate: AsyncGate) {
        updateCountLock.lock()
        secondPromptGate = gate
        updateCountLock.unlock()
    }

    func respondToPermission(id: JSONRPCID, response: ACPPermissionResponse) {}
    func respondToFileRequest(id: JSONRPCID, result: Result<Data, JSONRPCError>) {}
    func respondToTerminalRequest(id: JSONRPCID, result: Result<Data, JSONRPCError>) {}
    func respondToQuestion(id: JSONRPCID, response: ACPQuestionResponse) {}

    func shutdown() async {
        updatesCont.finish()
    }
}

private final class StreamingBatchACPClient: ACPClient {
    private let updatesCont: AsyncStream<ACPSessionUpdateParams>.Continuation
    private let chunksEmitted = AsyncGate()
    private let promptCanFinish = AsyncGate()
    private let chunkAcknowledgementRecorder: DurableAcknowledgementRecorder?

    let incomingUpdates: AsyncStream<ACPSessionUpdateParams>
    let permissionRequests = AsyncStream<(id: JSONRPCID, params: ACPPermissionRequestParams)> { $0.finish() }
    let fileRequests = AsyncStream<ACPFileRequest> { $0.finish() }
    let terminalRequests = AsyncStream<ACPTerminalRequest> { $0.finish() }
    let questionRequests = AsyncStream<ACPQuestionRequest> { $0.finish() }
    var yieldedUpdateCount: Int { 2 }

    init(chunkAcknowledgementRecorder: DurableAcknowledgementRecorder? = nil) {
        self.chunkAcknowledgementRecorder = chunkAcknowledgementRecorder
        var updatesCont: AsyncStream<ACPSessionUpdateParams>.Continuation!
        incomingUpdates = AsyncStream { updatesCont = $0 }
        self.updatesCont = updatesCont
    }

    private func chunkAcknowledgement() -> ACPDurableConsumptionAcknowledgement? {
        guard let chunkAcknowledgementRecorder else { return nil }
        return { chunkAcknowledgementRecorder.record() }
    }

    func send(_ request: ACPRequest) async throws -> ACPResponse {
        guard request.method == "session/prompt" else {
            throw ACPClientError.noScript(method: request.method)
        }
        updatesCont.yield(.init(
            sessionId: "s",
            update: .agentMessageChunk(.text("hello ")),
            durableConsumptionAcknowledgement: chunkAcknowledgement()
        ))
        updatesCont.yield(.init(
            sessionId: "s",
            update: .agentMessageChunk(.text("world")),
            durableConsumptionAcknowledgement: chunkAcknowledgement()
        ))
        await chunksEmitted.open()
        await promptCanFinish.wait()
        return ACPResponse(body: Data("{}".utf8))
    }

    func waitForChunks() async {
        await chunksEmitted.wait()
    }

    func finishPrompt() async {
        await promptCanFinish.open()
    }

    func emitUsageUpdate() {
        updatesCont.yield(.init(
            sessionId: "s",
            update: .usageUpdate(.init(used: 1, size: 100, cost: nil))
        ))
    }

    func emitAgentChunk(_ text: String) {
        updatesCont.yield(.init(sessionId: "s", update: .agentMessageChunk(.text(text))))
    }

    func emitToolCallUpdate(_ update: ACPToolCallUpdate) {
        updatesCont.yield(.init(sessionId: "s", update: .toolCallUpdate(update)))
    }

    func notify(_ request: ACPRequest) async throws {}
    func respondToPermission(id: JSONRPCID, response: ACPPermissionResponse) {}
    func respondToFileRequest(id: JSONRPCID, result: Result<Data, JSONRPCError>) {}
    func respondToTerminalRequest(id: JSONRPCID, result: Result<Data, JSONRPCError>) {}
    func respondToQuestion(id: JSONRPCID, response: ACPQuestionResponse) {}
    func shutdown() async {
        updatesCont.finish()
    }
}

private actor AsyncGate {
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

private actor AsyncCounter {
    private var value = 0

    func next() -> Int {
        value += 1
        return value
    }
}

private final class DurableAcknowledgementRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var wasRecorded: Bool {
        recordedCount > 0
    }

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
