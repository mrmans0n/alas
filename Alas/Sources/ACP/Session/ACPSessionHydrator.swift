import CryptoKit
import Foundation

/// Off-main hydration of an ACP session's persisted state. Owns its own
/// `SQLiteDatabase` handle on the manager's underlying store path; safe
/// to run concurrently with main-thread writes via SQLite's WAL mode and
/// `SQLITE_OPEN_FULLMUTEX` (set by `SQLiteDatabase.init`).
///
/// Returns a Sendable `HydrationResult`; the caller converts `wireMessages`
/// to `[ACPMessage]` on the main actor (where `StreamingText` can be
/// allocated).
actor ACPSessionHydrator {
    enum Error: Swift.Error, Equatable {
        case sessionNotFound(String)
    }

    private let store: ACPSessionStore
    private let decoder = JSONDecoder()

    init(path: String) throws {
        self.store = try ACPSessionStore(path: path)
    }

#if DEBUG
    private var afterMessagesLoadedForTesting: (@Sendable () throws -> Void)?

    func setAfterMessagesLoadedForTesting(_ callback: (@Sendable () throws -> Void)?) {
        afterMessagesLoadedForTesting = callback
    }
#endif

    func hydrate(sessionId: String) async throws -> HydrationResult {
        var result = try loadSnapshot(sessionId: sessionId, includeDraft: true)
        // Post-load side effect: bump `last_opened_at` so the recents
        // list orders this session to the top. Use the narrow UPDATE
        // helper instead of `upsertSession` — the latter would resurrect
        // a row the user deleted between our `loadSession` read and now,
        // and would also rewrite `archived` back to whatever we captured.
        let now = Int64(Date().timeIntervalSince1970)
        try? store.touchLastOpenedAt(id: sessionId, at: now)
        result = result.replacingRowLastOpenedAt(now)
        return result.replacingRecent((try? store.recentSessions()) ?? [])
    }

    /// Passive refresh snapshot for read-only mirrors. Unlike `hydrate`,
    /// this does not touch `last_opened_at` or restore composer drafts.
    func mirrorSnapshot(sessionId: String) async throws -> HydrationResult {
        try loadSnapshot(sessionId: sessionId, includeDraft: false)
    }

    private func loadSnapshot(sessionId: String, includeDraft: Bool) throws -> HydrationResult {
        // Delivery evidence must not pair a newly persisted queue item with
        // an older transcript when another connection writes during hydration.
        let (row, stored, forkRecord, storedDraft, queue) = try store.db.transaction {
            guard let row = try store.loadSession(id: sessionId) else {
                throw Error.sessionNotFound(sessionId)
            }
            let stored = try store.loadMessages(sessionId: sessionId)
#if DEBUG
            try afterMessagesLoadedForTesting?()
#endif
            let forkRecord = try store.loadFork(targetSessionID: sessionId)
            let storedDraft = includeDraft ? try? store.loadComposerDraftRecord(sessionId: sessionId) : nil
            let queue = (try? store.loadQueue(sessionId: sessionId)) ?? []
            return (row, stored, forkRecord, storedDraft, queue)
        }

        // Malformed message payloads are skipped rather than failing hydration.
        var staleSubmittedDraft = false
        var sawRecordedSubmittedDraft = false
        var messages: [ACPHydratedMessage] = []
        messages.reserveCapacity(stored.count)
        for m in stored {
            if let w = try? ACPMessageWire.decode(kind: m.kind, payload: m.payload, decoder: decoder) {
                let createdAt = Date(timeIntervalSince1970: TimeInterval(m.createdAt))
                messages.append(.init(
                    wire: w,
                    createdAt: createdAt,
                    mirrorFingerprint: .init(
                        payloadDigest: Data(SHA256.hash(data: m.payload)),
                        createdAt: createdAt
                    )
                ))
                if storedDraft != nil,
                   sawRecordedSubmittedDraft,
                   w.isAgentSideProgress {
                    staleSubmittedDraft = true
                }
                if let storedDraft,
                   storedDraft.submittedRecovery,
                   case .user(_, let text, let attachments, _, _) = w,
                   storedDraft.draft.matchesSubmittedRecoveryPrompt(
                    seq: m.seq,
                    text: text,
                    attachments: attachments,
                    queue: queue,
                    submittedAfterSeq: storedDraft.submittedAfterSeq)
                {
                    sawRecordedSubmittedDraft = true
                }
            }
        }

        let draft: ACPComposerDraft?
        var draftAwaitsAgentReply = false
        if staleSubmittedDraft, let storedDraft {
            if (try? store.deleteComposerDraft(sessionId: sessionId, matching: storedDraft)) == true {
                draft = nil
            } else {
                draft = (try? store.loadComposerDraftRecord(sessionId: sessionId))?.draft
            }
        } else {
            draft = storedDraft?.draft
            draftAwaitsAgentReply = sawRecordedSubmittedDraft
        }
        let recent = (try? store.recentSessions()) ?? []
        let deliveredQueuedPromptIDs = QueuedPrompt.deliveredRecordedPromptIDs(
            in: queue, transcript: messages.map(\.wire))

        // Child transcripts, in child-local order. A session that never
        // spawned a subagent reads an empty table and pays one query.
        var subagentMessages: [ACPHydratedSubagentMessage] = []
        for stored in (try? store.loadSubagentMessages(sessionId: sessionId)) ?? [] {
            guard let wire = try? ACPMessageWire.decode(
                kind: stored.kind, payload: stored.payload, decoder: decoder)
            else { continue }
            subagentMessages.append(.init(
                subagentSessionId: stored.subagentSessionId,
                wire: wire,
                createdAt: Date(timeIntervalSince1970: TimeInterval(stored.createdAt)),
                seq: stored.seq))
        }

        return HydrationResult(
            row: row,
            messages: messages,
            queue: queue,
            draft: draft,
            draftAwaitsAgentReply: draftAwaitsAgentReply,
            deliveredQueuedPromptIDs: deliveredQueuedPromptIDs,
            forkRecord: forkRecord,
            recent: recent,
            subagentMessages: subagentMessages)
    }
}

/// Sendable snapshot returned by the hydrator. The main actor unwraps
/// `wireMessages` into full `ACPMessage` values (which contain
/// `StreamingText`, a `@MainActor` class).
struct HydrationResult: Sendable {
    let row: ACPSessionRow
    let messages: [ACPHydratedMessage]
    let queue: [QueuedPrompt]
    let draft: ACPComposerDraft?
    /// `draft` is a submitted prompt already recorded in the transcript with
    /// no agent output after it yet. Kept for recovery, since the agent may
    /// never have received it; the manager drops it once the agent replies.
    let draftAwaitsAgentReply: Bool
    /// Recorded queued prompts the full transcript shows the agent answered.
    let deliveredQueuedPromptIDs: Set<UUID>
    let forkRecord: ACPSessionForkRecord?
    let recent: [ACPSessionRow]
    /// Child transcripts of the session's native subagents, flattened and
    /// tagged with their child session id.
    let subagentMessages: [ACPHydratedSubagentMessage]

    init(
        row: ACPSessionRow,
        messages: [ACPHydratedMessage],
        queue: [QueuedPrompt],
        draft: ACPComposerDraft?,
        draftAwaitsAgentReply: Bool = false,
        deliveredQueuedPromptIDs: Set<UUID> = [],
        forkRecord: ACPSessionForkRecord?,
        recent: [ACPSessionRow],
        subagentMessages: [ACPHydratedSubagentMessage] = []
    ) {
        self.row = row
        self.messages = messages
        self.queue = queue
        self.draft = draft
        self.draftAwaitsAgentReply = draftAwaitsAgentReply
        self.deliveredQueuedPromptIDs = deliveredQueuedPromptIDs
        self.forkRecord = forkRecord
        self.recent = recent
        self.subagentMessages = subagentMessages
    }

    var wireMessages: [ACPMessageWire] { messages.map(\.wire) }

    func replacingRowLastOpenedAt(_ lastOpenedAt: Int64) -> HydrationResult {
        var row = self.row
        row.lastOpenedAt = lastOpenedAt
        return HydrationResult(
            row: row,
            messages: messages,
            queue: queue,
            draft: draft,
            draftAwaitsAgentReply: draftAwaitsAgentReply,
            deliveredQueuedPromptIDs: deliveredQueuedPromptIDs,
            forkRecord: forkRecord,
            recent: recent,
            subagentMessages: subagentMessages)
    }

    func replacingRecent(_ recent: [ACPSessionRow]) -> HydrationResult {
        HydrationResult(
            row: row,
            messages: messages,
            queue: queue,
            draft: draft,
            draftAwaitsAgentReply: draftAwaitsAgentReply,
            deliveredQueuedPromptIDs: deliveredQueuedPromptIDs,
            forkRecord: forkRecord,
            recent: recent,
            subagentMessages: subagentMessages)
    }
}

/// One persisted child-transcript row, decoded into its Sendable wire form.
struct ACPHydratedSubagentMessage: Sendable {
    let subagentSessionId: String
    let wire: ACPMessageWire
    let createdAt: Date
    /// The SQL `seq` this row was stored under. Carried explicitly rather
    /// than inferred from array position: persistence can leave gaps (one
    /// write in a sequence fails while a later one succeeds), and treating
    /// a gappy, compacted array's offsets as durable sequence numbers would
    /// let a later re-persist write a recovered row over an unrelated,
    /// already-stored one.
    let seq: Int64
}

struct ACPMirrorMessageFingerprint: Sendable, Equatable {
    let payloadDigest: Data
    let createdAt: Date
}

struct ACPHydratedMessage: Sendable {
    let wire: ACPMessageWire
    let createdAt: Date
    let mirrorFingerprint: ACPMirrorMessageFingerprint
}
