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
        guard let row = try store.loadSession(id: sessionId) else {
            throw Error.sessionNotFound(sessionId)
        }

        // Decode every stored message into a Sendable wire variant.
        // Malformed payloads are skipped (matching the legacy try? in
        // openSession) rather than failing the whole hydration.
        let stored = try store.loadMessages(sessionId: sessionId)
        let forkRecord = try store.loadFork(targetSessionID: sessionId)
        let storedDraft = includeDraft ? try? store.loadComposerDraftRecord(sessionId: sessionId) : nil
        let queue = (try? store.loadQueue(sessionId: sessionId)) ?? []
        var staleSubmittedDraft = false
        var sawRecordedSubmittedDraft = false
        var wire: [ACPMessageWire] = []
        wire.reserveCapacity(stored.count)
        for m in stored {
            if let w = try? ACPMessageWire.decode(kind: m.kind, payload: m.payload, decoder: decoder) {
                wire.append(w)
                if storedDraft != nil,
                   sawRecordedSubmittedDraft,
                   w.isAgentSideProgress {
                    staleSubmittedDraft = true
                }
                if let storedDraft,
                   storedDraft.submittedRecovery,
                   case .user(_, let text, let attachments, _) = w,
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
        if staleSubmittedDraft, let storedDraft {
            if (try? store.deleteComposerDraft(sessionId: sessionId, matching: storedDraft)) == true {
                draft = nil
            } else {
                draft = (try? store.loadComposerDraftRecord(sessionId: sessionId))?.draft
            }
        } else {
            draft = storedDraft?.draft
        }
        let recent = (try? store.recentSessions()) ?? []

        return HydrationResult(
            row: row,
            wireMessages: wire,
            queue: queue,
            draft: draft,
            forkRecord: forkRecord,
            recent: recent)
    }
}

/// Sendable snapshot returned by the hydrator. The main actor unwraps
/// `wireMessages` into full `ACPMessage` values (which contain
/// `StreamingText`, a `@MainActor` class).
struct HydrationResult: Sendable {
    let row: ACPSessionRow
    let wireMessages: [ACPMessageWire]
    let queue: [QueuedPrompt]
    let draft: ACPComposerDraft?
    let forkRecord: ACPSessionForkRecord?
    let recent: [ACPSessionRow]

    func replacingRowLastOpenedAt(_ lastOpenedAt: Int64) -> HydrationResult {
        HydrationResult(
            row: ACPSessionRow(
                id: row.id, agentId: row.agentId, title: row.title,
                titleSource: row.titleSource,
                remoteSessionId: row.remoteSessionId,
                origin: row.origin,
                contextRecoveryPending: row.contextRecoveryPending,
                mcpPreamblePending: row.mcpPreamblePending,
                mcpPreambleSent: row.mcpPreambleSent,
                currentModel: row.currentModel, currentMode: row.currentMode,
                autoRun: row.autoRun,
                createdAt: row.createdAt, updatedAt: row.updatedAt,
                lastOpenedAt: lastOpenedAt,
                archived: row.archived),
            wireMessages: wireMessages,
            queue: queue,
            draft: draft,
            forkRecord: forkRecord,
            recent: recent)
    }

    func replacingRecent(_ recent: [ACPSessionRow]) -> HydrationResult {
        HydrationResult(
            row: row,
            wireMessages: wireMessages,
            queue: queue,
            draft: draft,
            forkRecord: forkRecord,
            recent: recent)
    }
}
