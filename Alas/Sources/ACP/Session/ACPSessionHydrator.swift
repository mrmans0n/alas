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
        guard let row = try store.loadSession(id: sessionId) else {
            throw Error.sessionNotFound(sessionId)
        }

        // Decode every stored message into a Sendable wire variant.
        // Malformed payloads are skipped (matching the legacy try? in
        // openSession) rather than failing the whole hydration.
        let stored = try store.loadMessages(sessionId: sessionId)
        var wire: [ACPMessageWire] = []
        wire.reserveCapacity(stored.count)
        for m in stored {
            if let w = try? ACPMessageWire.decode(kind: m.kind, payload: m.payload, decoder: decoder) {
                wire.append(w)
            }
        }

        let queue = (try? store.loadQueue(sessionId: sessionId)) ?? []
        let draft = try? store.loadComposerDraft(sessionId: sessionId)

        // Post-load side effect: bump `last_opened_at` so the recents
        // list orders this session to the top. Use the narrow UPDATE
        // helper instead of `upsertSession` — the latter would resurrect
        // a row the user deleted between our `loadSession` read and now,
        // and would also rewrite `archived` back to whatever we captured.
        let now = Int64(Date().timeIntervalSince1970)
        try? store.touchLastOpenedAt(id: sessionId, at: now)
        let touched = ACPSessionRow(
            id: row.id, agentId: row.agentId, title: row.title,
            currentModel: row.currentModel, currentMode: row.currentMode,
            autoRun: row.autoRun,
            createdAt: row.createdAt, updatedAt: row.updatedAt,
            lastOpenedAt: now,
            archived: row.archived)
        let recent = (try? store.recentSessions()) ?? []

        return HydrationResult(
            row: touched,
            wireMessages: wire,
            queue: queue,
            draft: draft,
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
    let recent: [ACPSessionRow]
}
