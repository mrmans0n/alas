import Foundation

private struct ACPTranscriptScrollMemory: Equatable {
    var anchorMessageId: String?
    /// ACP view ids for persisted text rows are regenerated during hydration;
    /// the transcript index is the durable restore target across eviction.
    var anchorMessageIndex: Int?
    var followsTail: Bool
}

@MainActor
final class ACPSessionManager: ObservableObject {
    typealias ACPSetupEvaluator = @MainActor (_ spec: ACPLaunchSpec) async -> ACPSetupResult
    typealias ACPConnectionFactory = @MainActor (_ spec: ACPLaunchSpec) throws -> ACPConnection

    let instanceId: String
    let pid: Int64
    let worktreeId: String
    let worktreePath: String
    let store: ACPSessionStore
    let changeNotifier: ACPChangeNotifier
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

    /// Live session object if cached (does not trigger hydration).
    func liveSession(for id: ACPSession.ID) -> ACPSession? { sessions[id] }

    /// Permission policy for a session that currently has an attached runner.
    /// Returns nil if no runner is attached (session not actively connected).
    func permissionPolicy(for id: ACPSession.ID) -> ACPPermissionPolicy? { runners[id]?.policy }

    /// Answers a pending question for a session that currently has an attached runner.
    func answerQuestion(for id: ACPSession.ID, _ response: ACPQuestionResponse) {
        runners[id]?.answerQuestion(response)
    }

    /// Lightweight summaries for the remote sessions list.
    var sessionRows: [ACPSessionRow] { recent }

    /// Whether this instance is the legitimate current writer for the session —
    /// gates every remote drive action (`canDrive`, `sendPrompt`, `stop`).
    ///
    /// Requires BOTH the in-memory claim AND store agreement: after another
    /// window takes over, the former owner keeps the id in `_ownedLeases` until
    /// its heartbeat stands down (~5s). Trusting the in-memory set alone would
    /// let a phone connected to the old owner keep writing into a session
    /// another instance now drives — corrupting the active conversation. So we
    /// also consult the store row via `anotherLiveInstanceOwnsLease`, the same
    /// guard the local write path (`holdsLeaseForWrite`) relies on.
    func isWriter(for id: ACPSession.ID) -> Bool {
        _ownedLeases.contains(id) && !anotherLiveInstanceOwnsLease(sessionId: id)
    }

    /// Submit a prompt using the same path the local composer uses (`.auto`
    /// intent resolves to send-now or enqueue based on agent state).
    ///
    /// `onResult` fires exactly once with the final outcome so the gateway can
    /// tell the client to restore the text on failure (the local composer uses
    /// the same callback to reinstate its draft):
    /// - `false` immediately when we no longer hold the lease or `submit`
    ///   refuses synchronously (no live session / needs auth);
    /// - otherwise the eventual `submit` completion — `true` once the prompt is
    ///   sent or safely queued, `false` if the `session/prompt` RPC later fails
    ///   (auth/network/agent error) on the already-`.ready` path.
    ///
    /// Re-checks `isWriter` at the point of action: a cross-process takeover can
    /// land between the gateway's `isWriter` gate and here, and `submit`'s
    /// `.idle`/`.disconnected` path would otherwise enqueue + persist the prompt
    /// as a mirror — injecting it into a session another instance now drives.
    func sendPrompt(for id: ACPSession.ID, text: String, attachments: [ACPMessage.Attachment], onResult: @escaping @MainActor (Bool) -> Void) {
        guard isWriter(for: id) else {
            onResult(false)
            return
        }
        let accepted = submit(sessionId: id, text: text, attachments: attachments, intent: .auto,
                              onCompleted: { ok in onResult(ok) })
        if !accepted { onResult(false) }   // submit refused synchronously; onCompleted won't fire
    }

    /// Interrupt the in-flight turn (same as the composer Stop / Esc). Guarded
    /// on the live lease for the same cross-process-takeover reason as `sendPrompt`.
    func interrupt(for id: ACPSession.ID) {
        guard isWriter(for: id), let runner = runners[id] else { return }
        Task { await runner.userCancel() }
    }

    /// Pending model/mode to apply once a runner registers (the writer took over
    /// but `attach` is still in flight). Keyed by session id. Applied in `attach`.
    var pendingModel: [ACPSession.ID: String] = [:]
    var pendingMode: [ACPSession.ID: String] = [:]

    /// Toggle auto-run for a remotely-driven session. Writer-gated; persists.
    func setAutoRun(for id: ACPSession.ID, enabled: Bool) {
        guard isWriter(for: id), let session = sessions[id] else { return }
        session.autoRunEnabled = enabled
        persist(session)
    }

    /// Select the agent model. Optimistically updates + persists, then issues the
    /// agent RPC on the live runner — or records it pending until `attach`
    /// registers one (post-takeover window). Writer-gated.
    func setModel(for id: ACPSession.ID, modelId: String) {
        guard isWriter(for: id), let session = sessions[id] else { return }
        session.currentModel = modelId
        persist(session)
        guard let runner = runners[id] else {
            pendingModel[id] = modelId
            return
        }
        let remoteId = session.remoteSessionId ?? id
        Task { try? await runner.connection.setModel(sessionId: remoteId, modelId: modelId) }
    }

    /// Select the agent mode. Same semantics as `setModel`.
    func setMode(for id: ACPSession.ID, modeId: String) {
        guard isWriter(for: id), let session = sessions[id] else { return }
        session.currentMode = modeId
        persist(session)
        guard let runner = runners[id] else {
            pendingMode[id] = modeId
            return
        }
        let remoteId = session.remoteSessionId ?? id
        Task { try? await runner.connection.setMode(sessionId: remoteId, modeId: modeId) }
    }

    /// Sessions for which THIS instance holds the writer lease (backing store).
    var _ownedLeases: Set<ACPSession.ID> = []
    /// Per-session periodic heartbeat tasks (backing store).
    var _heartbeatTasks: [ACPSession.ID: Task<Void, Never>] = [:]
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
    // MARK: Mirror state (read-only follower when another instance holds the lease)
    private var mirrorTokens: [ACPSession.ID: Int32] = [:]
    private var mirrorDebounce: [ACPSession.ID: Task<Void, Never>] = [:]
    private var mirrorPoll: [ACPSession.ID: Task<Void, Never>] = [:]
    // MARK: Writer-watch state (prompt stand-down when a takeover ping arrives)
    private var writerWatchTokens: [ACPSession.ID: Int32] = [:]
    private var writerWatchDebounce: [ACPSession.ID: Task<Void, Never>] = [:]
    /// Runtime-only layout memory for the plan sidebar. This intentionally
    /// lives on the manager rather than `ACPSession` so a tab switch can
    /// evict and later recreate the session object without losing whether
    /// the plan was last rendered inline or in the toolbar pill.
    private var planSidebarVisibility: [ACPSession.ID: Bool] = [:]
    /// Runtime-only transcript scroll memory. Kept on the manager for the
    /// same reason as `planSidebarVisibility`: idle ACP sessions can be
    /// evicted on tab switches, but returning to the tab should not reset
    /// a user-paused transcript to the top of whatever render window hydrates
    /// first.
    private var transcriptScrollMemory: [ACPSession.ID: ACPTranscriptScrollMemory] = [:]
    /// Set to true by `shutdownBackgroundTasks` so any in-flight `attach`
    /// coroutine that resumes after dispose aborts at the pre-commit guard
    /// rather than registering a runner for a session whose manager is dead.
    private var isDisposed = false
    /// Sessions for which an `attach` coroutine has acquired the writer
    /// lease but has not yet registered a runner (the pre-runner window).
    /// `releaseAllOwnedLeases` skips these so their own `defer` block can
    /// release the lease after `connection.shutdown` — preserving the
    /// correct shutdown order (connection down before lease freed).
    private var attachingSessions: Set<ACPSession.ID> = []

    init(worktreeId: String, worktreePath: String, store: ACPSessionStore,
         instanceId: String = UUID().uuidString,
         pid: Int64 = Int64(ProcessInfo.processInfo.processIdentifier),
         hydratorPath: String? = nil,
         onDirtyCheck: ((String) -> Bool)? = nil,
         onLiveBufferRead: ((String) -> String?)? = nil,
         changeNotifier: ACPChangeNotifier? = nil,
         setupEvaluator: ACPSetupEvaluator? = nil,
         connectionFactory: ACPConnectionFactory? = nil)
    {
        self.instanceId = instanceId
        self.pid = pid
        self.worktreeId = worktreeId
        self.worktreePath = worktreePath
        self.store = store
        self.onDirtyCheck = onDirtyCheck
        self.onLiveBufferRead = onLiveBufferRead
        self.changeNotifier = changeNotifier ?? DarwinChangeNotifier(worktreeId: worktreeId)
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
                    environment: ACPProcessEnvironment.sanitizedForACP(extra: spec.extraEnv))
            } else {
                client = try ACPStdioClient(
                    executable: URL(fileURLWithPath: "/usr/bin/env"),
                    arguments: [spec.command] + spec.arguments,
                    environment: ACPProcessEnvironment.sanitizedForACP(extra: spec.extraEnv))
            }
            try client.start()
            return ACPConnection(client: client)
        }
        self.recent = (try? store.recentSessions()) ?? []
    }

    func createSession(agentId: String, autoRunDefault: Bool = false) -> ACPSession {
        let id = UUID().uuidString
        let now = Int64(Date().timeIntervalSince1970)
        let row = ACPSessionRow(
            id: id, agentId: agentId, title: "New session",
            titleSource: .placeholder,
            currentModel: nil, currentMode: nil, autoRun: autoRunDefault,
            createdAt: now, updatedAt: now, lastOpenedAt: now, archived: false)
        try? store.upsertSession(row)
        let session = ACPSession(
            id: id, agentId: agentId, worktreeId: worktreeId,
            title: row.title, titleSource: .placeholder, hydrationState: .ready)
        session.autoRunEnabled = autoRunDefault
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
        if let memory = transcriptScrollMemory[id] {
            session.followsTranscriptTail = memory.followsTail
        }
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
        applyRememberedTranscriptScrollWindow(to: session, messageIndexOffset: tailStart)
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
            // Compute `canSendTranscript` against the FULL wire list rather
            // than `session.hasConversationTranscript`. Tail-first hydration
            // leaves only the last 30 messages in the in-memory transcript
            // when this runs, so a long session whose tail is all tool
            // calls / file edits would look conversation-less here and
            // permanently disable the "Send transcript" action — the
            // warning is set once and never recomputed after backfill.
            let canSendTranscript = Self.wireMessagesHaveConversation(result.wireMessages)
            session.contextRestoreWarning = .init(
                message: "Agent context could not be restored.",
                canSendTranscript: canSendTranscript
            )
            if canSendTranscript {
                session.contextRecoveryStatus = .sendingTranscript
            }
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

    /// Mirror of `ACPSession.hasConversationTranscript` that operates on the
    /// wire (Sendable) representation, so callers can ask the question
    /// before the in-memory transcript has been fully reassembled — i.e.
    /// during the tail-only window of tail-first hydration.
    private static func wireMessagesHaveConversation(_ wires: [ACPMessageWire]) -> Bool {
        wires.contains { wire in
            switch wire {
            case let .user(text, _):
                return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case let .agent(text):
                return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            default:
                return false
            }
        }
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
        session.transcript.isBackfillingOlderMessages = true

        // Capture a stable handle the task body can compare against the
        // current entry in `inFlightBackfills` before clearing it. Without
        // this guard, a backfill that is cancelled and then immediately
        // superseded (close + reopen, or a re-hydrate) would still run its
        // cleanup when the cancelled task finally returns from its yield,
        // clearing the slot that now holds the NEWER task. `awaitBackfill`
        // would then observe no task and let `attach`/export proceed
        // against the tail-only transcript — exactly the index-corruption
        // path the gating exists to prevent.
        final class TaskHandle { var task: Task<Void, Never>? }
        let handle = TaskHandle()
        let task = Task { @MainActor [weak self, weak session] in
            defer {
                if let me = handle.task, self?.inFlightBackfills[sessionId] == me {
                    session?.transcript.isBackfillingOlderMessages = false
                    self?.inFlightBackfills[sessionId] = nil
                }
            }
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
            self.applyRememberedTranscriptScrollWindow(to: session)
        }
        handle.task = task
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
        planSidebarVisibility.removeValue(forKey: id)
        transcriptScrollMemory.removeValue(forKey: id)
        pendingModel.removeValue(forKey: id)
        pendingMode.removeValue(forKey: id)
    }

    func deleteSession(id: ACPSession.ID) {
        cancelPendingDraftWrite(for: id)
        inFlightBackfills[id]?.cancel()
        inFlightBackfills[id] = nil
        sessions[id]?.transcript.resetMarkdownCaches()
        sessions[id] = nil
        sessionRefCounts.removeValue(forKey: id)
        planSidebarVisibility.removeValue(forKey: id)
        transcriptScrollMemory.removeValue(forKey: id)
        pendingModel.removeValue(forKey: id)
        pendingMode.removeValue(forKey: id)
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

    func rememberedPlanSidebarVisibility(for id: ACPSession.ID) -> Bool? {
        planSidebarVisibility[id]
    }

    func rememberPlanSidebarVisibility(_ visible: Bool, for id: ACPSession.ID) {
        planSidebarVisibility[id] = visible
    }

    func rememberedTranscriptScrollAnchor(for id: ACPSession.ID) -> String? {
        guard transcriptScrollMemory[id]?.followsTail == false else { return nil }
        return transcriptScrollMemory[id]?.anchorMessageId
    }

    func rememberTranscriptScrollAnchor(
        sessionId id: ACPSession.ID,
        anchorMessageId: String?,
        anchorMessageIndex: Int? = nil,
        followsTail: Bool
    ) {
        if followsTail {
            transcriptScrollMemory.removeValue(forKey: id)
        } else {
            transcriptScrollMemory[id] = ACPTranscriptScrollMemory(
                anchorMessageId: anchorMessageId,
                anchorMessageIndex: anchorMessageIndex,
                followsTail: false
            )
        }
        sessions[id]?.followsTranscriptTail = followsTail
    }

    private func applyRememberedTranscriptScrollWindow(
        to session: ACPSession,
        messageIndexOffset: Int = 0
    ) {
        guard let memory = transcriptScrollMemory[session.id], !memory.followsTail else { return }
        if let index = memory.anchorMessageIndex {
            let localIndex = index - messageIndexOffset
            guard localIndex >= 0, localIndex < session.transcript.messages.count else { return }
            session.transcript.setVisibleHead(localIndex)
            return
        }
        guard let anchor = memory.anchorMessageId,
              let index = session.transcript.messages.firstIndex(where: { $0.stableId == anchor })
        else { return }
        session.transcript.setVisibleHead(index)
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
        // Stop any active mirror poll/subscription so the 2.5s poll task
        // doesn't keep waking after a mirrored tab closes. Idempotent —
        // no-op for writer sessions.
        endMirroring(sessionId: id)
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
    /// No-ops only when another live instance owns the writer lease (this pane
    /// is a mirror); the writer and not-yet-leased cases persist normally.
    func persist(_ s: ACPSession, preserveTitle: Bool = true) {
        guard !anotherLiveInstanceOwnsLease(sessionId: s.id) else { return }
        guard let row = try? store.loadSession(id: s.id) else { return }
        let now = Int64(Date().timeIntervalSince1970)
        try? store.upsertSession(.init(
            id: row.id, agentId: row.agentId, title: s.title,
            titleSource: s.titleSource,
            currentModel: s.currentModel, currentMode: s.currentMode,
            autoRun: s.autoRunEnabled,
            createdAt: row.createdAt, updatedAt: now,
            lastOpenedAt: row.lastOpenedAt, archived: row.archived),
            preserveTitle: preserveTitle)
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
    /// the in-memory session and SQLite in one call. No-ops only when
    /// another live instance owns the writer lease (this pane is a mirror).
    func renameSession(id: ACPSession.ID, title: String, source: ACPSessionTitleSource) {
        guard !anotherLiveInstanceOwnsLease(sessionId: id) else { return }
        guard let session = sessions[id] else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        session.title = trimmed
        session.titleSource = source
        persist(session, preserveTitle: false)
    }

    @discardableResult
    func renameSessionCosmetic(id: ACPSession.ID, title: String, source: ACPSessionTitleSource) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let row = try? store.loadSession(id: id),
              !row.archived else { return false }
        let now = Int64(Date().timeIntervalSince1970)
        do {
            guard try store.renameSession(id: id, title: trimmed, titleSource: source, updatedAt: now) else {
                return false
            }
            if let session = sessions[id] {
                session.title = trimmed
                session.titleSource = source
            }
            refreshRecent()
            return true
        } catch {
            return false
        }
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
    ///
    /// No-ops only when another live instance owns the writer lease — a
    /// mirror must not overwrite the active owner's queue. The writer and
    /// not-yet-leased cases persist normally.
    func persistQueue(for session: ACPSession) {
        guard !anotherLiveInstanceOwnsLease(sessionId: session.id) else { return }
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

// MARK: - Writer lease + heartbeat

extension ACPSessionManager {
    /// Seconds after which a lease whose owner stopped heart-beating is
    /// considered abandoned and reclaimable.
    static let leaseStaleAfter: Int64 = 15

    /// Attempt to become the writer for `sessionId`. Returns true if we
    /// now hold the lease. Idempotent for a lease we already own.
    @discardableResult
    func acquireWriterLease(sessionId: ACPSession.ID) -> Bool {
        let now = Int64(Date().timeIntervalSince1970)
        let won = (try? store.claimLease(
            sessionId: sessionId, instanceId: instanceId, pid: pid,
            now: now, staleAfter: Self.leaseStaleAfter)) ?? false
        if won { _ownedLeases.insert(sessionId) } else { _ownedLeases.remove(sessionId) }
        return won
    }

    func releaseWriterLease(sessionId: ACPSession.ID) {
        try? store.releaseLease(sessionId: sessionId, instanceId: instanceId)
        _ownedLeases.remove(sessionId)
    }

    /// True when this session is open here but owned by another live
    /// instance (read-only mirror). Delegates to `anotherLiveInstanceOwnsLease`
    /// so a stale former owner (still in `_ownedLeases`) is immediately treated
    /// as read-only after a takeover ping, without waiting for the heartbeat.
    func isMirror(sessionId: ACPSession.ID) -> Bool {
        anotherLiveInstanceOwnsLease(sessionId: sessionId)
    }

    /// True when a DIFFERENT, live instance currently owns this session's
    /// lease in the store. Unlike `isMirror`, this does NOT short-circuit on
    /// our in-memory `_ownedLeases`: during a takeover the former owner keeps
    /// the id in `_ownedLeases` until its heartbeat catches up, so manager
    /// writes must consult the store row directly to avoid writing to a
    /// session another instance now owns.
    private func anotherLiveInstanceOwnsLease(sessionId: ACPSession.ID) -> Bool {
        guard let lease = try? store.loadLease(sessionId: sessionId) else { return false }
        return lease.ownerInstance != instanceId
            && ACPProcessLiveness.pidAlive(lease.pid)
            && lease.heartbeatAt >= Int64(Date().timeIntervalSince1970) - Self.leaseStaleAfter
    }

    /// Whether the instance currently writing this mirrored session is
    /// actively streaming (drives the mirror's busy spinner). Reads the
    /// lease status written by the owner's heartbeat.
    func mirrorIsBusy(sessionId: ACPSession.ID) -> Bool {
        guard let lease = try? store.loadLease(sessionId: sessionId) else { return false }
        return lease.status == "busy"
    }

    /// One heartbeat tick for an owned session. Returns true if the
    /// caller should stand down (we lost the lease to another instance).
    /// Side effects: refreshes our heartbeat when we still own the row,
    /// or re-asserts ownership (re-inserts) when the row has gone missing
    /// while we still believe we own it (e.g. a failed concurrent takeover
    /// deleted it) — preventing a rowless session another instance could
    /// claim out from under us.
    // exposed for tests
    @discardableResult
    func heartbeatTick(sessionId: ACPSession.ID) -> Bool {
        guard _ownedLeases.contains(sessionId) else { return false }
        let now = Int64(Date().timeIntervalSince1970)
        if let lease = try? store.loadLease(sessionId: sessionId) {
            if lease.ownerInstance != instanceId {
                return true   // taken over → stand down
            }
            // Still ours — refresh heartbeat + status.
            let status = runners[sessionId]?.session.transcript.streamingState == .streaming
                ? "busy" : "idle"
            try? store.refreshHeartbeat(
                sessionId: sessionId, instanceId: instanceId, now: now, status: status)
            return false
        } else {
            // Row missing but we believe we own it — re-assert ownership so
            // the session isn't left rowless and claimable by another instance.
            try? store.seizeLease(sessionId: sessionId, instanceId: instanceId, pid: pid, now: now)
            return false
        }
    }

    private func startHeartbeat(sessionId: ACPSession.ID) {
        _heartbeatTasks[sessionId]?.cancel()
        _heartbeatTasks[sessionId] = Task { [weak self] in
            // Refresh immediately so the just-claimed lease doesn't rely on
            // the first 5s tick (a slow initialize/newSession could otherwise
            // let the heartbeat age past leaseStaleAfter mid-attach).
            await MainActor.run {
                guard let self else { return }
                if self.heartbeatTick(sessionId: sessionId) {
                    Task { await self.standDown(sessionId: sessionId) }
                }
            }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)   // 5s
                guard let self else { return }
                let shouldStandDown = await MainActor.run { self.heartbeatTick(sessionId: sessionId) }
                if shouldStandDown {
                    await self.standDown(sessionId: sessionId)
                }
            }
        }
    }

    private func stopHeartbeat(sessionId: ACPSession.ID) {
        _heartbeatTasks.removeValue(forKey: sessionId)?.cancel()
    }

    // MARK: - Writer watch (prompt stand-down on takeover ping)

    /// Subscribe to the change notifier while we own a session so a
    /// takeover ping triggers an immediate ownership re-check and stand-down
    /// rather than waiting up to 5 s for the heartbeat.
    private func startWriterWatch(sessionId: ACPSession.ID) {
        guard writerWatchTokens[sessionId] == nil else { return }
        let token = changeNotifier.subscribe { [weak self] in
            // The Darwin notifier delivers off the main thread; hop back.
            Task { @MainActor [weak self] in
                self?.scheduleWriterOwnershipCheck(sessionId: sessionId)
            }
        }
        writerWatchTokens[sessionId] = token
    }

    private func scheduleWriterOwnershipCheck(sessionId: ACPSession.ID) {
        writerWatchDebounce[sessionId]?.cancel()
        writerWatchDebounce[sessionId] = Task { [weak self] in
            // 100 ms coalesce window: the writer itself posts a ping on every
            // persist, so we debounce to avoid checking on each of those.
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard let self else { return }
            await MainActor.run {
                guard self._ownedLeases.contains(sessionId) else { return }
                if self.heartbeatTick(sessionId: sessionId) {
                    self._ownedLeases.remove(sessionId)
                    Task { await self.standDown(sessionId: sessionId) }
                }
            }
        }
    }

    private func stopWriterWatch(sessionId: ACPSession.ID) {
        if let t = writerWatchTokens.removeValue(forKey: sessionId) { changeNotifier.unsubscribe(t) }
        writerWatchDebounce.removeValue(forKey: sessionId)?.cancel()
    }

    // MARK: - Test accessors for writer watch

    /// True when a writer-watch change-notifier subscription is active for
    /// `sessionId`. Used by tests to verify start/stop symmetry.
    func writerWatchActiveForTest(sessionId: ACPSession.ID) -> Bool {
        writerWatchTokens[sessionId] != nil
    }

    // MARK: - Takeover (mirror seizes writer role)

    /// Explicit user takeover from a mirror: seize the lease, nudge the
    /// previous owner to notice (via the change ping), then attach as the
    /// writer (re-attaching to the remote session via session/load inside
    /// `attach`). The previous owner stands down when its heartbeat sees
    /// it no longer owns the lease (within ~5s).
    func takeOver(sessionId: ACPSession.ID) {
        let now = Int64(Date().timeIntervalSince1970)
        try? store.seizeLease(sessionId: sessionId, instanceId: instanceId, pid: pid, now: now)
        _ownedLeases.insert(sessionId)
        changeNotifier.post()
        endMirroring(sessionId: sessionId)
        startHeartbeat(sessionId: sessionId)
        startWriterWatch(sessionId: sessionId)
        if let session = sessions[sessionId] {
            // Refresh the cached remoteSessionId from the store so the
            // re-attach uses session/load (resuming the existing agent
            // conversation) rather than session/new (creating a fresh one).
            // A mirror that was opened before the writer persisted
            // remote_session_id has a stale/nil in-memory value; reading
            // the store row here fixes that before attach branches on it.
            // Only overwrite when the store has a non-empty value so we
            // don't clobber a good in-memory id with a missing row.
            if let row = try? store.loadSession(id: sessionId),
               let remote = row.remoteSessionId, !remote.isEmpty {
                session.remoteSessionId = remote
            }
            // Refresh the queue from the store so the taking-over instance
            // starts from the current persisted queue rather than whatever
            // stale/empty in-memory state the mirror cached. Queue writes
            // don't post a change notification, so the mirror's in-memory
            // queue can be stale at takeover time.
            let queue = (try? store.loadQueue(sessionId: sessionId)) ?? []
            session.restoreQueue(queue)
            session.agentState = .idle   // allow attach's agentState guard to proceed
            Task { await attach(to: sessionId, freshlyCreated: false) }
        }
    }

    /// Relinquish the writer role we just lost to a takeover: cancel any
    /// in-flight prompt, tear down the runner/agent, and become a mirror.
    /// Does NOT release the lease — we no longer own it.
    private func standDown(sessionId: ACPSession.ID) async {
        stopHeartbeat(sessionId: sessionId)
        stopWriterWatch(sessionId: sessionId)
        _ownedLeases.remove(sessionId)
        // We no longer own the lease — drop any not-yet-applied config so it
        // can't fire against a session another instance now drives.
        pendingModel.removeValue(forKey: sessionId)
        pendingMode.removeValue(forKey: sessionId)
        if let runner = runners.removeValue(forKey: sessionId) {
            runner.invalidateActivePrompt()
            runner.stop()
            await runner.connection.shutdown()
        }
        if let session = sessions[sessionId] {
            session.agentState = .idle
            session.transcript.streamingState = .idle
        }
        // Only begin mirroring when the session is still open. A takeover
        // notification can race with tab closure: if `detach`/`evictIfIdle`
        // already removed the session, starting a mirror poll would leak a
        // background task for a session that no longer exists.
        if sessions[sessionId] != nil {
            beginMirroring(sessionId: sessionId)
        }
    }

    // MARK: - Test accessors

    /// True once `shutdownBackgroundTasks` has been called. In-flight attach
    /// coroutines check this flag at their pre-commit guard to avoid
    /// registering a runner on a disposed manager.
    func isDisposedForTest() -> Bool { isDisposed }

    func ownsLeaseForTest(sessionId: ACPSession.ID) -> Bool {
        (try? store.loadLease(sessionId: sessionId))?.ownerInstance == instanceId
    }

    /// True while an `attach` coroutine holds the lease for `sessionId`
    /// but has not yet registered a runner. Used by tests to verify that
    /// `releaseAllOwnedLeases` skips attaching sessions.
    func isAttachingForTest(_ sessionId: ACPSession.ID) -> Bool {
        attachingSessions.contains(sessionId)
    }

    func heartbeatTickForTest(sessionId: ACPSession.ID) -> Bool {
        heartbeatTick(sessionId: sessionId)
    }

    /// True when a mirror poll task is active for `sessionId`. Used by
    /// tests to verify that eviction cancels the poll.
    func mirrorPollActiveForTest(sessionId: ACPSession.ID) -> Bool {
        mirrorPoll[sessionId] != nil
    }
}

// MARK: - Mirror (read-only follower)

extension ACPSessionManager {
    /// Start mirroring a session owned by another instance: subscribe to
    /// the change ping (debounced) and run a slow poll backstop. Never
    /// spawns a runner.
    func beginMirroring(sessionId: ACPSession.ID) {
        guard sessions[sessionId] != nil else { return }
        guard mirrorTokens[sessionId] == nil else { return }
        let token = changeNotifier.subscribe { [weak self] in
            // The Darwin notifier delivers off the main thread; hop back.
            Task { @MainActor [weak self] in
                self?.scheduleMirrorRefresh(sessionId: sessionId)
            }
        }
        mirrorTokens[sessionId] = token
        mirrorPoll[sessionId] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_500_000_000)   // 2.5s backstop
                await self?.refreshMirror(sessionId: sessionId)
            }
        }
        mirrorDebounce[sessionId]?.cancel()
        mirrorDebounce[sessionId] = Task { [weak self] in await self?.refreshMirror(sessionId: sessionId) }
    }

    func endMirroring(sessionId: ACPSession.ID) {
        if let t = mirrorTokens.removeValue(forKey: sessionId) { changeNotifier.unsubscribe(t) }
        mirrorDebounce.removeValue(forKey: sessionId)?.cancel()
        mirrorPoll.removeValue(forKey: sessionId)?.cancel()
    }

    /// Cancel every background task owned by this manager — mirror
    /// subscriptions/pollers (which have no runner and so are never reached
    /// by `detach`) and heartbeats. Called when the worktree's manager is
    /// disposed so nothing keeps waking after the manager is dropped.
    ///
    /// NOTE: does NOT release leases. Call `releaseAllOwnedLeases()` AFTER
    /// all runner connections have been shut down (`detach` loops in
    /// `disposeACPManager`) so a freed lease is never claimable while the
    /// old agent process is still alive.
    func shutdownBackgroundTasks() {
        isDisposed = true   // must be first: in-flight attach resumes after this and checks the flag
        for sid in Array(mirrorTokens.keys) { endMirroring(sessionId: sid) }
        for sid in Array(writerWatchTokens.keys) { stopWriterWatch(sessionId: sid) }
        for (_, task) in _heartbeatTasks { task.cancel() }
        _heartbeatTasks.removeAll()
    }

    /// Release every lease this manager still owns. Call AFTER runner
    /// connections are shut down so a freed lease is never claimable while
    /// the old agent is still alive.
    ///
    /// Sessions that are still in the pre-runner attach window (`attachingSessions`)
    /// are intentionally skipped: their `attach` defer releases the lease AFTER
    /// `connection.shutdown`, preserving the correct teardown order. The lease
    /// is never leaked — it is either released by the attach defer on abort, or
    /// goes stale in 15 s if the attach coroutine is permanently wedged.
    func releaseAllOwnedLeases() {
        for sid in Array(_ownedLeases) where !attachingSessions.contains(sid) {
            try? store.releaseLease(sessionId: sid, instanceId: instanceId)
            _ownedLeases.remove(sid)
        }
    }

    private func scheduleMirrorRefresh(sessionId: ACPSession.ID) {
        mirrorDebounce[sessionId]?.cancel()
        mirrorDebounce[sessionId] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)   // 100ms coalesce
            guard !Task.isCancelled else { return }
            await self?.refreshMirror(sessionId: sessionId)
        }
    }

    /// Re-read the transcript from SQLite and apply it into the cached
    /// mirror session. Performs a full rebuild using `replaceTranscriptMessages`
    /// so `toolCallIndices` and the render window stay consistent — bypassing
    /// by-index mutation avoids violating those invariants.
    func refreshMirror(sessionId: ACPSession.ID) async {
        guard let session = sessions[sessionId] else { return }
        // Always sync the queue — it can change (drain/clear) with no new
        // transcript rows, so this must run before any early-return below.
        let queue = (try? store.loadQueue(sessionId: sessionId)) ?? []
        session.restoreQueue(queue)
        // Sync transcript messages; early-return when nothing new to apply.
        let stored = (try? store.loadMessages(sessionId: sessionId)) ?? []
        guard !stored.isEmpty else { return }
        let decoder = JSONDecoder()
        var messages: [ACPMessage] = []
        messages.reserveCapacity(stored.count)
        for m in stored {
            guard let wire = try? ACPMessageWire.decode(kind: m.kind, payload: m.payload, decoder: decoder)
            else { continue }
            messages.append(wire.toMessage())
        }
        session.replaceTranscriptMessages(messages)
        // Anchor the visible window to the tail so new content is visible,
        // but only when the session is following the tail (user hasn't scrolled up).
        if session.followsTranscriptTail {
            session.transcript.resetWindowToTail()
        } else {
            applyRememberedTranscriptScrollWindow(to: session)
        }
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
        let firstRunAttach = freshlyCreated
            && !session.restoredFromPersistence
            && session.transcript.messages.isEmpty
        if firstRunAttach {
            session.firstRunConnectingPhase = .checkingSetup
        } else {
            session.firstRunConnectingPhase = nil
        }
        defer {
            if session.firstRunConnectingPhase != nil {
                session.firstRunConnectingPhase = nil
            }
        }

        // Claim the spawn slot BEFORE awaiting backfill so a concurrent
        // attach (e.g. retry button while the first attempt is still in the
        // backfill wait) early-returns on the `.spawning` guard above
        // instead of racing into a duplicate runner.
        session.agentState = .spawning
        // Only the lease holder runs a live agent + writes. If another
        // live instance owns this session, stay a read-only mirror.
        guard acquireWriterLease(sessionId: sessionId) else {
            session.agentState = .idle
            beginMirroring(sessionId: sessionId)
            return
        }
        endMirroring(sessionId: sessionId)
        startHeartbeat(sessionId: sessionId)
        startWriterWatch(sessionId: sessionId)
        // Mark this session as attaching so `releaseAllOwnedLeases` skips it.
        // The remove runs on every exit (success, abort, throw) via the defer below.
        attachingSessions.insert(sessionId)
        // Any failure path below must hand the session back: release the
        // lease and stop the heartbeat so another instance can claim it.
        // Only a fully-registered runner (the success path) keeps them.
        var attachSucceeded = false
        defer {
            attachingSessions.remove(sessionId)
            if !attachSucceeded {
                stopHeartbeat(sessionId: sessionId)
                stopWriterWatch(sessionId: sessionId)
                releaseWriterLease(sessionId: sessionId)
            }
        }
        // The runner persists transcript mutations under `msg-<sid>-<index>`,
        // where `index` is the in-memory transcript position. Tail-first
        // hydration leaves `transcript.messages` shorter than the persisted
        // row count until backfill prepends the older entries, so any apply()
        // that landed before that finished would overwrite the wrong stored
        // row (or skip an append it should have made). Wait here so the
        // in-memory and persisted indices line up before any runner work —
        // including replayed load updates — touches the store. No-op once
        // backfill is done.
        await awaitBackfill(id: sessionId)
        // Re-verify the session still exists; a close during the await above
        // would have cleared it.
        guard sessions[sessionId] === session else { return }
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
        session.contextRecoveryStatus = nil
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
        if firstRunAttach {
            session.firstRunConnectingPhase = .launchingAdapter
        }

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
            if firstRunAttach {
                session.firstRunConnectingPhase = .initializing
            }
            let initialized = try await connection.initialize()
            session.promptCapabilities = initialized.promptCapabilities
            session.authMethods = initialized.authMethods
            if let pendingAuthMethodId = session.pendingAuthMethodId {
                do {
                    try await connection.authenticate(methodId: pendingAuthMethodId)
                    session.pendingAuthMethodId = nil
                } catch {
                    let reason = ACPAuthFailure.message(from: error) ?? error.localizedDescription
                    session.setupState = .needsAuth(methods: initialized.authMethods, reason: reason)
                    session.agentState = .failed(reason)
                    await connection.shutdown()
                    return
                }
            }
            let shouldSuppressLoadReplay = !freshlyCreated
                && session.hydrationState == .ready
                && session.hasConversationTranscript
                && !(session.remoteSessionId ?? "").isEmpty
            let runner = ACPSessionRunner(session: session, connection: connection,
                                          store: store, sessionId: sessionId,
                                          worktreePath: worktreePath,
                                          agentEnv: ACPProcessEnvironment.sanitizedForACP(extra: spec.extraEnv),
                                          suppressingLoadReplay: shouldSuppressLoadReplay,
                                          onDirtyCheck: onDirtyCheck,
                                          onLiveBufferRead: onLiveBufferRead,
                                          onAuthRequired: { [weak self] runner, _ in
                                              await self?.handleAuthRequiredRunner(
                                                runner,
                                                sessionId: sessionId
                                              )
                                          },
                                          onPersist: { [weak self] in self?.changeNotifier.post() },
                                          onResumeTranscriptTail: { [weak self] in
                                              self?.rememberTranscriptScrollAnchor(
                                                sessionId: sessionId,
                                                anchorMessageId: nil,
                                                anchorMessageIndex: nil,
                                                followsTail: true
                                              )
                                          },
                                          ownerInstanceId: instanceId)
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
            if firstRunAttach {
                session.firstRunConnectingPhase = .creatingSession
            }
            if freshlyCreated {
                result = try await connection.newSession(cwd: worktreePath)
            } else if let remoteId = session.remoteSessionId, !remoteId.isEmpty {
                if session.hasConversationTranscript {
                    session.contextRecoveryStatus = .restoring
                }
                do {
                    result = try await connection.loadSession(cwd: worktreePath, sessionId: remoteId)
                    runner.finishSuppressingLoadReplay(
                        throughYieldedUpdateCount: connection.client.yieldedUpdateCount
                    )
                    if !pendingRecovery {
                        session.contextRecoveryStatus = nil
                    }
                } catch {
                    runner.finishSuppressingLoadReplay(
                        throughYieldedUpdateCount: connection.client.yieldedUpdateCount
                    )
                    if ACPAuthFailure.message(from: error) != nil {
                        throw error
                    }
                    result = try await connection.newSession(cwd: worktreePath)
                    if session.hasConversationTranscript {
                        shouldHoldQueueForRecovery = true
                        // Guard the store write: if another instance took over
                        // while we were awaiting loadSession/newSession, do not
                        // persist recovery state to a session we no longer own.
                        if !anotherLiveInstanceOwnsLease(sessionId: sessionId) {
                            persistContextRecoveryPending(sessionId: sessionId, pending: true)
                        }
                    }
                    restoreWarning = .init(
                        message: "Agent context could not be restored.",
                        canSendTranscript: session.hasConversationTranscript
                    )
                    if session.hasConversationTranscript {
                        session.contextRecoveryStatus = .sendingTranscript
                    }
                }
            } else {
                result = try await connection.newSession(cwd: worktreePath)
                if session.hasConversationTranscript {
                    shouldHoldQueueForRecovery = true
                    // Guard the store write: if another instance took over
                    // while we were awaiting newSession, do not persist
                    // recovery state to a session we no longer own.
                    if !anotherLiveInstanceOwnsLease(sessionId: sessionId) {
                        persistContextRecoveryPending(sessionId: sessionId, pending: true)
                    }
                }
                restoreWarning = .init(
                    message: "Agent context could not be restored.",
                    canSendTranscript: session.hasConversationTranscript
                )
                if session.hasConversationTranscript {
                    session.contextRecoveryStatus = .sendingTranscript
                }
            }
            if restoreWarning == nil, pendingRecovery {
                restoreWarning = .init(
                    message: "Agent context could not be restored.",
                    canSendTranscript: session.hasConversationTranscript
                )
                if session.hasConversationTranscript {
                    session.contextRecoveryStatus = .sendingTranscript
                }
            }
            // Abort the commit if we were taken over OR the manager was disposed
            // while we awaited spawn/initialize — never register a runner or
            // persist for a session we no longer (or never will) own.
            // `attachSucceeded` stays false so the defer releases the lease
            // and stops the heartbeat/writerWatch.
            if isDisposed || anotherLiveInstanceOwnsLease(sessionId: sessionId) {
                await connection.shutdown()
                startedRunner?.stop()
                session.agentState = .idle
                if !isDisposed { beginMirroring(sessionId: sessionId) }   // don't start a mirror on a disposed manager
                return
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
            attachSucceeded = true
            session.agentState = .ready
            if shouldHoldQueueForRecovery {
                sendTranscriptAsContext(sessionId: sessionId, agentName: nil)
            } else {
                runner.flushQueueIfIdle()
            }
            // Drain a pending model/mode picked during the post-takeover window.
            // The load result just above overwrote `currentModel`/`currentMode`
            // with the agent's restored values, so reapply + persist the user's
            // choice before firing the RPC — `session/set_model` returns nothing
            // and not every agent emits a follow-up update, so the local config
            // and stored row would otherwise drift off the agent's actual state.
            if let m = pendingModel.removeValue(forKey: sessionId) {
                session.currentModel = m
                persist(session)
                let remoteId = session.remoteSessionId ?? sessionId
                Task { try? await runner.connection.setModel(sessionId: remoteId, modelId: m) }
            }
            if let m = pendingMode.removeValue(forKey: sessionId) {
                session.currentMode = m
                persist(session)
                let remoteId = session.remoteSessionId ?? sessionId
                Task { try? await runner.connection.setMode(sessionId: remoteId, modeId: m) }
            }
            stderrTask.cancel()
        } catch {
            // Give stderr a moment to drain so the message is the real cause.
            try? await Task.sleep(nanoseconds: 200_000_000)
            stderrTask.cancel()
            let tail = stderrBuffer.tail()
            let authReason = ACPAuthFailure.message(from: error)
            let baseMessage = authReason ?? error.localizedDescription
            let base = "ACP initialize/new failed: \(baseMessage)"
            let full = tail.isEmpty ? base : base + "\nstderr: " + tail
            session.lastError = full
            session.contextRecoveryStatus = nil
            if let authReason {
                session.setupState = .needsAuth(methods: session.authMethods, reason: authReason)
                session.agentState = .failed(authReason)
            } else {
                session.agentState = .failed(full)
            }
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

        session.contextRecoveryStatus = .sendingTranscript
        runner.sendRecoveryContext(prompt) { delivered in
            if delivered {
                self.persistContextRecoveryPending(sessionId: sessionId, pending: false)
                session.contextRestoreWarning = nil
                session.markContextRecoveryRestored()
            } else {
                session.contextRecoveryStatus = .failed("Transcript recovery failed.")
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
        if case .needsAuth = session.setupState {
            return false
        }

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

    private func handleAuthRequiredRunner(
        _ runner: ACPSessionRunner,
        sessionId: ACPSession.ID
    ) async {
        guard runners[sessionId] === runner else { return }
        runner.invalidateActivePrompt()
        if let session = sessions[sessionId] {
            session.transcript.streamingState = .idle
            session.restoreQueue(session.queue)
        }
        runner.stop()
        runners[sessionId] = nil
        await runner.connection.shutdown()
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
        stopHeartbeat(sessionId: sessionId)
        stopWriterWatch(sessionId: sessionId)
        releaseWriterLease(sessionId: sessionId)
        endMirroring(sessionId: sessionId)
        // SwiftUI's `.onDisappear` retain release for a closing tab can
        // arrive BEFORE this async detach starts, so the release runs while
        // agentState is still `.ready` and short-circuits eviction. Re-check
        // now that state is `.idle` so a closed-while-attached session
        // doesn't keep its transcript + caches resident indefinitely.
        evictIfIdle(id: sessionId)
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
