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
        if case .agent(_, let buf) = session.transcript.messages[0] { #expect(buf.value == "hello world") }
        else { Issue.record("expected single agent message") }
    }

    @Test("agent chunks after a completed output boundary start a new message")
    func completedOutputBoundaryStartsNewMessage() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.apply(.agentMessageChunk(.text("first task output")))
        session.markCompletedOutputBoundary()
        session.apply(.agentMessageChunk(.text("next task output")))

        #expect(session.transcript.messages.count == 2)
        if case .agent(_, let first) = session.transcript.messages[0],
           case .agent(_, let second) = session.transcript.messages[1] {
            #expect(first.value == "first task output")
            #expect(second.value == "next task output")
        } else {
            Issue.record("expected two agent messages")
        }
    }

    @Test("completed output boundary does not alter existing message text")
    func completedOutputBoundaryDoesNotAddBlankLines() async {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        session.apply(.agentMessageChunk(.text("line one\nline two")))
        session.markCompletedOutputBoundary()

        if case .agent(_, let buf) = session.transcript.messages[0] {
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
        if case .agent(_, let first) = session.transcript.messages[0],
           case .plan = session.transcript.messages[1],
           case .agent(_, let second) = session.transcript.messages[2] {
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
        if case .agent(_, let first) = session.transcript.messages[0],
           case .thought(_, let thought) = session.transcript.messages[1],
           case .agent(_, let second) = session.transcript.messages[2] {
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
        if case .agent(_, let first) = session.transcript.messages[0],
           case .thought(_, let firstThought) = session.transcript.messages[1],
           case .thought(_, let secondThought) = session.transcript.messages[2],
           case .agent(_, let second) = session.transcript.messages[3] {
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
        if case .user(_, let text, _) = session.transcript.messages[0] { #expect(text == "hi") }
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
        #expect(session.availableConfigOptions[0].currentValue == "high")
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
