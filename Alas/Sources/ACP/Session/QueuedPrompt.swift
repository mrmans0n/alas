import Foundation

struct QueuedPrompt: Identifiable, Equatable, Codable, Sendable {
    enum Status: String, Codable, Equatable, Sendable { case pending, sending }

    let id: UUID
    var blocks: [ACPContentBlock]
    let enqueuedAt: Date
    var status: Status
    var lastError: String?
    /// Set the first time `sendNow` dispatches this item: the user prompt
    /// has been appended to the transcript. Retries (after `lastError`)
    /// don't re-record it, so the message list doesn't grow a duplicate
    /// user bubble per retry. Persisted so a relaunch-mid-attempt
    /// doesn't double-record either.
    var transcriptRecorded: Bool
    /// Structured composer state captured at enqueue time, so editing a
    /// queued prompt restores the EXACT original draft instead of inverting
    /// the lossy `blocks` serialization. `nil` for block-only origins
    /// (items persisted before this field existed, recovery-path enqueues,
    /// rolled-back direct sends) — those fall back to the heuristic via
    /// `restorableDraft`. Not sent to the agent; `blocks` remains the wire form.
    var draft: ACPComposerDraft?
    /// Present only for prompts delivered by a direct delegated-session edge.
    /// It is intentionally omitted from ordinary prompt JSON for compatibility.
    let delegatedSource: ACPDelegatedPromptSource?
    var brokerOperationAttempt: Int

    init(id: UUID = UUID(),
         blocks: [ACPContentBlock],
         enqueuedAt: Date = Date(),
         status: Status = .pending,
         lastError: String? = nil,
         draft: ACPComposerDraft? = nil,
         delegatedSource: ACPDelegatedPromptSource? = nil,
         transcriptRecorded: Bool = false,
         brokerOperationAttempt: Int = 0)
    {
        self.id = id
        self.blocks = blocks
        self.enqueuedAt = enqueuedAt
        self.status = status
        self.lastError = lastError
        self.draft = draft
        self.delegatedSource = delegatedSource
        self.transcriptRecorded = transcriptRecorded
        self.brokerOperationAttempt = brokerOperationAttempt
    }

    enum CodingKeys: String, CodingKey {
        case id, blocks, enqueuedAt, status, lastError, draft, delegatedSource, transcriptRecorded, brokerOperationAttempt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        blocks = try c.decode([ACPContentBlock].self, forKey: .blocks)
        enqueuedAt = try c.decode(Date.self, forKey: .enqueuedAt)
        status = try c.decode(Status.self, forKey: .status)
        lastError = try? c.decode(String.self, forKey: .lastError)
        draft = try? c.decode(ACPComposerDraft.self, forKey: .draft)
        delegatedSource = try? c.decode(ACPDelegatedPromptSource.self, forKey: .delegatedSource)
        transcriptRecorded = (try? c.decode(Bool.self, forKey: .transcriptRecorded)) ?? false
        brokerOperationAttempt = (try? c.decode(Int.self, forKey: .brokerOperationAttempt)) ?? 0
    }

    /// Used by the persistence decoder: any item that was mid-send when
    /// the app exited gets reset to `.pending` so the next flusher run
    /// re-attempts the prompt. `lastError` is preserved so a previously
    /// failed item that the user hasn't acked stays visibly errored.
    func normalizedAfterRestore() -> QueuedPrompt {
        guard status == .sending else { return self }
        var copy = self
        copy.status = .pending
        return copy
    }

    /// The draft to load back into the composer when this item is edited:
    /// the structured `draft` when captured, otherwise the heuristic inverse
    /// of `blocks`. See the `draft` field for why the fallback is lossy.
    var restorableDraft: ACPComposerDraft {
        draft ?? ACPComposerDraft(blocks: blocks)
    }

    var brokerOperationKey: String {
        "queued-prompt:\(id.uuidString):\(brokerOperationAttempt):session/prompt"
    }

    mutating func advanceBrokerOperationAttempt() {
        brokerOperationAttempt += 1
    }
}
