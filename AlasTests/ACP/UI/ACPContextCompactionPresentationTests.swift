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

    @MainActor
    @Test("a completed compaction with no summary and no summary chunk renders without one")
    func completedCompactionWithoutSummaryDoesNotCrash() {
        // Codex 1.13 emits a standard compaction_update with status
        // "completed" but no `summary` field and no compaction_summary_chunk
        // at all — confirm the session applies it cleanly and the resulting
        // tool call still reports completed with no content synthesized.
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        let update = ACPCompactionUpdate(compactionId: "compact-1", status: "completed")
        #expect(update.summaryWasProvided == false)

        session.apply(.compactionUpdate(update))

        let toolCallId = "context-compaction:compact-1"
        guard let index = session.transcript.toolCallIndex(toolCallId: toolCallId),
              case .toolCall(let toolCall) = session.transcript.messages[index] else {
            Issue.record("expected a persisted context-compaction tool call")
            return
        }
        #expect(toolCall.status == "completed")
        #expect(toolCall.content.isEmpty)
        let compaction = ACPContextCompaction(toolCall: toolCall)
        #expect(compaction?.status == .completed)
    }

    @Test("ordinary tool calls are not context compactions")
    func ordinaryToolCall() {
        #expect(ACPContextCompaction(toolCall: .init(
            toolCallId: "run-1", title: "Run tests", kind: "execute", status: "completed"
        )) == nil)
    }
}
