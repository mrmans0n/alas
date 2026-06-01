import Foundation

@MainActor
final class ACPSessionManager: ObservableObject {
    typealias ACPSetupEvaluator = @MainActor (_ spec: ACPLaunchSpec) async -> ACPSetupResult
    typealias ACPConnectionFactory = @MainActor (_ spec: ACPLaunchSpec) throws -> ACPConnection

    let worktreeId: String
    let worktreePath: String
    let store: ACPSessionStore
    /// Called by each runner's write handler to check whether the target path
    /// has an open, dirty editor buffer. `nil` disables the check (no notices).
    let onDirtyCheck: ((String) -> Bool)?
    /// Read the in-memory editor contents for the absolute `path` when an
    /// open dirty buffer exists. Returns nil for clean/un-opened files;
    /// the runner falls back to disk in that case. Lets agent reads see
    /// the user's unsaved edits rather than stale disk bytes.
    let onLiveBufferRead: ((String) -> String?)?
    @Published private(set) var sessions: [ACPSession.ID: ACPSession] = [:]
    @Published private(set) var recent: [ACPSessionRow] = []
    private(set) var runners: [ACPSession.ID: ACPSessionRunner] = [:]
    #if DEBUG
    /// Number of attached runners. Public-but-namespaced read accessor for
    /// `MemoryDiagnostics`; we don't expose the runner instances themselves.
    var runnerCountForDiagnostics: Int { runners.count }
    #endif
    /// Per-session debounced write tasks for `composer_drafts`. The
    /// in-memory `session.composerDraft` updates on every keystroke;
    /// the SQLite write only fires after a brief idle (or a forced
    /// flush on submit / delete). Cancelled and re-scheduled on each
    /// further keystroke so a typing burst produces one write.
    private var pendingDraftWrites: [ACPSession.ID: Task<Void, Never>] = [:]
    private static let draftDebounceNanos: UInt64 = 300_000_000
    private let hydrator: ACPSessionHydrator?
    private let setupEvaluator: ACPSetupEvaluator
    private let connectionFactory: ACPConnectionFactory
    private var inFlightHydrations: [ACPSession.ID: Task<Void, Never>] = [:]
    /// Per-session task that prepends pre-tail messages after the initial
    /// tail-only paint applied by `applyHydration`. Tracked so tests (and
    /// teardown) can wait for it; production UI does not.
    private var inFlightBackfills: [ACPSession.ID: Task<Void, Never>] = [:]

    /// Per-session UI refcount. When this drops to zero AND the session is
    /// not `attached`, the cached `ACPSession` is evicted from `sessions`.
    /// Re-opening through `placeholderSession` + `hydrateIfNeeded` recreates
    /// it cleanly from SQLite.
    private var sessionRefCounts: [ACPSession.ID: Int] = [:]

    init(worktreeId: String, worktreePath: String, store: ACPSessionStore,
         hydratorPath: String? = nil,
         onDirtyCheck: ((String) -> Bool)? = nil,
         onLiveBufferRead: ((String) -> String?)? = nil,
         setupEvaluator: ACPSetupEvaluator? = nil,
         connectionFactory: ACPConnectionFactory? = nil)
    {
        self.worktreeId = worktreeId
        self.worktreePath = worktreePath
        self.store = store
        self.onDirtyCheck = onDirtyCheck
        self.onLiveBufferRead = onLiveBufferRead
        self.hydrator = hydratorPath.flatMap { try? ACPSessionHydrator(path: $0) }
        self.setupEvaluator = setupEvaluator ?? { spec in
            let checker = ACPSetupChecker(env: ProcessInfo.processInfo.environment)
            return await checker.evaluate(spec.setupCheck)
        }
        self.connectionFactory = connectionFactory ?? { spec in
            let client: ACPStdioClient
            if spec.command.hasPrefix("/") {
                client = try ACPStdioClient(
                    executable: URL(fileURLWithPath: spec.command),
                    arguments: spec.arguments,
                    environment: Self.mergeEnv(extra: spec.extraEnv))
            } else {
                client = try ACPStdioClient(
                    executable: URL(fileURLWithPath: "/usr/bin/env"),
                    arguments: [spec.command] + spec.arguments,
                    environment: Self.mergeEnv(extra: spec.extraEnv))
            }
            try client.start()
            return ACPConnection(client: client)
        }
        self.recent = (try? store.recentSessions()) ?? []
    }

    func createSession(agentId: String) -> ACPSession {
        let id = UUID().uuidString
        let now = Int64(Date().timeIntervalSince1970)
        let row = ACPSessionRow(
            id: id, agentId: agentId, title: "New session",
            titleSource: .placeholder,
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: now, updatedAt: now, lastOpenedAt: now, archived: false)
        try? store.upsertSession(row)
        let session = ACPSession(
            id: id, agentId: agentId, worktreeId: worktreeId,
            title: row.title, titleSource: .placeholder, hydrationState: .ready)
        sessions[id] = session
        refreshRecent()
        return session
    }

    /// Returns a cached session or a `.loading` placeholder. Cache hits
    /// are O(1); cache misses do a single indexed `loadSession` query
    /// against SQLite so we don't insert orphan loading entries for
    /// typo'd ids. The heavy work (loading every message, decoding,
    /// reading the queue + draft) is deferred to `hydrateIfNeeded`.
    func placeholderSession(id: ACPSession.ID) -> ACPSession? {
        if let s = sessions[id] { return s }
        // Verify the session exists before allocating a placeholder so we
        // don't insert orphan loading entries for typo'd ids.
        guard let row = try? store.loadSession(id: id) else { return nil }
        let session = ACPSession(
            id: row.id, agentId: row.agentId, worktreeId: worktreeId,
            title: row.title, titleSource: row.titleSource, hydrationState: .loading,
            restoredFromPersistence: true)
        session.remoteSessionId = row.remoteSessionId
        sessions[id] = session
        return session
    }

    /// Awaits any in-flight background backfill of older transcript messages
    /// for `id`. After `hydrateIfNeeded` returns, only the tail window has
    /// been applied to the transcript so the UI can paint immediately; the
    /// rest is prepended on a separate task. Production callers rarely need
    /// to wait for it (the UI is happy with the tail), but tests use this to
    /// observe the fully-materialised transcript.
    func awaitBackfill(id: ACPSession.ID) async {
        if let task = inFlightBackfills[id] { await task.value }
    }

    /// Drives a session from `.loading` to `.ready` (or `.failed`). Safe to
    /// call multiple times concurrently — duplicate callers await the same
    /// in-flight task. No-op when the session is already `.ready` or
    /// `.failed`.
    func hydrateIfNeeded(id: ACPSession.ID) async {
        guard let session = sessions[id] else { return }
        guard session.hydrationState == .loading else { return }
        if let existing = inFlightHydrations[id] {
            await existing.value
            // The in-flight task captured an earlier session instance; if
            // it was closed + reopened while we awaited, the new placeholder
            // (still `.loading`) needs its own hydration pass. Recurse once
            // so the visible session reaches `.ready`. The guards at the
            // top prevent runaway recursion — they'll see the just-applied
            // `.ready` from a happy-path completion and exit. The task body
            // clears `inFlightHydrations[id]` before returning, so the
            // recursive call won't re-await the completed task.
            await hydrateIfNeeded(id: id)
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runHydration(id: id, session: session)
            // Clear the map from inside the task body so any waiter that
            // resumes from `await existing.value` observes a clean slate
            // and can spawn a fresh hydration for a reopened placeholder
            // rather than re-awaiting this completed task.
            self.inFlightHydrations[id] = nil
        }
        inFlightHydrations[id] = task
        await task.value
    }

    private func runHydration(id: ACPSession.ID, session: ACPSession) async {
        do {
            let result: HydrationResult
            if let hydrator {
                result = try await hydrator.hydrate(sessionId: id)
            } else {
                // No off-main hydrator (test fallback): perform the same
                // work synchronously via the manager's store.
                result = try synchronousHydrate(id: id)
            }
            // Drop the result if the captured session was closed (or closed
            // and reopened — the cached entry now points to a different
            // ACPSession instance) while we awaited. The fresh placeholder
            // will be hydrated by the recursive call in `hydrateIfNeeded`.
            guard sessions[id] === session else { return }
            applyHydration(result, to: session)
        } catch {
            guard sessions[id] === session else { return }
            session.hydrationState = .failed(error.localizedDescription)
        }
    }

    /// Synchronous hydration fallback used when no hydrator was wired in
    /// (tests that construct the manager without a path). Same data, same
    /// shape — just on the main thread.
    private func synchronousHydrate(id: ACPSession.ID) throws -> HydrationResult {
        guard let row = try store.loadSession(id: id) else {
            throw ACPSessionHydrator.Error.sessionNotFound(id)
        }
        let stored = (try? store.loadMessages(sessionId: id)) ?? []
        var wire: [ACPMessageWire] = []
        wire.reserveCapacity(stored.count)
        let decoder = JSONDecoder()
        for m in stored {
            if let w = try? ACPMessageWire.decode(kind: m.kind, payload: m.payload, decoder: decoder) {
                wire.append(w)
            }
        }
        let queue = (try? store.loadQueue(sessionId: id)) ?? []
        let draft = try? store.loadComposerDraft(sessionId: id)
        let now = Int64(Date().timeIntervalSince1970)
        try? store.touchLastOpenedAt(id: id, at: now)
        let touched = ACPSessionRow(
            id: row.id, agentId: row.agentId, title: row.title,
            titleSource: row.titleSource,
            remoteSessionId: row.remoteSessionId,
            contextRecoveryPending: row.contextRecoveryPending,
            currentModel: row.currentModel, currentMode: row.currentMode,
            autoRun: row.autoRun,
            createdAt: row.createdAt, updatedAt: row.updatedAt,
            lastOpenedAt: now,
            archived: row.archived)
        let recent = (try? store.recentSessions()) ?? []
        return HydrationResult(row: touched, wireMessages: wire,
                               queue: queue, draft: draft, recent: recent)
    }

    private func applyHydration(_ result: HydrationResult, to session: ACPSession) {
        // Tail-first hydration: a long transcript would otherwise force an
        // O(N) main-actor pass to wrap every wire message in `StreamingText`
        // (a `@MainActor` class) before the first paint can land, freezing
        // the UI on every tab switch into a session with hundreds of stored
        // messages. We instead apply only the messages SwiftUI will draw on
        // first paint — the tail window — and prepend the rest from a
        // background task once the tab has painted.
        //
        // The visible window is intentionally placed at index 0 of the
        // initial array (rather than the natural `count - tailWindow`
        // offset) so the tail array IS the visible window. When backfill
        // later prepends the older entries, `visibleHead` is shifted by
        // the prepended count so the same tail messages stay on screen
        // without a layout jump.
        let wires = result.wireMessages
        let total = wires.count
        let tailWindow = ACPTranscript.tailWindow
        let tailStart = max(0, total - tailWindow)

        var tail: [ACPMessage] = []
        tail.reserveCapacity(total - tailStart)
        for i in tailStart..<total {
            tail.append(wires[i].toMessage())
        }
        session.replaceTranscriptMessages(tail)
        session.transcript.visibleHead = 0
        session.restoreQueue(result.queue)
        // The composer is rendered (and focused) the moment the placeholder
        // appears, so the user can start typing before hydration finishes.
        // Only restore the persisted draft when the live composer is still
        // pristine (revision == 0); an intentional clear still bumps the
        // revision, so it's distinguishable from "never edited" even though
        // both leave `composerDraft.isEmpty == true`.
        if let draft = result.draft, session.composerDraftRevision == 0 {
            session.replaceComposerDraft(draft)
        }
        session.currentModel = result.row.currentModel
        session.currentMode = result.row.currentMode
        if session.remoteSessionId == nil || session.remoteSessionId == result.row.remoteSessionId {
            session.remoteSessionId = result.row.remoteSessionId
        }
        if result.row.contextRecoveryPending {
            session.contextRestoreWarning = .init(
                message: "Agent context could not be restored.",
                canSendTranscript: session.hasConversationTranscript
            )
        }
        session.autoRunEnabled = result.row.autoRun
        // Title intentionally NOT overwritten: `placeholderSession` already
        // seeded it from the same row, and a rename made through the
        // toolbar during the hydration window should win against the value
        // we captured before the user typed it.
        session.hydrationState = .ready
        self.recent = result.recent
        scheduleBackfillIfNeeded(olderWires: Array(wires.prefix(tailStart)),
                                 sessionId: session.id, session: session)
    }

    /// Materialise the pre-tail messages on a follow-up task. The task
    /// converts wires to `ACPMessage`s in chunks, yielding between batches
    /// so SwiftUI gets cycles to lay out the just-painted tail and respond
    /// to user input. When the conversion is done it prepends them all in
    /// one transcript mutation — incremental prepends would re-render the
    /// list once per batch for no visible benefit (the older messages are
    /// hidden behind `visibleHead`).
    ///
    /// Bail out if the cached session for `sessionId` no longer points at
    /// the same instance: the user closed-then-reopened the tab and the
    /// fresh placeholder will run its own hydration.
    private func scheduleBackfillIfNeeded(
        olderWires: [ACPMessageWire],
        sessionId: ACPSession.ID,
        session: ACPSession
    ) {
        // Replace any prior pending backfill for this id — a re-hydration
        // (close + reopen) supersedes an older run.
        inFlightBackfills[sessionId]?.cancel()
        inFlightBackfills[sessionId] = nil

        guard !olderWires.isEmpty else { return }

        let task = Task { @MainActor [weak self, weak session] in
            defer { self?.inFlightBackfills[sessionId] = nil }
            // Yield once so the tail paint reaches the screen before we
            // start allocating older messages on the main actor.
            await Task.yield()
            guard !Task.isCancelled else { return }

            var older: [ACPMessage] = []
            older.reserveCapacity(olderWires.count)
            let batchSize = 100
            var index = 0
            while index < olderWires.count {
                let end = min(index + batchSize, olderWires.count)
                for i in index..<end {
                    older.append(olderWires[i].toMessage())
                }
                index = end
                if index < olderWires.count {
                    await Task.yield()
                    if Task.isCancelled { return }
                }
            }
            guard let self, let session,
                  self.sessions[sessionId] === session
            else { return }
            session.prependTranscriptMessages(older)
        }
        inFlightBackfills[sessionId] = task
    }

    func closeSession(id: ACPSession.ID) {
        // Flush any pending draft write before dropping the in-memory
        // session reference — otherwise a tab-switch-while-typing
        // window can lose the last ~300ms of input.
        flushPendingDraftWrite(for: id)
        inFlightBackfills[id]?.cancel()
        inFlightBackfills[id] = nil
        sessions[id]?.transcript.resetMarkdownCaches()
        sessions[id] = nil
        sessionRefCounts.removeValue(forKey: id)
    }

    func deleteSession(id: ACPSession.ID) {
        cancelPendingDraftWrite(for: id)
        inFlightBackfills[id]?.cancel()
        inFlightBackfills[id] = nil
        sessions[id]?.transcript.resetMarkdownCaches()
        sessions[id] = nil
        sessionRefCounts.removeValue(forKey: id)
        try? store.deleteSession(id: id)
        refreshRecent()
    }

    /// Increment the UI refcount for `id`. No-op if the session isn't
    /// currently cached (e.g. typo'd id, or already evicted by a prior
    /// release). Callers must pair every retain with exactly one release.
    func retainSession(id: ACPSession.ID) {
        guard sessions[id] != nil else { return }
        sessionRefCounts[id, default: 0] += 1
    }

    /// Decrement the UI refcount for `id`. When it reaches zero AND the
    /// session is not `attached`, the cached `ACPSession` is evicted
    /// (markdown caches torn down). Releases beyond the retain count are
    /// silently ignored so a missed retain (e.g. id-typo) can't underflow.
    func releaseSession(id: ACPSession.ID) {
        guard let current = sessionRefCounts[id], current > 0 else { return }
        let next = current - 1
        if next == 0 {
            sessionRefCounts.removeValue(forKey: id)
            evictIfIdle(id: id)
        } else {
            sessionRefCounts[id] = next
        }
    }

    /// Drops the cached `ACPSession` when its refcount is zero AND no live
    /// runner is attached. Sessions whose agent process is spawning or ready
    /// stay resident so in-flight streaming still has somewhere to land.
    private func evictIfIdle(id: ACPSession.ID) {
        guard let session = sessions[id] else { return }
        switch session.agentState {
        case .spawning, .ready: return
        case .idle, .disconnected, .failed: break
        }
        guard (sessionRefCounts[id] ?? 0) == 0 else { return }
        // Flush the debounced composer-draft write SYNCHRONOUSLY before
        // dropping the in-memory session. Otherwise a typing burst that
        // ends within the 300ms debounce window loses its tail when the
        // session is evicted — the timer task fires on a nil `sessions[id]`
        // and silently returns.
        flushPendingDraftWrite(for: id)
        inFlightBackfills[id]?.cancel()
        inFlightBackfills[id] = nil
        session.transcript.resetMarkdownCaches()
        sessions[id] = nil
    }

    func setArchived(id: ACPSession.ID, archived: Bool) {
        try? store.setArchived(id: id, archived: archived)
        refreshRecent()
    }

    /// Persist a fresh trailing chunk of messages (`from..<session.transcript.messages.count`)
    /// to the store. Used by code paths that mutate the session outside the
    /// runner's update loop (composer fallback when no runner is attached
    /// yet, or any direct manager call) so the messages survive a reload.
    func persistTrailingMessages(_ session: ACPSession, fromIndex from: Int) {
        let now = Int64(Date().timeIntervalSince1970)
        let messages = session.transcript.messages
        guard from < messages.count else { return }
        for i in from..<messages.count {
            let m = messages[i]
            guard let payload = try? ACPMessageCodec.encode(m) else { continue }
            let id = "msg-\(session.id)-\(i)"
            try? store.appendMessage(
                sessionId: session.id, id: id, kind: m.kind,
                seq: Int64(i), payload: payload, createdAt: now)
        }
    }

    /// Persist a session-level change (model/mode/title/autoRun) and bump updated_at.
    func persist(_ s: ACPSession) {
        guard let row = try? store.loadSession(id: s.id) else { return }
        let now = Int64(Date().timeIntervalSince1970)
        try? store.upsertSession(.init(
            id: row.id, agentId: row.agentId, title: s.title,
            titleSource: s.titleSource,
            currentModel: s.currentModel, currentMode: s.currentMode,
            autoRun: s.autoRunEnabled,
            createdAt: row.createdAt, updatedAt: now,
            lastOpenedAt: row.lastOpenedAt, archived: row.archived))
        refreshRecent()
    }

    private func persistSessionRemoteId(_ s: ACPSession) {
        guard let row = try? store.loadSession(id: s.id) else { return }
        try? store.upsertSession(.init(
            id: row.id,
            agentId: row.agentId,
            title: row.title,
            titleSource: row.titleSource,
            remoteSessionId: s.remoteSessionId,
            contextRecoveryPending: row.contextRecoveryPending,
            currentModel: row.currentModel,
            currentMode: row.currentMode,
            autoRun: row.autoRun,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt,
            lastOpenedAt: row.lastOpenedAt,
            archived: row.archived
        ))
    }

    private func persistContextRecoveryPending(sessionId: ACPSession.ID, pending: Bool) {
        try? store.setContextRecoveryPending(sessionId: sessionId, pending: pending)
    }

    /// Rename a session with the given title and source. Updates both
    /// the in-memory session and SQLite in one call.
    func renameSession(id: ACPSession.ID, title: String, source: ACPSessionTitleSource) {
        guard let session = sessions[id] else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        session.title = trimmed
        session.titleSource = source
        persist(session)
    }

    func persistComposerDraft(_ draft: ACPComposerDraft, for session: ACPSession) {
        // In-memory state updates instantly so cross-tab restore is live.
        // The SQLite write is debounced so a typing burst produces at
        // most one upsert per ~300ms instead of one per keystroke.
        session.replaceComposerDraft(draft)
        scheduleDraftPersistence(for: session.id)
    }

    func clearComposerDraft(for session: ACPSession) {
        session.replaceComposerDraft(.empty)
        cancelPendingDraftWrite(for: session.id)
        try? store.deleteComposerDraft(sessionId: session.id)
    }

    private func scheduleDraftPersistence(for sessionId: ACPSession.ID) {
        pendingDraftWrites[sessionId]?.cancel()
        pendingDraftWrites[sessionId] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.draftDebounceNanos)
            guard !Task.isCancelled else { return }
            await self?.flushPendingDraftWrite(for: sessionId)
        }
    }

    private func flushPendingDraftWrite(for sessionId: ACPSession.ID) {
        pendingDraftWrites[sessionId] = nil
        // Write the LATEST in-memory state, not whatever was captured at
        // schedule time — additional keystrokes may have come in during
        // the debounce window.
        guard let session = sessions[sessionId] else { return }
        let draft = session.composerDraft
        if draft.isEmpty {
            try? store.deleteComposerDraft(sessionId: sessionId)
        } else {
            let now = Int64(Date().timeIntervalSince1970)
            try? store.upsertComposerDraft(sessionId: sessionId, draft: draft, updatedAt: now)
        }
    }

    private func cancelPendingDraftWrite(for sessionId: ACPSession.ID) {
        pendingDraftWrites[sessionId]?.cancel()
        pendingDraftWrites[sessionId] = nil
    }

    /// Flush every pending debounced draft write synchronously. Hook for
    /// app-termination, scene resign, or tests that need a deterministic
    /// post-write read.
    func flushPendingDraftWrites() {
        for sessionId in Array(pendingDraftWrites.keys) {
            flushPendingDraftWrite(for: sessionId)
        }
    }

    /// Flush the debounced draft write for one session. Hook for the
    /// tab-close path (single session goes away while the worktree's
    /// manager stays alive).
    func flushPendingDraftWrite(forSession sessionId: ACPSession.ID) {
        flushPendingDraftWrite(for: sessionId)
    }

    /// Persist the in-memory queue to SQLite. The runner has the same
    /// `persistQueue` method, but UI actions on a session that has no
    /// runner yet (setup nudge, launch failure) must still reach the
    /// store directly — otherwise removing or clearing queue items
    /// only mutates the cached `ACPSession`, and the supposedly-removed
    /// prompts reappear on relaunch.
    func persistQueue(for session: ACPSession) {
        try? store.upsertQueue(sessionId: session.id, items: session.queue)
    }

    /// Eager-clear hook for an accepted composer submission. Synchronously
    /// flushes the submitted draft to SQLite (so a crash or detach before
    /// the prompt is recorded can still recover the user's text on next
    /// hydration), cancels the debounced timer so a delayed wake-up can't
    /// overwrite the suspended row, then clears the in-memory draft.
    ///
    /// Eager in-memory clearing prevents the ACP composer from re-showing
    /// the sent text when its NSView is dismantled and re-mounted while
    /// the agent's RPC is still in flight (e.g. user switches worktrees
    /// and comes back). Pair with `purgeSuspendedComposerDraft` on success
    /// or `reinstateSuspendedComposerDraft` on failure.
    ///
    /// Returns the post-clear revision; the completion handler uses it as
    /// the conditional token so a draft the user has typed since the
    /// suspension survives untouched.
    @discardableResult
    func suspendComposerDraftForSubmission(
        _ submitted: ACPComposerDraft, for session: ACPSession
    ) -> Int {
        let sid = session.id
        pendingDraftWrites[sid]?.cancel()
        pendingDraftWrites[sid] = nil
        if !submitted.isEmpty {
            let now = Int64(Date().timeIntervalSince1970)
            try? store.upsertComposerDraft(sessionId: sid, draft: submitted, updatedAt: now)
        }
        session.replaceComposerDraft(.empty)
        return session.composerDraftRevision
    }

    /// Delete the SQLite row left by `suspendComposerDraftForSubmission`
    /// once the prompt has been durably recorded. Guarded on the post-
    /// suspend revision so a draft the user has typed since the suspension
    /// (which is now what `composerDraft` holds) survives untouched.
    func purgeSuspendedComposerDraft(
        for session: ACPSession, suspendedRevision: Int
    ) {
        guard session.composerDraftRevision == suspendedRevision,
              session.composerDraft.isEmpty
        else { return }
        try? store.deleteComposerDraft(sessionId: session.id)
    }

    /// Restore the suspended draft back into memory when the prompt
    /// failed to record. SQLite already holds the suspended row, so this
    /// only needs to bring the in-memory state back into agreement so the
    /// composer (if still mounted, or on next mount) shows the text.
    /// Guarded on the post-suspend revision so a draft the user has typed
    /// since the suspension wins.
    func reinstateSuspendedComposerDraft(
        _ submitted: ACPComposerDraft,
        for session: ACPSession,
        suspendedRevision: Int
    ) {
        guard session.composerDraftRevision == suspendedRevision,
              session.composerDraft.isEmpty
        else { return }
        session.replaceComposerDraft(submitted)
    }

    func refreshRecent() {
        recent = (try? store.recentSessions()) ?? []
    }

    /// Loads the full persisted `content` for a tool call. Used by the
    /// tool-call card when expanding a message whose in-memory content
    /// was truncated to save memory. Returns nil if the row is gone or
    /// the payload can't be decoded.
    func reloadFullToolCallContent(sessionId: ACPSession.ID, toolCallId: String) -> String? {
        try? store.loadToolCallContent(sessionId: sessionId, toolCallId: toolCallId)
    }
}

// MARK: - Process lifecycle

extension ACPSessionManager {
    /// Ensures the session has a live connection. Idempotent — if a runner
    /// already exists for this session, returns immediately. On cold start,
    /// runs the setup check; if ready, spawns the process, initialises ACP,
    /// and calls `session/new` (new sessions) or `session/load` (reopened).
    func attach(to sessionId: ACPSession.ID, freshlyCreated: Bool) async {
        guard let session = sessions[sessionId] else { return }
        switch session.agentState {
        case .spawning, .ready: return
        case .idle, .disconnected, .failed: break
        }
        // Drop any stale runner left over from a prior process (e.g. the
        // runner's stream-end branch flipped agentState to .disconnected
        // but did not unregister itself). The .ready/.spawning early-return
        // above already covers the live-runner case — a runner is only
        // registered AFTER state flips to .ready — so anything still here
        // is a zombie whose update task already exited.
        if let stale = runners[sessionId] {
            stale.stop()
        }
        runners[sessionId] = nil
        // Clear stale failure UI from the prior attempt while we spawn fresh.
        // If this attempt also fails, the catch branches below will repopulate
        // `lastError` with the new reason.
        session.lastError = nil
        session.contextRestoreWarning = nil
        session.agentState = .spawning

        guard let spec = ACPLaunchCatalog.spec(for: session.agentId) else {
            let reason = "No ACP launch spec for \(session.agentId)"
            session.setupState = .needsSetup(reason: reason)
            session.agentState = .failed(reason)
            return
        }
        let setup = await setupEvaluator(spec)
        guard case .ready = setup else {
            session.setupState = .needsSetup(reason: setup.reasonText)
            session.agentState = .failed(setup.reasonText)
            return
        }
        session.setupState = .ready

        let connection: ACPConnection
        do {
            connection = try connectionFactory(spec)
        } catch {
            let msg = "Failed to launch agent: \(error.localizedDescription)"
            session.lastError = msg
            session.agentState = .failed(msg)
            return
        }
        // Collect a short tail of stderr so we can surface it when the
        // agent rejects initialize / new for protocol or auth reasons.
        let stderrBuffer = StderrBuffer()
        let stderrTask = Task { [weak client = connection.client] in
            guard let stream = (client as? ACPStdioClient)?.incomingStderr else { return }
            for await data in stream {
                stderrBuffer.append(data)
            }
        }
        var startedRunner: ACPSessionRunner?
        do {
            session.promptCapabilities = (try await connection.initialize())
            let shouldSuppressLoadReplay = !freshlyCreated
                && session.hydrationState == .ready
                && session.hasConversationTranscript
                && !(session.remoteSessionId ?? "").isEmpty
            let runner = ACPSessionRunner(session: session, connection: connection,
                                          store: store, sessionId: sessionId,
                                          worktreePath: worktreePath,
                                          agentEnv: Self.mergeEnv(extra: spec.extraEnv),
                                          suppressingLoadReplay: shouldSuppressLoadReplay,
                                          onDirtyCheck: onDirtyCheck,
                                          onLiveBufferRead: onLiveBufferRead)
            var runnerStarted = false
            func startRunnerIfNeeded() {
                guard !runnerStarted else { return }
                runner.start()
                runnerStarted = true
                startedRunner = runner
            }
            if shouldSuppressLoadReplay {
                startRunnerIfNeeded()
            }
            let pendingRecovery = (try? store.loadSession(id: sessionId)?.contextRecoveryPending) == true
            let result: ACPSessionNewResult
            var restoreWarning: ACPSession.ContextRestoreWarning?
            var shouldHoldQueueForRecovery = pendingRecovery && session.hasConversationTranscript
            if freshlyCreated {
                result = try await connection.newSession(cwd: worktreePath)
            } else if let remoteId = session.remoteSessionId, !remoteId.isEmpty {
                do {
                    result = try await connection.loadSession(cwd: worktreePath, sessionId: remoteId)
                    runner.finishSuppressingLoadReplay(
                        throughYieldedUpdateCount: connection.client.yieldedUpdateCount
                    )
                } catch {
                    runner.finishSuppressingLoadReplay(
                        throughYieldedUpdateCount: connection.client.yieldedUpdateCount
                    )
                    result = try await connection.newSession(cwd: worktreePath)
                    if session.hasConversationTranscript {
                        shouldHoldQueueForRecovery = true
                        persistContextRecoveryPending(sessionId: sessionId, pending: true)
                    }
                    restoreWarning = .init(
                        message: "Agent context could not be restored.",
                        canSendTranscript: session.hasConversationTranscript
                    )
                }
            } else {
                result = try await connection.newSession(cwd: worktreePath)
                if session.hasConversationTranscript {
                    shouldHoldQueueForRecovery = true
                    persistContextRecoveryPending(sessionId: sessionId, pending: true)
                }
                restoreWarning = .init(
                    message: "Agent context could not be restored.",
                    canSendTranscript: session.hasConversationTranscript
                )
            }
            if restoreWarning == nil, pendingRecovery {
                restoreWarning = .init(
                    message: "Agent context could not be restored.",
                    canSendTranscript: session.hasConversationTranscript
                )
            }
            session.remoteSessionId = result.sessionId
            session.availableModels = result.availableModels
            session.availableModes = result.availableModes
            session.currentModel = result.currentModel
            session.currentMode = result.currentMode
            session.promptSuggestions = result.promptSuggestions
            session.availableConfigOptions = result.configOptions
            session.contextRestoreWarning = restoreWarning
            persistSessionRemoteId(session)
            startRunnerIfNeeded()
            runners[sessionId] = runner
            session.agentState = .ready
            if !shouldHoldQueueForRecovery {
                runner.flushQueueIfIdle()
            }
            stderrTask.cancel()
        } catch {
            // Give stderr a moment to drain so the message is the real cause.
            try? await Task.sleep(nanoseconds: 200_000_000)
            stderrTask.cancel()
            let tail = stderrBuffer.tail()
            let base = "ACP initialize/new failed: \(error.localizedDescription)"
            let full = tail.isEmpty ? base : base + "\nstderr: " + tail
            session.lastError = full
            session.agentState = .failed(full)
            startedRunner?.stop()
            await connection.shutdown()
        }
    }

    /// Idempotent recovery entry point. Called by the composer when the
    /// user submits into a pane whose agent isn't `.ready`. A no-op for
    /// states that already represent in-flight or live agents.
    func reattach(to sessionId: ACPSession.ID) async {
        guard let session = sessions[sessionId] else { return }
        switch session.agentState {
        case .spawning, .ready: return
        case .idle, .disconnected, .failed:
            await attach(to: sessionId, freshlyCreated: false)
        }
    }

    func transcriptContextPrompt(for session: ACPSession, agentName: String?) -> String? {
        guard session.hasConversationTranscript else { return nil }
        let markdown = ACPTranscriptMarkdown.document(
            title: session.title,
            agentName: agentName,
            messages: session.transcript.messages
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !markdown.isEmpty else { return nil }
        return """
        The previous agent context for this pane could not be restored. Use the transcript below as background context for future turns. Do not summarize or repeat it back unless I ask.

        \(markdown)
        """
    }

    @discardableResult
    func sendTranscriptAsContext(sessionId: ACPSession.ID, agentName: String?) -> Bool {
        guard let session = sessions[sessionId],
              let runner = runners[sessionId],
              session.contextRestoreWarning?.canSendTranscript == true,
              session.agentState == .ready,
              session.transcript.streamingState == .idle,
              let prompt = transcriptContextPrompt(for: session, agentName: agentName)
        else { return false }

        runner.sendRecoveryContext(prompt) { delivered in
            if delivered {
                self.persistContextRecoveryPending(sessionId: sessionId, pending: false)
                session.contextRestoreWarning = nil
            }
        }
        return true
    }

    /// Enqueue a prompt into a session whose agent isn't `.ready` yet.
    /// Mirrors `ACPSessionRunner`'s `.enqueue` intent so the persisted
    /// queue looks identical regardless of which side wrote it. The
    /// existing `flushQueueIfIdle()` call inside `attach()` will drain
    /// these items once the agent becomes `.ready`.
    func enqueueWhileRecovering(
        text: String,
        attachments: [ACPMessage.Attachment],
        draft: ACPComposerDraft? = nil,
        into sessionId: ACPSession.ID
    ) {
        guard let session = sessions[sessionId] else { return }
        let blocks = ACPSessionRunner.blocks(text: text, attachments: attachments)
        session.enqueue(blocks: blocks, draft: draft)
        do {
            try store.upsertQueue(sessionId: sessionId, items: session.queue)
        } catch {
            session.lastError = "Failed to persist queued prompt: \(error.localizedDescription)"
        }
    }

    /// Composer submit. Returns `true` if the prompt was accepted (either
    /// sent immediately or queued for delivery once the agent is ready).
    /// `onCompleted` fires once the underlying send/enqueue resolves; the
    /// composer uses it to decide whether to clear or re-persist the draft.
    ///
    /// Branches on `session.agentState`:
    /// - `.ready`: dispatch via the runner as before.
    /// - `.spawning`: enqueue only — an `attach` is already in flight and
    ///   the post-attach `flushQueueIfIdle()` will drain the head.
    /// - `.idle` / `.disconnected` / `.failed`: enqueue AND kick `reattach`
    ///   so the user's prompt is what brings the agent back online.
    ///
    @discardableResult
    func submit(
        sessionId: ACPSession.ID,
        text: String,
        attachments: [ACPMessage.Attachment],
        intent: ACPSubmitIntent,
        draft: ACPComposerDraft? = nil,
        onCompleted: @escaping @MainActor (Bool) -> Void
    ) -> Bool {
        guard let session = sessions[sessionId] else { return false }

        switch session.agentState {
        case .ready:
            guard let runner = runners[sessionId] else {
                // State and registry disagree — somehow we lost the runner
                // without the stream-end branch flipping agentState. Reflect
                // reality (`.disconnected`, same surface as the runner's
                // stream-end branch) so `reattach()` actually fires a fresh
                // attach instead of no-opping on `.ready`. Defer `onCompleted`
                // to the next tick so it runs after the composer's submit
                // closure returns and registers its pending id (without the
                // hop the completion fires too early and gets ignored).
                session.agentState = .disconnected
                enqueueWhileRecovering(text: text, attachments: attachments, draft: draft, into: sessionId)
                Task { @MainActor in onCompleted(true) }
                Task { @MainActor in await reattach(to: sessionId) }
                return true
            }
            runner.send(text: text, attachments: attachments, intent: intent, draft: draft) { succeeded in
                onCompleted(succeeded)
            }
            return true

        case .spawning:
            // An attach is in flight; the post-attach `flushQueueIfIdle()`
            // will pick up the freshly enqueued head.
            enqueueWhileRecovering(text: text, attachments: attachments, draft: draft, into: sessionId)
            Task { @MainActor in onCompleted(true) }
            return true

        case .idle, .disconnected, .failed:
            // Prompt is accepted the moment it lands in the queue. Defer
            // `onCompleted` to the next tick so it runs after the composer's
            // submit closure returns and registers its pending id — firing
            // synchronously here would race the composer's bookkeeping and
            // get ignored, leaving the persisted draft uncleared.
            enqueueWhileRecovering(text: text, attachments: attachments, draft: draft, into: sessionId)
            Task { @MainActor in onCompleted(true) }
            Task { @MainActor in await reattach(to: sessionId) }
            return true
        }
    }

    func detach(sessionId: ACPSession.ID) async {
        // Reset transient session state SYNCHRONOUSLY before any await.
        // The steer task is unstructured and can resume during the
        // `connection.shutdown()` await below — if `agentState` is still
        // `.ready` at that point, its post-`userCancel` liveness
        // check passes and it dispatches `sendNow` against a connection
        // being torn down. Flipping the state here closes that window.
        if let session = sessions[sessionId] {
            // .idle (user-initiated teardown), not .disconnected — the latter
            // is reserved for the runner's unexpected stream-end branch.
            session.agentState = .idle
            session.transcript.streamingState = .idle
            // Normalize any in-flight queue head: the sendNow task that
            // owned it is gone with the runner, so the next attach must
            // see a `.pending` head to be able to flush it. Without this,
            // closing a tab mid-flush leaves the cached session's head
            // as `.sending`; the next `placeholderSession` returns the
            // cached object (skipping `restoreQueue`), the post-attach
            // flush sees `.sending`, and the queue stays stuck until a
            // full app restart reloads from SQLite.
            session.restoreQueue(session.queue)
        }
        if let runner = runners.removeValue(forKey: sessionId) {
            // Invalidate the in-flight prompt BEFORE shutting down the
            // connection. The unstructured `sendNow` task survives stop()
            // and the connection close will make its RPC throw — we want
            // its catch path to recognise the failure as "deliberately
            // cancelled" so it skips `setQueueHeadError` and the queue
            // head can come back as cleanly `.pending` after restoreQueue.
            runner.invalidateActivePrompt()
            runner.stop()
            await runner.connection.shutdown()
        }
        // SwiftUI's `.onDisappear` retain release for a closing tab can
        // arrive BEFORE this async detach starts, so the release runs while
        // agentState is still `.ready` and short-circuits eviction. Re-check
        // now that state is `.idle` so a closed-while-attached session
        // doesn't keep its transcript + caches resident indefinitely.
        evictIfIdle(id: sessionId)
    }

    private static func mergeEnv(extra: [String: String]) -> [String: String] {
        var env = ACPProcessEnvironment.augmented()
        // Strip env vars that mark this process as running INSIDE a coding
        // agent's session. Without this, `claude-code-acp` (and likely any
        // other Anthropic-aware tool we spawn) refuses to start, reporting
        // "Claude Code cannot be launched inside another Claude Code session"
        // — which is exactly what happens when Alas is run from a terminal
        // that's itself inside Claude Code.
        for key in [
            "CLAUDECODE", "CLAUDE_CODE", "CLAUDE_PROJECT_DIR",
            "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_SESSION_ID",
        ] {
            env.removeValue(forKey: key)
        }
        for (k, v) in extra { env[k] = v }
        return env
    }
}

private extension ACPSetupResult {
    var reasonText: String {
        switch self {
        case .ready: return ""
        case .missing(let r): return r
        case .error(let m): return m
        }
    }
}

/// Thread-safe ring of stderr bytes from the agent process. Keeps the last
/// ~2 KB so we can surface useful context when initialize/new fails.
private final class StderrBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private let cap = 2048
    func append(_ d: Data) {
        lock.lock()
        defer { lock.unlock() }
        bytes.append(d)
        if bytes.count > cap {
            bytes.removeSubrange(0..<(bytes.count - cap))
        }
    }
    func tail() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: bytes, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
