import Testing
@testable import Alas

@Suite("ACPContextCompaction presentation")
struct ACPContextCompactionPresentationTests {
    @Test("accepts documented version 1 facts and ignores unknown metadata")
    func documentedFactsOnly() {
        let compaction = ACPContextCompaction(toolCall: .init(
            toolCallId: "context-compaction:compact-1",
            title: "Compacting context",
            kind: "context_compaction",
            status: "completed",
            metadata: AnyCodable([
                "contextCompaction": [
                    "version": 1,
                    "trigger": "manual",
                    "preTokens": 128_000,
                    "postTokens": 16_000,
                    "durationMs": 950,
                    "unknown": "ignored"
                ]
            ])))

        #expect(compaction?.status == .completed)
        #expect(compaction?.trigger == "manual")
        #expect(compaction?.tokensBefore == 128_000)
        #expect(compaction?.tokensAfter == 16_000)
        #expect(compaction?.durationMs == 950)
        #expect(compaction?.label == "Context compacted")
        #expect(compaction?.details == "manual · 128000 → 16000 tokens · 950 ms")
    }

    @Test("failed compactions retain their error without inventing counts")
    func failedCompaction() {
        let compaction = ACPContextCompaction(toolCall: .init(
            toolCallId: "context-compaction:compact-failed",
            title: "Compacting context",
            kind: "context_compaction",
            status: "failed",
            metadata: AnyCodable([
                "contextCompaction": [
                    "version": 1,
                    "error": "Context limit exceeded"
                ]
            ])))

        #expect(compaction?.status == .failed)
        #expect(compaction?.error == "Context limit exceeded")
        #expect(compaction?.tokensBefore == nil)
        #expect(compaction?.tokensAfter == nil)
        #expect(compaction?.durationMs == nil)
        #expect(compaction?.label == "Context compaction failed")
    }

    @Test("ordinary tool calls are not context compactions")
    func ordinaryToolCall() {
        #expect(ACPContextCompaction(toolCall: .init(
            toolCallId: "run-1", title: "Run tests", kind: "execute", status: "completed"
        )) == nil)
    }
}
