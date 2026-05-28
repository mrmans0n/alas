import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACPSessionRunner queue routing")
struct ACPSessionRunnerQueueTests {
    private func mkRunner() throws -> (ACPSessionRunner, ACPMockClient, ACPSession, ACPSessionStore) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rn-q-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(
            id: "s", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        let mock = ACPMockClient()
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "wt", title: "t")
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: mock),
            store: store,
            sessionId: "s",
            worktreePath: FileManager.default.temporaryDirectory.path)
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
        runner.persistQueue()
        runner.flushQueueIfIdle()
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(session.queue.count == 1)
        #expect(session.queue[0].status == .pending)
        #expect(session.queue[0].lastError != nil)
        let persisted = try store.loadQueue(sessionId: "s")
        #expect(persisted == session.queue)
    }

    @Test(".steer while streaming with queue → cancel sent, queue cleared, new prompt sent, snapshot captured")
    func steerClearsAndSends() async throws {
        let (runner, mock, session, store) = try mkRunner()
        mock.script(method: "session/prompt") { _ in Data("null".utf8) }
        // Pre-seed queue + put session in streaming.
        session.attached = true
        session.transcript.streamingState = .streaming
        session.enqueue(blocks: [.text("stale-a")])
        session.enqueue(blocks: [.text("stale-b")])
        runner.persistQueue()

        runner.send(blocks: [.text("redirect")], intent: .steer)
        try await Task.sleep(nanoseconds: 250_000_000)

        // session/cancel was sent
        #expect(mock.sent.contains { $0.method == "session/cancel" })
        // queue is empty after drain (cleared by steer, redirect popped after send)
        #expect(session.queue.isEmpty)
        // session/prompt was sent with the steer blocks
        let prompts = mock.sent.filter { $0.method == "session/prompt" }
        #expect(prompts.count == 1)
        // Undo snapshot captured
        #expect(runner.steerUndoSnapshot()?.count == 2)
        #expect(runner.steerUndoSnapshot()?.map { $0.blocks } == [[.text("stale-a")], [.text("stale-b")]])
        // Persisted queue empty
        #expect(try store.loadQueue(sessionId: "s").isEmpty)
    }

    @Test("steer that races a detach skips the redirect on a torn-down session")
    func steerSkipsRedirectAfterDetach() async throws {
        // Regression: the unstructured steer Task survives the runner +
        // connection it was spawned in. If the user closes the tab while
        // we're awaiting `userCancel`, `ACPSessionManager.detach` flips
        // `session.attached = false` and shuts down the connection but
        // doesn't cancel this task. Without a liveness check, the trailing
        // `sendNow` would append the redirect prompt and persist a
        // `lastError` on the detached session.
        let (runner, mock, session, _) = try mkRunner()
        mock.script(method: "session/prompt") { _ in Data("null".utf8) }
        session.attached = true
        session.transcript.streamingState = .streaming

        runner.send(blocks: [.text("redirect")], intent: .steer)
        // Simulate the detach landing while userCancel is still in flight.
        session.attached = false

        try await Task.sleep(nanoseconds: 250_000_000)

        // session/cancel still went out (we started userCancel before the
        // detach was observable), but the redirect prompt was suppressed.
        #expect(mock.sent.contains { $0.method == "session/cancel" })
        let prompts = mock.sent.filter { $0.method == "session/prompt" }
        #expect(prompts.isEmpty)
    }

    @Test("steerUndo() re-prepends snapshot and drains it on next idle")
    func steerUndoRestores() async throws {
        let (runner, mock, session, store) = try mkRunner()
        mock.script(method: "session/prompt") { _ in Data("null".utf8) }
        session.attached = true
        session.transcript.streamingState = .streaming
        session.enqueue(blocks: [.text("a")])
        runner.send(blocks: [.text("redirect")], intent: .steer)
        try await Task.sleep(nanoseconds: 250_000_000)
        // Steer fired: redirect sent, snapshot captured, state .idle.
        #expect(runner.steerUndoSnapshot() != nil)
        #expect(session.queue.isEmpty)
        let promptsAfterSteer = mock.sent.filter { $0.method == "session/prompt" }.count
        #expect(promptsAfterSteer == 1)

        runner.steerUndo()
        try await Task.sleep(nanoseconds: 200_000_000)
        // Undo restored "a" to the queue AND the flusher drained it
        // (state was .idle, so flushQueueIfIdle ran). Final state:
        // queue empty, 2 prompts total (redirect + the undone item).
        #expect(session.queue.isEmpty)
        let promptsAfterUndo = mock.sent.filter { $0.method == "session/prompt" }.count
        #expect(promptsAfterUndo == 2)
        let persisted = try store.loadQueue(sessionId: "s")
        #expect(persisted.isEmpty)
        // Snapshot is consumed after undo.
        #expect(runner.steerUndoSnapshot() == nil)
    }

    @Test("steerUndo() is a no-op when snapshot is empty / expired")
    func steerUndoEmptyNoop() {
        let (runner, _, session, _) = try! mkRunner()
        session.enqueue(blocks: [.text("x")])
        runner.steerUndo()
        // Queue unchanged.
        #expect(session.queue.count == 1)
        #expect(session.queue[0].blocks == [.text("x")])
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
            if case .user(_, let text, _) = msg { userTexts.append(text) }
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

    @Test("steer drops a .sending head and excludes it from the undo snapshot")
    func steerDiscardsSendingHead() async throws {
        // Regression for the race where steer happens while the flusher
        // has already marked the head .sending. The .sending item must
        // be evicted along with the .pending tail; otherwise the stale
        // in-flight RPC would settle later and mutate session state
        // behind the steer.
        let (runner, mock, session, store) = try mkRunner()
        mock.script(method: "session/prompt") { _ in Data("null".utf8) }
        session.attached = true
        // Simulate: flusher already promoted the head to .sending; a
        // pending tail is sitting behind it.
        session.enqueue(blocks: [.text("in-flight")])
        session.markQueueHeadSending()
        session.enqueue(blocks: [.text("tail-pending")])
        runner.persistQueue()
        session.transcript.streamingState = .sending

        runner.send(blocks: [.text("redirect")], intent: .steer)
        try await Task.sleep(nanoseconds: 250_000_000)

        // Both queued items are gone; only the redirect prompt fired.
        #expect(session.queue.isEmpty)
        #expect(mock.sent.contains { $0.method == "session/cancel" })
        let prompts = mock.sent.filter { $0.method == "session/prompt" }
        #expect(prompts.count == 1)
        // The .sending head MUST NOT appear in the undo snapshot — it was
        // mid-flight; resurrecting it would just re-fire the prompt the
        // user steered away from. Only the .pending tail is restorable.
        let snapshot = runner.steerUndoSnapshot() ?? []
        #expect(snapshot.map { $0.blocks } == [[.text("tail-pending")]])
        #expect(try store.loadQueue(sessionId: "s").isEmpty)
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

    @Test("queue survives runner restart: persist + restart + drain")
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
        // the head to .sending and persisting.
        session1.markQueueHeadSending()
        runner1.persistQueue()
        let persisted = try store.loadQueue(sessionId: "rt")
        #expect(persisted.count == 2)
        #expect(persisted[0].status == .sending)

        // Second runner: fresh session, restored queue, then drain.
        let mock2 = ACPMockClient()
        mock2.script(method: "session/prompt") { _ in Data("null".utf8) }
        let mgr = ACPSessionManager(worktreeId: "wt", worktreePath: FileManager.default.temporaryDirectory.path, store: store)
        let session2 = mgr.openSession(id: "rt")!
        #expect(session2.queue.count == 2)
        // .sending was normalized to .pending on restore.
        #expect(session2.queue[0].status == .pending)
        let runner2 = ACPSessionRunner(
            session: session2, connection: ACPConnection(client: mock2), store: store,
            sessionId: "rt", worktreePath: FileManager.default.temporaryDirectory.path)
        runner2.flushQueueIfIdle()
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(session2.queue.isEmpty)
        let prompts = mock2.sent.filter { $0.method == "session/prompt" }
        #expect(prompts.count == 2)
    }
}
