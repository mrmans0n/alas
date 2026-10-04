import Foundation

struct QueuedPrompt: Identifiable, Equatable, Codable, Sendable {
    enum Status: String, Codable, Equatable, Sendable { case pending, sending }

    let id: UUID
    var blocks: [ACPContentBlock]
    /// Reset to now when the user forces a held item out (`forceQueueItem`),
    /// so it stops counting as queued before a usage limit.
    var enqueuedAt: Date
    var scheduledAt: Date?
    var status: Status
    var lastError: String?
    /// Set the first time `sendNow` dispatches this item: the user prompt
    /// has been appended to the transcript. Retries (after `lastError`)
    /// don't re-record it, so the message list doesn't grow a duplicate
    /// user bubble per retry. Persisted so a relaunch-mid-attempt
    /// doesn't double-record either.
    var transcriptRecorded: Bool
    /// Epoch milliseconds at which the turn for this item started, captured
    /// with `transcriptRecorded`. A resend of the same prompt (a relaunch
    /// re-attaching to a broker that kept the turn running) reports this as
    /// the turn's start instead of the resend time, so a delegated child's
    /// report made mid-turn is still seen as covering it.
    var turnStartedAt: Int64?
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
    /// The broker generation on which this prompt crossed the dispatch
    /// boundary. A later generation cannot tell whether that request
    /// completed, so replay is held for an explicit user decision.
    var dispatchedBrokerGeneration: ACPBrokerGeneration?
    /// True when this prompt may have reached a broker but completion could
    /// not be confirmed. The queue flusher must not resend it automatically.
    var deliveryUncertain: Bool
    /// Set only on the resume item Alas schedules after a usage limit. It
    /// carries the limit so a relaunch restores the session's Limited state.
    var usageLimit: ACPUsageLimit?

    /// Whether the queue UI lists this item. A delegated prompt is hidden
    /// while it waits its turn — it is not the user's to edit or reorder —
    /// but surfaces once a send fails or its delivery is uncertain: the
    /// flusher will not retry it until the user does, so a hidden failed
    /// head would block the whole queue.
    var isShownToUser: Bool {
        delegatedSource == nil || lastError != nil || deliveryUncertain
    }

    static let deliveryUncertaintyMessage =
        "Delivery is uncertain because the previous connection ended before confirming this prompt. Retry to send it again."

    init(id: UUID = UUID(),
         blocks: [ACPContentBlock],
         enqueuedAt: Date = Date(),
         scheduledAt: Date? = nil,
         status: Status = .pending,
         lastError: String? = nil,
         draft: ACPComposerDraft? = nil,
         delegatedSource: ACPDelegatedPromptSource? = nil,
         transcriptRecorded: Bool = false,
         turnStartedAt: Int64? = nil,
         brokerOperationAttempt: Int = 0,
         dispatchedBrokerGeneration: ACPBrokerGeneration? = nil,
         deliveryUncertain: Bool = false,
         usageLimit: ACPUsageLimit? = nil)
    {
        self.id = id
        self.blocks = blocks
        self.enqueuedAt = enqueuedAt
        self.scheduledAt = scheduledAt
        self.status = status
        self.lastError = lastError
        self.draft = draft
        self.delegatedSource = delegatedSource
        self.transcriptRecorded = transcriptRecorded
        self.turnStartedAt = turnStartedAt
        self.brokerOperationAttempt = brokerOperationAttempt
        self.dispatchedBrokerGeneration = dispatchedBrokerGeneration
        self.deliveryUncertain = deliveryUncertain
        self.usageLimit = usageLimit
    }

    enum CodingKeys: String, CodingKey {
        case id, blocks, enqueuedAt, scheduledAt, status, lastError, draft, delegatedSource
        case transcriptRecorded, turnStartedAt, brokerOperationAttempt, dispatchedBrokerGeneration, deliveryUncertain
        case usageLimit
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        blocks = try c.decode([ACPContentBlock].self, forKey: .blocks)
        enqueuedAt = try c.decode(Date.self, forKey: .enqueuedAt)
        scheduledAt = try? c.decode(Date.self, forKey: .scheduledAt)
        status = try c.decode(Status.self, forKey: .status)
        lastError = try? c.decode(String.self, forKey: .lastError)
        draft = try? c.decode(ACPComposerDraft.self, forKey: .draft)
        delegatedSource = try? c.decode(ACPDelegatedPromptSource.self, forKey: .delegatedSource)
        transcriptRecorded = (try? c.decode(Bool.self, forKey: .transcriptRecorded)) ?? false
        turnStartedAt = try? c.decode(Int64.self, forKey: .turnStartedAt)
        brokerOperationAttempt = (try? c.decode(Int.self, forKey: .brokerOperationAttempt)) ?? 0
        dispatchedBrokerGeneration = try? c.decode(ACPBrokerGeneration.self, forKey: .dispatchedBrokerGeneration)
        deliveryUncertain = (try? c.decode(Bool.self, forKey: .deliveryUncertain)) ?? false
        usageLimit = try? c.decode(ACPUsageLimit.self, forKey: .usageLimit)
        if deliveryUncertain, lastError == nil {
            lastError = Self.deliveryUncertaintyMessage
        }
    }

    /// Used by the persistence decoder: any item that was mid-send when
    /// the app exited gets reset to `.pending` so the next flusher run
    /// re-attempts the prompt. `lastError` is preserved so a previously
    /// failed item that the user hasn't acked stays visibly errored.
    func normalizedAfterRestore(markLegacySendingUncertain: Bool = true) -> QueuedPrompt {
        guard status == .sending else { return self }
        var copy = self
        copy.status = .pending
        if markLegacySendingUncertain, copy.dispatchedBrokerGeneration == nil {
            copy.markDeliveryUncertain()
        }
        return copy
    }

    mutating func markDeliveryUncertain() {
        deliveryUncertain = true
        if lastError == nil {
            lastError = Self.deliveryUncertaintyMessage
        }
    }

    /// Whether a usage limit holds this item back from the flusher: it was
    /// queued at or before `limit` last stopped the session, and is not the
    /// resume item itself. Held items wait until the Limited state clears.
    func isHeld(by limit: ACPUsageLimit?) -> Bool {
        guard let limit, usageLimit == nil else { return false }
        return enqueuedAt <= limit.holdCutoff
    }

    func isReady(at date: Date = Date()) -> Bool {
        scheduledAt.map { $0 <= date } ?? true
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

    var steeringBrokerOperationKey: String {
        "queued-prompt:\(id.uuidString):\(brokerOperationAttempt):_session/steering"
    }

    mutating func advanceBrokerOperationAttempt() {
        brokerOperationAttempt += 1
    }
}
