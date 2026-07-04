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

        let succeeded = await withCheckedContinuation { continuation in
            runner.send(text: "hello", attachments: []) { succeeded in
                continuation.resume(returning: succeeded)
            }
        }

        #expect(succeeded == true)
        #expect(runner.session.lastError == nil)
        #expect(runner.session.transcript.streamingState == .idle)
    }

    @Test("question request waits for user answer and responds to client")
    func questionRequestWaitsForUserAnswer() async throws {
        let (runner, mock) = try makeRunner()
        runner.start()

        let params = ACPQuestionRequestParams(
            toolCallId: "call_123",
            title: "Need input",
            questions: [
                .init(
                    id: "q1",
                    prompt: "Which implementation path should I take?",
                    options: [
                        .init(id: "cursor", label: "Implement Cursor first"),
                        .init(id: "generic", label: "Wait for generic ACP")
                    ],
                    allowMultiple: false
                )
            ]
        )

        mock.emitQuestion(id: .number(42), params: params)

        try await waitUntil {
            runner.session.transcript.pendingQuestion?.params == params
                && runner.session.transcript.streamingState == .awaitingInput
        }

        runner.answerQuestion(.init(outcome: .answered(answers: [
            .init(questionId: "q1", selectedOptionIds: ["cursor"])
        ])))

        try await waitUntil {
            mock.questionResponses[.number(42)] == .init(outcome: .answered(answers: [
                .init(questionId: "q1", selectedOptionIds: ["cursor"])
            ]))
        }
        #expect(runner.session.transcript.pendingQuestion == nil)
        #expect(runner.session.transcript.streamingState == .idle)
    }

    @Test("question answer does not flush queued prompt while original prompt is active")
    func questionAnswerDoesNotFlushQueueWhilePromptActive() async throws {
        let (runner, mock) = try makeRunner()
        runner.session.agentState = .ready
        runner.start()

        let promptCounter = AsyncCounter()
        let firstStarted = AsyncGate()
        let finishFirst = AsyncGate()
        mock.scriptAsync(method: "session/prompt") { _ in
            let promptNumber = await promptCounter.next()
            if promptNumber == 1 {
                await firstStarted.open()
                await finishFirst.wait()
            }
            return Data("{}".utf8)
        }

        runner.send(text: "first", attachments: [])
        await firstStarted.wait()
        try await waitUntil { runner.session.transcript.streamingState == .sending }

        runner.send(text: "queued", attachments: [], intent: .auto)
        #expect(runner.session.queue.count == 1)

        let params = ACPQuestionRequestParams(
            toolCallId: "call_123",
            title: "Need input",
            questions: [
                .init(
                    id: "q1",
                    prompt: "Which implementation path should I take?",
                    options: [
                        .init(id: "cursor", label: "Implement Cursor first"),
                        .init(id: "generic", label: "Wait for generic ACP")
                    ],
                    allowMultiple: false
                )
            ]
        )
        mock.emitQuestion(id: .number(42), params: params)
        try await waitUntil {
            runner.session.transcript.pendingQuestion?.params == params
                && runner.session.transcript.streamingState == .awaitingInput
        }

        runner.answerQuestion(.init(outcome: .answered(answers: [
            .init(questionId: "q1", selectedOptionIds: ["cursor"])
        ])))

        try await waitUntil {
            mock.questionResponses[.number(42)] != nil
        }
        #expect(runner.session.transcript.pendingQuestion == nil)
        #expect(runner.session.transcript.streamingState == .sending)
        #expect(runner.session.queue.count == 1)
        #expect(mock.sent.filter { $0.method == "session/prompt" }.count == 1)

        await finishFirst.open()
        try await waitUntil {
            mock.sent.filter { $0.method == "session/prompt" }.count == 2
                && runner.session.queue.isEmpty
                && runner.session.transcript.streamingState == .idle
        }
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

        if case .user(_, _, let firstUser, _) = session.transcript.messages[0],
           case .agent(_, _, let firstAnswer) = session.transcript.messages[1],
           case .user(_, _, let secondUser, _) = session.transcript.messages[2] {
            #expect(firstUser == "hello")
            #expect(firstAnswer.value == "first second")
            #expect(secondUser == "next")
        } else {
            Issue.record("expected delayed chunk to land before the queued next prompt")
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

        let row = try #require(try runner.store.loadSession(id: "s"))
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

    @Test("initial tool image enrichments apply during load replay suppression")
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
        runner.start()
        defer { runner.stop() }

        mock.emit(.init(
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

        try await waitUntil {
            guard let row = try? store.loadMessages(sessionId: "s").first,
                  let decoded = try? ACPMessageCodec.decode(kind: row.kind, payload: row.payload),
                  case .toolCall(let persisted) = decoded
            else { return false }
            return persisted.assets.contains(.image(data: "content-image-data", mimeType: "image/png"))
                && persisted.assets.contains(.image(data: "raw-output-data", mimeType: "image/png"))
        }
    }

    @Test("streaming chunks are persisted in a batch when streaming ends")
    func streamingChunksPersistAsBatchOnIdle() async throws {
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

        await mock.finishPrompt()
        #expect(await completed.value)

        let rows = try store.loadMessages(sessionId: "s")
        let agentRow = try #require(rows.first(where: { $0.kind == "agent" }))
        let decoded = try ACPMessageCodec.decode(kind: agentRow.kind, payload: agentRow.payload)
        guard case .agent(_, _, let text) = decoded else {
            Issue.record("expected persisted agent message")
            return
        }
        #expect(text.value == "hello world")
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
        runner.stop()
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

    private func makeRunner() throws -> (ACPSessionRunner, ACPMockClient) {
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
            worktreePath: FileManager.default.temporaryDirectory.path
        )
        return (runner, mock)
    }

    // MARK: - onPersist callback tests

    @Test("onPersist fires after persistFromIndex writes a message")
    func onPersistFiresAfterPersistFromIndex() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rn-onpersist-\(UUID().uuidString).sqlite")
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
        runner.persistFromIndex(0)
        #expect(posts >= 1)
    }

    @Test("onPersist fires after persistIndices writes a message")
    func onPersistFiresAfterPersistIndices() throws {
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
        #expect(posts >= 1)
    }

    @Test("persistIndices preserves stored full tool content after metadata-only update")
    func persistIndicesPreservesStoredFullToolContentAfterMetadataOnlyUpdate() throws {
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
    func persistIndicesStoresReplacementToolContentAfterTruncation() throws {
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
    func persistIndicesUpdatesLateDeterministicRowCollisionKind() throws {
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
    func persistSkippedWhenLeaseLost() throws {
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

        // Nothing should have been written — the lease is held by "OTHER", not "ME".
        #expect(try store.messageCount(sessionId: sid) == 0)
    }

    @Test("runner persists when it holds the session lease")
    func persistProceedsWhenLeaseHeld() throws {
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

    @Test("terminal create denied when lease is held by another instance")
    func terminalCreateDeniedWhenLeaseLost() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rn-terminal-lease-\(UUID().uuidString).sqlite")
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
        runner.start()
        defer { runner.stop() }

        // Request a terminal/create while the lease is held by "OTHER".
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
        let row = try #require(try store.loadSession(id: sid))
        #expect(row.title == "Remote Title")
        #expect(row.titleSource == .manual)
        #expect(session.title == "Remote Title")
        #expect(session.titleSource == .manual)
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

    let incomingUpdates: AsyncStream<ACPSessionUpdateParams>
    let permissionRequests = AsyncStream<(id: JSONRPCID, params: ACPPermissionRequestParams)> { $0.finish() }
    let fileRequests = AsyncStream<ACPFileRequest> { $0.finish() }
    let terminalRequests = AsyncStream<ACPTerminalRequest> { $0.finish() }
    let questionRequests = AsyncStream<ACPQuestionRequest> { $0.finish() }
    var yieldedUpdateCount: Int { 2 }

    init() {
        var updatesCont: AsyncStream<ACPSessionUpdateParams>.Continuation!
        incomingUpdates = AsyncStream { updatesCont = $0 }
        self.updatesCont = updatesCont
    }

    func send(_ request: ACPRequest) async throws -> ACPResponse {
        guard request.method == "session/prompt" else {
            throw ACPClientError.noScript(method: request.method)
        }
        updatesCont.yield(.init(sessionId: "s", update: .agentMessageChunk(.text("hello "))))
        updatesCont.yield(.init(sessionId: "s", update: .agentMessageChunk(.text("world"))))
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
