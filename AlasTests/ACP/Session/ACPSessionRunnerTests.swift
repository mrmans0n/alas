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
                  case .agent(_, let buffer) = session.transcript.messages[1]
            else { return false }
            return buffer.value == "first second"
                && session.transcript.completedOutputBoundaryMessageIds == [session.transcript.messages[1].stableId]
        }

        client.emitFresh(.agentMessageChunk(.text("next task")))
        try await waitUntil { session.transcript.messages.count == 3 }
        if case .agent(_, let first) = session.transcript.messages[1],
           case .agent(_, let second) = session.transcript.messages[2] {
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

        if case .user(_, let firstUser, _) = session.transcript.messages[0],
           case .agent(_, let firstAnswer) = session.transcript.messages[1],
           case .user(_, let secondUser, _) = session.transcript.messages[2] {
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

        #expect(session.transcript.messages.count == 1)
        let rows = try store.loadMessages(sessionId: "s")
        #expect(rows.count == 1)
        #expect(rows[0].kind == "agent")
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
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: mock),
            store: store,
            sessionId: "s",
            worktreePath: FileManager.default.temporaryDirectory.path
        )

        runner.send(text: "new turn", attachments: [])
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(session.followsTranscriptTail)
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
