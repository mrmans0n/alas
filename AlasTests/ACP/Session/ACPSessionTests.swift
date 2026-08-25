import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACPSession")
struct ACPSessionTests {
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

    @Test("agent message chunks append to a single agent message")
    func chunksMerge() async {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        session.apply(.agentMessageChunk(.text("hello ")))
        session.apply(.agentMessageChunk(.text("world")))
        #expect(session.transcript.messages.count == 1)
        if case .agent(_, _, let buf) = session.transcript.messages[0] { #expect(buf.value == "hello world") }
        else { Issue.record("expected single agent message") }
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

    @Test("agent chunks split at a sentence boundary get a newline separator")
    func chunksSplitAtSentenceGetNewline() async {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        session.apply(.agentMessageChunk(.text("Compacting completed.")))
        session.apply(.agentMessageChunk(.text("Running the pull tests.")))
        #expect(session.transcript.messages.count == 1)
        if case .agent(_, _, let buf) = session.transcript.messages[0] {
            #expect(buf.value == "Compacting completed.\nRunning the pull tests.")
        } else { Issue.record("expected single agent message") }
    }

    @Test("agent chunks already separated by whitespace are not double-spaced")
    func chunksWithExistingWhitespaceNoExtraSeparator() async {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        session.apply(.agentMessageChunk(.text("line one\n")))
        session.apply(.agentMessageChunk(.text("line two")))
        if case .agent(_, _, let buf) = session.transcript.messages[0] {
            #expect(buf.value == "line one\nline two")
        } else { Issue.record("expected single agent message") }
    }

    @Test("agent chunks with ! or ? boundary also get a newline separator")
    func chunksSplitAtPunctuationGetNewline() async {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        // Lowercase word before `!` with preceding whitespace → separator.
        session.apply(.agentMessageChunk(.text("All done!")))
        session.apply(.agentMessageChunk(.text("Next task")))
        if case .agent(_, _, let buf) = session.transcript.messages[0] {
            #expect(buf.value == "All done!\nNext task")
        } else { Issue.record("expected single agent message") }
    }

    @Test("agent chunks with capitalized word before punctuation do not get a newline")
    func chunksWithCapitalizedWordNoSeparator() async {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        // `Foo` is CamelCase → no separator (protects identifiers).
        session.apply(.agentMessageChunk(.text("Foo.")))
        session.apply(.agentMessageChunk(.text("Bar")))
        if case .agent(_, _, let buf) = session.transcript.messages[0] {
            #expect(buf.value == "Foo.Bar")
        } else { Issue.record("expected single agent message") }
    }

    @Test("single-character punctuation chunk does not crash and adds no separator")
    func chunksWithSingleCharPunctuationNoCrash() async {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        // A chunk that is just "." followed by "Next" must not trap when
        // walking back past the punctuation and must not inject a newline.
        session.apply(.agentMessageChunk(.text(".")))
        session.apply(.agentMessageChunk(.text("Next task")))
        if case .agent(_, _, let buf) = session.transcript.messages[0] {
            #expect(buf.value == ".Next task")
        } else { Issue.record("expected single agent message") }
    }

    @Test("qualified identifier with lowercase left segment gets no separator")
    func chunksWithQualifiedIdentifierNoSeparator() async {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        // `package.` + `Type` — lowercase word but no preceding whitespace
        // (qualified identifier at chunk start) → no separator.
        session.apply(.agentMessageChunk(.text("package.")))
        session.apply(.agentMessageChunk(.text("Type")))
        if case .agent(_, _, let buf) = session.transcript.messages[0] {
            #expect(buf.value == "package.Type")
        } else { Issue.record("expected single agent message") }
    }

    @Test("agent chunks with all-caps acronym after period do not get a newline")
    func chunksWithAcronymNoSeparator() async {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        session.apply(.agentMessageChunk(.text("See the API docs.")))
        session.apply(.agentMessageChunk(.text("API")))
        // "API" — first char 'A' (upper), second char 'P' (upper, not [a-z]) → no separator
        if case .agent(_, _, let buf) = session.transcript.messages[0] {
            #expect(buf.value == "See the API docs.API")
        } else { Issue.record("expected single agent message") }
    }

    @Test("agent chunks split at a URL tail do not get a newline")
    func chunksSplitAtURLNoSeparator() async {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        session.apply(.agentMessageChunk(.text("See https://example.com.")))
        session.apply(.agentMessageChunk(.text("Path")))
        // `com.` is preceded by `/` (URL tail) → no separator.
        if case .agent(_, _, let buf) = session.transcript.messages[0] {
            #expect(buf.value == "See https://example.com.Path")
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

    @Test("agent chunks after a completed output boundary start a new message")
    func completedOutputBoundaryStartsNewMessage() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.apply(.agentMessageChunk(.text("first task output")))
        session.markCompletedOutputBoundary()
        session.apply(.agentMessageChunk(.text("next task output")))

        #expect(session.transcript.messages.count == 2)
        if case .agent(_, _, let first) = session.transcript.messages[0],
           case .agent(_, _, let second) = session.transcript.messages[1] {
            #expect(first.value == "first task output")
            #expect(second.value == "next task output")
        } else {
            Issue.record("expected two agent messages")
        }
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

    @Test("late replay chunk with messageId does not mutate hydrated output")
    func lateReplayMessageIdChunkDoesNotMutateHydratedOutput() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.transcript.messages = [
            .agent(id: UUID(), messageId: "agent-1", StreamingText("earlier answer")),
            .user(id: UUID(), messageId: "user-1", text: "next prompt", attachments: [])
        ]
        session.allowsStreamingBoundaryCrossing = false

        let changed = session.apply(.agentMessageChunk(.init(messageId: "agent-1", content: .text(" replay"))))

        #expect(changed == [0])
        #expect(session.transcript.messages.count == 2)
        if case .agent(_, _, let text) = session.transcript.messages[0] {
            #expect(text.value == "earlier answer")
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

    @Test("a held short fragment is materialized when a tool call closes the message")
    func heldFragmentMaterializedOnToolCall() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.transcript.messages = [
            .agent(id: UUID(), messageId: "agent-1", StreamingText("I'm working on it."))
        ]
        session.allowsStreamingBoundaryCrossing = false

        // A new live message whose only chunk "I" is a substring of prior
        // output is held as a replay candidate. A tool call then closes the
        // message with no further text chunk — the held "I" must be
        // materialized (ahead of the tool call), not stranded and dropped.
        session.apply(.agentMessageChunk(.init(messageId: "agent-live-2", content: .text("I"))))
        session.apply(.toolCall(.init(
            toolCallId: "tool-1", title: "Run", kind: "execute", status: "completed",
            content: nil, locations: nil, rawInput: nil, rawOutput: nil)))

        let agentTexts = session.transcript.messages.compactMap { message -> String? in
            if case .agent(_, _, let text) = message { return text.value }
            return nil
        }
        #expect(agentTexts == ["I'm working on it.", "I"])
        if case .toolCall = session.transcript.messages.last {} else {
            Issue.record("expected the tool call to follow the materialized fragment")
        }
    }

    @Test("a held short fragment is materialized before the next user prompt")
    func heldFragmentMaterializedBeforeNextPrompt() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.transcript.messages = [
            .agent(id: UUID(), messageId: "agent-1", StreamingText("I'm working on it."))
        ]
        session.allowsStreamingBoundaryCrossing = false

        // The held fragment "I" is stranded when the turn ends with no further
        // text chunk; the next prompt must materialize it (keeping its place
        // before the user message) rather than drop it.
        session.apply(.agentMessageChunk(.init(messageId: "agent-live-2", content: .text("I"))))
        session.recordUserPrompt(text: "next", attachments: [])

        let texts: [String] = session.transcript.messages.compactMap { message in
            switch message {
            case .agent(_, _, let t): return "agent:\(t.value)"
            case .user(_, _, let t, _, _): return "user:\(t)"
            default: return nil
            }
        }
        #expect(texts == ["agent:I'm working on it.", "agent:I", "user:next"])
    }

    @Test("a state-only update does not flush a held replay candidate into a duplicate row")
    func stateOnlyUpdateDoesNotFlushHeldCandidate() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.transcript.messages = [
            .agent(id: UUID(), messageId: "agent-1", StreamingText("hello world"))
        ]
        session.allowsStreamingBoundaryCrossing = false

        // A late replay chunk "hello" is buffered (substring of prior output).
        // A state-only update (model change) appends no row and does not close
        // the text, so it must not materialize the held chunk as a duplicate.
        session.apply(.agentMessageChunk(.init(messageId: "regen-1", content: .text("hello"))))
        session.apply(.currentModelUpdate(modelId: "gpt-5.5"))

        let agentTexts = session.transcript.messages.compactMap { message -> String? in
            if case .agent(_, _, let text) = message { return text.value }
            return nil
        }
        #expect(agentTexts == ["hello world"])
    }

    @Test("a replayed user chunk does not flush a held agent replay candidate")
    func replayedUserChunkDoesNotFlushHeldCandidate() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.transcript.messages = [
            .user(id: UUID(), messageId: "user-1", text: "earlier prompt", attachments: []),
            .agent(id: UUID(), messageId: "agent-1", StreamingText("hello world"))
        ]
        session.allowsStreamingBoundaryCrossing = false

        // Held agent replay chunk "hello", then a replayed user prompt that
        // appendUserChunk drops (its text already exists). The held chunk must
        // not be flushed into a duplicate agent row by that dropped prompt.
        session.apply(.agentMessageChunk(.init(messageId: "regen-agent", content: .text("hello"))))
        session.apply(.userMessageChunk(.init(messageId: "regen-user", content: .text("earlier prompt"))))

        let agentTexts = session.transcript.messages.compactMap { message -> String? in
            if case .agent(_, _, let text) = message { return text.value }
            return nil
        }
        #expect(agentTexts == ["hello world"])
    }

    @Test("a real user chunk flushes a held agent replay candidate ahead of the prompt")
    func realUserChunkFlushesHeldCandidate() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.transcript.messages = [
            .agent(id: UUID(), messageId: "agent-1", StreamingText("hi there"))
        ]
        session.allowsStreamingBoundaryCrossing = false

        // Held agent chunk "hi", then a genuinely new user prompt. The held
        // chunk must materialize in order, ahead of the prompt.
        session.apply(.agentMessageChunk(.init(messageId: "regen-agent", content: .text("hi"))))
        session.apply(.userMessageChunk(.init(messageId: "user-new", content: .text("do the thing"))))

        let texts: [String] = session.transcript.messages.compactMap { message in
            switch message {
            case .agent(_, _, let t): return "agent:\(t.value)"
            case .user(_, _, let t, _, _): return "user:\(t)"
            default: return nil
            }
        }
        #expect(texts == ["agent:hi there", "agent:hi", "user:do the thing"])
    }

    @Test("a held final fragment is materialized when the output boundary completes")
    func heldFragmentMaterializedOnCompletedOutputBoundary() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.transcript.messages = [
            .agent(id: UUID(), messageId: "agent-1", StreamingText("OK done."))
        ]
        session.allowsStreamingBoundaryCrossing = false

        // A one-chunk reply "OK" whose text is a substring of prior output is
        // held. Turn completion reaches markCompletedOutputBoundary() without
        // an update, so it must materialize the held chunk rather than leave
        // it stranded (and lost on detach/reopen).
        session.apply(.agentMessageChunk(.init(messageId: "regen-1", content: .text("OK"))))
        session.markCompletedOutputBoundary()

        let agentTexts = session.transcript.messages.compactMap { message -> String? in
            if case .agent(_, _, let text) = message { return text.value }
            return nil
        }
        #expect(agentTexts == ["OK done.", "OK"])
    }

    @Test("a full-replay candidate is kept suppressed on flush, not materialized as a duplicate")
    func fullReplayCandidateKeptSuppressedOnFlush() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.transcript.messages = [
            .agent(id: UUID(), messageId: "agent-1", StreamingText("OK"))
        ]
        session.allowsStreamingBoundaryCrossing = false

        // A late replay delivers the complete "OK" under a regenerated id, so
        // it is held (it matches the existing message exactly). A tool call
        // then triggers a flush — but a candidate that fully reproduces an
        // existing message never diverged and must stay suppressed.
        session.apply(.agentMessageChunk(.init(messageId: "regen-1", content: .text("OK"))))
        session.apply(.toolCall(.init(
            toolCallId: "tool-1", title: "Run", kind: "execute", status: "completed",
            content: nil, locations: nil, rawInput: nil, rawOutput: nil)))

        let agentTexts = session.transcript.messages.compactMap { message -> String? in
            if case .agent(_, _, let text) = message { return text.value }
            return nil
        }
        #expect(agentTexts == ["OK"])
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

    @Test("a held fragment is flushed before an appended file edit, preserving order")
    func heldFragmentFlushedBeforeFileEdit() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.transcript.messages = [
            .agent(id: UUID(), messageId: "agent-1", StreamingText("editing files"))
        ]
        session.allowsStreamingBoundaryCrossing = false

        // A held fragment "editing" (substring), then a file edit. The file
        // edit path does not flow through apply(), so it must flush the held
        // text ahead of the edit rather than leave it after.
        session.apply(.agentMessageChunk(.init(messageId: "regen-1", content: .text("editing"))))
        session.appendFileEdit(.init(
            path: "x.swift", added: 1, removed: 0, oldText: "a\n", newText: "a\nb\n"))

        let ordered: [String] = session.transcript.messages.compactMap { message in
            switch message {
            case .agent(_, _, let t): return "agent:\(t.value)"
            case .fileEdit: return "fileEdit"
            default: return nil
            }
        }
        #expect(ordered == ["agent:editing files", "agent:editing", "fileEdit"])
    }

    @Test("chunked late replay with a regenerated messageId and short first fragment is not duplicated")
    func chunkedLateReplayShortFirstFragmentNotDuplicated() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.transcript.messages = [
            .user(id: UUID(), messageId: "user-1", text: "prev prompt", attachments: []),
            .agent(id: UUID(), messageId: "agent-1", StreamingText("The plan is complete."))
        ]
        session.allowsStreamingBoundaryCrossing = false

        // A late replay of the trailing hydrated message arrives under a
        // regenerated id, split into chunks whose first fragment is short.
        // It must stay suppressed for its whole length and never duplicate.
        session.apply(.agentMessageChunk(.init(messageId: "regen-1", content: .text("The "))))
        session.apply(.agentMessageChunk(.init(messageId: "regen-1", content: .text("plan is complete."))))

        let agentTexts = session.transcript.messages.compactMap { message -> String? in
            if case .agent(_, _, let text) = message { return text.value }
            return nil
        }
        #expect(agentTexts == ["The plan is complete."])
    }

    @Test("mid-stream late replay fragment with a regenerated messageId is not duplicated")
    func midStreamLateReplayFragmentNotDuplicated() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.transcript.messages = [
            .user(id: UUID(), messageId: "user-1", text: "prev prompt", attachments: []),
            .agent(id: UUID(), messageId: "agent-1", StreamingText("hello world"))
        ]
        session.allowsStreamingBoundaryCrossing = false

        // The "hello " prefix was consumed while replay suppression was
        // still active; the slip that reaches appendStreaming is a middle
        // fragment of the trailing hydrated message. It must not be appended
        // as a duplicate even though it is not a prefix of that message.
        session.apply(.agentMessageChunk(.init(messageId: "regen-1", content: .text("world"))))

        let agentTexts = session.transcript.messages.compactMap { message -> String? in
            if case .agent(_, _, let text) = message { return text.value }
            return nil
        }
        #expect(agentTexts == ["hello world"])
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

    @Test("replay continuation is still adopted across a trailing plan row")
    func replayContinuationAdoptedAcrossTrailingPlan() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.transcript.messages = [
            .agent(id: UUID(), messageId: "agent-1", StreamingText("hello")),
            .plan(id: UUID(), [])
        ]
        session.allowsStreamingBoundaryCrossing = false

        // A trailing plan does not close the agent output (like lastAgent()
        // and markCompletedOutputBoundary(), which skip plans), so the
        // replayed continuation must still merge into "hello", not duplicate.
        session.apply(.agentMessageChunk(.init(messageId: "regen-1", content: .text("hello"))))
        session.apply(.agentMessageChunk(.init(messageId: "regen-1", content: .text(" world"))))

        let agentTexts = session.transcript.messages.compactMap { message -> String? in
            if case .agent(_, _, let text) = message { return text.value }
            return nil
        }
        #expect(agentTexts == ["hello world"])
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

    @Test("replay split at a sentence boundary the original did not is still suppressed despite the separator")
    func replaySplitAtSentenceBoundaryStillSuppressed() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        // Hydrated as one chunk, so it carries no injected separator.
        session.transcript.messages = [
            .agent(id: UUID(), messageId: "agent-1", StreamingText("tests completed.Running"))
        ]
        session.allowsStreamingBoundaryCrossing = false

        // The replay splits at the sentence boundary, so streamingSeparator
        // would inject a newline. Matching on the raw concatenation as well
        // keeps this recognised as a replay instead of a duplicate.
        session.apply(.agentMessageChunk(.init(messageId: "regen-1", content: .text("tests completed."))))
        session.apply(.agentMessageChunk(.init(messageId: "regen-1", content: .text("Running"))))

        let agentTexts = session.transcript.messages.compactMap { message -> String? in
            if case .agent(_, _, let text) = message { return text.value }
            return nil
        }
        #expect(agentTexts == ["tests completed.Running"])
    }

    @Test("mid-message replay slip followed by real continuation starts its own row, not a merge")
    func midMessageReplaySlipThenContinuationStartsNewRow() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.transcript.messages = [
            .agent(id: UUID(), messageId: "agent-1", StreamingText("hello world"))
        ]
        session.allowsStreamingBoundaryCrossing = false

        // The surviving replay chunk is the middle fragment "world", which
        // then continues with "!". Only a whole-bubble prefix is adopted, so
        // a partial (suffix) match is NOT merged — it starts its own row.
        // This is the accepted trade-off (a rare duplicate) for never merging
        // a genuinely separate message into an existing bubble; a suffix like
        // "world" is indistinguishable from new output starting with that
        // word (see postPromptLiveOutputSharingTrailingWordNotAdopted).
        session.apply(.agentMessageChunk(.init(messageId: "regen-1", content: .text("world"))))
        session.apply(.agentMessageChunk(.init(messageId: "regen-1", content: .text("!"))))

        let agentTexts = session.transcript.messages.compactMap { message -> String? in
            if case .agent(_, _, let text) = message { return text.value }
            return nil
        }
        #expect(agentTexts == ["hello world", "world!"])
    }

    @Test("post-prompt output sharing only the trailing word of the previous bubble is not merged")
    func postPromptLiveOutputSharingTrailingWordNotAdopted() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.transcript.messages = [
            .agent(id: UUID(), messageId: "agent-1", StreamingText("hello world"))
        ]
        session.allowsStreamingBoundaryCrossing = false

        // A genuinely separate message that starts with the previous bubble's
        // last word ("world") then diverges. It must be its own row, never
        // merged into "hello world" as "hello world again".
        session.apply(.agentMessageChunk(.init(messageId: "regen-1", content: .text("world"))))
        session.apply(.agentMessageChunk(.init(messageId: "regen-1", content: .text(" again"))))

        let agentTexts = session.transcript.messages.compactMap { message -> String? in
            if case .agent(_, _, let text) = message { return text.value }
            return nil
        }
        #expect(agentTexts == ["hello world", "world again"])
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

    @Test("a partial (non-whole-bubble) suffix match starts its own row rather than merging")
    func partialSuffixMatchStartsNewRow() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.transcript.messages = [
            .agent(id: UUID(), messageId: "agent-1", StreamingText("OK"))
        ]
        session.allowsStreamingBoundaryCrossing = false

        // A genuinely new message "Keep going" whose first held fragment "K"
        // coincides with the tail of "OK". Only a whole-bubble prefix is
        // adopted, so this partial match is not merged into "OK" as
        // "OKeep going" — it starts its own row.
        session.apply(.agentMessageChunk(.init(messageId: "regen-1", content: .text("K"))))
        session.apply(.agentMessageChunk(.init(messageId: "regen-1", content: .text("eep going"))))

        let agentTexts = session.transcript.messages.compactMap { message -> String? in
            if case .agent(_, _, let text) = message { return text.value }
            return nil
        }
        #expect(agentTexts == ["OK", "Keep going"])
    }

    @Test("post-prompt live output sharing a prefix with a prior turn is not adopted into the old bubble")
    func postPromptLiveOutputNotAdoptedIntoPriorTurn() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.transcript.messages = [
            .agent(id: UUID(), messageId: "agent-1", StreamingText("hello")),
            .user(id: UUID(), messageId: "user-1", text: "next", attachments: [])
        ]
        session.allowsStreamingBoundaryCrossing = false

        // Genuinely new output for the "next" turn that happens to start
        // with the same word as the prior turn's "hello" bubble. It must
        // become its own message, not mutate the earlier (pre-user) bubble.
        session.apply(.agentMessageChunk(.init(messageId: "regen-1", content: .text("hello"))))
        session.apply(.agentMessageChunk(.init(messageId: "regen-1", content: .text(" there"))))

        let agentTexts = session.transcript.messages.compactMap { message -> String? in
            if case .agent(_, _, let text) = message { return text.value }
            return nil
        }
        #expect(agentTexts == ["hello", "hello there"])
    }

    @Test("post-tool live output sharing a prefix with a pre-tool bubble is not adopted across the tool call")
    func postToolLiveOutputNotAdoptedAcrossToolCall() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.transcript.messages = [
            .agent(id: UUID(), messageId: "agent-1", StreamingText("OK")),
            .toolCall(.init(
                toolCallId: "tool-1",
                title: "Run",
                kind: "execute",
                status: "completed",
                content: "done"
            ))
        ]
        session.allowsStreamingBoundaryCrossing = false

        // Fresh post-tool output that happens to start with the pre-tool
        // bubble's full text. It must become its own message after the tool
        // call, not append to the already-closed pre-tool bubble.
        session.apply(.agentMessageChunk(.init(messageId: "regen-1", content: .text("OK"))))
        session.apply(.agentMessageChunk(.init(messageId: "regen-1", content: .text(" done"))))

        let agentTexts = session.transcript.messages.compactMap { message -> String? in
            if case .agent(_, _, let text) = message { return text.value }
            return nil
        }
        #expect(agentTexts == ["OK", "OK done"])
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

    @Test("user prompt creates a user message")
    func userPrompt() async {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        session.recordUserPrompt(text: "hi", attachments: [])
        #expect(session.transcript.messages.count == 1)
        if case .user(_, _, let text, _, _) = session.transcript.messages[0] { #expect(text == "hi") }
        else { Issue.record("expected user message") }
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
        #expect(session.titleSource == .generated)
        if case .user(_, _, let text, _, _) = session.transcript.messages.first {
            #expect(text == prompt)
        } else {
            Issue.record("expected the original prompt in the transcript")
        }
    }

    @Test("transcript tail following is runtime state")
    func transcriptTailFollowingDefaultsToEnabled() async {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        #expect(session.followsTranscriptTail)

        session.followsTranscriptTail = false
        session.apply(.agentMessageChunk(.text("background update")))

        #expect(!session.followsTranscriptTail)
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

    @Test("empty transcript has no conversation transcript")
    func emptyTranscriptHasNoConversationTranscript() async {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")

        #expect(!session.hasConversationTranscript)
    }

    @Test("system notice alone has no conversation transcript")
    func systemNoticeHasNoConversationTranscript() async {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        session.appendSystemNotice("Agent disconnected")

        #expect(!session.hasConversationTranscript)
    }

    @Test("non-empty user message has conversation transcript")
    func userMessageHasConversationTranscript() async {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        session.recordUserPrompt(text: "hello", attachments: [])

        #expect(session.hasConversationTranscript)
    }

    @Test("whitespace-only user message has no conversation transcript")
    func whitespaceUserMessageHasNoConversationTranscript() async {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        session.recordUserPrompt(text: " \n\t ", attachments: [])

        #expect(!session.hasConversationTranscript)
    }

    @Test("non-empty agent message has conversation transcript")
    func agentMessageHasConversationTranscript() async {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        session.apply(.agentMessageChunk(.text("hello from agent")))

        #expect(session.hasConversationTranscript)
    }

    @Test("context restore warning can be set and compared")
    func contextRestoreWarningState() async {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        let warning = ACPSession.ContextRestoreWarning(
            message: "Context restore failed",
            canSendTranscript: true
        )

        session.contextRestoreWarning = warning

        #expect(session.contextRestoreWarning == warning)
        #expect(warning == ACPSession.ContextRestoreWarning(
            message: "Context restore failed",
            canSendTranscript: true
        ))
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

    @Test("availableModelsUpdate populates publishers")
    func models() async {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        session.apply(.availableModelsUpdate([.init(id: "x", name: "X")]))
        #expect(session.availableModels.count == 1)
    }

    @Test("currentModelUpdate updates currentModel")
    func currentModelUpdates() async {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        session.apply(.availableModelsUpdate([
            ACPModelInfo(id: "opus", name: "Opus"),
            ACPModelInfo(id: "sonnet", name: "Sonnet")]))
        session.apply(.currentModelUpdate(modelId: "sonnet"))
        #expect(session.currentModel == "sonnet")
    }

    @Test("sessionConfigOptionsUpdate replaces availableConfigOptions")
    func configOptionsUpdate() async {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        let opt = ACPConfigOption(id: "effort", name: "Effort", type: "select",
                                  category: nil, currentValue: "high",
                                  options: [ACPConfigOptionItem(id: "high", name: "High")])
        session.apply(.sessionConfigOptionsUpdate([opt]))
        #expect(session.availableConfigOptions.count == 1)
        #expect(session.availableConfigOptions[0].currentValue == .string("high"))
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
        #expect(session.titleSource == .generated)
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

    @Test("chipState reflects current ACPSession fields")
    func chipStateRecomputed() async {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        session.availableModels = [ACPModelInfo(id: "opus", name: "Opus")]
        session.currentModel = "opus"
        session.availableModes = [ACPModeInfo(id: "plan", name: "Plan")]
        session.currentMode = "plan"
        session.availableConfigOptions = [
            ACPConfigOption(id: "effort", name: "Effort", type: "select",
                            category: nil, currentValue: "low",
                            options: [ACPConfigOptionItem(id: "low", name: "Low")])
        ]
        let state = session.chipState
        #expect(state.mode?.currentId == "plan")
        #expect(state.thinking?.currentId == "low")
    }

    @Test("chipState for pi hides Mode and routes modes to Thinking")
    func chipStatePi() async {
        let session = ACPSession(id: "s", agentId: "pi", worktreeId: "w", title: "t")
        session.availableModels = [ACPModelInfo(id: "pi", name: "Pi")]
        session.currentModel = "pi"
        session.availableModes = [ACPModeInfo(id: "high", name: "High")]
        session.currentMode = "high"
        let state = session.chipState
        #expect(state.mode == nil)
        #expect(state.thinking?.currentId == "high")
        #expect(state.autoRun == .ignored)
    }

    @Test("tool_call_update with wrapped text content populates tc.content")
    func toolCallUpdateContent() async {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        // Initial tool_call with empty content
        session.apply(.toolCall(.init(
            toolCallId: "tc-1", title: "read", kind: "read", status: "in_progress",
            content: nil, locations: nil, rawInput: nil, rawOutput: nil)))
        // Streaming update carries the real output
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-1", status: "completed",
            content: [.content(.text("file contents\nline two"))],
            rawOutput: nil)))
        #expect(session.transcript.messages.count == 1)
        if case .toolCall(let tc) = session.transcript.messages[0] {
            #expect(tc.content == "file contents\nline two")
            #expect(tc.preview == "file contents")
            #expect(tc.status == "completed")
        } else { Issue.record("expected toolCall message") }
    }

    @Test("initial toolCall preserves raw input metadata")
    func toolCallPreservesRawInput() async {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        session.apply(.toolCall(.init(
            toolCallId: "tc-meta",
            title: "bash",
            kind: "execute",
            status: "in_progress",
            content: nil,
            locations: nil,
            rawInput: AnyCodable([
                "command": AnyCodable("swift test"),
                "timeout": AnyCodable(120)
            ]),
            rawOutput: nil)))

        if case .toolCall(let tc) = session.transcript.messages[0] {
            #expect(tc.rawInput?.contains(#""command":"swift test""#) == true)
            #expect(tc.rawInput?.contains(#""timeout":120"#) == true)
        } else {
            Issue.record("expected toolCall message")
        }
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

    @Test("raw output image result is preserved as an asset")
    func rawOutputImageResultPreservesAsset() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")

        session.apply(.toolCall(.init(
            toolCallId: "tc-raw-image",
            title: "Image generation",
            kind: "other",
            status: "completed",
            content: nil,
            locations: nil,
            rawInput: nil,
            rawOutput: AnyCodable([
                "created": AnyCodable(1),
                "data": AnyCodable([
                    AnyCodable([
                        "b64_json": AnyCodable("base64-data"),
                        "revised_prompt": AnyCodable("A useful screenshot")
                    ])
                ])
            ]))))

        if case .toolCall(let tc) = session.transcript.messages[0] {
            #expect(tc.rawOutput?.contains(#""b64_json":"base64-data""#) == true)
            #expect(tc.assets == [
                ACPMessage.ToolCallAsset.image(data: "base64-data", mimeType: "image/png")
            ])
        } else {
            Issue.record("expected toolCall message")
        }
    }

    @Test("raw output image URL result is preserved as an asset")
    func rawOutputImageURLResultPreservesAsset() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")

        session.apply(.toolCall(.init(
            toolCallId: "tc-raw-image-url",
            title: "Image generation",
            kind: "other",
            status: "completed",
            content: nil,
            locations: nil,
            rawInput: nil,
            rawOutput: AnyCodable([
                "data": AnyCodable([
                    AnyCodable([
                        "url": AnyCodable("https://example.com/generated"),
                        "revised_prompt": AnyCodable("A useful screenshot")
                    ])
                ])
            ]))))

        if case .toolCall(let tc) = session.transcript.messages[0] {
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

    @Test("raw output data URI URL result is preserved as an asset")
    func rawOutputDataURIURLResultPreservesAsset() async {
        let session = ACPSession(id: "s", agentId: "bridge", worktreeId: "w", title: "t")

        session.apply(.toolCall(.init(
            toolCallId: "tc-raw-data-uri-url",
            title: "Image generation",
            kind: "other",
            status: "completed",
            content: nil,
            locations: nil,
            rawInput: nil,
            rawOutput: AnyCodable([
                "data": AnyCodable([
                    AnyCodable([
                        "url": AnyCodable("data:image/png;base64,base64-data")
                    ])
                ])
            ]))))

        if case .toolCall(let tc) = session.transcript.messages[0] {
            #expect(tc.assets == [
                ACPMessage.ToolCallAsset.image(
                    data: nil,
                    uri: "data:image/png;base64,base64-data",
                    mimeType: "image/png",
                    name: nil)
            ])
        } else {
            Issue.record("expected toolCall message")
        }
    }

    @Test("raw output bare image data result is preserved as an asset")
    func rawOutputBareImageDataResultPreservesAsset() async {
        let session = ACPSession(id: "s", agentId: "bridge", worktreeId: "w", title: "t")

        session.apply(.toolCall(.init(
            toolCallId: "tc-raw-image-data",
            title: "Image generation",
            kind: "other",
            status: "completed",
            content: nil,
            locations: nil,
            rawInput: nil,
            rawOutput: AnyCodable([
                "data": AnyCodable("base64-data"),
                "mime_type": AnyCodable("image/png")
            ]))))

        if case .toolCall(let tc) = session.transcript.messages[0] {
            #expect(tc.assets == [
                ACPMessage.ToolCallAsset.image(data: "base64-data", mimeType: "image/png")
            ])
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

    @Test("raw output data URI asset survives later content update")
    func rawOutputDataURIAssetSurvivesLaterContentUpdate() async {
        let session = ACPSession(id: "s", agentId: "bridge", worktreeId: "w", title: "t")
        let dataURI = "data:image/png;base64," + String(repeating: "A", count: 5_000)

        session.apply(.toolCall(.init(
            toolCallId: "tc-raw-data-uri-update",
            title: "Image generation",
            kind: "other",
            status: "in_progress",
            content: nil,
            locations: nil,
            rawInput: nil,
            rawOutput: AnyCodable([
                "data": AnyCodable([
                    AnyCodable([
                        "url": AnyCodable(dataURI)
                    ])
                ])
            ]))))
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-raw-data-uri-update",
            status: "completed",
            content: [.content(.text("final output"))],
            rawOutput: nil)))

        if case .toolCall(let tc) = session.transcript.messages[0] {
            #expect(tc.content == "final output")
            #expect(tc.rawOutput?.contains("[truncated]") == true)
            #expect(tc.assets == [
                ACPMessage.ToolCallAsset.image(
                    data: nil,
                    uri: dataURI,
                    mimeType: "image/png",
                    name: nil)
            ])
        } else {
            Issue.record("expected toolCall message")
        }
    }

    @Test("raw output long image URL asset survives later content update")
    func rawOutputLongImageURLAssetSurvivesLaterContentUpdate() async {
        let session = ACPSession(id: "s", agentId: "bridge", worktreeId: "w", title: "t")
        let imageURL = "https://example.com/generated.png?signature=" + String(repeating: "A", count: 5_000)

        session.apply(.toolCall(.init(
            toolCallId: "tc-raw-long-url-update",
            title: "Image generation",
            kind: "other",
            status: "in_progress",
            content: nil,
            locations: nil,
            rawInput: nil,
            rawOutput: AnyCodable([
                "data": AnyCodable([
                    AnyCodable([
                        "url": AnyCodable(imageURL)
                    ])
                ])
            ]))))
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-raw-long-url-update",
            status: "completed",
            content: [.content(.text("final output"))],
            rawOutput: nil)))

        if case .toolCall(let tc) = session.transcript.messages[0] {
            #expect(tc.content == "final output")
            #expect(tc.rawOutput?.contains("[truncated]") == true)
            #expect(tc.assets == [
                ACPMessage.ToolCallAsset.image(
                    data: nil,
                    uri: imageURL,
                    mimeType: nil,
                    name: "generated.png")
            ])
        } else {
            Issue.record("expected toolCall message")
        }
    }

    @Test("raw output long bare image data asset survives later content update")
    func rawOutputLongBareImageDataAssetSurvivesLaterContentUpdate() async {
        let session = ACPSession(id: "s", agentId: "bridge", worktreeId: "w", title: "t")
        let imageData = String(repeating: "A", count: 5_000)

        session.apply(.toolCall(.init(
            toolCallId: "tc-raw-long-image-data-update",
            title: "Image generation",
            kind: "other",
            status: "in_progress",
            content: nil,
            locations: nil,
            rawInput: nil,
            rawOutput: AnyCodable([
                "data": AnyCodable(imageData),
                "mime_type": AnyCodable("image/png")
            ]))))
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-raw-long-image-data-update",
            status: "completed",
            content: [.content(.text("final output"))],
            rawOutput: nil)))

        if case .toolCall(let tc) = session.transcript.messages[0] {
            #expect(tc.content == "final output")
            #expect(tc.rawOutput?.contains("[truncated]") == true)
            #expect(tc.assets == [
                ACPMessage.ToolCallAsset.image(data: imageData, mimeType: "image/png")
            ])
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

    @Test("suppressed final tool replay preserves terminal ids from content")
    func suppressedFinalToolReplayPreservesTerminalIdsFromContent() async {
        let session = ACPSession(id: "s", agentId: "bridge", worktreeId: "w", title: "t")

        session.apply(.toolCall(.init(
            toolCallId: "tc-final-replay-terminal",
            title: "Final command",
            kind: "execute",
            status: "completed",
            content: [.content(.text("final output"))],
            locations: nil,
            rawInput: nil,
            rawOutput: nil)))

        let touched = session.applySuppressedReplaySideEffects(.toolCallUpdate(.init(
            toolCallId: "tc-final-replay-terminal",
            status: "completed",
            content: [.terminal(terminalId: "term-final-replay")],
            rawOutput: nil)))

        #expect(touched == [0])
        if case .toolCall(let tc) = session.transcript.messages[0] {
            #expect(tc.content == "final output")
            #expect(tc.terminalIds == ["term-final-replay"])
        } else {
            Issue.record("expected toolCall message")
        }
    }

    @Test("suppressed final tool payload replay preserves terminal ids from content")
    func suppressedFinalToolPayloadReplayPreservesTerminalIdsFromContent() async {
        let session = ACPSession(id: "s", agentId: "bridge", worktreeId: "w", title: "t")

        session.apply(.toolCall(.init(
            toolCallId: "tc-final-payload-replay-terminal",
            title: "Final command",
            kind: "execute",
            status: "completed",
            content: [.content(.text("final output"))],
            locations: nil,
            rawInput: nil,
            rawOutput: nil)))

        let touched = session.applySuppressedReplaySideEffects(.toolCall(.init(
            toolCallId: "tc-final-payload-replay-terminal",
            title: "Initial command",
            kind: "execute",
            status: "completed",
            content: [.terminal(terminalId: "term-final-payload-replay")],
            locations: nil,
            rawInput: nil,
            rawOutput: nil)))

        #expect(touched == [0])
        if case .toolCall(let tc) = session.transcript.messages[0] {
            #expect(tc.title == "Final command")
            #expect(tc.content == "final output")
            #expect(tc.terminalIds == ["term-final-payload-replay"])
        } else {
            Issue.record("expected toolCall message")
        }
    }

    @Test("suppressed in-progress tool payload replay preserves terminal ids from content")
    func suppressedInProgressToolPayloadReplayPreservesTerminalIdsFromContent() async {
        let session = ACPSession(id: "s", agentId: "bridge", worktreeId: "w", title: "t")

        session.apply(.toolCall(.init(
            toolCallId: "tc-in-progress-payload-replay-terminal",
            title: "Final command",
            kind: "execute",
            status: "completed",
            content: [.content(.text("final output"))],
            locations: nil,
            rawInput: nil,
            rawOutput: nil)))

        let touched = session.applySuppressedReplaySideEffects(.toolCall(.init(
            toolCallId: "tc-in-progress-payload-replay-terminal",
            title: "Initial command",
            kind: "execute",
            status: "in_progress",
            content: [.terminal(terminalId: "term-in-progress-payload-replay")],
            locations: nil,
            rawInput: nil,
            rawOutput: nil)))

        #expect(touched == [0])
        if case .toolCall(let tc) = session.transcript.messages[0] {
            #expect(tc.title == "Final command")
            #expect(tc.content == "final output")
            #expect(tc.terminalIds == ["term-in-progress-payload-replay"])
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
        session.applySuppressedReplaySideEffects(update)

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
        session.applySuppressedReplaySideEffects(.toolCallUpdate(.init(
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
        session.applySuppressedReplaySideEffects(.toolCallUpdate(.init(
            toolCallId: "cmd-replay-frames",
            status: "in_progress",
            rawOutput: nil,
            metadata: AnyCodable([
                "terminal_info": AnyCodable([
                    "terminal_id": AnyCodable("term-replay-frames"),
                    "cwd": AnyCodable("/tmp/project")
                ])
            ]))))
        session.applySuppressedReplaySideEffects(.toolCallUpdate(.init(
            toolCallId: "cmd-replay-frames",
            status: "in_progress",
            rawOutput: nil,
            metadata: AnyCodable([
                "terminal_output_delta": AnyCodable([
                    "terminal_id": AnyCodable("term-replay-frames"),
                    "data": AnyCodable("building\n")
                ])
            ]))))
        session.applySuppressedReplaySideEffects(.toolCallUpdate(.init(
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
        session.applySuppressedReplaySideEffects(.toolCallUpdate(.init(
            toolCallId: "cmd-replay-buffered-exit",
            status: "in_progress",
            rawOutput: nil,
            metadata: AnyCodable([
                "terminal_output_delta": AnyCodable([
                    "terminal_id": AnyCodable("term-replay-buffered-exit"),
                    "data": AnyCodable("building\n")
                ])
            ]))))
        session.applySuppressedReplaySideEffects(.toolCallUpdate(.init(
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

    @Test("suppressed replay payload content excludes exit-only terminal id")
    func suppressedReplayPayloadContentExcludesExitOnlyTerminalId() async throws {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")

        session.apply(.toolCall(.init(
            toolCallId: "cmd-payload-exit-content",
            title: "swift test",
            kind: "execute",
            status: "completed",
            content: [.content(.text("final output"))],
            locations: nil,
            rawInput: nil,
            rawOutput: nil)))
        session.beginSuppressedReplaySideEffects()
        session.applySuppressedReplaySideEffects(.toolCall(.init(
            toolCallId: "cmd-payload-exit-content",
            title: "swift test",
            kind: "execute",
            status: "completed",
            content: [.content(.text("final output"))],
            locations: nil,
            rawInput: nil,
            rawOutput: nil,
            metadata: AnyCodable([
                "terminal_exit": AnyCodable([
                    "terminal_id": AnyCodable("term-payload-exit-only"),
                    "exit_code": AnyCodable(0)
                ])
            ]))))

        let message = try #require(session.transcript.messages.first)
        guard case .toolCall(let toolCall) = message else {
            Issue.record("expected toolCall message")
            return
        }
        #expect(toolCall.terminalIds == [])

        let term = try #require(session.terminalHost.terminal(id: "term-payload-exit-only"))
        #expect(term.exitStatus == ACPTerminalExitStatus(exitCode: 0, signal: nil))
    }

    @Test("suppressed replay update content excludes exit-only terminal id")
    func suppressedReplayUpdateContentExcludesExitOnlyTerminalId() async throws {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")

        session.apply(.toolCall(.init(
            toolCallId: "cmd-update-exit-content",
            title: "swift test",
            kind: "execute",
            status: "completed",
            content: [.content(.text("final output"))],
            locations: nil,
            rawInput: nil,
            rawOutput: nil)))
        session.beginSuppressedReplaySideEffects()
        session.applySuppressedReplaySideEffects(.toolCallUpdate(.init(
            toolCallId: "cmd-update-exit-content",
            status: "completed",
            content: [.content(.text("final output"))],
            rawOutput: nil,
            metadata: AnyCodable([
                "terminal_exit": AnyCodable([
                    "terminal_id": AnyCodable("term-update-exit-only"),
                    "exit_code": AnyCodable(0)
                ])
            ]))))

        let message = try #require(session.transcript.messages.first)
        guard case .toolCall(let toolCall) = message else {
            Issue.record("expected toolCall message")
            return
        }
        #expect(toolCall.terminalIds == [])

        let term = try #require(session.terminalHost.terminal(id: "term-update-exit-only"))
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
            content: [.diff(path: "a.swift", oldText: "let x = 1\n", newText: "let x = 2\n")],
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

    @Test("initial toolCall with terminal content records terminalIds")
    func toolCallInitialTerminal() async {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        session.apply(.toolCall(.init(
            toolCallId: "tc-4", title: "run", kind: "execute", status: "in_progress",
            content: [.terminal(terminalId: "term-99")],
            locations: nil, rawInput: nil, rawOutput: nil)))
        #expect(session.transcript.messages.count == 1)
        if case .toolCall(let tc) = session.transcript.messages[0] {
            #expect(tc.terminalIds == ["term-99"])
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

    @Test("completed toolCall strips wrapping markdown fences")
    func toolCallStripsBothFences() async {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        session.apply(.toolCall(.init(
            toolCallId: "tc-5", title: "read", kind: "read", status: "in_progress",
            content: nil, locations: nil, rawInput: nil, rawOutput: nil)))
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-5", status: "completed",
            content: [.content(.text("```swift\nlet x = 1\nlet y = 2\n```"))],
            rawOutput: nil)))
        if case .toolCall(let tc) = session.transcript.messages[0] {
            #expect(tc.content == "let x = 1\nlet y = 2")
            #expect(tc.contentLanguage == "swift")
            #expect(tc.preview == "let x = 1")
        } else { Issue.record("expected toolCall message") }
    }

    @Test("toolCallUpdate preserves supported wrapped fence language")
    func toolCallUpdatePreservesWrappedFenceLanguage() async {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        session.apply(.toolCall(.init(
            toolCallId: "tc-sql", title: "query", kind: "read", status: "in_progress",
            content: nil, locations: nil, rawInput: nil, rawOutput: nil)))
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-sql", status: "completed",
            content: [.content(.text("```sql\nSELECT id FROM users\n```"))],
            rawOutput: nil)))
        if case .toolCall(let tc) = session.transcript.messages[0] {
            #expect(tc.content == "SELECT id FROM users")
            #expect(tc.contentLanguage == "sql")
        } else { Issue.record("expected toolCall message") }
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

    @Test("streamed partial opening fence then completion strips the wrapper fence")
    func toolCallUpdateStreamingPartialFenceThenCompletionStripsFence() async {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        session.apply(.toolCall(.init(
            toolCallId: "tc-partial-fence", title: "read", kind: "read", status: "in_progress",
            content: nil, locations: nil, rawInput: nil, rawOutput: nil)))
        // Partial opening fence (not yet a complete fence line: "``" is not
        // recognized by `isOpeningFence` which requires "```" prefix).
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-partial-fence", status: "in_progress",
            content: [.content(.text("``"))])))
        // Completion: the full opening fence plus code.
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-partial-fence", status: "completed",
            content: [.content(.text("```swift\nlet x = 1\n```"))])))
        if case .toolCall(let tc) = session.transcript.messages[0] {
            #expect(tc.content == "let x = 1")
            #expect(tc.contentLanguage == "swift")
            #expect(tc.preview == "let x = 1")
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

    @Test("streamed toolCallUpdate does not strip a trailing fence line when there is no opening fence")
    func toolCallUpdateStreamingNoOpeningFenceKeepsTrailingFenceLine() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.apply(.toolCall(.init(
            toolCallId: "tc-no-opening-fence", title: "run", kind: "execute", status: "in_progress",
            content: nil, locations: nil, rawInput: nil, rawOutput: nil)))
        // First chunk: ordinary log output (no opening fence).
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-no-opening-fence", status: "in_progress",
            content: [.content(.text("log line\n```"))])))
        // Final chunk: the log grows, ending with a line of three
        // backticks that is NOT a closing fence (there was no opening
        // fence). The suffix path must NOT strip the trailing "```".
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-no-opening-fence", status: "completed",
            content: [.content(.text("log line\n```\nmore output"))])))
        if case .toolCall(let tc) = session.transcript.messages[0] {
            #expect(tc.content == "log line\n```\nmore output")
            #expect(tc.preview == "log line")
        } else { Issue.record("expected toolCall message") }
    }

    @Test("streamed single text item growing takes the suffix path (regression)")
    func toolCallUpdateStreamingSingleTextItemGrowingTakesSuffixPath() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.apply(.toolCall(.init(
            toolCallId: "tc-growing-text", title: "run", kind: "execute", status: "in_progress",
            content: nil, locations: nil, rawInput: nil, rawOutput: nil)))
        // Adapter sends a single text content item that grows on each
        // update (the common cumulative shape). The suffix-only fast path
        // must fire on each update; this is a regression test for the
        // `prefixItemsUnchanged` guard which previously compared text
        // items element-wise and forced a full reprocess every update.
        let chunks = ["a", "ab", "abc", "abcdef", "abcdefghij"]
        for chunk in chunks {
            session.apply(.toolCallUpdate(.init(
                toolCallId: "tc-growing-text", status: "in_progress",
                content: [.content(.text(chunk))])))
        }
        if case .toolCall(let tc) = session.transcript.messages[0] {
            #expect(tc.content == "abcdefghij")
            #expect(tc.preview == "abcdefghij")
        } else { Issue.record("expected toolCall message") }
    }

    @Test("toolCallUpdate with same text but replaced rawOutput rebuilds assets")
    func toolCallUpdateSameTextReplacedRawOutputRebuildsAssets() async {
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
        // Second update: same text + same status, but rawOutput replaced
        // with image B. The identical-text fast path must fall to full
        // reprocess so `tc.assets` is rebuilt from content + the new
        // rawOutput (replacing image A, not accumulating it).
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-raw-replace", status: "in_progress",
            content: [.content(.text("same"))],
            rawOutput: AnyCodable(["data": AnyCodable("img-b"), "mime_type": AnyCodable("image/png")]))))
        if case .toolCall(let tc2) = session.transcript.messages[0] {
            #expect(tc2.assets == [
                ACPMessage.ToolCallAsset.image(data: "img-b", mimeType: "image/png")
            ], "after second: \(tc2.assets)")
        } else { Issue.record("expected toolCall message") }
    }

    @Test("toolCallUpdate with same text and rawOutput clearing image drops stale asset")
    func toolCallUpdateSameTextRawOutputClearsImageDropsStale() async {
        let session = ACPSession(id: "s", agentId: "bridge", worktreeId: "w", title: "t")
        session.apply(.toolCall(.init(
            toolCallId: "tc-raw-clear", title: "image", kind: "other", status: "in_progress",
            content: nil, locations: nil, rawInput: nil, rawOutput: nil)))
        // First update: text + rawOutput image.
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-raw-clear", status: "in_progress",
            content: [.content(.text("same"))],
            rawOutput: AnyCodable(["data": AnyCodable("img-a"), "mime_type": AnyCodable("image/png")]))))
        if case .toolCall(let tc1) = session.transcript.messages[0] {
            #expect(tc1.assets == [
                ACPMessage.ToolCallAsset.image(data: "img-a", mimeType: "image/png")
            ], "after first: \(tc1.assets)")
        }
        // Second update: same text + same status, but rawOutput replaced
        // with a non-image result (no assets). The identical-text fast
        // path must fall to full reprocess so the stale image is dropped.
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-raw-clear", status: "in_progress",
            content: [.content(.text("same"))],
            rawOutput: AnyCodable(["text": AnyCodable("done")]))))
        if case .toolCall(let tc2) = session.transcript.messages[0] {
            #expect(tc2.assets == [], "after second: \(tc2.assets)")
        } else { Issue.record("expected toolCall message") }
    }

    @Test("streamed partial fence completing to an invalid fence tag falls to full reprocess")
    func toolCallUpdateStreamingPartialFenceInvalidTagFallsToFullReprocess() async {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        session.apply(.toolCall(.init(
            toolCallId: "tc-invalid-tag", title: "read", kind: "read", status: "in_progress",
            content: nil, locations: nil, rawInput: nil, rawOutput: nil)))
        // First chunk: a valid-looking opening fence prefix "```".
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-invalid-tag", status: "in_progress",
            content: [.content(.text("```"))])))
        // Second chunk: the fence line completes to "```{.swift}" which
        // isOpeningFence REJECTS (the `{` is not a valid tag character).
        // The suffix path must fall to full reprocess so the line is kept
        // in the body (not stripped as a fence).
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-invalid-tag", status: "completed",
            content: [.content(.text("```{.swift}\nlet x = 1\n```"))])))
        if case .toolCall(let tc) = session.transcript.messages[0] {
            // The first line "```{.swift}" is NOT a valid opening fence
            // (isOpeningFence rejects `{`), so stripWrappingFence leaves
            // it in the content. The trailing "```" is also NOT stripped.
            // Note: `wrappingFenceLanguage` is more permissive than
            // `isOpeningFence` and still extracts "swift" from the tag —
            // that's the legacy behavior too.
            #expect(tc.content == "```{.swift}\nlet x = 1\n```")
        } else { Issue.record("expected toolCall message") }
    }

    @Test("streamed partial fence growing to invalid tag without newline falls to full reprocess")
    func toolCallUpdateStreamingPartialFenceInvalidNoNewlineFallsToFullReprocess() async {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        session.apply(.toolCall(.init(
            toolCallId: "tc-invalid-no-newline", title: "read", kind: "read", status: "in_progress",
            content: nil, locations: nil, rawInput: nil, rawOutput: nil)))
        // First chunk: a valid-looking opening fence prefix "```".
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-invalid-no-newline", status: "in_progress",
            content: [.content(.text("```"))])))
        // Second chunk: the fence line grows to "```{" (still no newline).
        // `{` is not a valid tag character, so couldBeOpeningFencePrefix
        // returns false and the suffix path falls to full reprocess,
        // keeping the line in the body.
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-invalid-no-newline", status: "completed",
            content: [.content(.text("```{\nbody"))])))
        if case .toolCall(let tc) = session.transcript.messages[0] {
            // "```{" is NOT a valid opening fence, so stripWrappingFence
            // leaves it in the content.
            #expect(tc.content == "```{\nbody")
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

    @Test("streamed inline-code first chunk does not trigger partial-fence full reprocess")
    func toolCallUpdateStreamingInlineCodeDoesNotTriggerPartialFenceReprocess() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.apply(.toolCall(.init(
            toolCallId: "tc-inline", title: "run", kind: "execute", status: "in_progress",
            content: nil, locations: nil, rawInput: nil, rawOutput: nil)))
        // First chunk: inline code starting with a backtick — NOT a partial
        // opening fence (it can never become "```" + valid tag).
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-inline", status: "in_progress",
            content: [.content(.text("`cmd` ran"))])))
        // Second chunk: the log grows. The suffix-only fast path must fire
        // (previousRawWasPartialFence returns false for "`cmd` ran").
        session.apply(.toolCallUpdate(.init(
            toolCallId: "tc-inline", status: "completed",
            content: [.content(.text("`cmd` ran successfully"))])))
        if case .toolCall(let tc) = session.transcript.messages[0] {
            #expect(tc.content == "`cmd` ran successfully")
            #expect(tc.preview == "`cmd` ran successfully")
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
