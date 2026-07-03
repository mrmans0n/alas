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
        if case .user(_, _, let text, let attachments) = s.transcript.messages[0] {
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
        if case .user(_, let messageId, let text, let attachments) = s.transcript.messages[0] {
            #expect(messageId == "user-1")
            #expect(text == "")
            #expect(attachments == [
                ACPMessage.Attachment(uri: "file:///tmp/example.swift", name: "example.swift")
            ])
        } else {
            Issue.record("expected user message")
        }
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
        if case .user(_, let messageId, let text, let attachments) = s.transcript.messages[0] {
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
        if case .user(_, let messageId, let text, let attachments) = s.transcript.messages[0] {
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
        if case .user(_, let messageId, let text, let attachments) = s.transcript.messages[0] {
            #expect(messageId == "user-1")
            #expect(text == "")
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
        if case .user(_, let messageId, let text, let attachments) = s.transcript.messages[0] {
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
        if case .user(_, let messageId, let text, let attachments) = s.transcript.messages[0] {
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
        if case .user(_, let messageId, let text, _) = s.transcript.messages[0] {
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
        if case .user(_, let messageId, let text, _) = s.transcript.messages[0] {
            #expect(messageId == nil)
            #expect(text == "hello world")
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
}
