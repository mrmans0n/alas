import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACPMessage stable identity")
struct ACPMessageStableIdTests {
    @Test("user/agent rows get distinct stable ids on append")
    func distinctIds() async {
        let s = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        s.recordUserPrompt(text: "hi", attachments: [])
        s.apply(.agentMessageChunk(.text("hello")))
        #expect(s.transcript.messages.count == 2)
        #expect(s.transcript.messages[0].stableId != s.transcript.messages[1].stableId)
    }

    @Test("appending a new agent chunk to an existing agent row keeps the same stable id")
    func chunkPreservesId() async {
        let s = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        s.apply(.agentMessageChunk(.text("hello ")))
        let id1 = s.transcript.messages[0].stableId
        s.apply(.agentMessageChunk(.text("world")))
        #expect(s.transcript.messages.count == 1)
        #expect(s.transcript.messages[0].stableId == id1)
    }

    @Test("agent chunks with messageId use it as stable id and append by id")
    func agentChunksUseMessageId() async {
        let s = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        s.apply(.agentMessageChunk(.init(messageId: "agent-1", content: .text("hello"))))
        s.apply(.agentThoughtChunk(.init(messageId: "thought-1", content: .text("thinking"))))
        s.apply(.agentMessageChunk(.init(messageId: "agent-1", content: .text(" world"))))

        #expect(s.transcript.messages.count == 2)
        #expect(s.transcript.messages[0].stableId == "acp-agent:agent-1")
        if case .agent(_, _, let text) = s.transcript.messages[0] {
            #expect(text.value == "hello world")
        } else {
            Issue.record("expected agent message")
        }
    }

    @Test("different messageIds create separate transcript rows")
    func differentMessageIdsCreateRows() async {
        let s = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        s.apply(.agentMessageChunk(.init(messageId: "agent-1", content: .text("one"))))
        s.apply(.agentMessageChunk(.init(messageId: "agent-2", content: .text("two"))))

        #expect(s.transcript.messages.map(\.stableId) == ["acp-agent:agent-1", "acp-agent:agent-2"])
    }

    @Test("user chunks with messageId use it as stable id and append by id")
    func userChunksUseMessageId() async {
        let s = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        s.apply(.userMessageChunk(.init(messageId: "user-1", content: .text("hello"))))
        s.apply(.agentMessageChunk(.init(messageId: "agent-1", content: .text("reply"))))
        s.apply(.userMessageChunk(.init(messageId: "user-1", content: .text(" world"))))

        #expect(s.transcript.messages.map(\.stableId) == ["acp-user:user-1", "acp-agent:agent-1"])
        if case .user(_, _, let text, let attachments, _, _) = s.transcript.messages[0] {
            #expect(text == "hello world")
            #expect(attachments.isEmpty)
        } else {
            Issue.record("expected user message")
        }
    }

    @Test("repeated user chunks with messageId are preserved")
    func repeatedUserChunksWithMessageIdArePreserved() async {
        let s = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        s.apply(.userMessageChunk(.init(messageId: "user-1", content: .text("a"))))
        s.apply(.userMessageChunk(.init(messageId: "user-1", content: .text("a"))))
        s.apply(.userMessageChunk(.init(messageId: "user-1", content: .text("a"))))

        #expect(s.transcript.messages.map(\.stableId) == ["acp-user:user-1"])
        if case .user(_, _, let text, let attachments, _, _) = s.transcript.messages[0] {
            #expect(text == "aaa")
            #expect(attachments.isEmpty)
        } else {
            Issue.record("expected user message")
        }
    }

    @Test("replayed user_message_chunk does not duplicate hydrated user text")
    func replayedUserMessageChunkDoesNotDuplicateHydratedUserText() async {
        let s = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        s.transcript.messages = [.user(id: UUID(), messageId: "user-1", text: "hello world", attachments: [])]

        let changed = s.apply(.userMessageChunk(.init(messageId: "user-1", content: .text("hello "))))

        #expect(changed == [0])
        #expect(s.transcript.messages.map(\.stableId) == ["acp-user:user-1"])
        if case .user(_, let messageId, let text, let attachments, _, _) = s.transcript.messages[0] {
            #expect(messageId == "user-1")
            #expect(text == "hello world")
            #expect(attachments.isEmpty)
        } else {
            Issue.record("expected user message")
        }
    }

    @Test("user chunks with resource links preserve attachments")
    func userResourceChunksPreserveAttachments() async {
        let s = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")

        s.apply(.userMessageChunk(.init(
            messageId: "user-1",
            content: .resourceLink(uri: "file:///tmp/example.swift", name: "example.swift"))))

        #expect(s.transcript.messages.map(\.stableId) == ["acp-user:user-1"])
        if case .user(_, let messageId, let text, let attachments, _, _) = s.transcript.messages[0] {
            #expect(messageId == "user-1")
            #expect(text == "")
            #expect(attachments == [
                ACPMessage.Attachment(uri: "file:///tmp/example.swift", name: "example.swift")
            ])
        } else {
            Issue.record("expected user message")
        }
    }

    @Test("empty user chunk without attachments does not append")
    func emptyUserChunkWithoutAttachmentsDoesNotAppend() async {
        let s = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")

        let changed = s.apply(.userMessageChunk(.text("")))

        #expect(changed.isEmpty)
        #expect(s.transcript.messages.isEmpty)
    }

    @Test("mixed user chunks with messageId keep text and attachments together")
    func mixedUserChunksKeepTextAndAttachmentsTogether() async {
        let s = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")

        s.apply(.userMessageChunk(.init(messageId: "user-1", content: .text("see "))))
        s.apply(.userMessageChunk(.init(
            messageId: "user-1",
            content: .image(data: nil, uri: "file:///tmp/screenshot.jpg", mimeType: "image/jpeg"))))
        s.apply(.userMessageChunk(.init(messageId: "user-1", content: .text("please"))))

        #expect(s.transcript.messages.map(\.stableId) == ["acp-user:user-1"])
        if case .user(_, let messageId, let text, let attachments, _, _) = s.transcript.messages[0] {
            #expect(messageId == "user-1")
            #expect(text == "see please")
            #expect(attachments == [
                ACPMessage.Attachment(uri: "file:///tmp/screenshot.jpg", name: "screenshot.jpg", mimeType: "image/jpeg")
            ])
        } else {
            Issue.record("expected user message")
        }
    }

    @Test("echoed user chunks do not duplicate local prompt attachments")
    func echoedUserChunksDoNotDuplicateLocalPromptAttachments() async {
        let s = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        let attachment = ACPMessage.Attachment(uri: "file:///tmp/example.swift", name: "example.swift")
        s.recordUserPrompt(text: "see this", attachments: [attachment])

        s.apply(.userMessageChunk(.init(messageId: "user-1", content: .text("see this"))))
        s.apply(.userMessageChunk(.init(
            messageId: "user-1",
            content: .resourceLink(uri: "file:///tmp/example.swift", name: "example.swift"))))

        #expect(s.transcript.messages.map(\.stableId) == ["acp-user:user-1"])
        if case .user(_, let messageId, let text, let attachments, _, _) = s.transcript.messages[0] {
            #expect(messageId == "user-1")
            #expect(text == "see this")
            #expect(attachments == [attachment])
        } else {
            Issue.record("expected user message")
        }
    }

    @Test("attachment-only user_message_chunk echo updates local prompt instead of duplicating")
    func attachmentOnlyUserMessageChunkEchoUpdatesLocalPrompt() async {
        let s = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        let attachment = ACPMessage.Attachment(
            uri: "file:///tmp/screenshot.jpg",
            name: "screenshot.jpg",
            mimeType: "image/jpeg")
        s.recordUserPrompt(text: "", attachments: [attachment])

        let changed = s.apply(.userMessageChunk(.init(
            messageId: "user-1",
            content: .image(data: nil, uri: "file:///tmp/screenshot.jpg", mimeType: "image/jpeg"))))

        #expect(changed == [0])
        #expect(s.transcript.messages.map(\.stableId) == ["acp-user:user-1"])
        if case .user(_, let messageId, let text, let attachments, _, _) = s.transcript.messages[0] {
            #expect(messageId == "user-1")
            #expect(text == "")
            #expect(attachments == [attachment])
        } else {
            Issue.record("expected user message")
        }
    }

    @Test("attachment-only replay does not mark hydrated user row as live")
    func attachmentOnlyReplayDoesNotMarkHydratedUserRowAsLive() async {
        let s = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        let attachment = ACPMessage.Attachment(
            uri: "file:///tmp/screenshot.jpg",
            name: "screenshot.jpg",
            mimeType: "image/jpeg")
        s.transcript.messages = [
            .user(id: UUID(), messageId: "user-1", text: "see this", attachments: [attachment])
        ]

        let attachmentChanged = s.apply(.userMessageChunk(.init(
            messageId: "user-1",
            content: .image(data: nil, uri: "file:///tmp/screenshot.jpg", mimeType: "image/jpeg"))))
        let textChanged = s.apply(.userMessageChunk(.init(messageId: "user-1", content: .text("see this"))))

        #expect(attachmentChanged == [0])
        #expect(textChanged == [0])
        #expect(s.transcript.messages.map(\.stableId) == ["acp-user:user-1"])
        if case .user(_, let messageId, let text, let attachments, _, _) = s.transcript.messages[0] {
            #expect(messageId == "user-1")
            #expect(text == "see this")
            #expect(attachments == [attachment])
        } else {
            Issue.record("expected user message")
        }
    }

    @Test("ACP messageIds are namespaced by text row kind")
    func messageIdStableIdsAreNamespaced() async {
        let user = ACPMessage.user(id: UUID(), messageId: "same", text: "u", attachments: [])
        let agent = ACPMessage.agent(id: UUID(), messageId: "same", StreamingText("a"))
        let thought = ACPMessage.thought(id: UUID(), messageId: "same", StreamingText("t"))

        #expect(user.stableId == "acp-user:same")
        #expect(agent.stableId == "acp-agent:same")
        #expect(thought.stableId == "acp-thought:same")
    }

    @Test("user_message_chunk echo updates local prompt instead of duplicating")
    func userMessageChunkEchoUpdatesLocalPrompt() async {
        let s = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        s.recordUserPrompt(text: "hello", attachments: [])

        let changed = s.apply(.userMessageChunk(.init(messageId: "user-1", content: .text("hello"))))

        #expect(changed == [0])
        #expect(s.transcript.messages.count == 1)
        #expect(s.transcript.messages[0].stableId == "acp-user:user-1")
        if case .user(_, let messageId, let text, let attachments, _, _) = s.transcript.messages[0] {
            #expect(messageId == "user-1")
            #expect(text == "hello")
            #expect(attachments.isEmpty)
        } else {
            Issue.record("expected user message")
        }
    }

    @Test("chunked user_message_chunk echo updates local prompt instead of duplicating")
    func chunkedUserMessageChunkEchoUpdatesLocalPrompt() async {
        let s = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        s.recordUserPrompt(text: "hello world", attachments: [])

        let firstChanged = s.apply(.userMessageChunk(.init(messageId: "user-1", content: .text("hello "))))
        let secondChanged = s.apply(.userMessageChunk(.init(messageId: "user-1", content: .text("world"))))

        #expect(firstChanged == [0])
        #expect(secondChanged == [0])
        #expect(s.transcript.messages.count == 1)
        #expect(s.transcript.messages[0].stableId == "acp-user:user-1")
        if case .user(_, let messageId, let text, let attachments, _, _) = s.transcript.messages[0] {
            #expect(messageId == "user-1")
            #expect(text == "hello world")
            #expect(attachments.isEmpty)
        } else {
            Issue.record("expected user message")
        }
    }

    @Test("legacy user_message_chunk echo without messageId does not duplicate local prompt")
    func legacyUserMessageChunkEchoDoesNotDuplicateLocalPrompt() async {
        let s = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        s.recordUserPrompt(text: "hello", attachments: [])

        let changed = s.apply(.userMessageChunk(.text("hello")))

        #expect(changed == [0])
        #expect(s.transcript.messages.count == 1)
        if case .user(_, let messageId, let text, _, _, _) = s.transcript.messages[0] {
            #expect(messageId == nil)
            #expect(text == "hello")
        } else {
            Issue.record("expected user message")
        }
    }

    @Test("legacy chunked user_message_chunk echo without messageId does not duplicate local prompt")
    func legacyChunkedUserMessageChunkEchoDoesNotDuplicateLocalPrompt() async {
        let s = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        s.recordUserPrompt(text: "hello world", attachments: [])

        let firstChanged = s.apply(.userMessageChunk(.text("hello ")))
        let secondChanged = s.apply(.userMessageChunk(.text("world")))

        #expect(firstChanged == [0])
        #expect(secondChanged == [0])
        #expect(s.transcript.messages.count == 1)
        if case .user(_, let messageId, let text, _, _, _) = s.transcript.messages[0] {
            #expect(messageId == nil)
            #expect(text == "hello world")
        } else {
            Issue.record("expected user message")
        }
    }

    @Test("legacy user_message_chunk blocks merge adjacent text and attachments")
    func legacyUserMessageChunksMergeAdjacentTextAndAttachments() async {
        let s = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        let attachment = ACPMessage.Attachment(uri: "file:///tmp/example.swift", name: "example.swift")

        let firstChanged = s.apply(.userMessageChunk(.text("see ")))
        let secondChanged = s.apply(.userMessageChunk(.init(
            messageId: nil,
            content: .resourceLink(uri: "file:///tmp/example.swift", name: "example.swift"))))

        #expect(firstChanged == [0])
        #expect(secondChanged == [0])
        #expect(s.transcript.messages.count == 1)
        if case .user(_, let messageId, let text, let attachments, _, _) = s.transcript.messages[0] {
            #expect(messageId == nil)
            #expect(text == "see ")
            #expect(attachments == [attachment])
        } else {
            Issue.record("expected user message")
        }
    }

    @Test("repeated legacy user_message_chunk text is preserved")
    func repeatedLegacyUserMessageChunkTextIsPreserved() async {
        let s = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")

        let firstChanged = s.apply(.userMessageChunk(.text("ha")))
        let secondChanged = s.apply(.userMessageChunk(.text("ha")))

        #expect(firstChanged == [0])
        #expect(secondChanged == [0])
        #expect(s.transcript.messages.count == 1)
        if case .user(_, let messageId, let text, let attachments, _, _) = s.transcript.messages[0] {
            #expect(messageId == nil)
            #expect(text == "haha")
            #expect(attachments.isEmpty)
        } else {
            Issue.record("expected user message")
        }
    }

    @Test("toolCall row stable id matches its toolCallId")
    func toolCallId() async {
        let s = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        s.apply(.toolCall(.init(toolCallId: "tc-1", title: "t", kind: nil, status: "in_progress", content: nil, locations: nil, rawInput: nil, rawOutput: nil)))
        guard case .toolCall(let tc) = s.transcript.messages[0] else { Issue.record("expected tool call")
        return }
        #expect(s.transcript.messages[0].stableId == "tc-\(tc.toolCallId)")
    }

    @Test("an echoed local prompt keeps its pasted spans; a merge that changes the text drops them")
    func echoKeepsPastedSpansOnlyForUnchangedText() async {
        let s = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        let spans = [ACPPastedTextSpan(ordinal: 1, utf16Offset: 4, utf16Length: 5)]
        s.recordUserPrompt(text: "see TRACE", attachments: [], pastedSpans: spans)

        s.apply(.userMessageChunk(.init(messageId: "user-1", content: .text("see TRACE"))))

        guard case .user(_, let messageId, _, _, _, let kept) = s.transcript.messages[0] else {
            Issue.record("expected user message")
            return
        }
        #expect(messageId == "user-1")
        #expect(kept == spans)

        s.apply(.userMessageChunk(.init(messageId: "user-1", content: .text("more"))))

        guard case .user(_, _, let text, _, _, let dropped) = s.transcript.messages[0] else {
            Issue.record("expected user message")
            return
        }
        #expect(text != "see TRACE")
        #expect(dropped.isEmpty)
    }

    @Test("an attachment-only update to an echoed local prompt keeps its pasted spans")
    func attachmentOnlyUpdateKeepsPastedSpans() async {
        let s = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        let spans = [ACPPastedTextSpan(ordinal: 1, utf16Offset: 4, utf16Length: 5)]
        s.recordUserPrompt(text: "see TRACE", attachments: [], pastedSpans: spans)

        s.apply(.userMessageChunk(.init(messageId: "user-1", content: .text("see TRACE"))))
        s.apply(.userMessageChunk(.init(
            messageId: "user-1",
            content: .resourceLink(uri: "file:///tmp/example.swift", name: "example.swift"))))

        guard case .user(_, _, let text, let attachments, _, let kept) = s.transcript.messages[0] else {
            Issue.record("expected user message")
            return
        }
        #expect(text == "see TRACE")
        #expect(attachments.count == 1)
        #expect(kept == spans)
    }

    @Test("an echoed symbol expansion stays out of the recorded prompt", arguments: [true, false])
    func echoedSymbolExpansionIsDropped(embeddedContext: Bool) async {
        let s = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        let link = ACPSymbolReference.uri(for: .init(path: "A.swift", name: "run", kind: .function,
                                                     container: nil, lineRange: 0...0, includeCode: true))
        let attachment = ACPMessage.Attachment(uri: link, name: "run()")
        s.recordUserPrompt(text: "explain ", attachments: [attachment])
        let blocks: [ACPContentBlock] = [.text("explain "), .resourceLink(uri: link, name: "run()")]
        let expansion = ACPSymbolReference.expansion(
            of: blocks, sources: ["A.swift": "func run() {}"],
            worktreeRoot: URL(fileURLWithPath: "/tmp/wt"), embeddedContext: embeddedContext)
        s.expectSymbolExpansionEchoes(expansion.sentBlocks)

        for block in ACPSymbolReference.replacingReferences(in: blocks, with: expansion) {
            s.apply(.userMessageChunk(.init(messageId: "user-1", content: block)))
        }

        #expect(s.transcript.messages.map(\.stableId) == ["acp-user:user-1"])
        guard case .user(_, _, let text, let attachments, _, _) = s.transcript.messages[0] else {
            Issue.record("expected user message")
            return
        }
        #expect(text == "explain ")
        #expect(attachments == [attachment])
    }

    @Test("a restart continuation's echo stays out of the transcript, even in fragments, until the turn ends")
    func continuationEchoIsDropped() {
        let s = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        s.recordInterruptedTurnContinuation()
        let text = QueuedPrompt.interruptedTurnContinueText
        let split = text.index(text.startIndex, offsetBy: 20)

        for fragment in [String(text[..<split]), " ", String(text[split...])] {
            #expect(s.apply(.userMessageChunk(.init(messageId: "user-1", content: .text(fragment)))).isEmpty)
        }
        #expect(s.transcript.messages.count == 1)

        s.endPromptEchoTurn()
        s.apply(.userMessageChunk(.init(messageId: "user-2", content: .text(String(text[..<split])))))
        #expect(s.transcript.messages.count == 2)
    }

    @Test("a steer's echo sharing the continuation's prefix is kept when the continuation was never echoed")
    func steerEchoIsNotTakenForContinuationEcho() {
        let s = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        s.recordInterruptedTurnContinuation()
        s.recordUserPrompt(text: "Your previous answer was wrong", attachments: [])

        s.apply(.userMessageChunk(.init(messageId: "user-1", content: .text("Your previous "))))
        s.apply(.userMessageChunk(.init(messageId: "user-1", content: .text("answer was wrong"))))

        guard case .user(_, _, let text, _, _, _) = s.transcript.messages.last else {
            Issue.record("expected user message")
            return
        }
        #expect(s.transcript.messages.count == 2)
        #expect(text == "Your previous answer was wrong")
    }

    @Test("output after a restart continuation starts a new row instead of extending the interrupted turn's",
          arguments: [true, false])
    func continuationNoticeBoundsLegacyOutput(thought: Bool) {
        let s = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        func chunk(_ text: String) -> ACPSessionUpdate {
            thought ? .agentThoughtChunk(.text(text)) : .agentMessageChunk(.text(text))
        }
        s.recordUserPrompt(text: "migrate", attachments: [])
        s.apply(chunk("before"))
        s.recordInterruptedTurnContinuation()

        s.apply(chunk("after"))

        #expect(s.transcript.messages.count == 4)
    }

    @Test("echoed expansions are expected for the whole turn, steers included, and only an exact resource matches")
    func echoedSymbolExpansionsAreScopedToTheTurn() async {
        let s = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        func expansion(_ name: String) -> [ACPContentBlock] {
            let link = ACPSymbolReference.uri(for: .init(path: "A.swift", name: name, kind: .function,
                                                         container: nil, lineRange: 0...0, includeCode: true))
            return ACPSymbolReference.expansion(
                of: [.resourceLink(uri: link, name: "\(name)()")], sources: ["A.swift": "func \(name)() {}"],
                worktreeRoot: URL(fileURLWithPath: "/tmp/wt"), embeddedContext: true).sentBlocks
        }
        let prompt = expansion("run")
        guard prompt.count == 2,
              case .text(let reference) = prompt[0],
              case .resource(let uri, let mimeType, _) = prompt[1] else {
            Issue.record("expected a reference and embedded code, got \(prompt)")
            return
        }
        s.recordUserPrompt(text: "explain ", attachments: [])
        s.expectSymbolExpansionEchoes(prompt)
        s.expectSymbolExpansionEchoes(expansion("stop"))

        // The prompt's echo arrives after the steer.
        for block in prompt {
            #expect(s.apply(.userMessageChunk(.init(messageId: "user-1", content: block))).isEmpty)
        }
        #expect(s.transcript.messages.count == 1)
        // Same URI, other code: not a block that was sent.
        let edited = ACPContentBlock.resource(uri: uri, mimeType: mimeType, text: "func run() { edited() }")
        #expect(!s.apply(.userMessageChunk(.init(messageId: "user-1", content: .text("kept")))).isEmpty)
        #expect(!s.apply(.userMessageChunk(.init(messageId: "user-1", content: edited))).isEmpty)

        s.endPromptEchoTurn()
        s.apply(.userMessageChunk(.init(messageId: "user-2", content: .text(reference))))
        guard case .user(_, _, let later, _, _, _) = s.transcript.messages.last else {
            Issue.record("expected user message")
            return
        }
        #expect(later == reference)
    }
}
