import Foundation

struct QueuedPrompt: Identifiable, Equatable, Codable, Sendable {
    enum Status: String, Codable, Equatable, Sendable { case pending, sending }
    struct BackgroundTaskWake: Codable, Equatable, Sendable {
        let taskId: String
        let wakeId: UUID
    }

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
    var delegatedSource: ACPDelegatedPromptSource?
    /// The first task remains in the legacy field so older readers continue
    /// to treat a batched notification as internal. New readers use the
    /// explicit members to confirm every task atomically.
    private(set) var backgroundTaskWake: String?
    private var backgroundTaskWakeBatch: [BackgroundTaskWake]?
    var brokerOperationAttempt: Int
    /// How many times the flusher has dispatched this item. Retries can keep
    /// `brokerOperationAttempt`, so this is what tells transcript evidence
    /// from the first dispatch apart from a resend that reused its row.
    var dispatchCount: Int
    /// The broker generation on which this prompt crossed the dispatch
    /// boundary. A later generation cannot tell whether that request
    /// completed, so replay is held for an explicit user decision.
    var dispatchedBrokerGeneration: ACPBrokerGeneration?
    /// True when this prompt may have reached a broker but completion could
    /// not be confirmed. The queue flusher must not resend it automatically.
    var deliveryUncertain: Bool
    /// Set when a connection ending left this prompt's delivery uncertain, and
    /// cleared once an attach has consumed that interruption. Persisted so a
    /// launch can find the session again when an earlier attach failed after
    /// the held prompt was saved. A prompt that was already uncertain when
    /// restored never gets it: that interruption predates this launch.
    var awaitingInterruptionResume: Bool = false
    /// Marks the continuation Alas queues for a turn a restart interrupted, so
    /// launch recovery never mistakes a user's own prompt for it.
    var interruptedTurnContinuation: Bool = false
    /// Set only on the resume item Alas schedules after a usage limit. It
    /// carries the limit so a relaunch restores the session's Limited state.
    var usageLimit: ACPUsageLimit?

    /// Whether the queue UI lists this item. A delegated prompt is hidden
    /// while it waits its turn — it is not the user's to edit or reorder —
    /// but surfaces once a send fails or its delivery is uncertain: the
    /// flusher will not retry it until the user does, so a hidden failed
    /// head would block the whole queue.
    var isShownToUser: Bool {
        (delegatedSource == nil && backgroundTaskWake == nil) || lastError != nil || deliveryUncertain
    }
    var backgroundTaskWakes: [BackgroundTaskWake] {
        if let backgroundTaskWakeBatch, !backgroundTaskWakeBatch.isEmpty {
            return backgroundTaskWakeBatch
        }
        guard let backgroundTaskWake else { return [] }
        return [.init(taskId: backgroundTaskWake, wakeId: id)]
    }

    var canBatchBackgroundTaskWake: Bool {
        backgroundTaskWake != nil && status == .pending && lastError == nil && !deliveryUncertain
    }

    func containsBackgroundTaskWake(taskId: String, wakeId: UUID) -> Bool {
        backgroundTaskWakes.contains { $0.taskId == taskId && $0.wakeId == wakeId }
    }

    func containsBackgroundTaskWake(wakeId: UUID) -> Bool {
        backgroundTaskWakes.contains { $0.wakeId == wakeId }
    }

    mutating func upsertBackgroundTaskWake(taskId: String, wakeId: UUID, block: ACPContentBlock) -> Bool {
        var wakes = backgroundTaskWakes
        if let index = wakes.firstIndex(where: { $0.taskId == taskId && $0.wakeId == wakeId }) {
            guard blocks.indices.contains(index) else { return false }
            blocks[index] = block
        } else {
            guard backgroundTaskWake != nil else { return false }
            wakes.append(.init(taskId: taskId, wakeId: wakeId))
            blocks.append(block)
        }
        setBackgroundTaskWakes(wakes)
        return true
    }

    @discardableResult
    mutating func removeBackgroundTaskWakes(taskIds: Set<String>) -> Bool {
        let wakes = backgroundTaskWakes
        guard wakes.count == blocks.count else { return false }
        let kept = wakes.indices.filter { !taskIds.contains(wakes[$0].taskId) }
        guard kept.count != wakes.count else { return false }
        blocks = kept.map { blocks[$0] }
        setBackgroundTaskWakes(kept.map { wakes[$0] })
        return true
    }

    private mutating func setBackgroundTaskWakes(_ wakes: [BackgroundTaskWake]) {
        backgroundTaskWake = wakes.first?.taskId
        if wakes.count == 1, wakes[0].wakeId == id {
            backgroundTaskWakeBatch = nil
        } else {
            backgroundTaskWakeBatch = wakes.isEmpty ? nil : wakes
        }
    }

    /// Internal task notifications retain their persisted delivery identity.
    /// Failed ones offer Retry/Send now, rather than dropping only the queue half.
    var canRemoveFromQueue: Bool { status == .pending && backgroundTaskWake == nil }

    static let interruptedTurnContinueText =
        "Your previous turn was interrupted because Alas restarted. Continue where you left off."

    /// Shown in the transcript in place of `interruptedTurnContinueText`: the
    /// user never typed the continuation, so it is not rendered as theirs.
    static let interruptedTurnContinueNotice = "Alas restarted mid-turn and asked the agent to continue."

    /// The continuation queued for a turn an app restart interrupted. It is an
    /// ordinary pending row, so launch recovery recognizes it by its flag.
    var isInterruptedTurnContinuation: Bool {
        interruptedTurnContinuation && status == .pending && lastError == nil
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
         backgroundTaskWake: String? = nil,
         transcriptRecorded: Bool = false,
         turnStartedAt: Int64? = nil,
         brokerOperationAttempt: Int = 0,
         dispatchCount: Int = 0,
         dispatchedBrokerGeneration: ACPBrokerGeneration? = nil,
         deliveryUncertain: Bool = false,
         awaitingInterruptionResume: Bool = false,
         interruptedTurnContinuation: Bool = false,
         usageLimit: ACPUsageLimit? = nil) {
        self.id = id
        self.blocks = blocks
        self.enqueuedAt = enqueuedAt
        self.scheduledAt = scheduledAt
        self.status = status
        self.lastError = lastError
        self.draft = draft
        self.delegatedSource = delegatedSource
        self.backgroundTaskWake = backgroundTaskWake
        self.transcriptRecorded = transcriptRecorded
        self.turnStartedAt = turnStartedAt
        self.brokerOperationAttempt = brokerOperationAttempt
        self.dispatchCount = dispatchCount
        self.dispatchedBrokerGeneration = dispatchedBrokerGeneration
        self.deliveryUncertain = deliveryUncertain
        self.awaitingInterruptionResume = awaitingInterruptionResume
        self.interruptedTurnContinuation = interruptedTurnContinuation
        self.usageLimit = usageLimit
    }

    enum CodingKeys: String, CodingKey {
        case id, blocks, enqueuedAt, scheduledAt, status, lastError, draft, delegatedSource, backgroundTaskWake
        case backgroundTaskWakeBatch
        case transcriptRecorded, turnStartedAt, brokerOperationAttempt, dispatchCount, dispatchedBrokerGeneration, deliveryUncertain
        case awaitingInterruptionResume, interruptedTurnContinuation
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
        backgroundTaskWake = try? c.decode(String.self, forKey: .backgroundTaskWake)
        backgroundTaskWakeBatch = try? c.decode([BackgroundTaskWake].self, forKey: .backgroundTaskWakeBatch)
        transcriptRecorded = (try? c.decode(Bool.self, forKey: .transcriptRecorded)) ?? false
        turnStartedAt = try? c.decode(Int64.self, forKey: .turnStartedAt)
        brokerOperationAttempt = (try? c.decode(Int.self, forKey: .brokerOperationAttempt)) ?? 0
        dispatchCount = (try? c.decode(Int.self, forKey: .dispatchCount)) ?? 0
        dispatchedBrokerGeneration = try? c.decode(ACPBrokerGeneration.self, forKey: .dispatchedBrokerGeneration)
        deliveryUncertain = (try? c.decode(Bool.self, forKey: .deliveryUncertain)) ?? false
        awaitingInterruptionResume = (try? c.decode(Bool.self, forKey: .awaitingInterruptionResume)) ?? false
        interruptedTurnContinuation = (try? c.decode(Bool.self, forKey: .interruptedTurnContinuation)) ?? false
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

    /// Recorded items the transcript proves the agent received: the latest
    /// user prompt is theirs and agent output follows it. Only the latest
    /// prompt can be a recorded queue item — nothing else is sent while its
    /// turn runs — so earlier prompts are not considered. A resend reuses the
    /// recorded row, so output after it proves only the first dispatch; items
    /// dispatched more than once are never counted.
    static func deliveredRecordedPromptIDs(
        in queue: [QueuedPrompt],
        transcript: [ACPMessageWire]
    ) -> Set<UUID> {
        deliveredRecordedPromptIDs(in: queue, newestFirst: transcript.reversed().lazy.map {
            if $0.isAgentSideProgress { return .progress }
            if case .systemNotice(text: Self.interruptedTurnContinueNotice) = $0 { return .interruptedTurnContinuation }
            guard case .user(_, let text, let attachments, _, _) = $0 else { return .other }
            return .user(text: text, attachments: attachments)
        })
    }

    /// The same check against the live transcript, which hydration-time
    /// evidence cannot see: output that arrived after hydration.
    static func deliveredRecordedPromptIDs(
        in queue: [QueuedPrompt],
        liveTranscript: [ACPMessage]
    ) -> Set<UUID> {
        deliveredRecordedPromptIDs(in: queue, newestFirst: liveTranscript.reversed().lazy.map {
            if $0.isAgentSideProgress { return .progress }
            if case .systemNotice(_, text: Self.interruptedTurnContinueNotice) = $0 { return .interruptedTurnContinuation }
            guard case .user(_, _, let text, let attachments, _, _) = $0 else { return .other }
            return .user(text: text, attachments: attachments)
        })
    }

    enum TranscriptEntry {
        case progress
        case user(text: String, attachments: [ACPMessage.Attachment])
        /// The notice recorded for a continuation prompt, which stands in for
        /// its user row.
        case interruptedTurnContinuation
        case other
    }

    private static func deliveredRecordedPromptIDs(
        in queue: [QueuedPrompt],
        newestFirst entries: some Sequence<TranscriptEntry>
    ) -> Set<UUID> {
        var answered = false
        for entry in entries {
            switch entry {
            case .progress:
                answered = true
            case .other:
                continue
            case .interruptedTurnContinuation:
                guard answered else { return [] }
                return Set(queue.lazy.filter {
                    $0.interruptedTurnContinuation && $0.transcriptRecorded
                        && $0.dispatchCount <= 1 && $0.brokerOperationAttempt == 0
                }.map(\.id))
            case .user(let text, let attachments):
                guard answered else { return [] }
                return Set(queue.lazy.filter {
                    $0.transcriptRecorded
                        && $0.dispatchCount <= 1
                        && $0.brokerOperationAttempt == 0
                        && $0.restorableDraft.matchesPersistedUserPrompt(text: text, attachments: attachments)
                }.map(\.id))
            }
        }
        return []
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
