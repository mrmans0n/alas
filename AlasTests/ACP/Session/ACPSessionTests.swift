import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACPSession")
struct ACPSessionTests {
    @Test("compaction updates with the same ID replace one transcript row")
    func compactionUpdatesMergeInPlace() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")

        session.apply(.compactionUpdate(.init(
            compactionId: "compact-1", status: "in_progress")))
        session.apply(.compactionUpdate(.init(
            compactionId: "compact-1", status: "completed",
            summary: [.text("Kept decisions.")])))

        #expect(session.transcript.messages.count == 1)
        guard case .toolCall(let toolCall) = session.transcript.messages[0],
              let compaction = ACPContextCompaction(toolCall: toolCall) else {
            Issue.record("expected a normalized compaction tool call")
            return
        }
        #expect(compaction.id == "compact-1")
        #expect(compaction.status == .completed)
        #expect(toolCall.content == "Kept decisions.")
    }

    @Test("Codex compaction updates retain previously supplied facts")
    func codexCompactionUpdatesMergeFacts() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")

        session.apply(.toolCall(.init(
            toolCallId: "compact-1", title: "Compact conversation", kind: "think", status: "in_progress",
            metadata: AnyCodable(["contextCompaction": ["version": 1, "trigger": "automatic", "preTokens": 100_000]]))))
        session.apply(.toolCallUpdate(.init(
            toolCallId: "compact-1", status: "completed",
            metadata: AnyCodable(["contextCompaction": ["version": 1, "postTokens": 12_000, "durationMs": 300]]))))

        guard case .toolCall(let toolCall) = session.transcript.messages.first,
              let compaction = ACPContextCompaction(toolCall: toolCall) else {
            Issue.record("expected a normalized context compaction")
            return
        }
        #expect(compaction.trigger == "automatic")
        #expect(compaction.tokensBefore == 100_000)
        #expect(compaction.tokensAfter == 12_000)
        #expect(compaction.durationMs == 300)
    }

    @Test("tool_call name survives an update without name; an update with name replaces it")
    func toolCallNamePersistsUnlessUpdateCarriesOne() async {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")

        session.apply(.toolCall(.init(
            toolCallId: "tool-1", title: "Bash", kind: "execute", status: "in_progress",
            name: "Bash")))
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tool-1", status: "completed")))

        guard case .toolCall(let toolCall) = session.transcript.messages.first else {
            Issue.record("expected a tool call")
            return
        }
        #expect(toolCall.name == "Bash")
        #expect(toolCall.status == "completed")

        session.apply(.toolCallUpdate(.init(
            toolCallId: "tool-1", status: "completed", name: "exec_command")))

        guard case .toolCall(let renamed) = session.transcript.messages.first else {
            Issue.record("expected a tool call")
            return
        }
        #expect(renamed.name == "exec_command")
    }

    @Test("compaction summary chunks append to the normalized row")
    func compactionSummaryChunksAppend() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")

        session.apply(.compactionUpdate(.init(
            compactionId: "compact-chunks", status: "in_progress")))
        session.apply(.compactionSummaryChunk(.init(
            compactionId: "compact-chunks", content: .text("Kept "))))
        session.apply(.compactionSummaryChunk(.init(
            compactionId: "compact-chunks", content: .text("decisions."))))

        guard case .toolCall(let toolCall) = session.transcript.messages.first else {
            Issue.record("expected a normalized compaction tool call")
            return
        }
        #expect(toolCall.content == "Kept decisions.")
    }

    @Test("usage update remains authoritative over compaction counts")
    func usageUpdateRemainsAuthoritative() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")

        session.apply(.compactionUpdate(.init(
            compactionId: "compact-usage", status: "completed",
            metadata: AnyCodable([
                "preTokens": 99_000,
                "postTokens": 12_000,
                "durationMs": 400
            ]))))
        #expect(session.contextUsage == nil)

        session.apply(.usageUpdate(.init(used: 3_000, size: 8_000, cost: nil)))
        #expect(session.contextUsage == .init(used: 3_000, size: 8_000, cost: nil))
    }

    @Test("notices are live-only: no transcript row, no persistence, no streaming state change")
    func noticesAreLiveStateOnly() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.transcript.streamingState = .idle

        let dirty = session.apply(.notice(.init(severity: .warning, title: "MCP server unavailable")))

        #expect(dirty.isEmpty)
        #expect(session.transcript.messages.isEmpty)
        #expect(session.activeNotice?.title == "MCP server unavailable")
        #expect(session.transcript.streamingState == .idle)
    }

    @Test("notices that only differ by _meta still coalesce as visually identical")
    func noticesDifferingOnlyByMetadataCoalesce() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        let first = ACPSessionNotice(
            severity: .info, title: "Model fallback", description: "Using backup model.",
            metadata: AnyCodable(["traceId": "a"]))
        let second = ACPSessionNotice(
            severity: .info, title: "Model fallback", description: "Using backup model.",
            metadata: AnyCodable(["traceId": "b"]))

        session.apply(.notice(first))
        session.apply(.notice(second))

        // Coalescing keeps the original instance in place rather than
        // adopting the later metadata, so a chatty repeat doesn't restart
        // the auto-dismiss timer or flash the banner.
        #expect(session.activeNotice == first)
    }

    @Test("an unrecognized severity auto-dismisses like info")
    func unrecognizedSeverityBehavesAsInfo() async {
        #expect(ACPSessionNotice.Severity.other("_debug").behavesAsInfo)
        #expect(ACPSessionNotice.Severity.other("future-severity").behavesAsInfo)
        #expect(ACPSessionNotice.Severity.info.behavesAsInfo)
        #expect(!ACPSessionNotice.Severity.warning.behavesAsInfo)
        #expect(!ACPSessionNotice.Severity.error.behavesAsInfo)
    }

    @Test("a different notice arriving while a pinned notice is active queues instead of replacing it")
    func differentNoticeQueuesBehindPinnedNotice() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        let warning = ACPSessionNotice(severity: .warning, title: "MCP server unavailable")
        let info = ACPSessionNotice(severity: .info, title: "Model fallback")

        session.apply(.notice(warning))
        session.apply(.notice(info))

        // The pinned warning must stay visible until dismissed, not get
        // silently replaced (and then vanish when info auto-dismisses).
        #expect(session.activeNotice == warning)

        session.dismissActiveNotice()

        // Dismissing the pinned notice promotes the one that queued up.
        #expect(session.activeNotice == info)
    }

    @Test("a queued notice replaces an older queued one instead of stacking")
    func queuedNoticeIsLatestWins() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        let warning = ACPSessionNotice(severity: .warning, title: "MCP server unavailable")
        let firstQueued = ACPSessionNotice(severity: .info, title: "First")
        let secondQueued = ACPSessionNotice(severity: .info, title: "Second")

        session.apply(.notice(warning))
        session.apply(.notice(firstQueued))
        session.apply(.notice(secondQueued))
        #expect(session.activeNotice == warning)

        session.dismissActiveNotice()

        #expect(session.activeNotice == secondQueued)
    }

    @Test("notices arriving during load-replay suppression are ignored")
    func noticesIgnoredDuringLoadReplay() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.beginSuppressedReplaySideEffects()

        let touched = session.applySuppressedReplaySideEffects(
            .notice(.init(severity: .warning, title: "Should not surface")))

        #expect(touched.isEmpty)
        #expect(session.activeNotice == nil)
    }

    @Test("recordPromptQuota clears lastTurnQuota when a later turn omits quota, but keeps the session total")
    func recordPromptQuotaClearsLastTurnOnNilButKeepsTotal() async {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        let turn1 = ACPPromptQuota(
            tokenCount: .init(totalTokens: 100, inputTokens: 80, cachedInputTokens: 0,
                              cachedWriteTokens: 0, outputTokens: 20, reasoningOutputTokens: 0),
            modelUsage: [.init(model: "claude-fable-5-1", tokenCount: .init(
                totalTokens: 100, inputTokens: 80, cachedInputTokens: 0,
                cachedWriteTokens: 0, outputTokens: 20, reasoningOutputTokens: 0))])

        session.recordPromptQuota(turn1)
        #expect(session.lastTurnQuota == turn1)

        session.recordPromptQuota(nil)
        #expect(session.lastTurnQuota == nil)
        #expect(session.sessionQuotaTotal == turn1)
    }

    @Test("recordPromptQuota with updatesLastTurn false accumulates into the total without touching lastTurnQuota")
    func recordPromptQuotaWithUpdatesLastTurnFalseSkipsLastTurn() async {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        let active = ACPPromptQuota(
            tokenCount: .init(totalTokens: 100, inputTokens: 80, cachedInputTokens: 0,
                              cachedWriteTokens: 0, outputTokens: 20, reasoningOutputTokens: 0),
            modelUsage: [.init(model: "m", tokenCount: .init(
                totalTokens: 100, inputTokens: 80, cachedInputTokens: 0,
                cachedWriteTokens: 0, outputTokens: 20, reasoningOutputTokens: 0))])
        session.recordPromptQuota(active)

        // A stale, superseded prompt's response arrives late: its tokens
        // still count toward the session total, but must not clobber the
        // active prompt's lastTurnQuota (nor clear it, when nil).
        let stale = ACPPromptQuota(
            tokenCount: .init(totalTokens: 50, inputTokens: 40, cachedInputTokens: 0,
                              cachedWriteTokens: 0, outputTokens: 10, reasoningOutputTokens: 0),
            modelUsage: [.init(model: "m", tokenCount: .init(
                totalTokens: 50, inputTokens: 40, cachedInputTokens: 0,
                cachedWriteTokens: 0, outputTokens: 10, reasoningOutputTokens: 0))])
        session.recordPromptQuota(stale, updatesLastTurn: false)

        #expect(session.lastTurnQuota == active)
        #expect(session.sessionQuotaTotal?.tokenCount?.totalTokens == 150)

        session.recordPromptQuota(nil, updatesLastTurn: false)
        #expect(session.lastTurnQuota == active)
    }

    @Test("replacement transcript preserves tool call content revision when content is unchanged")
    func replaceTranscriptPreservesToolCallContentRevisionForSameContent() {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        var original = ACPMessage.ToolCall(
            toolCallId: "tool-1",
            title: "run",
            kind: "execute",
            status: "completed",
            content: "same output")
        original.replaceContent("new output")
        original.replaceContent("same output")
        session.replaceTranscriptMessages([.toolCall(original)])

        let replacement = ACPMessage.ToolCall(
            toolCallId: "tool-1",
            title: "run",
            kind: "execute",
            status: "completed",
            content: "same output")
        session.replaceTranscriptMessages([.toolCall(replacement)])

        guard case .toolCall(let toolCall) = session.transcript.messages.first else {
            Issue.record("expected replacement tool call")
            return
        }
        #expect(toolCall.contentRevision == original.contentRevision)
    }

    @Test("replacement transcript advances tool call content revision when content changes")
    func replaceTranscriptAdvancesToolCallContentRevisionForChangedContent() {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        var original = ACPMessage.ToolCall(
            toolCallId: "tool-1",
            title: "run",
            kind: "execute",
            status: "completed",
            content: "plain output")
        original.replaceContent("still plain")
        session.replaceTranscriptMessages([.toolCall(original)])

        let replacement = ACPMessage.ToolCall(
            toolCallId: "tool-1",
            title: "run",
            kind: "execute",
            status: "completed",
            content: "@@ -1 +1 @@\n-old\n+new")
        session.replaceTranscriptMessages([.toolCall(replacement)])

        guard case .toolCall(let toolCall) = session.transcript.messages.first else {
            Issue.record("expected replacement tool call")
            return
        }
        #expect(toolCall.contentRevision == original.contentRevision + 1)
    }

    @Test("interleaved commentary and final chunks keep their own phase and message rows")
    func interleavedPhasedChunks() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        let commentary = AnyCodable(["codex": AnyCodable(["phase": AnyCodable("commentary")])])
        let final = AnyCodable(["codex": AnyCodable(["phase": AnyCodable("final_answer")])])

        session.apply(.agentMessageChunk(.init(messageId: "commentary-1", content: .text("Checking"), metadata: commentary)))
        session.apply(.agentMessageChunk(.init(messageId: "final-1", content: .text("Done"), metadata: final)))
        session.apply(.agentMessageChunk(.init(messageId: "commentary-1", content: .text(" files"), metadata: commentary)))

        #expect(session.transcript.messages.count == 2)
        guard case .agent(_, let commentaryID, let commentaryBuffer) = session.transcript.messages[0],
              case .agent(_, let finalID, let finalBuffer) = session.transcript.messages[1] else {
            Issue.record("expected phased agent messages")
            return
        }
        #expect(commentaryID == "commentary-1")
        #expect(commentaryBuffer.value == "Checking files")
        #expect(commentaryBuffer.phase == .commentary)
        #expect(finalID == "final-1")
        #expect(finalBuffer.value == "Done")
        #expect(finalBuffer.phase == .finalAnswer)
        // The third chunk resumed the OLDER commentary row (index 0), not
        // the trailing final-answer row (index 1) — `lastContentTouchIndex`
        // must follow the row actually written to, not array order. Feeds
        // `ACPNarrationLiveness.liveIndex`, which shimmers whichever row
        // this points at.
        #expect(session.transcript.lastContentTouchIndex == 0)
    }

    @Test("a plan update does not move lastContentTouchIndex off the in-progress row")
    func planUpdateDoesNotMoveContentTouch() {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.apply(.agentThoughtChunk(.text("thinking")))
        #expect(session.transcript.lastContentTouchIndex == 0)
        session.apply(.plan([.init(content: "Step 1", priority: nil, status: "pending")]))
        #expect(session.transcript.lastContentTouchIndex == 0)
    }

    @Test("markCompletedOutputBoundary clears lastContentTouchIndex")
    func completedBoundaryClearsContentTouch() {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.apply(.agentMessageChunk(.text("hello")))
        #expect(session.transcript.lastContentTouchIndex != nil)
        session.markCompletedOutputBoundary()
        #expect(session.transcript.lastContentTouchIndex == nil)
    }

    @Test("id-less phase transition starts a new agent row")
    func idlessPhaseTransitionStartsNewRow() {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        let commentary = AnyCodable(["codex": AnyCodable(["phase": AnyCodable("commentary")])])
        let final = AnyCodable(["codex": AnyCodable(["phase": AnyCodable("final_answer")])])

        session.apply(.agentMessageChunk(.init(content: .text("Checking files"), metadata: commentary)))
        session.apply(.agentMessageChunk(.init(content: .text("Done"), metadata: final)))

        guard session.transcript.messages.count == 2,
              case .agent(_, _, let commentaryBuffer) = session.transcript.messages[0],
              case .agent(_, _, let finalBuffer) = session.transcript.messages[1] else {
            Issue.record("expected separate commentary and final rows")
            return
        }
        #expect(commentaryBuffer.value == "Checking files")
        #expect(commentaryBuffer.phase == .commentary)
        #expect(finalBuffer.value == "Done")
        #expect(finalBuffer.phase == .finalAnswer)
    }

    @Test("a phase introduced by a later chunk survives persistence")
    func laterChunkPhaseSurvivesPersistence() throws {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        let firstMetadata = AnyCodable(["future": AnyCodable("kept")])
        let commentary = AnyCodable(["codex": AnyCodable(["phase": AnyCodable("commentary")])])

        session.apply(.agentMessageChunk(.init(
            messageId: "message-1", content: .text("Checking"), metadata: firstMetadata)))
        session.apply(.agentMessageChunk(.init(
            messageId: "message-1", content: .text(" files"), metadata: commentary)))

        guard case .agent(_, _, let buffer) = session.transcript.messages.first else {
            Issue.record("expected agent message")
            return
        }
        #expect(buffer.phase == .commentary)
        let metadata = try #require(buffer.metadata?.value as? [String: AnyCodable])
        #expect(metadata["future"]?.value as? String == "kept")
        #expect(metadata["codex"] != nil)

        let wire = try ACPMessageWire.decode(
            kind: "agent", payload: ACPMessageCodec.encode(session.transcript.messages[0]))
        guard case .agent(_, _, let phase, let persistedMetadata) = wire else {
            Issue.record("expected persisted agent message")
            return
        }
        #expect(phase == .commentary)
        #expect(persistedMetadata == buffer.metadata)
    }

    @Test("phased replay does not duplicate or change hydrated output")
    func phasedReplayPreservesHydratedMessage() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        let metadata = AnyCodable(["codex": AnyCodable(["phase": AnyCodable("commentary")])])
        session.transcript.messages = [
            .agent(id: UUID(), messageId: "commentary-1", StreamingText("Checking files", phase: .commentary, metadata: metadata)),
            .user(id: UUID(), messageId: "user-1", text: "next", attachments: [])
        ]
        session.allowsStreamingBoundaryCrossing = false

        let changed = session.apply(.agentMessageChunk(.init(
            messageId: "commentary-1", content: .text(" replay"), metadata: metadata)))

        #expect(changed == [0])
        #expect(session.transcript.messages.count == 2)
        guard case .agent(_, _, let buffer) = session.transcript.messages[0] else {
            Issue.record("expected agent message")
            return
        }
        #expect(buffer.value == "Checking files")
        #expect(buffer.phase == .commentary)
        #expect(buffer.metadata == metadata)
    }

    @Test("two agent chunks merge into one message with the right separator",
          arguments: ACPSessionTests.ChunkSeparatorCase.all)
    func agentChunksMergeWithSeparator(_ row: ChunkSeparatorCase) async {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        session.apply(.agentMessageChunk(.text(row.first)))
        session.apply(.agentMessageChunk(.text(row.second)))
        #expect(session.transcript.messages.count == 1)
        if case .agent(_, _, let buf) = session.transcript.messages[0] {
            #expect(buf.value == row.expected)
        } else { Issue.record("expected single agent message") }
    }

    @Test("thought chunks split at a sentence boundary get a newline separator")
    func thoughtChunksSplitAtSentenceGetNewline() async {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        session.apply(.agentThoughtChunk(.text("First thought.")))
        session.apply(.agentThoughtChunk(.text("Second thought.")))
        #expect(session.transcript.messages.count == 1)
        if case .thought(_, _, let buf) = session.transcript.messages[0] {
            #expect(buf.value == "First thought.\nSecond thought.")
        } else { Issue.record("expected single thought message") }
    }

    @Test("agent chunks with messageId after a completed output boundary update the same message")
    func messageIdChunkAfterCompletedOutputBoundaryUpdatesMessage() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.apply(.agentMessageChunk(.init(messageId: "agent-1", content: .text("first"))))
        session.markCompletedOutputBoundary()
        session.apply(.agentMessageChunk(.init(messageId: "agent-1", content: .text(" task output"))))

        #expect(session.transcript.messages.count == 1)
        #expect(session.transcript.messages[0].stableId == "acp-agent:agent-1")
        if case .agent(_, _, let text) = session.transcript.messages[0] {
            #expect(text.value == "first task output")
        } else {
            Issue.record("expected agent message")
        }
    }

    @Test("late replay chunk with unknown messageId does not append output")
    func lateReplayUnknownMessageIdChunkDoesNotAppendOutput() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.transcript.messages = [
            .agent(id: UUID(), messageId: "agent-1", StreamingText("earlier answer")),
            .user(id: UUID(), messageId: "user-1", text: "next prompt", attachments: [])
        ]
        session.allowsStreamingBoundaryCrossing = false

        let changed = session.apply(.agentMessageChunk(.init(messageId: "regenerated-agent-1", content: .text("earlier answer"))))

        #expect(changed.isEmpty)
        #expect(session.transcript.messages.count == 2)
        if case .agent(_, _, let text) = session.transcript.messages[0] {
            #expect(text.value == "earlier answer")
        } else {
            Issue.record("expected agent message")
        }
    }

    @Test("post-load live chunk with new messageId appends output")
    func postLoadLiveMessageIdChunkAppendsOutput() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.transcript.messages = [
            .user(id: UUID(), messageId: nil, text: "look at this", attachments: []),
            .agent(id: UUID(), messageId: nil, StreamingText("the image looks good")),
            .toolCall(.init(
                toolCallId: "tool-1",
                title: "Read file",
                kind: "read",
                status: "completed",
                content: "done"
            ))
        ]
        session.allowsStreamingBoundaryCrossing = false

        let changed = session.apply(.agentMessageChunk(.init(messageId: "agent-live-1", content: .text("live follow-up"))))

        #expect(changed == [3])
        #expect(session.transcript.messages.count == 4)
        if case .agent(_, let messageId, let text) = session.transcript.messages[3] {
            #expect(messageId == "agent-live-1")
            #expect(text.value == "live follow-up")
        } else {
            Issue.record("expected agent message")
        }
    }

    @Test("post-load live chunk with existing messageId updates in-progress output")
    func postLoadLiveExistingMessageIdChunkUpdatesInProgressOutput() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.transcript.messages = [
            .agent(id: UUID(), messageId: "agent-1", StreamingText("first")),
            .toolCall(.init(
                toolCallId: "tool-1",
                title: "Read file",
                kind: "read",
                status: "completed",
                content: "done"
            ))
        ]
        session.allowsStreamingBoundaryCrossing = false

        let changed = session.apply(.agentMessageChunk(.init(messageId: "agent-1", content: .text(" follow-up"))))

        #expect(changed == [0])
        #expect(session.transcript.messages.count == 2)
        if case .agent(_, let messageId, let text) = session.transcript.messages[0] {
            #expect(messageId == "agent-1")
            #expect(text.value == "first follow-up")
        } else {
            Issue.record("expected agent message")
        }
    }

    @Test("post-load live chunk whose short leading fragment coincides with earlier output is not dropped")
    func postLoadLiveShortLeadingFragmentNotDroppedAsReplay() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.transcript.messages = [
            .agent(id: UUID(), messageId: "agent-1", StreamingText("I'm rerunning the tests now.")),
            .toolCall(.init(
                toolCallId: "tool-1",
                title: "Run tests",
                kind: "execute",
                status: "completed",
                content: "done"
            ))
        ]
        session.allowsStreamingBoundaryCrossing = false

        // A genuinely new agent message streams its first fragment "I" — a
        // coincidental substring of the earlier message. It must not be
        // classified as a late replay and dropped; otherwise the message is
        // rebuilt from the second fragment, losing its leading character.
        session.apply(.agentMessageChunk(.init(messageId: "agent-live-2", content: .text("I"))))
        session.apply(.agentMessageChunk(.init(messageId: "agent-live-2", content: .text("'ve made that warning cleanup."))))

        let agentTexts = session.transcript.messages.compactMap { message -> String? in
            if case .agent(_, _, let text) = message { return text.value }
            return nil
        }
        #expect(agentTexts.contains("I've made that warning cleanup."))
    }

    /// A short live chunk that is a substring of prior output is held as a
    /// replay candidate. Whatever closes the text run (tool call, prompt,
    /// real user chunk, completed boundary, file edit) must materialize it
    /// in order ahead of the closer; things that do not close the run
    /// (state-only updates, a dropped replayed user chunk) must not flush it
    /// into a duplicate row, and a candidate that fully reproduces an
    /// existing message stays suppressed.
    @Test("a held replay candidate flushes only when the text run is really closed",
          arguments: ACPSessionTests.HeldCandidateCase.all)
    func heldReplayCandidateFlush(_ row: HeldCandidateCase) async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.transcript.messages = Self.seedMessages(row.seed)
        session.allowsStreamingBoundaryCrossing = false

        session.apply(.agentMessageChunk(.init(messageId: row.heldMessageId, content: .text(row.heldText))))
        switch row.trigger {
        case .toolCall:
            session.apply(.toolCall(.init(
                toolCallId: "tool-1", title: "Run", kind: "execute", status: "completed",
                content: nil, locations: nil, rawInput: nil, rawOutput: nil)))
        case .userPrompt(let text):
            session.recordUserPrompt(text: text, attachments: [])
        case .userChunk(let messageId, let text):
            session.apply(.userMessageChunk(.init(messageId: messageId, content: .text(text))))
        case .completedOutputBoundary:
            session.markCompletedOutputBoundary()
        case .fileEdit:
            session.appendFileEdit(.init(
                path: "x.swift", added: 1, removed: 0, oldText: "a\n", newText: "a\nb\n"))
        case .modelUpdate(let modelId):
            session.apply(.currentModelUpdate(modelId: modelId))
        }

        #expect(Self.orderedRows(session) == row.expected)
    }

    @Test("a held thought is flushed before an agent answer, preserving transcript order")
    func heldThoughtFlushedBeforeAgentAnswer() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.transcript.messages = [
            .thought(id: UUID(), messageId: "thought-1", StreamingText("thinking hard"))
        ]
        session.allowsStreamingBoundaryCrossing = false

        // A held thought fragment "thinking" (substring of the prior thought),
        // then an agent answer. An agent answer closes an in-progress thought,
        // so the thought must materialize ahead of the answer, not after it.
        session.apply(.agentThoughtChunk(.init(messageId: "regen-thought", content: .text("thinking"))))
        session.apply(.agentMessageChunk(.init(messageId: "regen-agent", content: .text("here is the answer"))))

        let ordered: [String] = session.transcript.messages.compactMap { message in
            switch message {
            case .thought(_, _, let t): return "thought:\(t.value)"
            case .agent(_, _, let t): return "agent:\(t.value)"
            default: return nil
            }
        }
        #expect(ordered == ["thought:thinking hard", "thought:thinking", "agent:here is the answer"])
    }

    @Test("a held thought is not flushed when the following agent chunk is itself suppressed as replay")
    func heldThoughtNotFlushedWhenAgentChunkSuppressed() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.transcript.messages = [
            .thought(id: UUID(), messageId: "thought-1", StreamingText("thinking hard")),
            .agent(id: UUID(), messageId: "agent-1", StreamingText("the answer"))
        ]
        session.allowsStreamingBoundaryCrossing = false

        // Held thought fragment "thinking", then a replayed agent chunk "the"
        // (a substring of the existing agent message) that appendStreaming
        // holds as a replay candidate. Since the agent chunk produces no live
        // output, the thought must stay buffered — not materialize as a
        // duplicate thought row.
        session.apply(.agentThoughtChunk(.init(messageId: "regen-thought", content: .text("thinking"))))
        session.apply(.agentMessageChunk(.init(messageId: "regen-agent", content: .text("the"))))

        let ordered: [String] = session.transcript.messages.compactMap { message in
            switch message {
            case .thought(_, _, let t): return "thought:\(t.value)"
            case .agent(_, _, let t): return "agent:\(t.value)"
            default: return nil
            }
        }
        #expect(ordered == ["thought:thinking hard", "agent:the answer"])
    }

    @Test("multiple held candidates flush in arrival order, not by messageId")
    func heldCandidatesFlushInArrivalOrder() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.transcript.messages = [
            .agent(id: UUID(), messageId: "agent-1", StreamingText("alpha beta"))
        ]
        session.allowsStreamingBoundaryCrossing = false

        // Two short live agent rows are both held (substrings of prior
        // output). Their ids sort opposite to arrival ("a-1" < "z-1"), so a
        // flush must still emit them in arrival order ("alpha" then "beta").
        session.apply(.agentMessageChunk(.init(messageId: "z-1", content: .text("alpha"))))
        session.apply(.agentMessageChunk(.init(messageId: "a-1", content: .text("beta"))))
        session.apply(.toolCall(.init(
            toolCallId: "tool-1", title: "Run", kind: "execute", status: "completed",
            content: nil, locations: nil, rawInput: nil, rawOutput: nil)))

        let agentTexts = session.transcript.messages.compactMap { message -> String? in
            if case .agent(_, _, let text) = message { return text.value }
            return nil
        }
        #expect(agentTexts == ["alpha beta", "alpha", "beta"])
    }

    @Test("two repeated held candidates with identical text are both materialized")
    func repeatedHeldCandidatesBothMaterialized() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.transcript.messages = [
            .agent(id: UUID(), messageId: "agent-1", StreamingText("OK done."))
        ]
        session.allowsStreamingBoundaryCrossing = false

        // Two distinct new one-chunk "OK" replies, both held as substrings of
        // "OK done.". Flushing must materialize both — the first must not make
        // the second look like a full replay of it.
        session.apply(.agentMessageChunk(.init(messageId: "z-1", content: .text("OK"))))
        session.apply(.agentMessageChunk(.init(messageId: "a-1", content: .text("OK"))))
        session.apply(.toolCall(.init(
            toolCallId: "tool-1", title: "Run", kind: "execute", status: "completed",
            content: nil, locations: nil, rawInput: nil, rawOutput: nil)))

        let agentTexts = session.transcript.messages.compactMap { message -> String? in
            if case .agent(_, _, let text) = message { return text.value }
            return nil
        }
        #expect(agentTexts == ["OK done.", "OK", "OK"])
    }

    /// The file edit always starts as `a\n` -> `a\nb\n` with heuristic
    /// counts 1/1; each row varies the completed tool call's diff block.
    @Test("adapter diffStats overwrite a file edit's counts only when the diff block matches it",
          arguments: ACPSessionTests.DiffStatsCase.all)
    func diffStatsCorrelateIntoFileEdit(_ row: DiffStatsCase) async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.appendFileEdit(.init(
            path: row.editPath, added: 1, removed: 1, oldText: "a\n", newText: "a\nb\n"))

        _ = session.apply(.toolCall(.init(
            toolCallId: "tc-1", title: "Edit x.swift", kind: "edit", status: "completed",
            content: [.diff(
                path: row.diffPath, oldText: row.diffOldText, newText: row.diffNewText,
                kind: row.diffKind,
                diffStats: row.stats.map { ACPDiffStats(added: $0.added, removed: $0.removed) })])),
            worktreeRoot: row.worktreeRoot)

        guard case .fileEdit(_, let edit) = session.transcript.messages.first(where: {
            if case .fileEdit = $0 { return true }
            return false
        }) else {
            Issue.record("expected a fileEdit message")
            return
        }
        #expect(edit.added == row.expectedAdded)
        #expect(edit.removed == row.expectedRemoved)
    }

    @Test("diffStats for a path with no matching file edit is a no-op")
    func diffStatsWithNoMatchingFileEditIsNoOp() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")

        let touched = session.apply(.toolCall(.init(
            toolCallId: "tc-1", title: "Edit missing.swift", kind: "edit", status: "completed",
            content: [.diff(
                path: "missing.swift", oldText: "a\n", newText: "b\n",
                kind: "update", diffStats: .init(added: 1, removed: 1))])))

        #expect(touched == [0])
        let hasFileEdit = session.transcript.messages.contains {
            if case .fileEdit = $0 { return true }
            return false
        }
        #expect(!hasFileEdit)
    }

    /// Chunks under a regenerated messageId arrive after hydration. Only a
    /// whole-bubble prefix of the still-open trailing agent message is
    /// adopted; replays of existing text stay suppressed; anything else
    /// (suffix matches, output after a user prompt or tool call) starts its
    /// own row — a rare duplicate is the accepted trade-off for never
    /// merging a genuinely separate message into an existing bubble.
    @Test("regenerated-id chunks after hydration are suppressed, adopted, or start a new row",
          arguments: ACPSessionTests.RegeneratedReplayCase.all)
    func regeneratedReplayChunks(_ row: RegeneratedReplayCase) async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.transcript.messages = Self.seedMessages(row.seed)
        session.allowsStreamingBoundaryCrossing = false

        for chunk in row.chunks {
            session.apply(.agentMessageChunk(.init(messageId: "regen-1", content: .text(chunk))))
        }

        let agentTexts = session.transcript.messages.compactMap { message -> String? in
            if case .agent(_, _, let text) = message { return text.value }
            return nil
        }
        #expect(agentTexts == row.expectedAgentTexts)
    }

    @Test("replay-then-continuation under a regenerated messageId merges into the hydrated message")
    func replayThenContinuationMergesIntoHydratedMessage() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.transcript.messages = [
            .agent(id: UUID(), messageId: "agent-1", StreamingText("hello"))
        ]
        session.allowsStreamingBoundaryCrossing = false

        // The in-progress "hello" is replayed under a regenerated id and
        // then continues with " world". The prefix must not be duplicated:
        // the continuation merges into the hydrated message.
        session.apply(.agentMessageChunk(.init(messageId: "regen-1", content: .text("hello"))))
        session.apply(.agentMessageChunk(.init(messageId: "regen-1", content: .text(" world"))))

        let agentTexts = session.transcript.messages.compactMap { message -> String? in
            if case .agent(_, _, let text) = message { return text.value }
            return nil
        }
        #expect(agentTexts == ["hello world"])

        // A further continuation chunk targets the adopted message via its
        // rebound id rather than spawning yet another row.
        session.apply(.agentMessageChunk(.init(messageId: "regen-1", content: .text("!"))))
        let after = session.transcript.messages.compactMap { message -> String? in
            if case .agent(_, _, let text) = message { return text.value }
            return nil
        }
        #expect(after == ["hello world!"])
    }

    @Test("regenerated replay continuation keeps the accumulated phase metadata")
    func replayContinuationKeepsAccumulatedPhaseMetadata() throws {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        let commentary = AnyCodable(["codex": AnyCodable(["phase": AnyCodable("commentary")])])
        session.transcript.messages = [
            .agent(id: UUID(), messageId: "agent-1", StreamingText("hello"))
        ]
        session.allowsStreamingBoundaryCrossing = false

        session.apply(.agentMessageChunk(.init(
            messageId: "regen-1", content: .text("hello"), metadata: commentary)))
        session.apply(.agentMessageChunk(.init(
            messageId: "regen-1", content: .text(" world"))))

        guard case .agent(_, _, let buffer) = session.transcript.messages.first else {
            Issue.record("expected agent message")
            return
        }
        #expect(buffer.value == "hello world")
        #expect(buffer.phase == .commentary)
        #expect(buffer.metadata == commentary)
        let wire = try ACPMessageWire.decode(
            kind: "agent", payload: ACPMessageCodec.encode(session.transcript.messages[0]))
        guard case .agent(_, _, let phase, let metadata) = wire else {
            Issue.record("expected persisted agent message")
            return
        }
        #expect(phase == .commentary)
        #expect(metadata == commentary)
    }

    @Test("a diverged replay candidate materializes with its accumulated phase metadata")
    func divergedReplayCandidateKeepsAccumulatedPhaseMetadata() {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        let commentary = AnyCodable(["codex": AnyCodable(["phase": AnyCodable("commentary")])])
        session.transcript.messages = [
            .agent(id: UUID(), messageId: "agent-1", StreamingText("hello there"))
        ]
        session.allowsStreamingBoundaryCrossing = false

        session.apply(.agentMessageChunk(.init(
            messageId: "regen-1", content: .text("hello"), metadata: commentary)))
        session.apply(.agentMessageChunk(.init(
            messageId: "regen-1", content: .text("!"))))

        guard session.transcript.messages.count == 2,
              case .agent(_, _, let buffer) = session.transcript.messages[1] else {
            Issue.record("expected materialized agent message")
            return
        }
        #expect(buffer.value == "hello!")
        #expect(buffer.phase == .commentary)
        #expect(buffer.metadata == commentary)
    }

    @Test("pending replay candidates are namespaced by kind so a shared id does not mix thought into agent text")
    func pendingReplayCandidatesNamespacedByKind() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.transcript.messages = [
            .thought(id: UUID(), messageId: "thought-1", StreamingText("pondering")),
            .agent(id: UUID(), messageId: "agent-1", StreamingText("response"))
        ]
        session.allowsStreamingBoundaryCrossing = false

        // A thought and an agent chunk reuse the same id during the restore
        // window. The suppressed thought fragment must not leak into the
        // agent chunk's candidate and materialize as "ponderingreply".
        session.apply(.agentThoughtChunk(.init(messageId: "dup", content: .text("pondering"))))
        session.apply(.agentMessageChunk(.init(messageId: "dup", content: .text("reply"))))

        let agentTexts = session.transcript.messages.compactMap { message -> String? in
            if case .agent(_, _, let text) = message { return text.value }
            return nil
        }
        #expect(agentTexts == ["response", "reply"])
    }

    @Test("regenerated thought replay is not adopted into a thought that an agent row already closed")
    func thoughtReplayNotAdoptedAcrossAgentRow() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.transcript.messages = [
            .thought(id: UUID(), messageId: "thought-1", StreamingText("earlier")),
            .agent(id: UUID(), messageId: "agent-1", StreamingText("answer"))
        ]
        session.allowsStreamingBoundaryCrossing = false

        // A regenerated thought stream that starts with the earlier thought's
        // text but continues. The agent row closed that thought (lastThought()
        // stops at it), so it must not be adopted; a new thought row appears.
        session.apply(.agentThoughtChunk(.init(messageId: "regen-1", content: .text("earlier"))))
        session.apply(.agentThoughtChunk(.init(messageId: "regen-1", content: .text(" more"))))

        let thoughtTexts = session.transcript.messages.compactMap { message -> String? in
            if case .thought(_, _, let text) = message { return text.value }
            return nil
        }
        #expect(thoughtTexts == ["earlier", "earlier more"])
        // The agent bubble between them is untouched.
        let agentTexts = session.transcript.messages.compactMap { message -> String? in
            if case .agent(_, _, let text) = message { return text.value }
            return nil
        }
        #expect(agentTexts == ["answer"])
    }

    @Test("regenerated thought replay is not adopted across a file edit")
    func thoughtReplayNotAdoptedAcrossFileEdit() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.transcript.messages = [
            .thought(id: UUID(), messageId: "thought-1", StreamingText("plan")),
            .fileEdit(id: UUID(), .init(
                path: "x.swift", added: 1, removed: 0,
                oldText: "a\n", newText: "a\nb\n"
            ))
        ]
        session.allowsStreamingBoundaryCrossing = false

        // A file edit closes the pre-edit thought (like lastAgent() and the
        // completed-output boundary). A regenerated thought stream starting
        // with the pre-edit thought's text must not extend it across the
        // edit; it becomes a new thought after the edit.
        session.apply(.agentThoughtChunk(.init(messageId: "regen-1", content: .text("plan"))))
        session.apply(.agentThoughtChunk(.init(messageId: "regen-1", content: .text(" more"))))

        let thoughtTexts = session.transcript.messages.compactMap { message -> String? in
            if case .thought(_, _, let text) = message { return text.value }
            return nil
        }
        #expect(thoughtTexts == ["plan", "plan more"])
    }

    @Test("late replay user chunk with unknown messageId does not append prompt")
    func lateReplayUnknownUserMessageIdChunkDoesNotAppendPrompt() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.transcript.messages = [
            .user(id: UUID(), messageId: "user-1", text: "earlier prompt", attachments: []),
            .agent(id: UUID(), messageId: "agent-1", StreamingText("earlier answer"))
        ]
        session.allowsStreamingBoundaryCrossing = false

        let changed = session.apply(.userMessageChunk(.init(messageId: "regenerated-user-1", content: .text("earlier prompt"))))

        #expect(changed.isEmpty)
        #expect(session.transcript.messages.count == 2)
        if case .user(_, _, let text, let attachments, _) = session.transcript.messages[0] {
            #expect(text == "earlier prompt")
            #expect(attachments.isEmpty)
        } else {
            Issue.record("expected user message")
        }
    }

    @Test("completed output boundary does not alter existing message text")
    func completedOutputBoundaryDoesNotAddBlankLines() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.apply(.agentMessageChunk(.text("line one\nline two")))
        session.markCompletedOutputBoundary()

        if case .agent(_, _, let buf) = session.transcript.messages[0] {
            #expect(buf.value == "line one\nline two")
        } else {
            Issue.record("expected agent message")
        }
    }

    @Test("completed output boundary skips trailing plan rows")
    func completedOutputBoundarySkipsTrailingPlan() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.apply(.agentMessageChunk(.text("first task")))
        session.apply(.plan([.init(content: "done", priority: nil, status: "completed")]))
        session.markCompletedOutputBoundary()
        session.apply(.agentMessageChunk(.text("second task")))

        #expect(session.transcript.messages.count == 3)
        if case .agent(_, _, let first) = session.transcript.messages[0],
           case .plan = session.transcript.messages[1],
           case .agent(_, _, let second) = session.transcript.messages[2] {
            #expect(first.value == "first task")
            #expect(second.value == "second task")
        } else {
            Issue.record("expected agent, plan, agent")
        }
    }

    @Test("completed output boundary tracks agent before trailing thought")
    func completedOutputBoundaryTracksAgentBeforeTrailingThought() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.apply(.agentMessageChunk(.text("visible answer")))
        session.apply(.agentThoughtChunk(.text("trailing thought")))
        session.markCompletedOutputBoundary()
        session.apply(.agentMessageChunk(.text("next task")))

        #expect(session.transcript.messages.count == 3)
        if case .agent(_, _, let first) = session.transcript.messages[0],
           case .thought(_, _, let thought) = session.transcript.messages[1],
           case .agent(_, _, let second) = session.transcript.messages[2] {
            #expect(first.value == "visible answer")
            #expect(thought.value == "trailing thought")
            #expect(second.value == "next task")
        } else {
            Issue.record("expected agent, thought, agent")
        }
    }

    @Test("completed output boundary survives next task leading thought")
    func completedOutputBoundarySurvivesNextTaskLeadingThought() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.apply(.agentMessageChunk(.text("first answer")))
        session.apply(.agentThoughtChunk(.text("first thought")))
        session.markCompletedOutputBoundary()
        session.apply(.agentThoughtChunk(.text("next thought")))
        session.apply(.agentMessageChunk(.text("second answer")))

        #expect(session.transcript.messages.count == 4)
        if case .agent(_, _, let first) = session.transcript.messages[0],
           case .thought(_, _, let firstThought) = session.transcript.messages[1],
           case .thought(_, _, let secondThought) = session.transcript.messages[2],
           case .agent(_, _, let second) = session.transcript.messages[3] {
            #expect(first.value == "first answer")
            #expect(firstThought.value == "first thought")
            #expect(secondThought.value == "next thought")
            #expect(second.value == "second answer")
        } else {
            Issue.record("expected agent, thought, thought, agent")
        }
    }

    @Test("checkpoint capture attaches to its recorded prompt")
    func checkpointCaptureAttachesToRecordedPrompt() async {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        let promptID = session.recordUserPrompt(text: "hi", attachments: [])
        let checkpointID = UUID()

        #expect(session.attachCheckpoint(checkpointID, toUserMessage: promptID))
        guard case .user(_, _, _, let attachments, _) = session.transcript.messages[0] else {
            Issue.record("expected user message")
            return
        }
        #expect(attachments.map(\.checkpointID) == [checkpointID])
    }

    @Test("generated title ignores Alas workspace context and uses the remaining prompt")
    func generatedTitleIgnoresAlasWorkspaceContext() async {
        let session = ACPSession(
            id: "s",
            agentId: "codex",
            worktreeId: "w",
            title: "New session",
            titleSource: .placeholder
        )
        let prompt = """
        <alas-workspace-context>
        Private workspace metadata that should not become the title.
        </alas-workspace-context>
        Fix the session title inference
        """

        session.recordUserPrompt(text: prompt, attachments: [])

        #expect(session.title == "Fix the session title inference")
        #expect(session.titleSource == .fallback)
        if case .user(_, _, let text, _, _) = session.transcript.messages.first {
            #expect(text == prompt)
        } else {
            Issue.record("expected the original prompt in the transcript")
        }
    }

    @Test("live transcript advances render window while following tail")
    func liveTranscriptAdvancesRenderWindow() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")

        for i in 0..<50 {
            session.appendSystemNotice("notice \(i)")
        }

        #expect(session.transcript.visibleHead == 20)
    }

    @Test("live transcript does not advance render window when user is reading history")
    func liveTranscriptKeepsWindowWhenNotFollowingTail() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.followsTranscriptTail = false

        for i in 0..<50 {
            session.appendSystemNotice("notice \(i)")
        }

        #expect(session.transcript.visibleHead == 0)
    }

    /// Reported bug: an actively-streaming turn that runs many tools — each
    /// tool call is its own transcript message, but a whole run collapses
    /// into a single "Ran N tools" row in the UI — silently trimmed the
    /// user's own prompt out of the live render window, because the render
    /// window used to advance by raw message count on every appended
    /// message while following the tail. The visible result looked short
    /// (a couple of rows) while the window had already moved well past the
    /// start of the conversation. Goes through the real `apply` update path
    /// (not a direct array mutation) so this exercises exactly what a live
    /// ACP turn does.
    @Test("a long tool-call burst does not trim the user's prompt out of the live render window")
    func liveTranscriptToolCallBurstKeepsPromptInWindow() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.recordUserPrompt(text: "the user's prompt", attachments: [])
        session.appendSystemNotice("a short notice")

        for i in 0..<43 {
            let id = "tc-\(i)"
            session.apply(.toolCall(ACPToolCallPayload(
                toolCallId: id, title: "Tool \(i)", kind: "read", status: "in_progress"
            )))
            session.apply(.toolCallUpdate(ACPToolCallUpdate(toolCallId: id, status: "completed")))
        }

        #expect(session.transcript.visibleHead == 0)
    }

    @Test("hasConversationTranscript counts only non-blank user or agent text",
          arguments: ACPSessionTests.ConversationTranscriptCase.all)
    func conversationTranscriptDetection(_ row: ConversationTranscriptCase) async {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        switch row.content {
        case .empty:
            break
        case .systemNotice(let text):
            session.appendSystemNotice(text)
        case .userPrompt(let text):
            session.recordUserPrompt(text: text, attachments: [])
        case .agentChunk(let text):
            session.apply(.agentMessageChunk(.text(text)))
        }

        #expect(session.hasConversationTranscript == row.expected)
    }

    @Test("restored context recovery marker clears when agent output starts")
    func restoredContextRecoveryMarkerClearsWhenAgentOutputStarts() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.markContextRecoveryRestored(expiryNanoseconds: 60_000_000_000)

        session.apply(.agentMessageChunk(.text("answer")))

        #expect(session.contextRecoveryStatus == nil)
    }

    @Test("context recovery failure remains visible when agent output starts")
    func contextRecoveryFailureRemainsVisibleWhenAgentOutputStarts() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.contextRecoveryStatus = .failed("Transcript recovery failed.")

        session.apply(.agentMessageChunk(.text("answer")))

        #expect(session.contextRecoveryStatus == .failed("Transcript recovery failed."))
    }

    @Test("restored context recovery marker expires")
    func restoredContextRecoveryMarkerExpires() async throws {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.markContextRecoveryRestored(expiryNanoseconds: 1_000_000)

        try await Task.sleep(nanoseconds: 20_000_000)

        #expect(session.contextRecoveryStatus == nil)
    }

    @Test("plan update creates / replaces the plan message")
    func plan() async {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        session.apply(.plan([.init(content: "a", priority: nil, status: "pending")]))
        session.apply(.plan([.init(content: "a", priority: nil, status: "completed"),
                             .init(content: "b", priority: nil, status: "in_progress")]))
        #expect(session.transcript.messages.count == 1)
        if case .plan(_, let items) = session.transcript.messages[0] {
            #expect(items.count == 2)
            #expect(items[0].status == "completed")
        } else { Issue.record("expected plan") }
    }

    @Test("sessionConfigOptionsUpdate synchronizes config-backed currentModel")
    func configOptionsUpdateSynchronizesConfigBackedCurrentModel() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.currentModel = "opus"
        session.apply(.sessionConfigOptionsUpdate([ACPConfigOption(
            id: "model",
            name: "Model",
            category: "model",
            currentValue: "sonnet",
            options: [
                ACPConfigOptionItem(id: "sonnet", name: "Sonnet"),
                ACPConfigOptionItem(id: "opus", name: "Opus"),
            ])]))

        #expect(session.currentModel == "sonnet")
    }

    @Test("sessionConfigOptionsUpdate clears removed config-backed currentModel")
    func configOptionsUpdateClearsRemovedConfigBackedCurrentModel() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.currentModel = "sonnet"
        session.apply(.sessionConfigOptionsUpdate([ACPConfigOption(
            id: "model",
            name: "Model",
            category: "model",
            currentValue: "sonnet",
            options: [ACPConfigOptionItem(id: "sonnet", name: "Sonnet")]
        )]))
        session.apply(.sessionConfigOptionsUpdate([]))

        #expect(session.currentModel == nil)
    }

    @Test("session info applies title and goal")
    func sessionInfoAppliesTitleAndGoal() async throws {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "Old title")
        session.apply(.sessionInfoUpdate(.init(
            title: "Investigate ACP events",
            metadata: AnyCodable([
                "codex": AnyCodable([
                    "goal": AnyCodable([
                        "objective": AnyCodable("Surface richer ACP events"),
                        "status": AnyCodable("in_progress"),
                        "tokenBudget": AnyCodable(12_000)
                    ])
                ])
            ]))))

        let goal = try #require(session.currentGoal)
        #expect(session.title == "Investigate ACP events")
        #expect(session.titleSource == .provider)
        #expect(goal.objective == "Surface richer ACP events")
        #expect(goal.status == "in_progress")
        #expect(goal.tokenBudget == 12_000)
    }

    @Test("retryable Codex session error exposes only its safe message")
    func retryableCodexErrorUsesSafeMessage() async throws {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.transcript.streamingState = .streaming

        session.apply(.sessionInfoUpdate(.init(
            title: nil,
            metadata: AnyCodable([
                "codex": AnyCodable([
                    "error": AnyCodable([
                        "willRetry": AnyCodable(true),
                        "turnId": AnyCodable("turn-42"),
                        "message": AnyCodable("Temporary service issue\nplease wait"),
                        "codexErrorInfo": AnyCodable("internal-stack-trace"),
                        "additionalDetails": AnyCodable("unsafe diagnostic")
                    ])
                ])
            ]))))

        let retry = try #require(session.retryStatus)
        #expect(retry.turnId == "turn-42")
        #expect(retry.detail == "Temporary service issue please wait")
        #expect(session.lastError == nil)
        #expect(session.transcript.streamingState == .streaming)
    }

    @Test("agent progress and completion clear retryable Codex status")
    func retryStatusClearsOnProgressAndCompletion() {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        let retry = AnyCodable(["codex": AnyCodable(["error": AnyCodable([
            "willRetry": AnyCodable(true), "message": AnyCodable("Retrying")
        ])])])

        session.apply(.sessionInfoUpdate(.init(title: nil, metadata: retry)))
        session.apply(.agentMessageChunk(.text("resumed output")))
        #expect(session.retryStatus == nil)

        session.apply(.sessionInfoUpdate(.init(title: nil, metadata: retry)))
        session.markCompletedOutputBoundary()
        #expect(session.retryStatus == nil)
    }

    @Test("permanent Codex error clears retryable status")
    func permanentCodexErrorClearsRetryStatus() {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        let retry = AnyCodable(["codex": AnyCodable(["error": AnyCodable([
            "willRetry": AnyCodable(true), "message": AnyCodable("Retrying")
        ])])])
        let permanent = AnyCodable(["codex": AnyCodable(["error": AnyCodable([
            "willRetry": AnyCodable(false), "message": AnyCodable("Permanent failure")
        ])])])

        session.apply(.sessionInfoUpdate(.init(title: nil, metadata: retry)))
        session.apply(.sessionInfoUpdate(.init(title: nil, metadata: permanent)))

        #expect(session.retryStatus == nil)
    }

    @Test("session info applies top-level goal metadata")
    func sessionInfoAppliesTopLevelGoalMetadata() async throws {
        let session = ACPSession(id: "s", agentId: "bridge", worktreeId: "w", title: "t")
        session.apply(.sessionInfoUpdate(.init(
            title: nil,
            metadata: AnyCodable([
                "goal": AnyCodable([
                    "objective": AnyCodable("Surface generic ACP events"),
                    "status": AnyCodable("in_progress"),
                    "tokenBudget": AnyCodable(500)
                ])
            ]))))

        let goal = try #require(session.currentGoal)
        #expect(goal.objective == "Surface generic ACP events")
        #expect(goal.status == "in_progress")
        #expect(goal.tokenBudget == 500)
    }

    @Test("session info clears goal on null goal")
    func sessionInfoClearsGoalOnNullGoal() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.apply(.sessionInfoUpdate(.init(
            title: nil,
            metadata: AnyCodable([
                "codex": AnyCodable([
                    "goal": AnyCodable([
                        "objective": AnyCodable("Keep me"),
                        "status": AnyCodable("in_progress")
                    ])
                ])
            ]))))

        session.apply(.sessionInfoUpdate(.init(
            title: nil,
            metadata: AnyCodable([
                "codex": AnyCodable([
                    "goal": AnyCodable(NSNull())
                ])
            ]))))

        #expect(session.currentGoal == nil)
    }

    @Test("session info without goal leaves existing goal unchanged")
    func sessionInfoWithoutGoalLeavesExistingGoalUnchanged() async throws {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "Old title")
        session.apply(.sessionInfoUpdate(.init(
            title: nil,
            metadata: AnyCodable([
                "codex": AnyCodable([
                    "goal": AnyCodable([
                        "objective": AnyCodable("Original goal"),
                        "status": AnyCodable("in_progress"),
                        "tokenBudget": AnyCodable(200)
                    ])
                ])
            ]))))

        session.apply(.sessionInfoUpdate(.init(
            title: "Only title changed",
            metadata: AnyCodable([
                "codex": AnyCodable([
                    "unrelated": AnyCodable(true)
                ])
            ]))))

        let goal = try #require(session.currentGoal)
        #expect(session.title == "Only title changed")
        #expect(goal.objective == "Original goal")
        #expect(goal.status == "in_progress")
        #expect(goal.tokenBudget == 200)
    }

    @Test("session info partial goal metadata updates existing goal")
    func sessionInfoPartialGoalMetadataUpdatesExistingGoal() async throws {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.apply(.sessionInfoUpdate(.init(
            title: nil,
            metadata: AnyCodable([
                "codex": AnyCodable([
                    "goal": AnyCodable([
                        "objective": AnyCodable("Original goal"),
                        "status": AnyCodable("in_progress"),
                        "tokenBudget": AnyCodable(200)
                    ])
                ])
            ]))))

        session.apply(.sessionInfoUpdate(.init(
            title: nil,
            metadata: AnyCodable([
                "codex": AnyCodable([
                    "goal": AnyCodable([
                        "status": AnyCodable("completed"),
                        "tokenBudget": AnyCodable(300)
                    ])
                ])
            ]))))

        let goal = try #require(session.currentGoal)
        #expect(goal.objective == "Original goal")
        #expect(goal.status == "completed")
        #expect(goal.tokenBudget == 300)
    }

    @Test("tool duration starts with active execution and stops at completion")
    func toolCallExecutionDuration() {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        let startedAt = Date(timeIntervalSince1970: 100)
        let finishedAt = Date(timeIntervalSince1970: 102.4)

        session.apply(.toolCall(.init(
            toolCallId: "tc-duration", title: "Run", kind: "execute", status: "in_progress",
            content: nil, locations: nil, rawInput: nil, rawOutput: nil
        )), at: startedAt)
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-duration", status: "completed", content: nil, rawOutput: nil
        )), at: finishedAt)

        guard case .toolCall(let toolCall) = session.transcript.messages.first else {
            Issue.record("expected tool call")
            return
        }
        #expect(toolCall.executionStartedAt == startedAt)
        #expect(toolCall.executionFinishedAt == finishedAt)
        #expect(abs((toolCall.executionDuration ?? 0) - 2.4) < 0.0001)
    }

    @Test("canceling an active tool stops its duration")
    func cancelingToolCallStopsExecutionDuration() {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        let startedAt = Date(timeIntervalSince1970: 100)
        let canceledAt = Date(timeIntervalSince1970: 102.4)
        session.apply(.toolCall(.init(
            toolCallId: "tc-cancel", title: "Run", kind: "execute", status: "in_progress",
            content: nil, locations: nil, rawInput: nil, rawOutput: nil
        )), at: startedAt)

        _ = session.cancelInFlightToolCalls(at: canceledAt)

        guard case .toolCall(let toolCall) = session.transcript.messages.first else {
            Issue.record("expected tool call")
            return
        }
        #expect(toolCall.status == "canceled")
        #expect(toolCall.executionFinishedAt == canceledAt)
        #expect(abs((toolCall.executionDuration ?? 0) - 2.4) < 0.0001)
    }

    @Test("initial toolCall stores bounded raw input metadata")
    func toolCallBoundsRawInput() async {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        session.apply(.toolCall(.init(
            toolCallId: "tc-large-meta",
            title: "write",
            kind: "edit",
            status: "in_progress",
            content: nil,
            locations: nil,
            rawInput: AnyCodable([
                "path": AnyCodable("/tmp/large.txt"),
                "content": AnyCodable(String(repeating: "x", count: 8_192))
            ]),
            rawOutput: nil)))

        if case .toolCall(let tc) = session.transcript.messages[0] {
            #expect(tc.rawInput?.hasSuffix("… [truncated]") == true)
            #expect((tc.rawInput?.count ?? 0) <= 4_096 + "… [truncated]".count)
        } else {
            Issue.record("expected toolCall message")
        }
    }

    @Test("toolCallUpdate mutates enriched fields")
    func toolCallUpdateMutatesEnrichedFields() async {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        let metadata = AnyCodable([
            "terminal_exit": AnyCodable([
                "terminal_id": AnyCodable("term-1"),
                "exit_code": AnyCodable(0)
            ])
        ])

        session.apply(.toolCall(.init(
            toolCallId: "tc-enriched",
            title: "running",
            kind: "execute",
            status: "in_progress",
            content: [
                .terminal(terminalId: "stale-term"),
                .content(.resourceLink(uri: "file:///tmp/stale.txt", name: "stale.txt"))
            ],
            locations: nil,
            rawInput: nil,
            rawOutput: nil)))

        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-enriched",
            status: "completed",
            content: [
                .content(.text("```swift\nlet ok = true\n```")),
                .content(.image(data: "image-data", uri: "file:///tmp/result.png", mimeType: "image/png"))
            ],
            rawOutput: AnyCodable(["exit_code": AnyCodable(0)]),
            title: "swift test --filter ACP",
            locations: [ACPToolLocation(path: "AlasTests/ACP/Session/ACPSessionTests.swift", line: 12)],
            rawInput: AnyCodable(["command": AnyCodable("swift test --filter ACP")]),
            metadata: metadata)))

        if case .toolCall(let tc) = session.transcript.messages[0] {
            #expect(tc.title == "swift test --filter ACP")
            #expect(tc.status == "completed")
            #expect(tc.content == "let ok = true")
            #expect(tc.preview == "let ok = true")
            #expect(tc.contentLanguage == "swift")
            #expect(tc.locations == ["AlasTests/ACP/Session/ACPSessionTests.swift"])
            #expect(tc.rawInput?.contains(#""command":"swift test --filter ACP""#) == true)
            #expect(tc.rawOutput?.contains(#""exit_code":0"#) == true)
            #expect(tc.metadata == metadata)
            #expect(tc.terminalIds.isEmpty)
            #expect(tc.assets == [
                ACPMessage.ToolCallAsset.image(
                    data: "image-data",
                    uri: "file:///tmp/result.png",
                    mimeType: "image/png",
                    name: "result.png")
            ])
        } else {
            Issue.record("expected toolCall message")
        }
    }

    @Test("initial toolCall stores raw output and metadata")
    func initialToolCallStoresRawOutputAndMetadata() async {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        let metadata = AnyCodable([
            "is_mcp_tool_call": AnyCodable(true),
            "tool": AnyCodable("screenshot")
        ])

        session.apply(.toolCall(.init(
            toolCallId: "tc-output",
            title: "screenshot",
            kind: "read",
            status: "completed",
            content: [.content(.image(data: "base64-data", uri: nil, mimeType: "image/png"))],
            locations: nil,
            rawInput: nil,
            rawOutput: AnyCodable(["status": AnyCodable("ok")]),
            metadata: metadata)))

        if case .toolCall(let tc) = session.transcript.messages[0] {
            #expect(tc.rawOutput?.contains(#""status":"ok""#) == true)
            #expect(tc.metadata == metadata)
            #expect(tc.assets == [
                ACPMessage.ToolCallAsset.image(data: "base64-data", uri: nil, mimeType: "image/png")
            ])
        } else {
            Issue.record("expected toolCall message")
        }
    }

    @Test("an image-generation rawOutput shape is preserved as an asset",
          arguments: ACPSessionTests.RawOutputAssetCase.shapes)
    func rawOutputImageResultPreservesAsset(_ row: RawOutputAssetCase) async {
        let session = ACPSession(id: "s", agentId: "bridge", worktreeId: "w", title: "t")

        session.apply(.toolCall(.init(
            toolCallId: "tc-raw-image",
            title: "Image generation",
            kind: "other",
            status: "completed",
            content: nil,
            locations: nil,
            rawInput: nil,
            rawOutput: row.rawOutput)))

        if case .toolCall(let tc) = session.transcript.messages[0] {
            #expect(tc.assets == row.expectedAssets)
        } else {
            Issue.record("expected toolCall message")
        }
    }

    @Test("raw output image asset survives later content update")
    func rawOutputImageAssetSurvivesLaterContentUpdate() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")

        session.apply(.toolCall(.init(
            toolCallId: "tc-raw-image-update",
            title: "Image generation",
            kind: "other",
            status: "in_progress",
            content: nil,
            locations: nil,
            rawInput: nil,
            rawOutput: nil)))
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-raw-image-update",
            status: "in_progress",
            rawOutput: AnyCodable([
                "data": AnyCodable([
                    AnyCodable([
                        "b64_json": AnyCodable("base64-data")
                    ])
                ])
            ]))))
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-raw-image-update",
            status: "completed",
            content: [.content(.text("final output"))],
            rawOutput: nil)))

        if case .toolCall(let tc) = session.transcript.messages[0] {
            #expect(tc.content == "final output")
            #expect(tc.assets == [
                ACPMessage.ToolCallAsset.image(data: "base64-data", mimeType: "image/png")
            ])
        } else {
            Issue.record("expected toolCall message")
        }
    }

    @Test("a long rawOutput image asset survives rawOutput truncation and a later content update",
          arguments: ACPSessionTests.RawOutputAssetCase.longPayloads)
    func longRawOutputAssetSurvivesLaterContentUpdate(_ row: RawOutputAssetCase) async {
        let session = ACPSession(id: "s", agentId: "bridge", worktreeId: "w", title: "t")

        session.apply(.toolCall(.init(
            toolCallId: "tc-raw-long-update",
            title: "Image generation",
            kind: "other",
            status: "in_progress",
            content: nil,
            locations: nil,
            rawInput: nil,
            rawOutput: row.rawOutput)))
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-raw-long-update",
            status: "completed",
            content: [.content(.text("final output"))],
            rawOutput: nil)))

        if case .toolCall(let tc) = session.transcript.messages[0] {
            #expect(tc.content == "final output")
            #expect(tc.rawOutput?.contains("[truncated]") == true)
            #expect(tc.assets == row.expectedAssets)
        } else {
            Issue.record("expected toolCall message")
        }
    }

    @Test("suppressed initial tool replay does not downgrade completed output")
    func suppressedInitialToolReplayDoesNotDowngradeCompletedOutput() async {
        let session = ACPSession(id: "s", agentId: "bridge", worktreeId: "w", title: "t")

        session.apply(.toolCall(.init(
            toolCallId: "tc-replay-downgrade",
            title: "Final image generation",
            kind: "read",
            status: "completed",
            content: [.content(.text("final output"))],
            locations: nil,
            rawInput: nil,
            rawOutput: nil)))

        let touched = session.applySuppressedReplaySideEffects(.toolCall(.init(
            toolCallId: "tc-replay-downgrade",
            title: "Initial tool",
            kind: "other",
            status: "in_progress",
            content: [.content(.text("partial output"))],
            locations: nil,
            rawInput: nil,
            rawOutput: AnyCodable([
                "data": AnyCodable([
                    AnyCodable([
                        "b64_json": AnyCodable("raw-output-data")
                    ])
                ])
            ]))))

        #expect(touched == [0])
        if case .toolCall(let tc) = session.transcript.messages[0] {
            #expect(tc.title == "Final image generation")
            #expect(tc.kind == "read")
            #expect(tc.status == "completed")
            #expect(tc.content == "final output")
            #expect(tc.rawOutput == nil)
            #expect(tc.assets == [])
        } else {
            Issue.record("expected toolCall message")
        }
    }

    @Test("suppressed tool update replay does not downgrade completed output")
    func suppressedToolUpdateReplayDoesNotDowngradeCompletedOutput() async throws {
        let session = ACPSession(id: "s", agentId: "bridge", worktreeId: "w", title: "t")

        session.apply(.toolCall(.init(
            toolCallId: "tc-update-replay-downgrade",
            title: "Final command",
            kind: "execute",
            status: "completed",
            content: [.content(.text("final output"))],
            locations: [.init(path: "Sources/Final.swift", line: 10)],
            rawInput: AnyCodable(["command": AnyCodable("swift test")]),
            rawOutput: nil)))

        let touched = session.applySuppressedReplaySideEffects(.toolCallUpdate(.init(
            toolCallId: "tc-update-replay-downgrade",
            status: "in_progress",
            content: [.content(.image(data: "stale-content-data", uri: nil, mimeType: "image/png"))],
            rawOutput: AnyCodable([
                "data": AnyCodable([
                    AnyCodable([
                        "b64_json": AnyCodable("raw-output-data")
                    ])
                ])
            ]),
            title: "Initial command",
            locations: [.init(path: "Sources/Stale.swift", line: 1)],
            rawInput: AnyCodable(["command": AnyCodable("stale")]),
            metadata: AnyCodable([
                "terminal_output_delta": AnyCodable([
                    "terminal_id": AnyCodable("term-replay"),
                    "data": AnyCodable("delta")
                ])
            ]))))

        #expect(touched == [0])
        if case .toolCall(let tc) = session.transcript.messages[0] {
            #expect(tc.title == "Final command")
            #expect(tc.kind == "execute")
            #expect(tc.status == "completed")
            #expect(tc.content == "final output")
            #expect(tc.locations == ["Sources/Final.swift"])
            #expect(tc.rawInput?.contains("swift test") == true)
            #expect(tc.rawInput?.contains("stale") == false)
            #expect(tc.terminalIds == ["term-replay"])
            let metadata = try #require(tc.metadata?.value as? [String: AnyCodable])
            #expect(metadata["terminal_output_delta"] != nil)
            #expect(tc.rawOutput == nil)
            #expect(tc.assets == [])
        } else {
            Issue.record("expected toolCall message")
        }
    }

    @Test("suppressed initial tool replay applies a newly available name even onto a completed snapshot")
    func suppressedInitialToolReplayAppliesNameOntoCompletedSnapshot() async {
        // Regression: a call persisted by an older build (no stored `name`)
        // is loaded, then session/load replay resends its initial tool_call
        // — now carrying `name` because the adapter/build was upgraded.
        // Content fields stay locked by canReplaceSnapshot (see the
        // "does not downgrade completed output" tests above), but `name`
        // is pure presentation metadata and must still apply.
        let session = ACPSession(id: "s", agentId: "bridge", worktreeId: "w", title: "t")

        session.apply(.toolCall(.init(
            toolCallId: "tc-replay-name",
            title: "Final command",
            kind: "execute",
            status: "completed",
            content: [.content(.text("final output"))])))

        let touched = session.applySuppressedReplaySideEffects(.toolCall(.init(
            toolCallId: "tc-replay-name",
            title: "Initial command",
            kind: "execute",
            status: "in_progress",
            name: "Bash")))

        #expect(touched == [0])
        if case .toolCall(let tc) = session.transcript.messages[0] {
            #expect(tc.title == "Final command")
            #expect(tc.status == "completed")
            #expect(tc.name == "Bash")
        } else {
            Issue.record("expected toolCall message")
        }
    }

    @Test("suppressed tool update replay applies a newly available name even onto a completed snapshot")
    func suppressedToolUpdateReplayAppliesNameOntoCompletedSnapshot() async {
        let session = ACPSession(id: "s", agentId: "bridge", worktreeId: "w", title: "t")

        session.apply(.toolCall(.init(
            toolCallId: "tc-update-replay-name",
            title: "Final command",
            kind: "execute",
            status: "completed",
            content: [.content(.text("final output"))])))

        let touched = session.applySuppressedReplaySideEffects(.toolCallUpdate(.init(
            toolCallId: "tc-update-replay-name",
            status: "in_progress",
            name: "exec_command")))

        #expect(touched == [0])
        if case .toolCall(let tc) = session.transcript.messages[0] {
            #expect(tc.title == "Final command")
            #expect(tc.status == "completed")
            #expect(tc.name == "exec_command")
        } else {
            Issue.record("expected toolCall message")
        }
    }

    @Test("suppressed replay onto a completed tool call preserves terminal ids from content",
          arguments: ACPSessionTests.TerminalReplayFrame.allCases)
    func suppressedToolReplayPreservesTerminalIdsFromContent(_ frame: TerminalReplayFrame) async {
        let session = ACPSession(id: "s", agentId: "bridge", worktreeId: "w", title: "t")

        session.apply(.toolCall(.init(
            toolCallId: "tc-replay-terminal",
            title: "Final command",
            kind: "execute",
            status: "completed",
            content: [.content(.text("final output"))],
            locations: nil,
            rawInput: nil,
            rawOutput: nil)))

        let replay: ACPSessionUpdate
        switch frame {
        case .completedUpdate:
            replay = .toolCallUpdate(.init(
                toolCallId: "tc-replay-terminal",
                status: "completed",
                content: [.terminal(terminalId: "term-replay")],
                rawOutput: nil))
        case .completedPayload, .inProgressPayload:
            replay = .toolCall(.init(
                toolCallId: "tc-replay-terminal",
                title: "Initial command",
                kind: "execute",
                status: frame == .completedPayload ? "completed" : "in_progress",
                content: [.terminal(terminalId: "term-replay")],
                locations: nil,
                rawInput: nil,
                rawOutput: nil))
        }
        let touched = session.applySuppressedReplaySideEffects(replay)

        #expect(touched == [0])
        if case .toolCall(let tc) = session.transcript.messages[0] {
            #expect(tc.title == "Final command")
            #expect(tc.content == "final output")
            #expect(tc.terminalIds == ["term-replay"])
        } else {
            Issue.record("expected toolCall message")
        }
    }

    @Test("content update does not preserve stale content image assets")
    func contentUpdateDoesNotPreserveStaleContentImageAssets() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")

        session.apply(.toolCall(.init(
            toolCallId: "tc-stale-content-image",
            title: "Image generation",
            kind: "other",
            status: "in_progress",
            content: [.content(.image(data: "stale-data", uri: nil, mimeType: "image/png"))],
            locations: nil,
            rawInput: nil,
            rawOutput: nil)))
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-stale-content-image",
            status: "in_progress",
            rawOutput: AnyCodable([
                "data": AnyCodable([
                    AnyCodable([
                        "url": AnyCodable("https://example.com/generated"),
                        "revised_prompt": AnyCodable("A useful screenshot")
                    ])
                ])
            ]))))
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-stale-content-image",
            status: "completed",
            content: [.content(.text("final output"))],
            rawOutput: nil)))

        if case .toolCall(let tc) = session.transcript.messages[0] {
            #expect(tc.content == "final output")
            #expect(tc.assets == [
                ACPMessage.ToolCallAsset.image(
                    data: nil,
                    uri: "https://example.com/generated",
                    mimeType: nil,
                    name: "generated")
            ])
        } else {
            Issue.record("expected toolCall message")
        }
    }

    @Test("toolCallUpdate merges metadata with existing tool metadata")
    func toolCallUpdateMergesMetadataWithExistingToolMetadata() async throws {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")

        session.apply(.toolCall(.init(
            toolCallId: "tc-metadata",
            title: "mcp tool",
            kind: "other",
            status: "in_progress",
            content: nil,
            locations: nil,
            rawInput: nil,
            rawOutput: nil,
            metadata: AnyCodable([
                "is_mcp_tool_call": AnyCodable(true),
                "tool": AnyCodable("screenshot")
            ]))))
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-metadata",
            status: "in_progress",
            rawOutput: nil,
            metadata: AnyCodable([
                "terminal_output_delta": AnyCodable([
                    "terminal_id": AnyCodable("term-metadata"),
                    "data": AnyCodable("ok\n")
                ])
            ]))))

        guard case .toolCall(let tc) = session.transcript.messages[0] else {
            Issue.record("expected toolCall message")
            return
        }
        let metadata = try #require(tc.metadata?.value as? [String: AnyCodable])
        #expect(metadata["is_mcp_tool_call"]?.value as? Bool == true)
        #expect(metadata["tool"]?.value as? String == "screenshot")
        let delta = try #require(metadata["terminal_output_delta"]?.value as? [String: AnyCodable])
        #expect(delta["terminal_id"]?.value as? String == "term-metadata")
    }

    @Test("image-only toolCall content is preserved as assets without preview")
    func imageOnlyToolCallContentPreservesAssetsWithoutPreview() async {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")

        session.apply(.toolCall(.init(
            toolCallId: "tc-image-only",
            title: "screenshot",
            kind: "read",
            status: "completed",
            content: [
                .content(.image(data: "base64-data", uri: "/tmp/result.png", mimeType: "image/png")),
                .content(.image(data: nil, uri: "file:///tmp/second-result.jpg", mimeType: "image/jpeg"))
            ],
            locations: nil,
            rawInput: nil,
            rawOutput: nil)))

        if case .toolCall(let tc) = session.transcript.messages[0] {
            #expect(tc.content == "")
            #expect(tc.preview == nil)
            #expect(tc.assets == [
                ACPMessage.ToolCallAsset.image(
                    data: "base64-data",
                    uri: "/tmp/result.png",
                    mimeType: "image/png",
                    name: "result.png"),
                ACPMessage.ToolCallAsset.image(
                    data: nil,
                    uri: "file:///tmp/second-result.jpg",
                    mimeType: "image/jpeg",
                    name: "second-result.jpg")
            ])
        } else {
            Issue.record("expected toolCall message")
        }
    }

    @Test("tool call metadata routes terminal output and exit")
    func toolCallMetadataRoutesTerminalOutputAndExit() async throws {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")

        session.apply(.toolCall(.init(
            toolCallId: "cmd-meta",
            title: "swift test",
            kind: "execute",
            status: "in_progress",
            content: [.terminal(terminalId: "cmd-meta")],
            locations: nil,
            rawInput: nil,
            rawOutput: nil,
            metadata: AnyCodable([
                "terminal_info": AnyCodable([
                    "terminal_id": AnyCodable("cmd-meta"),
                    "cwd": AnyCodable("/repo")
                ])
            ]))))
        session.apply(.toolCallUpdate(.init(
            toolCallId: "cmd-meta",
            status: "completed",
            rawOutput: nil,
            metadata: AnyCodable([
                "terminal_output_delta": AnyCodable([
                    "terminal_id": AnyCodable("cmd-meta"),
                    "data": AnyCodable("ok\n")
                ]),
                "terminal_exit": AnyCodable([
                    "terminal_id": AnyCodable("cmd-meta"),
                    "exit_code": AnyCodable(0),
                    "signal": AnyCodable(NSNull())
                ])
            ]))))

        let term = try #require(session.terminalHost.terminal(id: "cmd-meta"))
        #expect(term.snapshot(byteLimit: 1024).text == "ok\n")
        #expect(term.exitStatus == ACPTerminalExitStatus(exitCode: 0, signal: nil))
    }

    @Test("metadata-only terminal output attaches terminal id to tool call")
    func metadataOnlyTerminalOutputAttachesTerminalIdToToolCall() async throws {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")

        session.apply(.toolCall(.init(
            toolCallId: "cmd-meta-only",
            title: "swift test",
            kind: "execute",
            status: "in_progress",
            content: nil,
            locations: nil,
            rawInput: nil,
            rawOutput: nil)))
        session.apply(.toolCallUpdate(.init(
            toolCallId: "cmd-meta-only",
            status: "completed",
            rawOutput: nil,
            metadata: AnyCodable([
                "terminal_output_delta": AnyCodable([
                    "terminal_id": AnyCodable("cmd-meta-only"),
                    "data": AnyCodable("ok\n")
                ])
            ]))))

        let message = try #require(session.transcript.messages.first)
        guard case .toolCall(let toolCall) = message else {
            Issue.record("expected toolCall message")
            return
        }
        #expect(toolCall.terminalIds == ["cmd-meta-only"])

        let term = try #require(session.terminalHost.terminal(id: "cmd-meta-only"))
        #expect(term.snapshot(byteLimit: 1024).text == "ok\n")
    }

    @Test("suppressed replay does not duplicate existing terminal metadata output")
    func suppressedReplayDoesNotDuplicateExistingTerminalMetadataOutput() async throws {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        let update = ACPSessionUpdate.toolCallUpdate(.init(
            toolCallId: "cmd-replay-terminal",
            status: "in_progress",
            rawOutput: nil,
            metadata: AnyCodable([
                "terminal_output_delta": AnyCodable([
                    "terminal_id": AnyCodable("term-replay-terminal"),
                    "data": AnyCodable("building\n")
                ])
            ])))

        session.apply(.toolCall(.init(
            toolCallId: "cmd-replay-terminal",
            title: "swift test",
            kind: "execute",
            status: "in_progress",
            content: nil,
            locations: nil,
            rawInput: nil,
            rawOutput: nil)))
        session.apply(update)
        session.beginSuppressedReplaySideEffects()
        _ = session.applySuppressedReplaySideEffects(update)

        let term = try #require(session.terminalHost.terminal(id: "term-replay-terminal"))
        #expect(term.snapshot(byteLimit: 1024).text == "building\n")
    }

    @Test("suppressed replay replacement terminal output refreshes existing buffer")
    func suppressedReplayReplacementTerminalOutputRefreshesExistingBuffer() async throws {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.apply(.toolCall(.init(
            toolCallId: "cmd-replay-terminal-snapshot",
            title: "swift test",
            kind: "execute",
            status: "in_progress",
            content: nil,
            locations: nil,
            rawInput: nil,
            rawOutput: nil)))
        session.apply(.toolCallUpdate(.init(
            toolCallId: "cmd-replay-terminal-snapshot",
            status: "in_progress",
            rawOutput: nil,
            metadata: AnyCodable([
                "terminal_output_delta": AnyCodable([
                    "terminal_id": AnyCodable("term-replay-terminal-snapshot"),
                    "data": AnyCodable("partial\n")
                ])
            ]))))

        session.beginSuppressedReplaySideEffects()
        _ = session.applySuppressedReplaySideEffects(.toolCallUpdate(.init(
            toolCallId: "cmd-replay-terminal-snapshot",
            status: "completed",
            rawOutput: nil,
            metadata: AnyCodable([
                "terminal_output": AnyCodable([
                    "terminal_id": AnyCodable("term-replay-terminal-snapshot"),
                    "data": AnyCodable("partial\ncomplete\n")
                ])
            ]))))

        let term = try #require(session.terminalHost.terminal(id: "term-replay-terminal-snapshot"))
        #expect(term.snapshot(byteLimit: 1024).text == "partial\ncomplete\n")
    }

    @Test("suppressed replay rebuilds terminal metadata across replay frames")
    func suppressedReplayRebuildsTerminalMetadataAcrossReplayFrames() async throws {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.apply(.toolCall(.init(
            toolCallId: "cmd-replay-frames",
            title: "swift test",
            kind: "execute",
            status: "in_progress",
            content: nil,
            locations: nil,
            rawInput: nil,
            rawOutput: nil)))

        session.beginSuppressedReplaySideEffects()
        _ = session.applySuppressedReplaySideEffects(.toolCallUpdate(.init(
            toolCallId: "cmd-replay-frames",
            status: "in_progress",
            rawOutput: nil,
            metadata: AnyCodable([
                "terminal_info": AnyCodable([
                    "terminal_id": AnyCodable("term-replay-frames"),
                    "cwd": AnyCodable("/tmp/project")
                ])
            ]))))
        _ = session.applySuppressedReplaySideEffects(.toolCallUpdate(.init(
            toolCallId: "cmd-replay-frames",
            status: "in_progress",
            rawOutput: nil,
            metadata: AnyCodable([
                "terminal_output_delta": AnyCodable([
                    "terminal_id": AnyCodable("term-replay-frames"),
                    "data": AnyCodable("building\n")
                ])
            ]))))
        _ = session.applySuppressedReplaySideEffects(.toolCallUpdate(.init(
            toolCallId: "cmd-replay-frames",
            status: "completed",
            rawOutput: nil,
            metadata: AnyCodable([
                "terminal_exit": AnyCodable([
                    "terminal_id": AnyCodable("term-replay-frames"),
                    "exit_code": AnyCodable(0)
                ])
            ]))))

        let term = try #require(session.terminalHost.terminal(id: "term-replay-frames"))
        #expect(term.cwd == "/tmp/project")
        #expect(term.snapshot(byteLimit: 1024).text == "building\n")
        #expect(term.exitStatus == ACPTerminalExitStatus(exitCode: 0, signal: nil))
    }

    @Test("suppressed replay preserves exit for buffered metadata terminal")
    func suppressedReplayPreservesExitForBufferedMetadataTerminal() async throws {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.apply(.toolCall(.init(
            toolCallId: "cmd-replay-buffered-exit",
            title: "swift test",
            kind: "execute",
            status: "in_progress",
            content: nil,
            locations: nil,
            rawInput: nil,
            rawOutput: nil)))
        session.apply(.toolCallUpdate(.init(
            toolCallId: "cmd-replay-buffered-exit",
            status: "in_progress",
            rawOutput: nil,
            metadata: AnyCodable([
                "terminal_output_delta": AnyCodable([
                    "terminal_id": AnyCodable("term-replay-buffered-exit"),
                    "data": AnyCodable("building\n")
                ])
            ]))))

        session.beginSuppressedReplaySideEffects()
        _ = session.applySuppressedReplaySideEffects(.toolCallUpdate(.init(
            toolCallId: "cmd-replay-buffered-exit",
            status: "in_progress",
            rawOutput: nil,
            metadata: AnyCodable([
                "terminal_output_delta": AnyCodable([
                    "terminal_id": AnyCodable("term-replay-buffered-exit"),
                    "data": AnyCodable("building\n")
                ])
            ]))))
        _ = session.applySuppressedReplaySideEffects(.toolCallUpdate(.init(
            toolCallId: "cmd-replay-buffered-exit",
            status: "completed",
            rawOutput: nil,
            metadata: AnyCodable([
                "terminal_exit": AnyCodable([
                    "terminal_id": AnyCodable("term-replay-buffered-exit"),
                    "exit_code": AnyCodable(0)
                ])
            ]))))

        let term = try #require(session.terminalHost.terminal(id: "term-replay-buffered-exit"))
        #expect(term.snapshot(byteLimit: 1024).text == "building\n")
        #expect(term.exitStatus == ACPTerminalExitStatus(exitCode: 0, signal: nil))
    }

    @Test("metadata terminal id survives later content-only update")
    func metadataTerminalIdSurvivesLaterContentOnlyUpdate() async throws {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")

        session.apply(.toolCall(.init(
            toolCallId: "cmd-meta-then-content",
            title: "swift test",
            kind: "execute",
            status: "in_progress",
            content: nil,
            locations: nil,
            rawInput: nil,
            rawOutput: nil)))
        session.apply(.toolCallUpdate(.init(
            toolCallId: "cmd-meta-then-content",
            status: "in_progress",
            rawOutput: nil,
            metadata: AnyCodable([
                "terminal_output_delta": AnyCodable([
                    "terminal_id": AnyCodable("term-meta-then-content"),
                    "data": AnyCodable("building\n")
                ])
            ]))))
        session.apply(.toolCallUpdate(.init(
            toolCallId: "cmd-meta-then-content",
            status: "completed",
            content: [.content(.text("final output"))],
            rawOutput: nil)))

        let message = try #require(session.transcript.messages.first)
        guard case .toolCall(let toolCall) = message else {
            Issue.record("expected toolCall message")
            return
        }
        #expect(toolCall.terminalIds == ["term-meta-then-content"])
        #expect(toolCall.content == "final output")

        let term = try #require(session.terminalHost.terminal(id: "term-meta-then-content"))
        #expect(term.snapshot(byteLimit: 1024).text == "building\n")
    }

    @Test("terminal exit metadata-only update attaches terminal id to tool call")
    func terminalExitMetadataOnlyUpdateAttachesTerminalIdToToolCall() async throws {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")

        session.apply(.toolCall(.init(
            toolCallId: "cmd-exit-only",
            title: "swift test",
            kind: "execute",
            status: "in_progress",
            content: nil,
            locations: nil,
            rawInput: nil,
            rawOutput: nil)))
        session.apply(.toolCallUpdate(.init(
            toolCallId: "cmd-exit-only",
            status: "completed",
            rawOutput: nil,
            metadata: AnyCodable([
                "terminal_exit": AnyCodable([
                    "terminal_id": AnyCodable("term-exit-only"),
                    "exit_code": AnyCodable(1)
                ])
            ]))))

        let message = try #require(session.transcript.messages.first)
        guard case .toolCall(let toolCall) = message else {
            Issue.record("expected toolCall message")
            return
        }
        #expect(toolCall.terminalIds == ["term-exit-only"])

        let term = try #require(session.terminalHost.terminal(id: "term-exit-only"))
        #expect(term.exitStatus == ACPTerminalExitStatus(exitCode: 1, signal: nil))
    }

    @Test("suppressed replay content excludes an exit-only terminal id but still records the exit",
          arguments: ACPSessionTests.ExitOnlyReplayFrame.allCases)
    func suppressedReplayContentExcludesExitOnlyTerminalId(_ frame: ExitOnlyReplayFrame) async throws {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        let exitMetadata = AnyCodable([
            "terminal_exit": AnyCodable([
                "terminal_id": AnyCodable("term-exit-only"),
                "exit_code": AnyCodable(0)
            ])
        ])

        session.apply(.toolCall(.init(
            toolCallId: "cmd-exit-content",
            title: "swift test",
            kind: "execute",
            status: "completed",
            content: [.content(.text("final output"))],
            locations: nil,
            rawInput: nil,
            rawOutput: nil)))
        session.beginSuppressedReplaySideEffects()
        switch frame {
        case .payload:
            _ = session.applySuppressedReplaySideEffects(.toolCall(.init(
                toolCallId: "cmd-exit-content",
                title: "swift test",
                kind: "execute",
                status: "completed",
                content: [.content(.text("final output"))],
                locations: nil,
                rawInput: nil,
                rawOutput: nil,
                metadata: exitMetadata)))
        case .update:
            _ = session.applySuppressedReplaySideEffects(.toolCallUpdate(.init(
                toolCallId: "cmd-exit-content",
                status: "completed",
                content: [.content(.text("final output"))],
                rawOutput: nil,
                metadata: exitMetadata)))
        }

        let message = try #require(session.transcript.messages.first)
        guard case .toolCall(let toolCall) = message else {
            Issue.record("expected toolCall message")
            return
        }
        #expect(toolCall.terminalIds == [])

        let term = try #require(session.terminalHost.terminal(id: "term-exit-only"))
        #expect(term.exitStatus == ACPTerminalExitStatus(exitCode: 0, signal: nil))
    }

    @Test("terminal_output metadata replaces previous deltas")
    func terminalOutputMetadataReplacesPreviousDeltas() async throws {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")

        session.apply(.toolCall(.init(
            toolCallId: "cmd-replace",
            title: "swift test",
            kind: "execute",
            status: "in_progress",
            content: [.terminal(terminalId: "cmd-replace")],
            locations: nil,
            rawInput: nil,
            rawOutput: nil)))
        session.apply(.toolCallUpdate(.init(
            toolCallId: "cmd-replace",
            status: "in_progress",
            rawOutput: nil,
            metadata: AnyCodable([
                "terminal_output_delta": AnyCodable([
                    "terminal_id": AnyCodable("cmd-replace"),
                    "data": AnyCodable("stale\n")
                ])
            ]))))
        session.apply(.toolCallUpdate(.init(
            toolCallId: "cmd-replace",
            status: "completed",
            rawOutput: nil,
            metadata: AnyCodable([
                "terminal_output": AnyCodable([
                    "terminal_id": AnyCodable("cmd-replace"),
                    "data": AnyCodable("fresh\n")
                ])
            ]))))

        let term = try #require(session.terminalHost.terminal(id: "cmd-replace"))
        #expect(term.snapshot(byteLimit: 1024).text == "fresh\n")
    }

    @Test("terminal metadata accepts raw Swift dictionaries")
    func terminalMetadataAcceptsRawSwiftDictionaries() async throws {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")

        session.apply(.toolCall(.init(
            toolCallId: "cmd-raw-meta",
            title: "swift test",
            kind: "execute",
            status: "in_progress",
            content: [.terminal(terminalId: "cmd-raw-meta")],
            locations: nil,
            rawInput: nil,
            rawOutput: nil)))
        session.apply(.toolCallUpdate(.init(
            toolCallId: "cmd-raw-meta",
            status: "completed",
            rawOutput: nil,
            metadata: AnyCodable([
                "terminal_output_delta": [
                    "terminal_id": "cmd-raw-meta",
                    "data": "raw\n"
                ]
            ]))))

        let term = try #require(session.terminalHost.terminal(id: "cmd-raw-meta"))
        #expect(term.snapshot(byteLimit: 1024).text == "raw\n")
    }

    @Test("unknown tool call metadata does not create detached terminal")
    func unknownToolCallMetadataDoesNotCreateDetachedTerminal() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")

        let touched = session.apply(.toolCallUpdate(.init(
            toolCallId: "missing",
            status: "completed",
            rawOutput: nil,
            metadata: AnyCodable([
                "terminal_output_delta": AnyCodable([
                    "terminal_id": AnyCodable("missing"),
                    "data": AnyCodable("orphan\n")
                ])
            ]))))

        #expect(touched.isEmpty)
        #expect(session.terminalHost.terminal(id: "missing") == nil)
    }

    @Test("toolCall content preserves embedded resource text and asset")
    func toolCallPreservesEmbeddedResourceTextAndAsset() async {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")

        session.apply(.toolCall(.init(
            toolCallId: "tc-resource",
            title: "read resource",
            kind: "read",
            status: "completed",
            content: [.content(.resource(
                uri: "file:///tmp/File.swift",
                mimeType: "text/plain",
                text: "let value = 1\n"
            ))],
            locations: nil,
            rawInput: nil,
            rawOutput: nil)))

        if case .toolCall(let tc) = session.transcript.messages[0] {
            #expect(tc.content == "let value = 1\n")
            #expect(tc.assets == [
                ACPMessage.ToolCallAsset.resource(
                    uri: "file:///tmp/File.swift",
                    name: "File.swift",
                    mimeType: "text/plain")
            ])
        } else {
            Issue.record("expected toolCall message")
        }
    }

    @Test("diff content flattens to a readable text representation")
    func toolCallUpdateDiff() async {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        session.apply(.toolCall(.init(
            toolCallId: "tc-2", title: "edit", kind: "edit", status: "in_progress",
            content: nil, locations: nil, rawInput: nil, rawOutput: nil)))
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-2", status: "completed",
            content: [.diff(path: "a.swift", oldText: "let x = 1\n", newText: "let x = 2\n", kind: nil, diffStats: nil)],
            rawOutput: nil)))
        #expect(session.transcript.messages.count == 1)
        if case .toolCall(let tc) = session.transcript.messages[0] {
            #expect(tc.content == "--- a.swift\n-let x = 1\n+let x = 2")
        } else { Issue.record("expected toolCall message") }
    }

    @Test("terminal content records terminalIds and drops placeholder from content")
    func toolCallUpdateTerminal() async {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        session.apply(.toolCall(.init(
            toolCallId: "tc-3", title: "run", kind: "execute", status: "in_progress",
            content: nil, locations: nil, rawInput: nil, rawOutput: nil)))
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-3", status: "in_progress",
            content: [.terminal(terminalId: "term-42")],
            rawOutput: nil)))
        #expect(session.transcript.messages.count == 1)
        if case .toolCall(let tc) = session.transcript.messages[0] {
            #expect(tc.terminalIds == ["term-42"])
            #expect(tc.content == "")
        } else { Issue.record("expected toolCall message") }
    }

    @Test("initial toolCall content excludes exit-only terminal id")
    func toolCallInitialContentExcludesExitOnlyTerminalId() async throws {
        let session = ACPSession(id: "s", agentId: "bridge", worktreeId: "w", title: "t")
        session.apply(.toolCall(.init(
            toolCallId: "tc-initial-exit-content",
            title: "run",
            kind: "execute",
            status: "completed",
            content: [.content(.text("final output"))],
            locations: nil,
            rawInput: nil,
            rawOutput: nil,
            metadata: AnyCodable([
                "terminal_exit": AnyCodable([
                    "terminal_id": AnyCodable("term-initial-exit-only"),
                    "exit_code": AnyCodable(0)
                ])
            ]))))

        if case .toolCall(let tc) = session.transcript.messages[0] {
            #expect(tc.terminalIds.isEmpty)
            #expect(tc.content == "final output")
        } else { Issue.record("expected toolCall message") }

        let term = try #require(session.terminalHost.terminal(id: "term-initial-exit-only"))
        #expect(term.exitStatus == ACPTerminalExitStatus(exitCode: 0, signal: nil))
    }

    @Test("toolCallUpdate clears stale terminalIds when content has no terminals")
    func toolCallUpdateClearsTerminalIds() async {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        session.apply(.toolCall(.init(
            toolCallId: "tc-clear", title: "run", kind: "execute", status: "in_progress",
            content: [.terminal(terminalId: "term-x")],
            locations: nil, rawInput: nil, rawOutput: nil)))
        if case .toolCall(let tc) = session.transcript.messages[0] {
            #expect(tc.terminalIds == ["term-x"])
        } else { Issue.record("expected toolCall message") }
        // Final replacement update carries text only — terminalIds must clear.
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-clear", status: "completed",
            content: [.content(.text("final output"))],
            rawOutput: nil)))
        if case .toolCall(let tc) = session.transcript.messages[0] {
            #expect(tc.terminalIds.isEmpty)
            #expect(tc.content == "final output")
        } else { Issue.record("expected toolCall message") }
    }

    @Test("terminal exit metadata does not reattach cleared terminalIds")
    func terminalExitMetadataDoesNotReattachClearedTerminalIds() async throws {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        session.apply(.toolCall(.init(
            toolCallId: "tc-exit-clear", title: "run", kind: "execute", status: "in_progress",
            content: [.terminal(terminalId: "term-exit")],
            locations: nil, rawInput: nil, rawOutput: nil)))
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-exit-clear",
            status: "completed",
            content: [.content(.text("final output"))],
            rawOutput: nil,
            metadata: AnyCodable([
                "terminal_exit": AnyCodable([
                    "terminal_id": AnyCodable("term-exit"),
                    "exit_code": AnyCodable(0)
                ])
            ]))))

        if case .toolCall(let tc) = session.transcript.messages[0] {
            #expect(tc.terminalIds.isEmpty)
            #expect(tc.content == "final output")
        } else { Issue.record("expected toolCall message") }

        let term = try #require(session.terminalHost.terminal(id: "term-exit"))
        #expect(term.exitStatus == ACPTerminalExitStatus(exitCode: 0, signal: nil))
    }

    @Test("in-progress toolCall strips opening fence but keeps trailing line")
    func toolCallKeepsTrailingMidStream() async {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        session.apply(.toolCall(.init(
            toolCallId: "tc-6", title: "read", kind: "read", status: "in_progress",
            content: [.content(.text("```\npartial output"))],
            locations: nil, rawInput: nil, rawOutput: nil)))
        if case .toolCall(let tc) = session.transcript.messages[0] {
            #expect(tc.content == "partial output")
            #expect(tc.contentLanguage == nil)
        } else { Issue.record("expected toolCall message") }
    }

    @Test("toolCall without wrapping fences is left untouched")
    func toolCallNoFencePassthrough() async {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        session.apply(.toolCall(.init(
            toolCallId: "tc-7", title: "read", kind: "read", status: "completed",
            content: [.content(.text("hello\n```\ninner\n```\nworld"))],
            locations: nil, rawInput: nil, rawOutput: nil)))
        if case .toolCall(let tc) = session.transcript.messages[0] {
            #expect(tc.content == "hello\n```\ninner\n```\nworld")
            #expect(tc.contentLanguage == nil)
        } else { Issue.record("expected toolCall message") }
    }

    @Test("streamed toolCallUpdate suffix chunks accumulate into the full content")
    func toolCallUpdateStreamingSuffixAccumulates() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.apply(.toolCall(.init(
            toolCallId: "tc-stream", title: "run", kind: "execute", status: "in_progress",
            content: nil, locations: nil, rawInput: nil, rawOutput: nil)))
        // Adapter sends the full cumulative content on each update.
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-stream", status: "in_progress",
            content: [.content(.text("line one\n"))])))
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-stream", status: "in_progress",
            content: [.content(.text("line one\nline two\n"))])))
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-stream", status: "in_progress",
            content: [.content(.text("line one\nline two\nline three\n"))])))
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-stream", status: "completed",
            content: [.content(.text("line one\nline two\nline three\n"))])))
        if case .toolCall(let tc) = session.transcript.messages[0] {
            #expect(tc.content == "line one\nline two\nline three\n")
            #expect(tc.preview == "line one")
            #expect(tc.status == "completed")
        } else { Issue.record("expected toolCall message") }
    }

    @Test("streamed toolCallUpdate strips wrapping fence across suffix chunks")
    func toolCallUpdateStreamingFenceStripsAcrossChunks() async {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        session.apply(.toolCall(.init(
            toolCallId: "tc-fence-stream", title: "read", kind: "read", status: "in_progress",
            content: nil, locations: nil, rawInput: nil, rawOutput: nil)))
        // Opening fence arrives alone.
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-fence-stream", status: "in_progress",
            content: [.content(.text("```swift"))])))
        // First line of code arrives.
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-fence-stream", status: "in_progress",
            content: [.content(.text("```swift\nlet x = 1"))])))
        // More code arrives.
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-fence-stream", status: "in_progress",
            content: [.content(.text("```swift\nlet x = 1\nlet y = 2"))])))
        // Closing fence arrives with final status.
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-fence-stream", status: "completed",
            content: [.content(.text("```swift\nlet x = 1\nlet y = 2\n```"))])))
        if case .toolCall(let tc) = session.transcript.messages[0] {
            #expect(tc.content == "let x = 1\nlet y = 2")
            #expect(tc.contentLanguage == "swift")
            #expect(tc.preview == "let x = 1")
            #expect(tc.status == "completed")
        } else { Issue.record("expected toolCall message") }
    }

    @Test("streamed toolCallUpdate preserves assets declared across suffix chunks")
    func toolCallUpdateStreamingAssetsAcrossChunks() async {
        let session = ACPSession(id: "s", agentId: "bridge", worktreeId: "w", title: "t")
        session.apply(.toolCall(.init(
            toolCallId: "tc-asset-stream", title: "screenshot", kind: "read", status: "in_progress",
            content: nil, locations: nil, rawInput: nil, rawOutput: nil)))
        // First chunk: text + an image asset.
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-asset-stream", status: "in_progress",
            content: [
                .content(.text("captured")),
                .content(.image(data: "first-bytes", uri: nil, mimeType: "image/png"))
            ])))
        // Second chunk: same text+image plus a second image (cumulative snapshot).
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-asset-stream", status: "completed",
            content: [
                .content(.text("captured")),
                .content(.image(data: "first-bytes", uri: nil, mimeType: "image/png")),
                .content(.image(data: nil, uri: "file:///tmp/second.png", mimeType: "image/png"))
            ])))
        if case .toolCall(let tc) = session.transcript.messages[0] {
            #expect(tc.content == "captured")
            #expect(tc.assets == [
                ACPMessage.ToolCallAsset.image(data: "first-bytes", mimeType: "image/png"),
                ACPMessage.ToolCallAsset.image(
                    data: nil, uri: "file:///tmp/second.png", mimeType: "image/png", name: "second.png")
            ])
        } else { Issue.record("expected toolCall message") }
    }

    @Test("streamed toolCallUpdate preserves terminal ids declared across suffix chunks")
    func toolCallUpdateStreamingTerminalIdsAcrossChunks() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.apply(.toolCall(.init(
            toolCallId: "tc-term-stream", title: "bash", kind: "execute", status: "in_progress",
            content: nil, locations: nil, rawInput: nil, rawOutput: nil)))
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-term-stream", status: "in_progress",
            content: [
                .terminal(terminalId: "term-a"),
                .content(.text("starting"))
            ])))
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-term-stream", status: "completed",
            content: [
                .terminal(terminalId: "term-a"),
                .content(.text("starting\nfinished")),
                .terminal(terminalId: "term-b")
            ])))
        if case .toolCall(let tc) = session.transcript.messages[0] {
            #expect(tc.content == "starting\nfinished")
            #expect(tc.terminalIds == ["term-a", "term-b"])
        } else { Issue.record("expected toolCall message") }
    }

    @Test("toolCallUpdate with identical cumulative content does not bump contentRevision")
    func toolCallUpdateIdenticalContentDoesNotBumpRevision() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.apply(.toolCall(.init(
            toolCallId: "tc-identical", title: "run", kind: "execute", status: "in_progress",
            content: [.content(.text("same output"))])))
        guard case .toolCall(let initial) = session.transcript.messages[0] else {
            Issue.record("expected toolCall message")
            return
        }
        let revisionBefore = initial.contentRevision
        // Adapter re-sends the same cumulative content (e.g. a status-only
        // update that happens to also include the content snapshot).
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-identical", status: "completed",
            content: [.content(.text("same output"))])))
        if case .toolCall(let tc) = session.transcript.messages[0] {
            #expect(tc.contentRevision == revisionBefore)
            #expect(tc.content == "same output")
            #expect(tc.status == "completed")
        } else { Issue.record("expected toolCall message") }
    }

    @Test("toolCallUpdate with divergent content (non-prefix) reprocesses fully")
    func toolCallUpdateDivergentContentReprocessesFully() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.apply(.toolCall(.init(
            toolCallId: "tc-divergent", title: "run", kind: "execute", status: "in_progress",
            content: [.content(.text("first output\n"))])))
        // The next update carries entirely different content (not a prefix
        // extension). The full reprocess path must replace content.
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-divergent", status: "completed",
            content: [.content(.text("completely different output\n"))])))
        if case .toolCall(let tc) = session.transcript.messages[0] {
            #expect(tc.content == "completely different output\n")
            #expect(tc.preview == "completely different output")
            #expect(tc.status == "completed")
        } else { Issue.record("expected toolCall message") }
    }

    @Test("streamed text-growing item preserves earlier content assets across suffix updates")
    func toolCallUpdateStreamingTextGrowthPreservesEarlierAssets() async {
        let session = ACPSession(id: "s", agentId: "bridge", worktreeId: "w", title: "t")
        session.apply(.toolCall(.init(
            toolCallId: "tc-asset-preserve", title: "screenshot", kind: "read", status: "in_progress",
            content: nil, locations: nil, rawInput: nil, rawOutput: nil)))
        // First chunk: text + image (two items).
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-asset-preserve", status: "in_progress",
            content: [
                .content(.text("a")),
                .content(.image(data: "img-bytes", uri: nil, mimeType: "image/png"))
            ])))
        // Second chunk: the SAME image item, but the text item grew in place
        // (text "a" -> "ab"). Items count is still 2; the suffix path's
        // `newItemSlice` is empty, so the image must be preserved from the
        // previous apply, not dropped.
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-asset-preserve", status: "completed",
            content: [
                .content(.text("ab")),
                .content(.image(data: "img-bytes", uri: nil, mimeType: "image/png"))
            ])))
        if case .toolCall(let tc) = session.transcript.messages[0] {
            #expect(tc.content == "ab")
            #expect(tc.assets == [
                ACPMessage.ToolCallAsset.image(data: "img-bytes", mimeType: "image/png")
            ])
        } else { Issue.record("expected toolCall message") }
    }

    @Test("toolCallUpdate with same text but newly added image asset extracts the asset")
    func toolCallUpdateSameTextNewAssetExtractsAsset() async {
        let session = ACPSession(id: "s", agentId: "bridge", worktreeId: "w", title: "t")
        session.apply(.toolCall(.init(
            toolCallId: "tc-same-text-asset", title: "screenshot", kind: "read", status: "in_progress",
            content: nil, locations: nil, rawInput: nil, rawOutput: nil)))
        // First update establishes the text + cache.
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-same-text-asset", status: "in_progress",
            content: [.content(.text("same"))])))
        // Second update re-sends the same flattened text but adds a new
        // image asset, with the SAME status (in_progress) so `isFinal`
        // doesn't flip and force a full reprocess. The identical-text fast
        // path must NOT skip asset extraction for the newly added item.
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-same-text-asset", status: "in_progress",
            content: [
                .content(.text("same")),
                .content(.image(data: "new-img", uri: nil, mimeType: "image/png"))
            ])))
        if case .toolCall(let tc) = session.transcript.messages[0] {
            #expect(tc.content == "same")
            #expect(tc.assets == [
                ACPMessage.ToolCallAsset.image(data: "new-img", mimeType: "image/png")
            ], "assets=\(tc.assets)")
        } else { Issue.record("expected toolCall message") }
    }

    @Test("toolCallUpdate with same text but newly added terminal id extracts the terminal id")
    func toolCallUpdateSameTextNewTerminalExtractsTerminalId() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.apply(.toolCall(.init(
            toolCallId: "tc-same-text-term", title: "bash", kind: "execute", status: "in_progress",
            content: nil, locations: nil, rawInput: nil, rawOutput: nil)))
        // First update establishes the text + cache.
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-same-text-term", status: "in_progress",
            content: [.content(.text("running"))])))
        // Second update re-sends the same text but adds a terminal item,
        // with the SAME status (in_progress) so `isFinal` doesn't flip.
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-same-text-term", status: "in_progress",
            content: [
                .content(.text("running")),
                .terminal(terminalId: "term-late")
            ])))
        if case .toolCall(let tc) = session.transcript.messages[0] {
            #expect(tc.content == "running")
            #expect(tc.terminalIds == ["term-late"], "terminalIds=\(tc.terminalIds)")
        } else { Issue.record("expected toolCall message") }
    }

    /// An in-progress snapshot followed by a completed cumulative snapshot:
    /// the suffix fast path must either apply or fall to a full reprocess so
    /// fence stripping matches a from-scratch parse of the final text.
    @Test("streamed toolCallUpdate fence handling across a partial then completed snapshot",
          arguments: ACPSessionTests.StreamedFenceCase.all)
    func toolCallUpdateStreamedFenceHandling(_ row: StreamedFenceCase) async {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        session.apply(.toolCall(.init(
            toolCallId: "tc-streamed-fence", title: "read", kind: "read", status: "in_progress",
            content: nil, locations: nil, rawInput: nil, rawOutput: nil)))
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-streamed-fence", status: "in_progress",
            content: [.content(.text(row.partial))])))
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-streamed-fence", status: "completed",
            content: [.content(.text(row.completed))])))
        if case .toolCall(let tc) = session.transcript.messages[0] {
            #expect(tc.content == row.expectedContent)
            if let language = row.expectedLanguage {
                #expect(tc.contentLanguage == language)
            }
            if let preview = row.expectedPreview {
                #expect(tc.preview == preview)
            }
        } else { Issue.record("expected toolCall message") }
    }

    @Test("toolCallUpdate with same text and item count but replaced image reprocesses assets")
    func toolCallUpdateSameTextReplacedImageReprocessesAssets() async {
        let session = ACPSession(id: "s", agentId: "bridge", worktreeId: "w", title: "t")
        session.apply(.toolCall(.init(
            toolCallId: "tc-replaced-img", title: "screenshot", kind: "read", status: "in_progress",
            content: nil, locations: nil, rawInput: nil, rawOutput: nil)))
        // First update: text + image(old).
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-replaced-img", status: "in_progress",
            content: [
                .content(.text("same")),
                .content(.image(data: "old-img", uri: nil, mimeType: "image/png"))
            ])))
        if case .toolCall(let tc1) = session.transcript.messages[0] {
            #expect(tc1.assets == [
                ACPMessage.ToolCallAsset.image(data: "old-img", mimeType: "image/png")
            ], "assets after first=\(tc1.assets)")
        }
        // Second update: text + image(new) — same item count, same
        // flattened text, but the image was replaced in place. The
        // identical-text fast path must detect the structured change and
        // reprocess to pick up the new asset (replacing the old one, matching
        // the legacy full-reprocess semantics).
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-replaced-img", status: "in_progress",
            content: [
                .content(.text("same")),
                .content(.image(data: "new-img", uri: nil, mimeType: "image/png"))
            ])))
        if case .toolCall(let tc2) = session.transcript.messages[0] {
            #expect(tc2.content == "same")
            #expect(tc2.assets == [
                ACPMessage.ToolCallAsset.image(data: "new-img", mimeType: "image/png")
            ], "assets after second=\(tc2.assets)")
        } else { Issue.record("expected toolCall message") }
    }

    @Test("streamed toolCallUpdate refreshes preview while the first line is still being built")
    func toolCallUpdateStreamingRefreshesPreviewForPartialFirstLine() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.apply(.toolCall(.init(
            toolCallId: "tc-partial-first-line", title: "run", kind: "execute", status: "in_progress",
            content: nil, locations: nil, rawInput: nil, rawOutput: nil)))
        // First chunk: a partial first line "bui" (no newline yet).
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-partial-first-line", status: "in_progress",
            content: [.content(.text("bui"))])))
        if case .toolCall(let tc1) = session.transcript.messages[0] {
            #expect(tc1.preview == "bui", "preview=\(tc1.preview ?? "nil")")
        }
        // Second chunk: the first line is completed to "building" and a
        // newline starts the second line. The preview must be refreshed
        // from "bui" to "building".
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-partial-first-line", status: "in_progress",
            content: [.content(.text("building\nsecond line"))])))
        if case .toolCall(let tc2) = session.transcript.messages[0] {
            #expect(tc2.content == "building\nsecond line")
            #expect(tc2.preview == "building", "preview=\(tc2.preview ?? "nil")")
        } else { Issue.record("expected toolCall message") }
    }

    @Test("streamed toolCallUpdate refreshes fence language while the tag is still being built")
    func toolCallUpdateStreamingRefreshesFenceLanguageForPartialTag() async {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        session.apply(.toolCall(.init(
            toolCallId: "tc-partial-tag", title: "read", kind: "read", status: "in_progress",
            content: nil, locations: nil, rawInput: nil, rawOutput: nil)))
        // First chunk: opening fence with a partial language tag "```c".
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-partial-tag", status: "in_progress",
            content: [.content(.text("```c\nint x = 1;"))])))
        if case .toolCall(let tc1) = session.transcript.messages[0] {
            #expect(tc1.contentLanguage == "c", "lang=\(tc1.contentLanguage ?? "nil")")
        }
        // Second chunk: the tag is completed to "cpp". The fence language
        // must be refreshed from "c" to "cpp".
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-partial-tag", status: "in_progress",
            content: [.content(.text("```cpp\nint x = 1;\nint y = 2;"))])))
        if case .toolCall(let tc2) = session.transcript.messages[0] {
            #expect(tc2.content == "int x = 1;\nint y = 2;")
            #expect(tc2.contentLanguage == "cpp", "lang=\(tc2.contentLanguage ?? "nil")")
        } else { Issue.record("expected toolCall message") }
    }

    @Test("streamed toolCallUpdate with terminal inserted before text reprocesses terminals")
    func toolCallUpdateStreamingTerminalInsertedBeforeTextReprocesses() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.apply(.toolCall(.init(
            toolCallId: "tc-term-insert", title: "bash", kind: "execute", status: "in_progress",
            content: nil, locations: nil, rawInput: nil, rawOutput: nil)))
        // First update: text only.
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-term-insert", status: "in_progress",
            content: [.content(.text("run"))])))
        // Second update: a terminal is inserted BEFORE the text item, and
        // the text grows. The suffix path's `newItemSlice` (starting at
        // the old item count) would miss the terminal; the prefix-items
        // guard must detect the restructure and fall to full reprocess.
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-term-insert", status: "completed",
            content: [
                .terminal(terminalId: "t1"),
                .content(.text("running"))
            ])))
        if case .toolCall(let tc) = session.transcript.messages[0] {
            #expect(tc.content == "running")
            #expect(tc.terminalIds == ["t1"], "terminalIds=\(tc.terminalIds)")
        } else { Issue.record("expected toolCall message") }
    }

    /// Same text and status, so only the rawOutput changes: the
    /// identical-text fast path must fall to a full reprocess so the assets
    /// are rebuilt from the new rawOutput (replacing, not accumulating).
    @Test("toolCallUpdate with same text but a replaced rawOutput rebuilds assets",
          arguments: ACPSessionTests.RawOutputAssetCase.sameTextReplacements)
    func toolCallUpdateSameTextReplacedRawOutputRebuildsAssets(_ row: RawOutputAssetCase) async {
        let session = ACPSession(id: "s", agentId: "bridge", worktreeId: "w", title: "t")
        session.apply(.toolCall(.init(
            toolCallId: "tc-raw-replace", title: "image", kind: "other", status: "in_progress",
            content: nil, locations: nil, rawInput: nil, rawOutput: nil)))
        // First update: text + rawOutput image A.
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-raw-replace", status: "in_progress",
            content: [.content(.text("same"))],
            rawOutput: AnyCodable(["data": AnyCodable("img-a"), "mime_type": AnyCodable("image/png")]))))
        if case .toolCall(let tc1) = session.transcript.messages[0] {
            #expect(tc1.assets == [
                ACPMessage.ToolCallAsset.image(data: "img-a", mimeType: "image/png")
            ], "after first: \(tc1.assets)")
        }
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-raw-replace", status: "in_progress",
            content: [.content(.text("same"))],
            rawOutput: row.rawOutput)))
        if case .toolCall(let tc2) = session.transcript.messages[0] {
            #expect(tc2.assets == row.expectedAssets, "after second: \(tc2.assets)")
        } else { Issue.record("expected toolCall message") }
    }

    @Test("streamed toolCallUpdate refreshes preview when the first line is empty then filled")
    func toolCallUpdateStreamingEmptyFirstLineThenFilledRefreshesPreview() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.apply(.toolCall(.init(
            toolCallId: "tc-empty-first", title: "run", kind: "execute", status: "in_progress",
            content: nil, locations: nil, rawInput: nil, rawOutput: nil)))
        // First chunk: a leading blank line (first line is empty).
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-empty-first", status: "in_progress",
            content: [.content(.text("\n"))])))
        if case .toolCall(let tc1) = session.transcript.messages[0] {
            #expect(tc1.preview == nil, "preview after first=\(tc1.preview ?? "nil")")
        }
        // Second chunk: the second line fills in. The preview must be
        // recomputed from the now-non-empty second line (which becomes the
        // first non-empty line for `previewLine`).
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-empty-first", status: "completed",
            content: [.content(.text("\nactual first line"))])))
        if case .toolCall(let tc2) = session.transcript.messages[0] {
            #expect(tc2.content == "\nactual first line")
            #expect(tc2.preview == "actual first line", "preview=\(tc2.preview ?? "nil")")
        } else { Issue.record("expected toolCall message") }
    }

    @Test("toolCallUpdate with same text but changed metadata terminal id reprocesses")
    func toolCallUpdateSameTextChangedMetadataTerminalReprocesses() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.apply(.toolCall(.init(
            toolCallId: "tc-meta-term", title: "bash", kind: "execute", status: "in_progress",
            content: nil, locations: nil, rawInput: nil, rawOutput: nil)))
        // First update: text + metadata terminal m1.
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-meta-term", status: "in_progress",
            content: [.content(.text("running"))],
            metadata: AnyCodable([
                "terminal_output_delta": AnyCodable([
                    "terminal_id": AnyCodable("m1"),
                    "data": AnyCodable("out\n")
                ])
            ]))))
        if case .toolCall(let tc1) = session.transcript.messages[0] {
            #expect(tc1.terminalIds == ["m1"], "after first: \(tc1.terminalIds)")
        }
        // Second update: same text + same status, but metadata changed to
        // terminal m2. The identical-text fast path must fall to full
        // reprocess so `tc.terminalIds` is rebuilt from the current metadata
        // (adding m2, keeping m1 via merge — matching legacy semantics).
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-meta-term", status: "in_progress",
            content: [.content(.text("running"))],
            metadata: AnyCodable([
                "terminal_output_delta": AnyCodable([
                    "terminal_id": AnyCodable("m2"),
                    "data": AnyCodable("more\n")
                ])
            ]))))
        if case .toolCall(let tc2) = session.transcript.messages[0] {
            // The metadata's terminal_output_delta was overwritten by
            // mergeMetadata, so the rebuilt terminalIds contains m2 (the
            // current metadata terminal). This matches the legacy
            // full-reprocess semantics.
            #expect(tc2.terminalIds.contains("m2"), "after second: \(tc2.terminalIds)")
        } else { Issue.record("expected toolCall message") }
    }

    @Test("toolCallUpdate suffix path with metadata change falls to full reprocess")
    func toolCallUpdateSuffixPathWithMetadataChangeFallsToFullReprocess() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.apply(.toolCall(.init(
            toolCallId: "tc-suffix-meta", title: "bash", kind: "execute", status: "in_progress",
            content: nil, locations: nil, rawInput: nil, rawOutput: nil)))
        // First update: text + metadata terminal m1.
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-suffix-meta", status: "in_progress",
            content: [.content(.text("run"))],
            metadata: AnyCodable([
                "terminal_output_delta": AnyCodable([
                    "terminal_id": AnyCodable("m1"),
                    "data": AnyCodable("out\n")
                ])
            ]))))
        if case .toolCall(let tc1) = session.transcript.messages[0] {
            #expect(tc1.terminalIds == ["m1"], "after first: \(tc1.terminalIds)")
        }
        // Second update: text grows (suffix path) AND metadata changes to
        // terminal m2. The suffix path must fall to full reprocess so
        // `tc.terminalIds` is rebuilt from the current metadata.
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-suffix-meta", status: "completed",
            content: [.content(.text("running"))],
            metadata: AnyCodable([
                "terminal_output_delta": AnyCodable([
                    "terminal_id": AnyCodable("m2"),
                    "data": AnyCodable("more\n")
                ])
            ]))))
        if case .toolCall(let tc2) = session.transcript.messages[0] {
            #expect(tc2.content == "running")
            #expect(tc2.terminalIds.contains("m2"), "after second: \(tc2.terminalIds)")
        } else { Issue.record("expected toolCall message") }
    }

    @Test("side-channel rawOutput-only update invalidates content cache for next same-content update")
    func toolCallUpdateSideChannelRawOutputInvalidatesCache() async {
        let session = ACPSession(id: "s", agentId: "bridge", worktreeId: "w", title: "t")
        session.apply(.toolCall(.init(
            toolCallId: "tc-side", title: "image", kind: "other", status: "in_progress",
            content: nil, locations: nil, rawInput: nil, rawOutput: nil)))
        // First update: text + rawOutput image A.
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-side", status: "in_progress",
            content: [.content(.text("same"))],
            rawOutput: AnyCodable(["data": AnyCodable("img-a"), "mime_type": AnyCodable("image/png")]))))
        if case .toolCall(let tc1) = session.transcript.messages[0] {
            #expect(tc1.assets == [
                ACPMessage.ToolCallAsset.image(data: "img-a", mimeType: "image/png")
            ], "after first: \(tc1.assets)")
        }
        // Side-channel update: rawOutput changes to image B, no content.
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-side", status: "in_progress",
            rawOutput: AnyCodable(["data": AnyCodable("img-b"), "mime_type": AnyCodable("image/png")]))))
        // Third update: same content "same" as the first, no rawOutput.
        // The cache was invalidated by the side-channel update, so this
        // falls to full reprocess and rebuilds tc.assets from content +
        // the current rawOutput (image B), dropping the stale image A.
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-side", status: "in_progress",
            content: [.content(.text("same"))])))
        if case .toolCall(let tc3) = session.transcript.messages[0] {
            #expect(tc3.content == "same")
            #expect(tc3.assets == [
                ACPMessage.ToolCallAsset.image(data: "img-b", mimeType: "image/png")
            ], "after third: \(tc3.assets)")
        } else { Issue.record("expected toolCall message") }
    }
}

// MARK: - Parameterized cases and helpers

extension ACPSessionTests {
    /// A hydrated transcript row. At most one of each kind is seeded, so
    /// fixed message ids ("user-1", "agent-1", "tool-1") are unambiguous.
    enum SeedMessage: Sendable {
        case user(String)
        case agent(String)
        case plan
        case toolCall
    }

    static func seedMessages(_ seed: [SeedMessage]) -> [ACPMessage] {
        seed.map { message -> ACPMessage in
            switch message {
            case .user(let text):
                return .user(id: UUID(), messageId: "user-1", text: text, attachments: [])
            case .agent(let text):
                return .agent(id: UUID(), messageId: "agent-1", StreamingText(text))
            case .plan:
                return .plan(id: UUID(), [])
            case .toolCall:
                return .toolCall(.init(
                    toolCallId: "tool-1",
                    title: "Run",
                    kind: "execute",
                    status: "completed",
                    content: "done"
                ))
            }
        }
    }

    /// Agent, user, tool-call and file-edit rows in transcript order.
    static func orderedRows(_ session: ACPSession) -> [String] {
        session.transcript.messages.compactMap { message -> String? in
            switch message {
            case .agent(_, _, let text): return "agent:\(text.value)"
            case .user(_, _, let text, _, _): return "user:\(text)"
            case .toolCall: return "toolCall"
            case .fileEdit: return "fileEdit"
            default: return nil
            }
        }
    }

    struct ChunkSeparatorCase: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let first: String
        let second: String
        let expected: String

        static let all: [ChunkSeparatorCase] = [
            .init(testDescription: "a chunk ending in a space merges verbatim",
                  first: "hello ", second: "world", expected: "hello world"),
            .init(testDescription: "a sentence boundary gets a newline",
                  first: "Compacting completed.", second: "Running the pull tests.",
                  expected: "Compacting completed.\nRunning the pull tests."),
            .init(testDescription: "an existing trailing newline is not doubled",
                  first: "line one\n", second: "line two", expected: "line one\nline two"),
            .init(testDescription: "! after a whitespace-preceded lowercase word gets a newline",
                  first: "All done!", second: "Next task", expected: "All done!\nNext task"),
            .init(testDescription: "a CamelCase word before the period gets no separator (protects identifiers)",
                  first: "Foo.", second: "Bar", expected: "Foo.Bar"),
            .init(testDescription: "a single-character punctuation chunk gets no separator and does not trap",
                  first: ".", second: "Next task", expected: ".Next task"),
            .init(testDescription: "a qualified identifier with no preceding whitespace gets no separator",
                  first: "package.", second: "Type", expected: "package.Type"),
            .init(testDescription: "an all-caps acronym after a period gets no separator",
                  first: "See the API docs.", second: "API", expected: "See the API docs.API"),
            .init(testDescription: "a URL tail before the period gets no separator",
                  first: "See https://example.com.", second: "Path", expected: "See https://example.com.Path"),
        ]
    }

    enum HeldCandidateTrigger: Sendable {
        case toolCall
        case userPrompt(String)
        case userChunk(messageId: String, text: String)
        case completedOutputBoundary
        case fileEdit
        case modelUpdate(String)
    }

    struct HeldCandidateCase: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let seed: [SeedMessage]
        let heldMessageId: String
        let heldText: String
        let trigger: HeldCandidateTrigger
        let expected: [String]

        static let all: [HeldCandidateCase] = [
            .init(testDescription: "a tool call materializes the held fragment ahead of itself",
                  seed: [.agent("I'm working on it.")], heldMessageId: "agent-live-2", heldText: "I",
                  trigger: .toolCall,
                  expected: ["agent:I'm working on it.", "agent:I", "toolCall"]),
            .init(testDescription: "the next user prompt materializes the stranded fragment before itself",
                  seed: [.agent("I'm working on it.")], heldMessageId: "agent-live-2", heldText: "I",
                  trigger: .userPrompt("next"),
                  expected: ["agent:I'm working on it.", "agent:I", "user:next"]),
            .init(testDescription: "a genuinely new user chunk flushes the held fragment ahead of the prompt",
                  seed: [.agent("hi there")], heldMessageId: "regen-agent", heldText: "hi",
                  trigger: .userChunk(messageId: "user-new", text: "do the thing"),
                  expected: ["agent:hi there", "agent:hi", "user:do the thing"]),
            .init(testDescription: "the completed output boundary materializes a held final fragment",
                  seed: [.agent("OK done.")], heldMessageId: "regen-1", heldText: "OK",
                  trigger: .completedOutputBoundary,
                  expected: ["agent:OK done.", "agent:OK"]),
            .init(testDescription: "a file edit (which bypasses apply) flushes the held fragment ahead of itself",
                  seed: [.agent("editing files")], heldMessageId: "regen-1", heldText: "editing",
                  trigger: .fileEdit,
                  expected: ["agent:editing files", "agent:editing", "fileEdit"]),
            .init(testDescription: "a state-only model update does not flush the held candidate",
                  seed: [.agent("hello world")], heldMessageId: "regen-1", heldText: "hello",
                  trigger: .modelUpdate("gpt-5.5"),
                  expected: ["agent:hello world"]),
            .init(testDescription: "a replayed user chunk that is dropped does not flush the held candidate",
                  seed: [.user("earlier prompt"), .agent("hello world")], heldMessageId: "regen-agent",
                  heldText: "hello",
                  trigger: .userChunk(messageId: "regen-user", text: "earlier prompt"),
                  expected: ["user:earlier prompt", "agent:hello world"]),
            .init(testDescription: "a candidate that fully reproduces an existing message stays suppressed on flush",
                  seed: [.agent("OK")], heldMessageId: "regen-1", heldText: "OK",
                  trigger: .toolCall,
                  expected: ["agent:OK", "toolCall"]),
        ]
    }

    struct RegeneratedReplayCase: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let seed: [SeedMessage]
        let chunks: [String]
        let expectedAgentTexts: [String]

        static let all: [RegeneratedReplayCase] = [
            .init(testDescription: "a chunked late replay with a short first fragment stays suppressed",
                  seed: [.user("prev prompt"), .agent("The plan is complete.")],
                  chunks: ["The ", "plan is complete."],
                  expectedAgentTexts: ["The plan is complete."]),
            .init(testDescription: "a mid-stream replay fragment that is not a prefix is not duplicated",
                  seed: [.user("prev prompt"), .agent("hello world")],
                  chunks: ["world"],
                  expectedAgentTexts: ["hello world"]),
            .init(testDescription: "a replayed continuation is adopted across a trailing plan row",
                  seed: [.agent("hello"), .plan],
                  chunks: ["hello", " world"],
                  expectedAgentTexts: ["hello world"]),
            .init(testDescription: "a replay split at a sentence boundary the original lacked is still suppressed",
                  seed: [.agent("tests completed.Running")],
                  chunks: ["tests completed.", "Running"],
                  expectedAgentTexts: ["tests completed.Running"]),
            .init(testDescription: "a mid-message slip followed by a real continuation starts its own row",
                  seed: [.agent("hello world")],
                  chunks: ["world", "!"],
                  expectedAgentTexts: ["hello world", "world!"]),
            .init(testDescription: "new output starting with the previous bubble's trailing word is not merged",
                  seed: [.agent("hello world")],
                  chunks: ["world", " again"],
                  expectedAgentTexts: ["hello world", "world again"]),
            .init(testDescription: "a partial suffix match (K of OK) starts its own row",
                  seed: [.agent("OK")],
                  chunks: ["K", "eep going"],
                  expectedAgentTexts: ["OK", "Keep going"]),
            .init(testDescription: "post-prompt output sharing a prefix is not adopted into the prior turn",
                  seed: [.agent("hello"), .user("next")],
                  chunks: ["hello", " there"],
                  expectedAgentTexts: ["hello", "hello there"]),
            .init(testDescription: "post-tool output sharing a prefix is not adopted across the tool call",
                  seed: [.agent("OK"), .toolCall],
                  chunks: ["OK", " done"],
                  expectedAgentTexts: ["OK", "OK done"]),
        ]
    }

    enum ConversationContent: Sendable {
        case empty
        case systemNotice(String)
        case userPrompt(String)
        case agentChunk(String)
    }

    struct ConversationTranscriptCase: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let content: ConversationContent
        let expected: Bool

        static let all: [ConversationTranscriptCase] = [
            .init(testDescription: "empty transcript", content: .empty, expected: false),
            .init(testDescription: "system notice only",
                  content: .systemNotice("Agent disconnected"), expected: false),
            .init(testDescription: "non-empty user prompt", content: .userPrompt("hello"), expected: true),
            .init(testDescription: "whitespace-only user prompt", content: .userPrompt(" \n\t "), expected: false),
            .init(testDescription: "non-empty agent message",
                  content: .agentChunk("hello from agent"), expected: true),
        ]
    }

    struct DiffStatsCase: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let editPath: String
        let diffPath: String
        let diffOldText: String?
        let diffNewText: String
        let diffKind: String?
        let stats: (added: Int, removed: Int)?
        let worktreeRoot: String?
        let expectedAdded: Int
        let expectedRemoved: Int

        static let all: [DiffStatsCase] = [
            .init(testDescription: "a matching diff block's diffStats overwrite the counts",
                  editPath: "x.swift", diffPath: "x.swift", diffOldText: "a\n", diffNewText: "a\nb\n",
                  diffKind: "update", stats: (added: 4, removed: 2), worktreeRoot: nil,
                  expectedAdded: 4, expectedRemoved: 2),
            .init(testDescription: "an absolute diff path matches the worktree-relative edit given the root",
                  editPath: "src/x.swift", diffPath: "/repo/src/x.swift", diffOldText: "a\n", diffNewText: "a\nb\n",
                  diffKind: "update", stats: (added: 4, removed: 2), worktreeRoot: "/repo",
                  expectedAdded: 4, expectedRemoved: 2),
            .init(testDescription: "a diff block without diffStats leaves the heuristic counts",
                  editPath: "x.swift", diffPath: "x.swift", diffOldText: "a\n", diffNewText: "a\nb\n",
                  diffKind: nil, stats: nil, worktreeRoot: nil,
                  expectedAdded: 1, expectedRemoved: 1),
            .init(testDescription: "a same-path diff with different text does not clobber an unrelated earlier edit",
                  editPath: "x.swift", diffPath: "x.swift", diffOldText: "z\n", diffNewText: "z\nq\n",
                  diffKind: "update", stats: (added: 99, removed: 99), worktreeRoot: nil,
                  expectedAdded: 1, expectedRemoved: 1),
        ]
    }

    struct RawOutputAssetCase: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let rawOutput: AnyCodable
        let expectedAssets: [ACPMessage.ToolCallAsset]

        static let shapes: [RawOutputAssetCase] = [
            .init(testDescription: "data[].b64_json",
                  rawOutput: AnyCodable([
                      "created": AnyCodable(1),
                      "data": AnyCodable([
                          AnyCodable([
                              "b64_json": AnyCodable("base64-data"),
                              "revised_prompt": AnyCodable("A useful screenshot")
                          ])
                      ])
                  ]),
                  expectedAssets: [.image(data: "base64-data", mimeType: "image/png")]),
            .init(testDescription: "data[].url with an http URL",
                  rawOutput: AnyCodable([
                      "data": AnyCodable([
                          AnyCodable([
                              "url": AnyCodable("https://example.com/generated"),
                              "revised_prompt": AnyCodable("A useful screenshot")
                          ])
                      ])
                  ]),
                  expectedAssets: [.image(
                      data: nil, uri: "https://example.com/generated", mimeType: nil, name: "generated")]),
            .init(testDescription: "data[].url with a data URI",
                  rawOutput: AnyCodable([
                      "data": AnyCodable([
                          AnyCodable([
                              "url": AnyCodable("data:image/png;base64,base64-data")
                          ])
                      ])
                  ]),
                  expectedAssets: [.image(
                      data: nil, uri: "data:image/png;base64,base64-data", mimeType: "image/png", name: nil)]),
            .init(testDescription: "bare data with mime_type",
                  rawOutput: AnyCodable([
                      "data": AnyCodable("base64-data"),
                      "mime_type": AnyCodable("image/png")
                  ]),
                  expectedAssets: [.image(data: "base64-data", mimeType: "image/png")]),
        ]

        /// Second-update rawOutputs replacing an earlier `img-a` image.
        static let sameTextReplacements: [RawOutputAssetCase] = [
            .init(testDescription: "another image replaces the stale one",
                  rawOutput: AnyCodable(["data": AnyCodable("img-b"), "mime_type": AnyCodable("image/png")]),
                  expectedAssets: [.image(data: "img-b", mimeType: "image/png")]),
            .init(testDescription: "a non-image result drops the stale image",
                  rawOutput: AnyCodable(["text": AnyCodable("done")]),
                  expectedAssets: []),
        ]

        /// Payloads long enough that the stored rawOutput is truncated.
        static let longPayloads: [RawOutputAssetCase] = {
            let dataURI = "data:image/png;base64," + String(repeating: "A", count: 5_000)
            let imageURL = "https://example.com/generated.png?signature=" + String(repeating: "A", count: 5_000)
            let imageData = String(repeating: "A", count: 5_000)
            return [
                .init(testDescription: "long data URI in data[].url",
                      rawOutput: AnyCodable([
                          "data": AnyCodable([
                              AnyCodable([
                                  "url": AnyCodable(dataURI)
                              ])
                          ])
                      ]),
                      expectedAssets: [.image(data: nil, uri: dataURI, mimeType: "image/png", name: nil)]),
                .init(testDescription: "long signed image URL in data[].url",
                      rawOutput: AnyCodable([
                          "data": AnyCodable([
                              AnyCodable([
                                  "url": AnyCodable(imageURL)
                              ])
                          ])
                      ]),
                      expectedAssets: [.image(data: nil, uri: imageURL, mimeType: nil, name: "generated.png")]),
                .init(testDescription: "long bare data with mime_type",
                      rawOutput: AnyCodable([
                          "data": AnyCodable(imageData),
                          "mime_type": AnyCodable("image/png")
                      ]),
                      expectedAssets: [.image(data: imageData, mimeType: "image/png")]),
            ]
        }()
    }

    enum TerminalReplayFrame: String, CaseIterable, Sendable {
        case completedUpdate
        case completedPayload
        case inProgressPayload
    }

    enum ExitOnlyReplayFrame: String, CaseIterable, Sendable {
        case payload
        case update
    }

    /// `nil` expectations are not asserted for that row.
    struct StreamedFenceCase: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let partial: String
        let completed: String
        let expectedContent: String
        let expectedLanguage: String?
        let expectedPreview: String?

        static let all: [StreamedFenceCase] = [
            .init(testDescription: "a partial `` opening then a complete fence strips the wrapper",
                  partial: "``", completed: "```swift\nlet x = 1\n```",
                  expectedContent: "let x = 1", expectedLanguage: "swift", expectedPreview: "let x = 1"),
            .init(testDescription: "a trailing ``` line with no opening fence is kept",
                  partial: "log line\n```", completed: "log line\n```\nmore output",
                  expectedContent: "log line\n```\nmore output", expectedLanguage: nil, expectedPreview: "log line"),
            .init(testDescription: "``` completing to the invalid tag {.swift} stays in the body",
                  partial: "```", completed: "```{.swift}\nlet x = 1\n```",
                  expectedContent: "```{.swift}\nlet x = 1\n```", expectedLanguage: nil, expectedPreview: nil),
            .init(testDescription: "``` growing to the invalid tag { before a newline stays in the body",
                  partial: "```", completed: "```{\nbody",
                  expectedContent: "```{\nbody", expectedLanguage: nil, expectedPreview: nil),
            .init(testDescription: "inline code starting with a backtick is not treated as a partial fence",
                  partial: "`cmd` ran", completed: "`cmd` ran successfully",
                  expectedContent: "`cmd` ran successfully", expectedLanguage: nil,
                  expectedPreview: "`cmd` ran successfully"),
        ]
    }
}
