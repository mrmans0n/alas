import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACPSession")
struct ACPSessionTests {
    @Test("agent message chunks append to a single agent message")
    func chunksMerge() async {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        session.apply(.agentMessageChunk(.text("hello ")))
        session.apply(.agentMessageChunk(.text("world")))
        #expect(session.transcript.messages.count == 1)
        if case .agent(_, _, let buf) = session.transcript.messages[0] { #expect(buf.value == "hello world") }
        else { Issue.record("expected single agent message") }
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
        if case .user(_, _, let text, let attachments) = session.transcript.messages[0] {
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
        if case .user(_, _, let text, _) = session.transcript.messages[0] { #expect(text == "hi") }
        else { Issue.record("expected user message") }
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
}
