import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACP subagent sessions")
struct ACPSubagentSessionTests {
    // MARK: - Parent row

    @Test("a spawn appends one subagent row to the parent transcript")
    func spawnAppendsRow() {
        let session = makeSession()
        let dirty = session.apply(.subagentSpawned(.init(
            subagentSessionId: "child-1",
            name: "Explore",
            task: "Find the router",
            capabilities: .cancellable)))

        #expect(dirty == [0])
        #expect(session.transcript.messages.count == 1)
        let descriptor = try? #require(subagentRowDescriptor(in: session, at: 0))
        #expect(descriptor?.subagentSessionId == "child-1")
        #expect(descriptor?.name == "Explore")
        #expect(descriptor?.task == "Find the router")
        #expect(descriptor?.state == .running)
        #expect(descriptor?.capabilities.supportsCancel == true)
        #expect(session.subagentRun("child-1")?.isRunning == true)
    }

    @Test("a repeated spawn neither duplicates the row nor resets the child")
    func repeatedSpawnIsIdempotent() {
        let session = makeSession()
        session.apply(.subagentSpawned(.init(subagentSessionId: "child-1", name: "Explore")))
        session.apply(.subagentStateUpdate(.init(subagentSessionId: "child-1", state: .completed)))
        let dirty = session.apply(.subagentSpawned(.init(subagentSessionId: "child-1", name: "Explore")))

        #expect(dirty.isEmpty)
        #expect(session.transcript.messages.count == 1)
        #expect(session.subagentRun("child-1")?.state == .completed)
    }

    @Test("a terminal state marks the row and stops the child")
    func terminalStateUpdatesRow() {
        let session = makeSession()
        session.apply(.subagentSpawned(.init(subagentSessionId: "child-1", name: "Explore")))
        let dirty = session.apply(.subagentStateUpdate(.init(
            subagentSessionId: "child-1", state: .failed)))

        #expect(dirty == [0])
        #expect(session.subagentRun("child-1")?.isRunning == false)
        let descriptor = try? #require(subagentRowDescriptor(in: session, at: 0))
        #expect(descriptor?.state == .failed)
        #expect(ACPSubagentRowPolicy.showsSpinner(state: .failed) == false)
        guard case .toolCall(let row) = session.transcript.messages[0] else {
            Issue.record("expected a tool-call row")
            return
        }
        #expect(row.status == "failed")
        #expect(row.executionFinishedAt != nil)
    }

    @Test("a failure's diagnostic text is preserved and survives a persist round trip")
    func failureDiagnosticIsPreservedAndPersisted() throws {
        let session = makeSession()
        session.apply(.subagentSpawned(.init(subagentSessionId: "child-1", name: "Explore")))
        session.apply(.subagentStateUpdate(.init(
            subagentSessionId: "child-1", state: .failed, error: "rate limited")))

        #expect(session.subagentRun("child-1")?.lastError == "rate limited")
        let descriptor = try #require(subagentRowDescriptor(in: session, at: 0))
        #expect(descriptor.lastError == "rate limited")

        // Round-trips through the same metadata encode/decode the row
        // itself already relies on for name/task/state.
        let toolCall = descriptor.toolCall(executionStartedAt: nil, executionFinishedAt: nil)
        let encoded = try JSONEncoder().encode(toolCall)
        let decoded = try JSONDecoder().decode(ACPMessage.ToolCall.self, from: encoded)
        #expect(ACPSubagentRowDescriptor(toolCall: decoded)?.lastError == "rate limited")
    }

    @Test("a later update without its own error keeps the earlier diagnostic")
    func failureDiagnosticIsSticky() {
        let session = makeSession()
        session.apply(.subagentSpawned(.init(subagentSessionId: "child-1")))
        session.apply(.subagentStateUpdate(.init(
            subagentSessionId: "child-1", state: .failed, error: "network error")))
        // A housekeeping update for the SAME terminal state, carrying no
        // error of its own (the standard shape, not OpenCode's).
        session.apply(.subagentStateUpdate(.init(subagentSessionId: "child-1", state: .failed)))

        #expect(session.subagentRun("child-1")?.lastError == "network error")
    }

    @Test("a state update for an unknown child changes nothing")
    func unknownChildStateIsIgnored() {
        let session = makeSession()
        let dirty = session.apply(.subagentStateUpdate(.init(
            subagentSessionId: "ghost", state: .completed)))
        #expect(dirty.isEmpty)
        #expect(session.transcript.messages.isEmpty)
    }

    // MARK: - Child transcript

    @Test("child output lands in the child transcript, never the parent's")
    func childOutputStaysInTheChild() {
        let session = makeSession()
        session.apply(.subagentSpawned(.init(subagentSessionId: "child-1")))
        session.applySubagentUpdate(.agentMessageChunk(.text("hello ")), subagentSessionId: "child-1")
        session.applySubagentUpdate(.agentMessageChunk(.text("world")), subagentSessionId: "child-1")
        session.applySubagentUpdate(
            .toolCall(.init(toolCallId: "t1", title: "Read", kind: "read", status: "in_progress")),
            subagentSessionId: "child-1")
        session.applySubagentUpdate(
            .toolCallUpdate(.init(toolCallId: "t1", status: "completed")),
            subagentSessionId: "child-1")

        // The parent still holds exactly the one subagent row.
        #expect(session.transcript.messages.count == 1)

        let run = try? #require(session.subagentRun("child-1"))
        #expect(run?.messages.count == 2)
        guard case .agent(_, _, let buffer) = run?.messages.first else {
            Issue.record("expected the child's prose row")
            return
        }
        #expect(buffer.value == "hello world")
        guard case .toolCall(let toolCall) = run?.messages.last else {
            Issue.record("expected the child's tool call")
            return
        }
        #expect(toolCall.status == "completed")
        #expect(toolCall.executionFinishedAt != nil)
    }

    @Test("a tool call closes the child's prose run, as in the parent transcript")
    func toolCallClosesChildProseRun() {
        let run = ACPSubagentRun(subagentSessionId: "child-1")
        run.apply(.agentMessageChunk(.text("before")))
        run.apply(.toolCall(.init(toolCallId: "t1", title: "Read", kind: "read", status: "completed")))
        run.apply(.agentMessageChunk(.text("after")))

        #expect(run.messages.count == 3)
        guard case .agent(_, _, let first) = run.messages[0],
              case .agent(_, _, let last) = run.messages[2] else {
            Issue.record("expected two separate prose rows around the tool call")
            return
        }
        #expect(first.value == "before")
        #expect(last.value == "after")
    }

    @Test("interleaved message ids extend their own child row")
    func interleavedMessageIdsExtendTheirOwnRow() {
        let run = ACPSubagentRun(subagentSessionId: "child-1")
        run.apply(.agentMessageChunk(.init(messageId: "A", content: .text("a1"))))
        run.apply(.agentMessageChunk(.init(messageId: "B", content: .text("b1"))))
        run.apply(.agentMessageChunk(.init(messageId: "A", content: .text(" a2"))))

        #expect(run.messages.count == 2)
        guard case .agent(_, "A", let a) = run.messages[0],
              case .agent(_, "B", let b) = run.messages[1] else {
            Issue.record("expected one row per message id")
            return
        }
        #expect(a.value == "a1 a2")
        #expect(b.value == "b1")
    }

    @Test("replay reconciles a historical prompt, not only the newest one")
    func replayReconcilesHistoricalPrompt() {
        let run = ACPSubagentRun(subagentSessionId: "child-1")
        // Two hydrated prompts — "p1" is no longer the newest `.user` row.
        run.restore(
            messages: [
                .user(id: UUID(), messageId: "p1", text: "first", attachments: []),
                .agent(id: UUID(), StreamingText("reply")),
                .user(id: UUID(), messageId: "p2", text: "second", attachments: [])
            ],
            createdAts: [Date(), Date(), Date()])

        // `session/load` replays both prompts chronologically, oldest
        // first — the SAME resend semantics as any other row.
        run.applyReplayed(.userMessageChunk(.init(messageId: "p1", content: .text("first"))))
        run.applyReplayed(.userMessageChunk(.init(messageId: "p2", content: .text("second"))))

        #expect(run.messages.count == 3)
        guard case .user(_, _, let firstText, _, _) = run.messages[0],
              case .user(_, _, let secondText, _, _) = run.messages[2] else {
            Issue.record("expected both prompts to be reconciled in place")
            return
        }
        #expect(firstText == "first")
        #expect(secondText == "second")
    }

    @Test("replay does not duplicate an id-less prompt that already persisted")
    func replayDoesNotDuplicateIdLessPrompt() {
        let run = ACPSubagentRun(subagentSessionId: "child-1")
        // An adapter that omits `messageId` on its prompt chunks — the
        // whole prompt already made it to SQLite before reattachment.
        run.restore(
            messages: [.user(id: UUID(), messageId: nil, text: "review this", attachments: [])],
            createdAts: [Date()])

        run.applyReplayed(.userMessageChunk(.text("review this")))

        #expect(run.messages.count == 1)
        guard case .user(_, nil, let text, _, _) = run.messages[0] else {
            Issue.record("expected the single id-less prompt to be reconciled in place")
            return
        }
        #expect(text == "review this")
    }

    @Test("replay reconciles two separate id-less text runs of the same kind without corrupting either")
    func replayReconcilesMultipleIdLessTextRuns() {
        let run = ACPSubagentRun(subagentSessionId: "child-1")
        // Two id-less agent rows separated by a tool call — e.g. the
        // agent narrates, invokes a tool, then narrates again.
        run.restore(
            messages: [
                .agent(id: UUID(), StreamingText("first")),
                .toolCall(.init(toolCallId: "t1", title: "Read", status: "completed")),
                .agent(id: UUID(), StreamingText("second"))
            ],
            createdAts: [Date(), Date(), Date()])

        // `session/load` resends every row chronologically.
        run.applyReplayed(.agentMessageChunk(.text("first")))
        run.applyReplayed(.toolCall(.init(toolCallId: "t1", title: "Read", kind: nil, status: "completed")))
        run.applyReplayed(.agentMessageChunk(.text("second")))

        #expect(run.messages.count == 3)
        guard case .agent(_, nil, let first) = run.messages[0],
              case .toolCall = run.messages[1],
              case .agent(_, nil, let second) = run.messages[2] else {
            Issue.record("expected both id-less runs to stay separate and in place")
            return
        }
        #expect(first.value == "first")
        #expect(second.value == "second")
    }

    @Test("a child prompt's blocks reassemble into one bubble with its attachments")
    func childPromptBlocksReassemble() {
        let run = ACPSubagentRun(subagentSessionId: "child-1")
        run.apply(.userMessageChunk(.init(messageId: "p1", content: .text("Review "))))
        run.apply(.userMessageChunk(.init(
            messageId: "p1",
            content: .resourceLink(uri: "file:///tmp/a.swift", name: "a.swift"))))
        run.apply(.userMessageChunk(.init(messageId: "p1", content: .text("this file"))))

        #expect(run.messages.count == 1)
        guard case .user(_, "p1", let text, let attachments, _) = run.messages[0] else {
            Issue.record("expected one prompt bubble")
            return
        }
        #expect(text == "Review this file")
        #expect(attachments.count == 1)
        #expect(attachments.first?.uri == "file:///tmp/a.swift")
    }

    @Test("a live prompt closed by agent output does not reopen when its id is reused")
    func liveReusedMessageIdDoesNotReopenClosedPrompt() {
        let run = ACPSubagentRun(subagentSessionId: "child-1")
        run.apply(.userMessageChunk(.init(messageId: "p1", content: .text("first task"))))
        run.apply(.agentMessageChunk(.text("reply")))
        // A second turn reusing the SAME id as the first — `userIndex` must
        // not skip past the agent's reply and reopen the closed bubble.
        run.apply(.userMessageChunk(.init(messageId: "p1", content: .text("second task"))))

        #expect(run.messages.count == 3)
        guard case .user(_, "p1", let firstText, _, _) = run.messages[0],
              case .user(_, "p1", let secondText, _, _) = run.messages[2] else {
            Issue.record("expected two separate prompt bubbles, not one concatenated row")
            return
        }
        #expect(firstText == "first task")
        #expect(secondText == "second task")
    }

    @Test("a second turn's plan starts a new row instead of overwriting the first turn's")
    func planStartsNewRowAfterNextTurn() {
        let run = ACPSubagentRun(subagentSessionId: "child-1")
        run.apply(.userMessageChunk(.text("first task")))
        run.apply(.plan([.init(content: "step one", priority: nil, status: "pending")]))
        run.apply(.userMessageChunk(.text("second task")))
        run.apply(.plan([.init(content: "step two", priority: nil, status: "pending")]))

        #expect(run.messages.count == 4)
        guard case .plan(_, let firstPlan) = run.messages[1],
              case .plan(_, let secondPlan) = run.messages[3] else {
            Issue.record("expected a separate plan row after each turn's prompt")
            return
        }
        #expect(firstPlan.map(\.content) == ["step one"])
        #expect(secondPlan.map(\.content) == ["step two"])

        // A follow-up plan update for the CURRENT (second) turn still
        // refines that turn's row in place rather than starting a third.
        run.apply(.plan([.init(content: "step two", priority: nil, status: "completed")]))
        #expect(run.messages.count == 4)
        guard case .plan(_, let refinedPlan) = run.messages[3] else {
            Issue.record("expected the second turn's plan to be refined in place")
            return
        }
        #expect(refinedPlan.first?.status == "completed")
    }

    @Test("a replayed historical plan reconciles its own turn, not the newest one")
    func replayedPlanTargetsItsOwnTurn() {
        let run = ACPSubagentRun(subagentSessionId: "child-1")
        // Hydrated with two turns already persisted correctly.
        run.restore(
            messages: [
                .user(id: UUID(), messageId: "p1", text: "first task", attachments: []),
                .plan(id: UUID(), [.init(content: "step one", status: "pending")]),
                .user(id: UUID(), messageId: "p2", text: "second task", attachments: []),
                .plan(id: UUID(), [.init(content: "step two", status: "pending")])
            ],
            createdAts: [Date(), Date(), Date(), Date()])

        // `session/load` resends the FIRST turn's prompt, then its plan,
        // chronologically — a plan has no stable identity to reconcile
        // against, only a turn-boundary position, so it must land on ITS
        // OWN turn's row and not clobber the newest (second turn's) one.
        run.applyReplayed(.userMessageChunk(.init(messageId: "p1", content: .text("first task"))))
        let dirty = run.applyReplayed(.plan([.init(content: "step one", priority: nil, status: "completed")]))

        #expect(dirty == [1])
        #expect(run.messages.count == 4)
        guard case .plan(_, let firstPlan) = run.messages[1],
              case .plan(_, let secondPlan) = run.messages[3] else {
            Issue.record("expected both turns' plan rows to still be in place")
            return
        }
        #expect(firstPlan.map(\.status) == ["completed"])
        #expect(secondPlan.map(\.content) == ["step two"])
    }

    @Test("replay recovers a plan that never reached storage")
    func replayRecoversMissingPlan() {
        let run = ACPSubagentRun(subagentSessionId: "child-1")
        // Only the prompt made it to SQLite before the crash — its plan
        // update never flushed.
        run.restore(
            messages: [.user(id: UUID(), messageId: "p1", text: "first task", attachments: [])],
            createdAts: [Date()])

        run.applyReplayed(.userMessageChunk(.init(messageId: "p1", content: .text("first task"))))
        let dirty = run.applyReplayed(.plan([.init(content: "step one", priority: nil, status: "pending")]))

        #expect(dirty == [1])
        #expect(run.messages.count == 2)
        guard case .plan(_, let plan) = run.messages[1] else {
            Issue.record("expected the missing plan to be recovered right after its prompt")
            return
        }
        #expect(plan.map(\.content) == ["step one"])
    }

    @Test("replay of a reused prompt id matches the turn at the replay cursor, not the newest one")
    func replayMatchesReusedMessageIdByPosition() {
        let run = ACPSubagentRun(subagentSessionId: "child-1")
        // Two turns that happen to reuse the same `messageId`, with the
        // first turn's reply between them — as in real usage, where a
        // reused id is only ever separated by the PREVIOUS turn's agent
        // activity, never immediately adjacent to its own reuse.
        run.restore(
            messages: [
                .user(id: UUID(), messageId: "p1", text: "first task", attachments: []),
                .agent(id: UUID(), StreamingText("reply")),
                .user(id: UUID(), messageId: "p1", text: "second task", attachments: [])
            ],
            createdAts: [Date(), Date(), Date()])

        // `session/load` resends everything chronologically. The FIRST
        // replayed occurrence must resolve to the FIRST (oldest) row, not
        // a backward search's globally-newest match — otherwise it would
        // reset and extend row 2, then the second occurrence would find
        // that same now-cached row and append to it too, combining both
        // turns' text into one row while row 0 goes stale.
        let firstDirty = run.applyReplayed(.userMessageChunk(.init(messageId: "p1", content: .text("first task"))))
        run.applyReplayed(.agentMessageChunk(.text("reply")))
        let secondDirty = run.applyReplayed(.userMessageChunk(.init(messageId: "p1", content: .text("second task"))))

        #expect(firstDirty == [0])
        #expect(secondDirty == [2])
        #expect(run.messages.count == 3)
        guard case .user(_, _, let firstText, _, _) = run.messages[0],
              case .user(_, _, let secondText, _, _) = run.messages[2] else {
            Issue.record("expected both reused-id prompts to stay in their own rows")
            return
        }
        #expect(firstText == "first task")
        #expect(secondText == "second task")
    }

    @Test("a data-only inline image is preserved in a child prompt")
    func childPromptPreservesDataOnlyImage() {
        let run = ACPSubagentRun(subagentSessionId: "child-1")
        let payload = "aGVsbG8=" // "hello", arbitrary base64 payload
        run.apply(.userMessageChunk(.init(
            messageId: "p1",
            content: .image(data: payload, uri: nil, mimeType: "image/png"))))

        #expect(run.messages.count == 1)
        guard case .user(_, "p1", let text, let attachments, _) = run.messages[0] else {
            Issue.record("expected one prompt bubble, not a dropped update")
            return
        }
        #expect(text.isEmpty)
        #expect(attachments.count == 1)
        #expect(attachments.first?.uri == "data:image/png;base64,\(payload)")
        #expect(attachments.first?.mimeType == "image/png")
    }

    @Test("an id-less chunk still extends only the trailing row of its kind")
    func idLessChunkExtendsTrailingRow() {
        let run = ACPSubagentRun(subagentSessionId: "child-1")
        run.apply(.agentThoughtChunk(.text("thinking")))
        run.apply(.agentMessageChunk(.text("answer ")))
        run.apply(.agentMessageChunk(.text("continues")))

        #expect(run.messages.count == 2)
        guard case .thought(_, _, let thought) = run.messages[0],
              case .agent(_, _, let answer) = run.messages[1] else {
            Issue.record("expected a thought row followed by one prose row")
            return
        }
        #expect(thought.value == "thinking")
        #expect(answer.value == "answer continues")
    }

    @Test("replaying an already-complete row is a visual no-op")
    func replayOfCompleteRowIsNoOp() {
        let run = ACPSubagentRun(subagentSessionId: "child-1")
        run.restore(
            messages: [.agent(id: UUID(), messageId: "m1", StreamingText("hello world"))],
            createdAts: [Date()])

        for chunk in ["hello", " world"] {
            run.applyReplayed(.agentMessageChunk(.init(messageId: "m1", content: .text(chunk))))
        }

        #expect(run.messages.count == 1)
        guard case .agent(_, _, let buffer) = run.messages[0] else {
            Issue.record("expected the single agent row")
            return
        }
        #expect(buffer.value == "hello world")
    }

    @Test("replay recovers a message that never reached storage")
    func replayRecoversMissingMessage() {
        let run = ACPSubagentRun(subagentSessionId: "child-1")
        // Nothing was hydrated — the row never made it to SQLite.
        for chunk in ["hello", " world"] {
            run.applyReplayed(.agentMessageChunk(.init(messageId: "m1", content: .text(chunk))))
        }

        #expect(run.messages.count == 1)
        guard case .agent(_, "m1", let buffer) = run.messages[0] else {
            Issue.record("expected a recovered agent row")
            return
        }
        #expect(buffer.value == "hello world")
    }

    @Test("replay recovers multiple consecutive missing prefix rows in order")
    func replayRecoversMultipleMissingPrefixRowsInOrder() {
        let run = ACPSubagentRun(subagentSessionId: "child-1")
        // Only seq 2 made it to SQLite — seq 0 and 1 never did.
        run.restore(
            messages: [.agent(id: UUID(), messageId: "m2", StreamingText("third"))],
            createdAts: [Date()],
            seqs: [2])

        // `session/load` resends the full chronological history: the two
        // missing rows, then the one that did persist.
        run.applyReplayed(.agentMessageChunk(.init(messageId: "m0", content: .text("first"))))
        run.applyReplayed(.agentMessageChunk(.init(messageId: "m1", content: .text("second"))))
        run.applyReplayed(.agentMessageChunk(.init(messageId: "m2", content: .text("third"))))

        #expect(run.messages.count == 3)
        guard case .agent(_, "m0", let first) = run.messages[0],
              case .agent(_, "m1", let second) = run.messages[1],
              case .agent(_, "m2", let third) = run.messages[2] else {
            Issue.record("expected all three rows in chronological order")
            return
        }
        #expect(first.value == "first")
        #expect(second.value == "second")
        #expect(third.value == "third")
        // The seq assigned to each recovered row must stay STRICTLY
        // increasing in array order — SQLite reloads by `ORDER BY seq`,
        // so an out-of-order seq would resurface these rows in the wrong
        // order on the next reattach even though this session's in-memory
        // array is correct right now.
        #expect(run.seq(at: 0) < run.seq(at: 1))
        #expect(run.seq(at: 1) < run.seq(at: 2))
    }

    @Test("replay recovers a lost tail without duplicating what was persisted")
    func replayRecoversLostTailWithoutDuplication() {
        let run = ACPSubagentRun(subagentSessionId: "child-1")
        // Only the first chunk made it to SQLite before the crash.
        run.restore(
            messages: [.agent(id: UUID(), messageId: "m1", StreamingText("hello "))],
            createdAts: [Date()])

        // The agent's own history is authoritative and resends the WHOLE
        // message from scratch, not just the missing suffix.
        for chunk in ["hello", " world"] {
            run.applyReplayed(.agentMessageChunk(.init(messageId: "m1", content: .text(chunk))))
        }

        #expect(run.messages.count == 1)
        guard case .agent(_, _, let buffer) = run.messages[0] else {
            Issue.record("expected the row to be rebuilt in place")
            return
        }
        #expect(buffer.value == "hello world")
    }

    @Test("replay recovers a lost tail on an id-less row without duplicating it")
    func replayRecoversIdLessLostTailWithoutDuplication() {
        let run = ACPSubagentRun(subagentSessionId: "child-1")
        // An agent that omits `messageId` entirely — only the first chunk
        // made it to SQLite before the crash.
        run.restore(
            messages: [.agent(id: UUID(), StreamingText("hello "))],
            createdAts: [Date()])

        for chunk in ["hello", " world"] {
            run.applyReplayed(.agentMessageChunk(.text(chunk)))
        }

        #expect(run.messages.count == 1)
        guard case .agent(_, _, let buffer) = run.messages[0] else {
            Issue.record("expected the id-less row to be rebuilt in place")
            return
        }
        #expect(buffer.value == "hello world")
    }

    @Test("replaying a tool call preserves the persisted row's execution timing")
    func replayPreservesToolCallTiming() {
        let run = ACPSubagentRun(subagentSessionId: "child-1")
        let started = Date(timeIntervalSince1970: 1_000)
        let finished = Date(timeIntervalSince1970: 1_010)
        run.restore(
            messages: [.toolCall(.init(
                toolCallId: "t1", title: "Read", status: "completed",
                executionStartedAt: started, executionFinishedAt: finished))],
            createdAts: [started])

        // Replayed far later than the original run — if timing weren't
        // preserved, the row would show a fresh start at THIS time.
        run.applyReplayed(
            .toolCall(.init(toolCallId: "t1", title: "Read", kind: nil, status: "completed")),
            at: Date(timeIntervalSince1970: 5_000))

        guard case .toolCall(let toolCall) = run.messages[0] else {
            Issue.record("expected the tool call row")
            return
        }
        #expect(toolCall.executionStartedAt == started)
        #expect(toolCall.executionFinishedAt == finished)
    }

    @Test("a replayed tool call upserts an existing row instead of duplicating it")
    func replayUpsertsExistingToolCall() {
        let run = ACPSubagentRun(subagentSessionId: "child-1")
        run.restore(
            messages: [.toolCall(.init(toolCallId: "t1", title: "Read", status: "completed"))],
            createdAts: [Date()])

        run.applyReplayed(.toolCall(.init(
            toolCallId: "t1", title: "Read", kind: nil, status: "completed",
            content: [.content(.text("file contents"))])))

        #expect(run.messages.count == 1)
        guard case .toolCall(let toolCall) = run.messages[0] else {
            Issue.record("expected the tool call to be replaced in place")
            return
        }
        #expect(toolCall.content == "file contents")
    }

    @Test("a replayed tool call recovers a row that never reached storage")
    func replayRecoversMissingToolCall() {
        let run = ACPSubagentRun(subagentSessionId: "child-1")
        run.applyReplayed(.toolCall(.init(toolCallId: "t1", title: "Read", kind: nil, status: "completed")))

        #expect(run.messages.count == 1)
        guard case .toolCall(let toolCall) = run.messages[0] else {
            Issue.record("expected a recovered tool call")
            return
        }
        #expect(toolCall.toolCallId == "t1")
    }

    @Test("a child's session-level updates never touch the parent's chrome")
    func childStateUpdatesAreIgnored() {
        let session = makeSession()
        session.apply(.subagentSpawned(.init(subagentSessionId: "child-1")))
        session.applySubagentUpdate(.currentModelUpdate(modelId: "child-model"), subagentSessionId: "child-1")
        session.applySubagentUpdate(
            .usageUpdate(.init(used: 10, size: 100, cost: nil)),
            subagentSessionId: "child-1")

        #expect(session.currentModel == nil)
        #expect(session.contextUsage == nil)
        #expect(session.subagentRun("child-1")?.messages.isEmpty == true)
    }

    @Test("a replayed terminal state reconciles a child left running by a crash")
    func replayReconcilesTerminalState() {
        let session = makeSession()
        session.apply(.subagentSpawned(.init(subagentSessionId: "child-1", name: "Explore")))

        // `session/load` replays the state the previous process never
        // committed. Replay side effects are the only path that runs here.
        let dirty = session.applySuppressedReplaySideEffects(
            .subagentStateUpdate(.init(subagentSessionId: "child-1", state: .completed)))

        #expect(dirty == [0])
        #expect(session.subagentRun("child-1")?.state == .completed)
    }

    @Test("replayed lifecycle history does not resurrect or re-timestamp an already-terminal child")
    func replayDoesNotResurrectOrRetimestampTerminalChild() {
        let session = makeSession()
        session.apply(.subagentSpawned(.init(subagentSessionId: "child-1", name: "Explore")))
        session.applySuppressedReplaySideEffects(
            .subagentStateUpdate(.init(subagentSessionId: "child-1", state: .completed)))
        let originalFinish = try? #require(session.subagentRun("child-1")?.finishedAt)

        // `session/load` resends the child's FULL lifecycle history
        // chronologically: the older "running" frame, then "completed"
        // again — exactly the sequence that used to resurrect the child
        // and then stamp a fresh (reattach-time) finish over the real one.
        session.applySuppressedReplaySideEffects(
            .subagentStateUpdate(.init(subagentSessionId: "child-1", state: .running)))
        session.applySuppressedReplaySideEffects(
            .subagentStateUpdate(.init(subagentSessionId: "child-1", state: .completed)))

        #expect(session.subagentRun("child-1")?.state == .completed)
        #expect(session.subagentRun("child-1")?.isRunning == false)
        #expect(session.subagentRun("child-1")?.finishedAt == originalFinish)
    }

    @Test("a replayed spawn re-registers a child whose row never reached disk")
    func replayRegistersMissingChild() {
        let session = makeSession()
        let dirty = session.applySuppressedReplaySideEffects(
            .subagentSpawned(.init(subagentSessionId: "child-1", name: "Explore")))

        #expect(dirty == [0])
        #expect(session.subagentRun("child-1")?.name == "Explore")

        // Replaying it again merges instead of duplicating the row.
        #expect(session.applySuppressedReplaySideEffects(
            .subagentSpawned(.init(subagentSessionId: "child-1", name: "Explore"))).isEmpty)
        #expect(session.transcript.messages.count == 1)
    }

    // MARK: - Row projection

    @Test("a subagent row is never folded into a tool-call bundle")
    func subagentRowIsNotCollapsible() {
        let descriptor = ACPSubagentRowDescriptor(
            subagentSessionId: "child-1",
            name: "Explore",
            task: nil,
            state: .completed,
            capabilities: .init())
        let row = ACPMessage.toolCall(descriptor.toolCall(
            executionStartedAt: nil, executionFinishedAt: nil))

        #expect(ACPToolCallGrouping.isCollapsible(row) == false)
        // An ordinary finished tool call still is — the exclusion is
        // specific to subagent rows.
        #expect(ACPToolCallGrouping.isCollapsible(.toolCall(.init(
            toolCallId: "t1", title: "Read", status: "completed"))))
    }

    @Test("the row descriptor survives an encode/decode round trip")
    func descriptorRoundTrips() throws {
        let descriptor = ACPSubagentRowDescriptor(
            subagentSessionId: "child-1",
            name: "Explore",
            task: "Find the router",
            state: .cancelled,
            capabilities: .cancellable)
        let toolCall = descriptor.toolCall(executionStartedAt: nil, executionFinishedAt: nil)
        let encoded = try JSONEncoder().encode(toolCall)
        let decoded = try JSONDecoder().decode(ACPMessage.ToolCall.self, from: encoded)

        let restored = try #require(ACPSubagentRowDescriptor(toolCall: decoded))
        #expect(restored == descriptor)
    }

    @Test("an ordinary tool call is not mistaken for a subagent row")
    func ordinaryToolCallHasNoDescriptor() {
        #expect(ACPSubagentRowDescriptor(toolCall: .init(
            toolCallId: "t1", title: "Read", status: "completed")) == nil)
    }

    @Test("losing the connection stops every running child, leaving finished ones alone")
    func disconnectStopsRunningChildren() {
        let session = makeSession()
        session.apply(.subagentSpawned(.init(subagentSessionId: "live")))
        session.apply(.subagentSpawned(.init(subagentSessionId: "done")))
        session.apply(.subagentStateUpdate(.init(subagentSessionId: "done", state: .completed)))

        let dirty = session.markSubagentsDisconnected()

        #expect(dirty == [0])
        #expect(session.subagentRun("live")?.state == .disconnected)
        #expect(session.subagentRun("done")?.state == .completed)
    }

    // MARK: - Restore

    @Test("restoring rebuilds each child with its persisted transcript")
    func restoreRebuildsChildren() {
        let session = makeSession()
        let descriptor = ACPSubagentRowDescriptor(
            subagentSessionId: "child-1",
            name: "Explore",
            task: "Find the router",
            state: .completed,
            capabilities: .cancellable)
        let created = Date(timeIntervalSince1970: 1_000)

        session.restoreSubagents(
            rows: [descriptor.toolCall(executionStartedAt: created, executionFinishedAt: nil)],
            messages: ["child-1": [
                (.agent(id: UUID(), StreamingText("restored")), created, 0)
            ]])

        let run = try? #require(session.subagentRun("child-1"))
        #expect(run?.name == "Explore")
        #expect(run?.task == "Find the router")
        #expect(run?.state == .completed)
        #expect(run?.capabilities.supportsCancel == true)
        #expect(run?.messages.count == 1)
        #expect(run?.createdAt(at: 0) == created)
    }

    @Test("re-restoring keeps the same run object so an expanded row stays open")
    func restoreReusesExistingRuns() {
        let session = makeSession()
        session.apply(.subagentSpawned(.init(subagentSessionId: "child-1", name: "Explore")))
        let original = try? #require(session.subagentRun("child-1"))

        guard case .toolCall(let row) = session.transcript.messages[0] else {
            Issue.record("expected a subagent row")
            return
        }
        session.restoreSubagents(rows: [row], messages: [:])

        #expect(session.subagentRun("child-1") === original)
    }

    @Test("restoring drops children whose rows are gone")
    func restoreDropsStaleChildren() {
        let session = makeSession()
        session.apply(.subagentSpawned(.init(subagentSessionId: "child-1")))
        session.restoreSubagents(rows: [], messages: [:])
        #expect(session.subagents.isEmpty)
    }

    // MARK: - Helpers

    private func makeSession() -> ACPSession {
        ACPSession(id: "s", agentId: "claude", worktreeId: "wt", title: "t")
    }

    private func subagentRowDescriptor(in session: ACPSession, at index: Int) -> ACPSubagentRowDescriptor? {
        guard case .toolCall(let toolCall) = session.transcript.messages[index] else { return nil }
        return ACPSubagentRowDescriptor(toolCall: toolCall)
    }
}

@Suite("Subagent row policy")
struct ACPSubagentRowPolicyTests {
    @Test("cancel is offered only for a running child that advertises it")
    func cancelVisibility() {
        #expect(ACPSubagentRowPolicy.showsCancel(state: .running, capabilities: .cancellable))
        #expect(ACPSubagentRowPolicy.showsCancel(state: .completed, capabilities: .cancellable) == false)
        #expect(ACPSubagentRowPolicy.showsCancel(state: .running, capabilities: .init()) == false)
    }

    @Test("the spinner stops only on a terminal state")
    func spinnerVisibility() {
        #expect(ACPSubagentRowPolicy.showsSpinner(state: .running))
        #expect(ACPSubagentRowPolicy.showsSpinner(state: .other("thinking")))
        for state in [ACPSubagentState.completed, .failed, .cancelled, .disconnected] {
            #expect(ACPSubagentRowPolicy.showsSpinner(state: state) == false)
        }
    }

    @Test("the summary prefers the task and falls back to a row count")
    func summary() {
        #expect(ACPSubagentRowPolicy.summary(task: "Find the router", messageCount: 3)
            == "Find the router")
        #expect(ACPSubagentRowPolicy.summary(task: "  ", messageCount: 3) == "3 messages")
        #expect(ACPSubagentRowPolicy.summary(task: nil, messageCount: 1) == "1 message")
        #expect(ACPSubagentRowPolicy.summary(task: nil, messageCount: 0) == nil)
    }

    @Test("state labels are human readable, including unknown states")
    func stateLabels() {
        #expect(ACPSubagentRowPolicy.stateLabel(for: .running) == "Working")
        #expect(ACPSubagentRowPolicy.stateLabel(for: .completed) == "Done")
        #expect(ACPSubagentRowPolicy.stateLabel(for: .disconnected) == "Disconnected")
        #expect(ACPSubagentRowPolicy.stateLabel(for: .other("awaiting_permission"))
            == "Awaiting Permission")
    }
}
