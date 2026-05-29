import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ToolCall in-memory truncation")
struct ACPSessionToolCallTruncationTests {
    private func bigContent() -> String { String(repeating: "a", count: 32_768) }

    @Test("setVisibleHead truncates completed tool calls below the new head")
    func truncatesCompleted() {
        let t = ACPTranscript()
        let tc = ACPMessage.ToolCall(
            toolCallId: "tc1", title: "read",
            status: "completed", content: bigContent(),
            preview: "aaa…", locations: [])
        t.messages.append(.toolCall(tc))
        t.messages.append(.systemNotice(id: UUID(), text: "later"))

        t.setVisibleHead(1)

        if case .toolCall(let after) = t.messages[0] {
            #expect(after.content.utf8.count <= ACPMessage.ToolCall.truncatedTailBytes + 64)
            #expect(after.isContentTruncated)
            #expect(after.preview == "aaa…")
        } else {
            Issue.record("expected toolCall at index 0")
        }
    }

    @Test("setVisibleHead does NOT truncate in-progress or pending tool calls")
    func skipsLive() {
        let t = ACPTranscript()
        let live = ACPMessage.ToolCall(
            toolCallId: "tc1", title: "run",
            status: "in_progress", content: bigContent(),
            preview: "…", locations: [])
        let pending = ACPMessage.ToolCall(
            toolCallId: "tc2", title: "run",
            status: "pending", content: bigContent(),
            preview: "…", locations: [])
        t.messages.append(.toolCall(live))
        t.messages.append(.toolCall(pending))
        t.messages.append(.systemNotice(id: UUID(), text: "tail"))

        t.setVisibleHead(2)

        if case .toolCall(let liveAfter) = t.messages[0] {
            #expect(liveAfter.content.utf8.count == 32_768)
            #expect(!liveAfter.isContentTruncated)
        } else { Issue.record("expected toolCall live") }
        if case .toolCall(let pendingAfter) = t.messages[1] {
            #expect(pendingAfter.content.utf8.count == 32_768)
            #expect(!pendingAfter.isContentTruncated)
        } else { Issue.record("expected toolCall pending") }
    }

    @Test("truncate() keeps the first truncatedTailBytes (character-wise) and sets the flag")
    func truncateMethod() {
        var tc = ACPMessage.ToolCall(
            toolCallId: "x", title: "t",
            status: "completed", content: String(repeating: "x", count: 100_000),
            preview: "x…", locations: [])
        tc.truncateForOffWindow()
        // We truncate by character count; for ASCII this equals byte count.
        #expect(tc.content.count == ACPMessage.ToolCall.truncatedTailBytes)
        #expect(tc.isContentTruncated)
    }

    @Test("two ToolCalls are equal even if one has been truncated")
    func equalityIgnoresTruncationFlag() {
        let original = ACPMessage.ToolCall(
            toolCallId: "tc1", title: "read",
            status: "completed", content: "0123456789",
            preview: "0…", locations: [])
        var truncated = original
        // Force the flag without changing content (or use the API and then put content back)
        truncated.truncateForOffWindow()
        // Re-equalize content so only the flag differs:
        truncated.content = "0123456789"
        #expect(original == truncated)
        #expect(original.hashValue == truncated.hashValue)
    }

    @Test("two ToolCalls remain unequal if content differs (truncated or not)")
    func contentStillDistinguishesEquality() {
        let a = ACPMessage.ToolCall(
            toolCallId: "tc1", title: "read",
            status: "completed", content: "abc",
            preview: "a", locations: [])
        let b = ACPMessage.ToolCall(
            toolCallId: "tc1", title: "read",
            status: "completed", content: "xyz",
            preview: "a", locations: [])
        #expect(a != b)
    }
}
