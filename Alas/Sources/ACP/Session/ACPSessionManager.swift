import Foundation

private struct ACPTranscriptScrollMemory: Equatable {
    var anchorMessageId: String?
    /// ACP view ids for persisted text rows are regenerated during hydration;
    /// the transcript index is the durable restore target across eviction.
    var anchorMessageIndex: Int?
    var followsTail: Bool
}

private enum ACPMirrorRefreshPolicy {
    static let debounceNanos: UInt64 = 100_000_000
    static let activePollNanos: UInt64 = 2_500_000_000
    static let inactivePollNanos: UInt64 = 30_000_000_000
}

@MainActor
final class ACPSessionManager: ObservableObject {
    typealias ACPSetupEvaluator = @MainActor (_ spec: ACPLaunchSpec) async -> ACPSetupResult
    typealias ACPConnectionFactory = @MainActor (
        _ spec: ACPLaunchSpec,
        _ host: String?,
        _ worktreePath: String
    ) throws -> ACPConnection
    typealias MCPProjectContextProvider = @MainActor () -> MCPProjectContext?

    let instanceId: String
    let pid: Int64
    let worktreeId: String
    let worktreePath: String
    let persistence: ACPSessionPersistence
    let changeNotifier: ACPChangeNotifier
    /// Called by each runner's write handler to check whether the target path
    /// has an open, dirty editor buffer. `nil` disables the check (no notices).
    let onDirtyCheck: ((String) -> Bool)?
    /// Read the in-memory editor contents for the absolute `path` when an
    /// open dirty buffer exists. Returns nil for clean/un-opened files;
    /// the runner falls back to disk in that case. Lets agent reads see
    /// the user's unsaved edits rather than stale disk bytes.
    let onLiveBufferRead: ((String) -> String?)?
    private let onSessionTitleUpdated: ((ACPSession.ID, String) -> Void)?
    private let onInputAwaiting: ((ACPSession, ACPUserInputRequest) -> Void)?
    private let mcpProjectContextProvider: MCPProjectContextProvider?
    @Published private(set) var sessions: [ACPSession.ID: ACPSession] = [:]
    @Published private(set) var recent: [ACPSessionRow] = []
    @Published private(set) var persistenceError: String?
    @Published private var persistedRows: [ACPSession.ID: ACPSessionRow] = [:]
    @Published private var missingPersistedSessionIds: Set<ACPSession.ID> = []
    private var rowLoadTasks: [ACPSession.ID: Task<Void, Never>] = [:]
    private var persistenceTail: Task<Void, Never>?
    private var persistenceGeneration = 0
    private var draftFlushHandoffSequence: UInt64 = 0
    private(set) var runners: [ACPSession.ID: ACPSessionRunner] = [:]
    private var elicitationCoordinators: [ACPSession.ID: ACPElicitationCoordinator] = [:]
    private var autoReconnectTasks: [ACPSession.ID: Task<Void, Never>] = [:]
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
    func answerQuestion(
        for id: ACPSession.ID,
        requestId: JSONRPCID,
        _ response: ACPQuestionResponse
    ) {
        elicitationCoordinators[id]?.respondToCursor(id: requestId, response: response)
    }

    func respondToUserInput(
        for id: ACPSession.ID,
        token: UUID,
        action: ACPUserInputAction
    ) {
        elicitationCoordinators[id]?.respond(to: token, action: action)
    }

    @discardableResult
    func openElicitationURL(for id: ACPSession.ID, token: UUID) async -> Bool {
        await elicitationCoordinators[id]?.openURL(for: token) == true
    }

    func dismissElicitationURLWait(for id: ACPSession.ID, elicitationId: String) {
        elicitationCoordinators[id]?.dismissURLWait(elicitationId: elicitationId)
    }

    /// Lightweight summaries for the remote sessions list.
    var sessionRows: [ACPSessionRow] { recent }

    /// Whether this instance is the legitimate current writer for the session —
    /// gates every remote drive action (`canDrive`, `sendPrompt`, `stop`).
    ///
    /// Combines the local claim with the latest lease observation. The writer
    /// watch refreshes that observation after takeover; SQLite mutations also
    /// carry a token fence so stale cached authority cannot commit.
    func isWriter(for id: ACPSession.ID) -> Bool {
        _ownedLeases.contains(id) && !anotherLiveInstanceOwnsLease(sessionId: id)
    }

    /// Confirms ownership off-main immediately before an RPC or local process
    /// side effect. Cached observations remain suitable for rendering, but are
    /// not authority for actions that cannot be transactionally fenced.
    private func confirmedWriterLease(for sessionId: ACPSession.ID) async -> Bool {
        guard _ownedLeases.contains(sessionId),
              let token = ownedLeaseTokens[sessionId]
        else { return false }
        do {
            let lease = try await persistence.loadLease(sessionId: sessionId)
            observedLeases[sessionId] = lease
            guard lease?.ownerInstance == instanceId, lease?.token == token else {
                await standDown(sessionId: sessionId)
                return false
            }
            return true
        } catch {
            persistenceError = error.localizedDescription
            await standDown(sessionId: sessionId)
            return false
        }
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
    func sendPrompt(for id: ACPSession.ID, text: String, attachments: [ACPMessage.Attachment], onResult: @escaping @MainActor (Bool) -> Void) async {
        guard await confirmedWriterLease(for: id) else {
            onResult(false)
            return
        }
        let accepted = submit(sessionId: id, text: text, attachments: attachments, intent: .auto,
                              onCompleted: { ok in onResult(ok) })
        if !accepted { onResult(false) }   // submit refused synchronously; onCompleted won't fire
    }

    /// Interrupt the in-flight turn (same as the composer Stop / Esc). Guarded
    /// on the live lease for the same cross-process-takeover reason as `sendPrompt`.
    func interrupt(for id: ACPSession.ID) async {
        guard await confirmedWriterLease(for: id), let runner = runners[id] else { return }
        await runner.userCancel()
    }

    /// Pending model/mode to apply once a runner registers (the writer took over
    /// but `attach` is still in flight). Keyed by session id. Applied in `attach`.
    var pendingModel: [ACPSession.ID: String] = [:]
    var pendingMode: [ACPSession.ID: String] = [:]

    /// Toggle auto-run for a remotely-driven session. Writer-gated; persists.
    func setAutoRun(for id: ACPSession.ID, enabled: Bool) async {
        guard await confirmedWriterLease(for: id), let session = sessions[id] else { return }
        session.autoRunEnabled = enabled
        persist(session)
    }

    /// Select the agent model. Optimistically updates + persists, then issues the
    /// agent RPC on the live runner — or records it pending until `attach`
    /// registers one (post-takeover window). Writer-gated.
    func setModel(for id: ACPSession.ID, modelId: String) async {
        guard await confirmedWriterLease(for: id), let session = sessions[id] else { return }
        session.currentModel = modelId
        persist(session)
        guard let runner = runners[id] else {
            pendingModel[id] = modelId
            return
        }
        let remoteId = session.remoteSessionId ?? id
        try? await runner.connection.setModel(sessionId: remoteId, modelId: modelId)
    }

    /// Select the agent mode. Same semantics as `setModel`.
    func setMode(for id: ACPSession.ID, modeId: String) async {
        guard await confirmedWriterLease(for: id), let session = sessions[id] else { return }
        session.currentMode = modeId
        persist(session)
        guard let runner = runners[id] else {
            pendingMode[id] = modeId
            return
        }
        let remoteId = session.remoteSessionId ?? id
        try? await runner.connection.setMode(sessionId: remoteId, modeId: modeId)
    }

    /// Sessions for which THIS instance holds the writer lease (backing store).
    var _ownedLeases: Set<ACPSession.ID> = []
    private var ownedLeaseTokens: [ACPSession.ID: String] = [:]
    private var observedLeases: [ACPSession.ID: ACPSessionLease?] = [:]
    /// Per-session periodic heartbeat tasks (backing store).
    var _heartbeatTasks: [ACPSession.ID: Task<Void, Never>] = [:]
    /// Per-session debounced write tasks for `composer_drafts`. The
    /// in-memory `session.composerDraft` updates on every keystroke;
    /// the SQLite write only fires after a brief idle (or a forced
    /// flush on submit / delete). Cancelled and re-scheduled on each
    /// further keystroke so a typing burst produces one write.
    private var pendingDraftWrites: [ACPSession.ID: Task<Void, Never>] = [:]
    private struct DraftFlushHandoff {
        let draft: ACPComposerDraft
        let sequence: UInt64
    }
    private var draftFlushHandoffs: [ACPSession.ID: DraftFlushHandoff] = [:]
    private static let draftDebounceNanos: UInt64 = 300_000_000
    private let setupEvaluator: ACPSetupEvaluator
    private let connectionFactory: ACPConnectionFactory
    private var inFlightHydrations: [ACPSession.ID: Task<Void, Never>] = [:]
    /// Per-session task that prepends pre-tail messages after the initial
    /// tail-only paint applied by `applyHydration`. Tracked so tests (and
    /// teardown) can wait for it; production UI does not.
    private var inFlightBackfills: [ACPSession.ID: Task<Void, Never>] = [:]
    private var pendingBackfillOlderWires: [ACPSession.ID: [ACPMessageWire]] = [:]

    /// Per-session UI refcount. When this drops to zero AND the session is
    /// not `attached`, the cached `ACPSession` is evicted from `sessions`.
    /// Re-opening through `placeholderSession` + `hydrateIfNeeded` recreates
    /// it cleanly from SQLite.
    private var sessionRefCounts: [ACPSession.ID: Int] = [:]
    /// Per-session active tab count. Other surfaces may retain a cached
    /// session without making its transcript visible; mirror polling uses
    /// this narrower signal to back off when the ACP tab is not on screen.
    private var visibleSessionCounts: [ACPSession.ID: Int] = [:]
    // MARK: Mirror state (read-only follower when another instance holds the lease)
    private var mirrorTokens: [ACPSession.ID: Int32] = [:]
    private var mirrorDebounce: [ACPSession.ID: Task<Void, Never>] = [:]
    private var mirrorPoll: [ACPSession.ID: Task<Void, Never>] = [:]
    private var inFlightMirrorRefreshes: [ACPSession.ID: Task<Void, Never>] = [:]
    private var dirtyMirrorRefreshes: Set<ACPSession.ID> = []
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

    init(worktreeId: String, worktreePath: String, store: ACPSessionStore? = nil,
         persistence: ACPSessionPersistence? = nil,
         instanceId: String = UUID().uuidString,
         pid: Int64 = Int64(ProcessInfo.processInfo.processIdentifier),
         hydratorPath: String? = nil,
         onDirtyCheck: ((String) -> Bool)? = nil,
         onLiveBufferRead: ((String) -> String?)? = nil,
         onSessionTitleUpdated: ((ACPSession.ID, String) -> Void)? = nil,
         onInputAwaiting: ((ACPSession, ACPUserInputRequest) -> Void)? = nil,
         changeNotifier: ACPChangeNotifier? = nil,
         setupEvaluator: ACPSetupEvaluator? = nil,
         connectionFactory: ACPConnectionFactory? = nil,
         mcpProjectContextProvider: MCPProjectContextProvider? = nil)
    {
        precondition(store != nil || persistence != nil, "ACPSessionManager requires persistence")
        let resolvedPersistence = persistence ?? ACPSessionPersistence(path: store!.path)
        self.instanceId = instanceId
        self.pid = pid
        self.worktreeId = worktreeId
        self.worktreePath = worktreePath
        self.persistence = resolvedPersistence
        self.onDirtyCheck = onDirtyCheck
        self.onLiveBufferRead = onLiveBufferRead
        self.onSessionTitleUpdated = onSessionTitleUpdated
        self.onInputAwaiting = onInputAwaiting
        self.mcpProjectContextProvider = mcpProjectContextProvider
        self.changeNotifier = changeNotifier ?? DarwinChangeNotifier(worktreeId: worktreeId)
        _ = hydratorPath
        self.setupEvaluator = setupEvaluator ?? { spec in
            let checker = ACPSetupChecker(env: ProcessInfo.processInfo.environment)
            return await checker.evaluate(spec.setupCheck)
        }
        self.connectionFactory = connectionFactory ?? { spec, host, worktreePath in
            let client: ACPStdioClient
            if let host {
                let invocation = ACPRemoteLaunch.channelInvocation(
                    host: host,
                    worktreePath: worktreePath,
                    command: spec.command,
                    arguments: spec.arguments
                )
                // Keep ssh's parent environment intact for SSH_AUTH_SOCK,
                // HOME, and any host-specific connection configuration.
                client = try ACPStdioClient(
                    executable: URL(fileURLWithPath: invocation.executable),
                    arguments: invocation.args,
                    environment: nil
                )
            } else if spec.command.hasPrefix("/") {
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
        let initialRecent = store.flatMap { try? $0.recentSessions() } ?? []
        self.recent = initialRecent
        self.persistedRows = Dictionary(uniqueKeysWithValues: initialRecent.map { ($0.id, $0) })
        if store == nil {
            refreshRecent()
        }
    }

    @discardableResult
    private func enqueuePersistence(
        _ operation: @escaping @Sendable (ACPSessionPersistence) async throws -> Void
    ) -> Task<Void, Never> {
        let previous = persistenceTail
        let persistence = persistence
        persistenceGeneration += 1
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            do {
                try await operation(persistence)
            } catch {
                self?.persistenceError = error.localizedDescription
            }
        }
        persistenceTail = task
        return task
    }

    func flushPersistence() async {
        while let tail = persistenceTail {
            let generation = persistenceGeneration
            await tail.value
            if persistenceGeneration == generation { return }
        }
    }

    func flushAllPersistence() async {
        for runner in runners.values {
            await runner.flushPersistence()
        }
        await flushPersistence()
    }

    func createSession(agentId: String, autoRunDefault: Bool = false) -> ACPSession {
        let id = UUID().uuidString
        let now = Int64(Date().timeIntervalSince1970)
        let row = ACPSessionRow(
            id: id, agentId: agentId, title: "New session",
            titleSource: .placeholder,
            currentModel: nil, currentMode: nil, autoRun: autoRunDefault,
            createdAt: now, updatedAt: now, lastOpenedAt: now, archived: false)
        persistedRows[id] = row
        recent.removeAll { $0.id == id }
        recent.insert(row, at: 0)
        enqueuePersistence { persistence in
            try await persistence.upsertSession(row)
        }
        let session = ACPSession(
            id: id, agentId: agentId, worktreeId: worktreeId,
            title: row.title, titleSource: .placeholder, origin: row.origin,
            hydrationState: .ready)
        session.autoRunEnabled = autoRunDefault
        sessions[id] = session
        return session
    }

    /// Returns a cached session or a `.loading` placeholder. Cache hits
    /// are O(1); cache misses do a single indexed `loadSession` query
    /// against SQLite so we don't insert orphan loading entries for
    /// typo'd ids. The heavy work (loading every message, decoding,
    /// reading the queue + draft) is deferred to `hydrateIfNeeded`.
    func placeholderSession(id: ACPSession.ID) -> ACPSession? {
        if let s = sessions[id] { return s }
        guard let row = persistedRows[id] else {
            loadPersistedRowIfNeeded(id: id)
            return nil
        }
        let session = ACPSession(
            id: row.id, agentId: row.agentId, worktreeId: worktreeId,
            title: row.title, titleSource: row.titleSource, origin: row.origin,
            hydrationState: .loading,
            restoredFromPersistence: true)
        session.remoteSessionId = row.remoteSessionId
        if let memory = transcriptScrollMemory[id] {
            session.followsTranscriptTail = memory.followsTail
        }
        if let handoff = draftFlushHandoffs[id] {
            session.replaceComposerDraft(handoff.draft)
        }
        sessions[id] = session
        return session
    }

    func isKnownMissingSession(id: ACPSession.ID) -> Bool {
        missingPersistedSessionIds.contains(id)
    }

    private func loadPersistedRowIfNeeded(id: ACPSession.ID) {
        guard rowLoadTasks[id] == nil else { return }
        let persistence = persistence
        rowLoadTasks[id] = Task { @MainActor [weak self] in
            defer { self?.rowLoadTasks[id] = nil }
            do {
                guard let row = try await persistence.loadSession(id: id) else {
                    self?.missingPersistedSessionIds.insert(id)
                    return
                }
                self?.persistedRows[id] = row
                self?.missingPersistedSessionIds.remove(id)
            } catch {
                self?.persistenceError = error.localizedDescription
            }
        }
    }

    /// Loads one row for an explicit open request. Unlike `sessionRows`, this
    /// covers rows outside the lazy recent-session cache before a tab title is
    /// chosen.
    func persistedSessionRow(id: ACPSession.ID) async -> ACPSessionRow? {
        if let row = persistedRows[id] { return row }
        do {
            guard let row = try await persistence.loadSession(id: id) else { return nil }
            persistedRows[id] = row
            missingPersistedSessionIds.remove(id)
            return row
        } catch {
            persistenceError = error.localizedDescription
            return nil
        }
    }

    /// Awaits any in-flight background backfill of older transcript messages
    /// for `id`. After `hydrateIfNeeded` returns, only the tail window has
    /// been applied to the transcript so the UI can paint immediately; the
    /// rest is prepended on a separate task. Production callers rarely need
    /// to wait for it (the UI is happy with the tail), but tests use this to
    /// observe the fully-materialised transcript.
    func awaitBackfill(id: ACPSession.ID) async {
        while let task = inFlightBackfills[id] {
            await task.value
        }
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
            let result = try await persistence.hydrate(sessionId: id)
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

    private func applyHydration(_ result: HydrationResult, to session: ACPSession) {
        persistedRows[result.row.id] = result.row
        for row in result.recent {
            persistedRows[row.id] = row
        }
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
        let tailStart = replaceTranscriptWithTail(wires, in: session, markCompletedBoundary: true)
        applyRememberedTranscriptScrollWindow(to: session, messageIndexOffset: tailStart)
        session.restoreQueue(result.queue)
        // The composer is rendered (and focused) the moment the placeholder
        // appears, so the user can start typing before hydration finishes.
        // Only restore the draft when the live composer is still pristine
        // (revision == 0); an intentional clear still bumps the revision, so
        // it's distinguishable from "never edited" even though both leave
        // `composerDraft.isEmpty == true`.
        if session.composerDraftRevision == 0 {
            if let handoff = draftFlushHandoffs[session.id] {
                session.replaceComposerDraft(handoff.draft)
            } else if let draft = result.draft {
                session.replaceComposerDraft(draft)
            }
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

    /// Apply only the visible tail of a wire transcript on the main actor.
    /// The caller can schedule older-message backfill after it has applied
    /// any surrounding session state.
    @discardableResult
    private func replaceTranscriptWithTail(
        _ wires: [ACPMessageWire],
        in session: ACPSession,
        markCompletedBoundary: Bool
    ) -> Int {
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
        if markCompletedBoundary {
            // Seed completedOutputBoundaryMessageIds from loaded history so
            // replay guards can detect a completed previous turn after restart.
            session.markCompletedOutputBoundary()
        }
        return tailStart
    }

    /// Mirror of `ACPSession.hasConversationTranscript` that operates on the
    /// wire (Sendable) representation, so callers can ask the question
    /// before the in-memory transcript has been fully reassembled — i.e.
    /// during the tail-only window of tail-first hydration.
    private static func wireMessagesHaveConversation(_ wires: [ACPMessageWire]) -> Bool {
        wires.contains { wire in
            switch wire {
            case let .user(_, text, _):
                return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case let .agent(_, text):
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
        if let existing = inFlightBackfills[sessionId], !existing.isCancelled {
            if olderWires.isEmpty {
                existing.cancel()
                inFlightBackfills[sessionId] = nil
                pendingBackfillOlderWires[sessionId] = nil
                session.transcript.isBackfillingOlderMessages = false
            } else {
                pendingBackfillOlderWires[sessionId] = olderWires
                session.transcript.isBackfillingOlderMessages = true
            }
            return
        }

        inFlightBackfills[sessionId] = nil
        pendingBackfillOlderWires[sessionId] = nil
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
                  let me = handle.task,
                  self.inFlightBackfills[sessionId] == me,
                  self.sessions[sessionId] === session
            else { return }
            if let newerWires = self.pendingBackfillOlderWires.removeValue(forKey: sessionId) {
                self.inFlightBackfills[sessionId] = nil
                self.scheduleBackfillIfNeeded(
                    olderWires: newerWires,
                    sessionId: sessionId,
                    session: session)
                return
            }
            session.prependTranscriptMessages(older)
            self.applyRememberedTranscriptScrollWindow(to: session)
        }
        handle.task = task
        inFlightBackfills[sessionId] = task
    }

    func closeSession(id: ACPSession.ID) {
        autoReconnectTasks.removeValue(forKey: id)?.cancel()
        // Flush any pending draft write before dropping the in-memory
        // session reference — otherwise a tab-switch-while-typing
        // window can lose the last ~300ms of input.
        flushPendingDraftWrite(for: id)
        inFlightBackfills[id]?.cancel()
        inFlightBackfills[id] = nil
        pendingBackfillOlderWires[id] = nil
        sessions[id]?.transcript.resetMarkdownCaches()
        sessions[id] = nil
        sessionRefCounts.removeValue(forKey: id)
        visibleSessionCounts.removeValue(forKey: id)
        planSidebarVisibility.removeValue(forKey: id)
        transcriptScrollMemory.removeValue(forKey: id)
        pendingModel.removeValue(forKey: id)
        pendingMode.removeValue(forKey: id)
    }

    func deleteSession(id: ACPSession.ID) {
        autoReconnectTasks.removeValue(forKey: id)?.cancel()
        cancelPendingDraftWrite(for: id)
        inFlightBackfills[id]?.cancel()
        inFlightBackfills[id] = nil
        pendingBackfillOlderWires[id] = nil
        sessions[id]?.transcript.resetMarkdownCaches()
        sessions[id] = nil
        sessionRefCounts.removeValue(forKey: id)
        visibleSessionCounts.removeValue(forKey: id)
        planSidebarVisibility.removeValue(forKey: id)
        transcriptScrollMemory.removeValue(forKey: id)
        pendingModel.removeValue(forKey: id)
        pendingMode.removeValue(forKey: id)
        persistedRows.removeValue(forKey: id)
        recent.removeAll { $0.id == id }
        enqueuePersistence { persistence in
            try await persistence.deleteSession(id: id)
        }
    }

    /// Increment the UI refcount for `id`. No-op if the session isn't
    /// currently cached (e.g. typo'd id, or already evicted by a prior
    /// release). Callers must pair every retain with exactly one release.
    func retainSession(id: ACPSession.ID) {
        guard sessions[id] != nil else { return }
        sessionRefCounts[id, default: 0] += 1
    }

    /// Marks an ACP tab as actively visible for `id`. This is intentionally
    /// separate from `retainSession`: sidebars can retain rows for cache
    /// lifetime without needing the mirror poller to stay hot.
    func markSessionVisible(id: ACPSession.ID) {
        guard sessions[id] != nil else { return }
        let wasHidden = (visibleSessionCounts[id] ?? 0) == 0
        visibleSessionCounts[id, default: 0] += 1
        if wasHidden {
            wakeVisibleMirror(sessionId: id)
        }
    }

    func unmarkSessionVisible(id: ACPSession.ID) {
        guard let current = visibleSessionCounts[id], current > 0 else { return }
        let next = current - 1
        if next == 0 {
            visibleSessionCounts.removeValue(forKey: id)
        } else {
            visibleSessionCounts[id] = next
        }
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
            let memory = ACPTranscriptScrollMemory(
                anchorMessageId: anchorMessageId,
                anchorMessageIndex: anchorMessageIndex,
                followsTail: false
            )
            if transcriptScrollMemory[id] != memory {
                transcriptScrollMemory[id] = memory
            }
        }
        if sessions[id]?.followsTranscriptTail != followsTail {
            sessions[id]?.followsTranscriptTail = followsTail
        }
    }

    private func applyRememberedTranscriptScrollWindow(
        to session: ACPSession,
        messageIndexOffset: Int = 0
    ) {
        guard let memory = transcriptScrollMemory[session.id], !memory.followsTail else { return }
        if let index = memory.anchorMessageIndex {
            let localIndex = index - messageIndexOffset
            guard localIndex >= 0, localIndex < session.transcript.messages.count else { return }
            session.transcript.setVisibleWindow(containing: localIndex)
            return
        }
        guard let anchor = memory.anchorMessageId,
              let index = session.transcript.messages.firstIndex(where: { $0.stableId == anchor })
        else { return }
        session.transcript.setVisibleWindow(containing: index)
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
        // Submit the debounced composer-draft write before dropping the
        // in-memory session. Otherwise a typing burst that
        // ends within the 300ms debounce window loses its tail when the
        // session is evicted — the timer task fires on a nil `sessions[id]`
        // and silently returns.
        flushPendingDraftWrite(for: id)
        inFlightBackfills[id]?.cancel()
        inFlightBackfills[id] = nil
        pendingBackfillOlderWires[id] = nil
        // Stop any active mirror poll/subscription so the 2.5s poll task
        // doesn't keep waking after a mirrored tab closes. Idempotent —
        // no-op for writer sessions.
        endMirroring(sessionId: id)
        session.transcript.resetMarkdownCaches()
        sessions[id] = nil
        visibleSessionCounts.removeValue(forKey: id)
    }

    func setArchived(id: ACPSession.ID, archived: Bool) {
        if var row = persistedRows[id] {
            row.archived = archived
            persistedRows[id] = row
        }
        recent.removeAll { $0.id == id }
        enqueuePersistence { persistence in
            try await persistence.setArchived(id: id, archived: archived)
        }
    }

    /// Persist a fresh trailing chunk of messages (`from..<session.transcript.messages.count`)
    /// to the store. Used by code paths that mutate the session outside the
    /// runner's update loop (composer fallback when no runner is attached
    /// yet, or any direct manager call) so the messages survive a reload.
    func persistTrailingMessages(_ session: ACPSession, fromIndex from: Int) {
        let now = Int64(Date().timeIntervalSince1970)
        let messages = session.transcript.messages
        guard from < messages.count else { return }
        var rows: [ACPStoredMessage] = []
        for i in from..<messages.count {
            let m = messages[i]
            guard let payload = try? ACPMessageCodec.encode(m) else { continue }
            let id = "msg-\(session.id)-\(i)"
            let sessionId = session.id
            rows.append(ACPStoredMessage(
                id: id,
                sessionId: sessionId,
                kind: m.kind,
                seq: Int64(i),
                payload: payload,
                createdAt: now
            ))
        }
        let messageRows = rows
        let fence = leaseFence(sessionId: session.id)
        if !messageRows.isEmpty {
            enqueuePersistence { persistence in
                _ = try await persistence.persistMessages(messageRows, fence: fence)
            }
        }
    }

    /// Persist a session-level change (model/mode/title/autoRun) and bump updated_at.
    /// No-ops only when another live instance owns the writer lease (this pane
    /// is a mirror); the writer and not-yet-leased cases persist normally.
    func persist(_ s: ACPSession, preserveTitle: Bool = true) {
        guard !isMirror(sessionId: s.id) else { return }
        guard var row = persistedRows[s.id] else { return }
        let now = Int64(Date().timeIntervalSince1970)
        if !preserveTitle {
            row.title = s.title
            row.titleSource = s.titleSource
        }
        row.currentModel = s.currentModel
        row.currentMode = s.currentMode
        row.autoRun = s.autoRunEnabled
        row.updatedAt = now
        persistedRows[s.id] = row
        replaceRecentRow(row)
        let rowToPersist = row
        let fence = leaseFence(sessionId: s.id)
        enqueuePersistence { persistence in
            _ = try await persistence.upsertSession(
                rowToPersist,
                preserveTitle: preserveTitle,
                fence: fence
            )
        }
    }

    private func persistSessionRemoteId(_ s: ACPSession) {
        guard var row = persistedRows[s.id] else { return }
        row.remoteSessionId = s.remoteSessionId
        persistedRows[s.id] = row
        replaceRecentRow(row)
        let rowToPersist = row
        let fence = leaseFence(sessionId: s.id)
        enqueuePersistence { persistence in
            _ = try await persistence.upsertSession(rowToPersist, fence: fence)
        }
    }

    private func persistContextRecoveryPending(sessionId: ACPSession.ID, pending: Bool) {
        if var row = persistedRows[sessionId] {
            row.contextRecoveryPending = pending
            persistedRows[sessionId] = row
        }
        let fence = leaseFence(sessionId: sessionId)
        enqueuePersistence { persistence in
            _ = try await persistence.setContextRecoveryPending(
                sessionId: sessionId,
                pending: pending,
                fence: fence
            )
        }
    }

    /// Rename a session with the given title and source. Updates both
    /// the in-memory session and SQLite in one call. No-ops only when
    /// another live instance owns the writer lease (this pane is a mirror).
    func renameSession(id: ACPSession.ID, title: String, source: ACPSessionTitleSource) {
        guard !isMirror(sessionId: id) else { return }
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
              var row = persistedRows[id],
              !row.archived else { return false }
        let now = Int64(Date().timeIntervalSince1970)
        row.title = trimmed
        row.titleSource = source
        row.updatedAt = now
        persistedRows[id] = row
        replaceRecentRow(row)
        if let session = sessions[id] {
            session.title = trimmed
            session.titleSource = source
        }
        enqueuePersistence { persistence in
            _ = try await persistence.renameSession(
                id: id,
                title: trimmed,
                titleSource: source,
                updatedAt: now
            )
        }
        return true
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
        let sessionId = session.id
        let fence = leaseFence(sessionId: sessionId)
        enqueuePersistence { persistence in
            _ = try await persistence.deleteComposerDraft(sessionId: sessionId, fence: fence)
        }
    }

    private func scheduleDraftPersistence(for sessionId: ACPSession.ID) {
        pendingDraftWrites[sessionId]?.cancel()
        pendingDraftWrites[sessionId] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.draftDebounceNanos)
            guard !Task.isCancelled else { return }
            self?.flushPendingDraftWrite(for: sessionId)
        }
    }

    private func flushPendingDraftWrite(for sessionId: ACPSession.ID) {
        pendingDraftWrites[sessionId] = nil
        // Write the LATEST in-memory state, not whatever was captured at
        // schedule time — additional keystrokes may have come in during
        // the debounce window.
        guard let session = sessions[sessionId] else { return }
        let draft = session.composerDraft
        let fence = leaseFence(sessionId: sessionId)
        draftFlushHandoffSequence += 1
        let handoffSequence = draftFlushHandoffSequence
        draftFlushHandoffs[sessionId] = DraftFlushHandoff(draft: draft, sequence: handoffSequence)
        let persistenceTask: Task<Void, Never>
        if draft.isEmpty {
            persistenceTask = enqueuePersistence { persistence in
                _ = try await persistence.deleteComposerDraft(sessionId: sessionId, fence: fence)
            }
        } else {
            let now = Int64(Date().timeIntervalSince1970)
            persistenceTask = enqueuePersistence { persistence in
                try await persistence.upsertComposerDraft(
                    sessionId: sessionId,
                    draft: draft,
                    updatedAt: now,
                    fence: fence
                )
            }
        }
        Task { @MainActor [weak self] in
            await persistenceTask.value
            guard self?.draftFlushHandoffs[sessionId]?.sequence == handoffSequence else { return }
            self?.draftFlushHandoffs.removeValue(forKey: sessionId)
        }
    }

    private func cancelPendingDraftWrite(for sessionId: ACPSession.ID) {
        pendingDraftWrites[sessionId]?.cancel()
        pendingDraftWrites[sessionId] = nil
    }

    /// Submit every pending debounced draft write to the ordered persistence
    /// pipeline. Callers that require durability then await `flushPersistence`.
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
        guard !isMirror(sessionId: session.id) else { return }
        let sessionId = session.id
        let items = session.queue
        let fence = leaseFence(sessionId: sessionId)
        enqueuePersistence { persistence in
            _ = try await persistence.upsertQueue(
                sessionId: sessionId,
                items: items,
                fence: fence
            )
        }
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
            let submittedAfterSeq = session.transcript.messages.isEmpty
                ? nil
                : Int64(session.transcript.messages.count - 1)
            let fence = leaseFence(sessionId: sid)
            enqueuePersistence { persistence in
                try await persistence.upsertComposerDraft(
                    sessionId: sid,
                    draft: submitted,
                    updatedAt: now,
                    submittedRecovery: true,
                    submittedAfterSeq: submittedAfterSeq,
                    fence: fence
                )
            }
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
        let sessionId = session.id
        let fence = leaseFence(sessionId: sessionId)
        enqueuePersistence { persistence in
            _ = try await persistence.deleteComposerDraft(sessionId: sessionId, fence: fence)
        }
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
        let now = Int64(Date().timeIntervalSince1970)
        let sessionId = session.id
        let fence = leaseFence(sessionId: sessionId)
        enqueuePersistence { persistence in
            try await persistence.upsertComposerDraft(
                sessionId: sessionId,
                draft: submitted,
                updatedAt: now,
                fence: fence
            )
        }
    }

    func refreshRecent() {
        Task { @MainActor [weak self] in
            await self?.refreshRecentNow()
        }
    }

    func refreshRecentNow() async {
        let persistence = persistence
        do {
            let rows = try await persistence.recentSessions()
            recent = rows
            for row in rows {
                persistedRows[row.id] = row
            }
        } catch {
            persistenceError = error.localizedDescription
        }
    }

    private func replaceRecentRow(_ row: ACPSessionRow) {
        recent.removeAll { $0.id == row.id }
        guard !row.archived else { return }
        let insertionIndex = recent.firstIndex { $0.lastOpenedAt < row.lastOpenedAt } ?? recent.endIndex
        recent.insert(row, at: insertionIndex)
    }

    func makeSessionDiscoveryHandle(agentId: String) async throws -> ACPSessionDiscoveryHandle {
        guard let spec = ACPLaunchCatalog.spec(for: agentId) else {
            throw ACPSessionDiscoveryError.noLaunchSpec(agentId)
        }
        let setup = await evaluateSetup(for: spec)
        guard case .ready = setup else {
            throw ACPSessionDiscoveryError.setupRequired(setup.reasonText)
        }

        let host = RemoteHostRegistry.shared.host(forPath: worktreePath)
        let launchSpec = await resolvedLaunchSpec(for: spec, host: host)
        let connection = try connectionFactory(launchSpec, host, worktreePath)
        do {
            let initialized = try await connection.initialize()
            guard initialized.sessionCapabilities.supportsList else {
                throw ACPSessionDiscoveryError.listingUnsupported
            }
            return ACPSessionDiscoveryHandle(
                worktreeId: worktreeId,
                agentId: agentId,
                cwd: worktreePath,
                persistence: persistence,
                connection: connection,
                capabilities: .init(
                    canLoad: initialized.loadSession,
                    canResume: initialized.sessionCapabilities.supportsResume,
                    canFork: initialized.sessionCapabilities.supportsFork
                )
            )
        } catch {
            await connection.shutdown()
            throw error
        }
    }

    @discardableResult
    func materializeDiscoveredSession(
        _ discovered: ACPDiscoveredSession,
        autoRunDefault: Bool = false,
        origin: ACPSessionOrigin = .agentImported
    ) async -> ACPSessionRow? {
        let discoveredCWD = URL(fileURLWithPath: discovered.cwd).standardizedFileURL.path
        let managerCWD = URL(fileURLWithPath: worktreePath).standardizedFileURL.path
        guard discovered.worktreeId == worktreeId, discoveredCWD == managerCWD else { return nil }
        if let existing = try? await persistence.loadSession(
            agentId: discovered.agentId,
            remoteSessionId: discovered.remoteSessionId
        ) {
            return existing
        }
        guard discovered.isCompatibleWithAlas else { return nil }

        let now = Int64(Date().timeIntervalSince1970)
        let remoteUpdatedAt = discovered.updatedAt.map { Int64($0.timeIntervalSince1970) } ?? now
        let title = discovered.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let row = ACPSessionRow(
            id: UUID().uuidString,
            agentId: discovered.agentId,
            title: title.isEmpty ? "Agent session" : title,
            titleSource: title.isEmpty ? .placeholder : .generated,
            remoteSessionId: discovered.remoteSessionId,
            origin: origin,
            currentModel: nil,
            currentMode: nil,
            autoRun: autoRunDefault,
            createdAt: remoteUpdatedAt,
            updatedAt: remoteUpdatedAt,
            lastOpenedAt: now,
            archived: false
        )
        do {
            try await persistence.upsertSession(row)
            persistedRows[row.id] = row
            replaceRecentRow(row)
            return row
        } catch {
            persistenceError = error.localizedDescription
            return nil
        }
    }

    /// Loads the full persisted `content` for a tool call. Used by the
    /// tool-call card when expanding a message whose in-memory content
    /// was truncated to save memory. Returns nil if the row is gone or
    /// the payload can't be decoded.
    func reloadFullToolCallContent(sessionId: ACPSession.ID, toolCallId: String) async -> String? {
        try? await persistence.loadToolCallContent(sessionId: sessionId, toolCallId: toolCallId)
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
    func acquireWriterLease(sessionId: ACPSession.ID) async -> Bool {
        await flushPersistence()
        let now = Int64(Date().timeIntervalSince1970)
        let requestedToken = UUID().uuidString
        do {
            guard let lease = try await persistence.claimLease(
                sessionId: sessionId,
                instanceId: instanceId,
                pid: pid,
                now: now,
                staleAfter: Self.leaseStaleAfter,
                leaseToken: requestedToken
            ) else {
                let current = try? await persistence.loadLease(sessionId: sessionId)
                observedLeases[sessionId] = current
                _ownedLeases.remove(sessionId)
                ownedLeaseTokens.removeValue(forKey: sessionId)
                return false
            }
            observedLeases[sessionId] = lease
            _ownedLeases.insert(sessionId)
            ownedLeaseTokens[sessionId] = lease.token
            return true
        } catch {
            persistenceError = error.localizedDescription
            _ownedLeases.remove(sessionId)
            ownedLeaseTokens.removeValue(forKey: sessionId)
            return false
        }
    }

    func releaseWriterLease(sessionId: ACPSession.ID) async {
        await flushAllPersistence()
        do {
            try await persistence.releaseLease(
                sessionId: sessionId,
                instanceId: instanceId,
                leaseToken: ownedLeaseTokens[sessionId]
            )
        } catch {
            persistenceError = error.localizedDescription
        }
        _ownedLeases.remove(sessionId)
        ownedLeaseTokens.removeValue(forKey: sessionId)
        observedLeases[sessionId] = nil
    }

    /// True when this session is open here and the latest observed lease is
    /// owned by another live instance.
    func isMirror(sessionId: ACPSession.ID) -> Bool {
        if _ownedLeases.contains(sessionId) { return false }
        guard let observed = observedLeases[sessionId] else {
            return isAwaitingInitialLeaseObservation(sessionId: sessionId)
        }
        guard let lease = observed else { return false }
        return lease.ownerInstance != instanceId
            && ACPProcessLiveness.pidAlive(lease.pid)
            && lease.heartbeatAt >= Int64(Date().timeIntervalSince1970) - Self.leaseStaleAfter
    }

    private func isAwaitingInitialLeaseObservation(sessionId: ACPSession.ID) -> Bool {
        guard let session = sessions[sessionId],
              session.restoredFromPersistence
        else { return false }
        return session.hydrationState == .loading || session.agentState == .spawning
    }

    /// True when the latest off-main lease read observed a different live
    /// owner. This never performs SQLite work on the main actor.
    private func anotherLiveInstanceOwnsLease(sessionId: ACPSession.ID) -> Bool {
        guard let observed = observedLeases[sessionId], let lease = observed else { return false }
        return lease.ownerInstance != instanceId
            && ACPProcessLiveness.pidAlive(lease.pid)
            && lease.heartbeatAt >= Int64(Date().timeIntervalSince1970) - Self.leaseStaleAfter
    }

    private func leaseFence(sessionId: ACPSession.ID) -> ACPSessionLeaseFence? {
        guard _ownedLeases.contains(sessionId),
              let token = ownedLeaseTokens[sessionId] else { return nil }
        return ACPSessionLeaseFence(
            sessionId: sessionId,
            ownerInstance: instanceId,
            token: token
        )
    }

    /// Whether the instance currently writing this mirrored session is
    /// actively streaming (drives the mirror's busy spinner). Reads the
    /// lease status written by the owner's heartbeat.
    func mirrorIsBusy(sessionId: ACPSession.ID) -> Bool {
        guard let observed = observedLeases[sessionId], let lease = observed else { return false }
        return lease.status == "busy"
    }

    /// One heartbeat tick for an owned session. Returns true if the
    /// caller should stand down (we lost the lease to another instance).
    /// Side effects: refreshes our heartbeat when we still own the row. A
    /// missing or differently owned row fails closed and requests stand-down.
    // exposed for tests
    @discardableResult
    func heartbeatTick(sessionId: ACPSession.ID) async -> Bool {
        guard _ownedLeases.contains(sessionId) else { return false }
        let now = Int64(Date().timeIntervalSince1970)
        do {
            guard let lease = try await persistence.loadLease(sessionId: sessionId) else {
                observedLeases[sessionId] = nil
                return true
            }
            observedLeases[sessionId] = lease
            if lease.ownerInstance != instanceId {
                return true   // taken over → stand down
            }
            // Still ours — refresh heartbeat + status.
            let status = runners[sessionId]?.session.transcript.streamingState == .streaming
                ? "busy" : "idle"
            try await persistence.refreshHeartbeat(
                sessionId: sessionId, instanceId: instanceId, now: now, status: status)
            return false
        } catch {
            persistenceError = error.localizedDescription
            return false
        }
    }

    private func startHeartbeat(sessionId: ACPSession.ID) {
        _heartbeatTasks[sessionId]?.cancel()
        _heartbeatTasks[sessionId] = Task { @MainActor [weak self] in
            // Refresh immediately so the just-claimed lease doesn't rely on
            // the first 5s tick (a slow initialize/newSession could otherwise
            // let the heartbeat age past leaseStaleAfter mid-attach).
            guard let self else { return }
            if await self.heartbeatTick(sessionId: sessionId) {
                await self.standDown(sessionId: sessionId)
            }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)   // 5s
                let shouldStandDown = await self.heartbeatTick(sessionId: sessionId)
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
        writerWatchDebounce[sessionId] = Task { @MainActor [weak self] in
            // 100 ms coalesce window: the writer itself posts a ping on every
            // persist, so we debounce to avoid checking on each of those.
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard let self, self._ownedLeases.contains(sessionId) else { return }
            if await self.heartbeatTick(sessionId: sessionId) {
                await self.standDown(sessionId: sessionId)
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
    @discardableResult
    func takeOver(sessionId: ACPSession.ID) async -> Bool {
        let now = Int64(Date().timeIntervalSince1970)
        let requestedToken = UUID().uuidString
        let lease: ACPSessionLease
        do {
            lease = try await persistence.seizeLease(
                sessionId: sessionId,
                instanceId: instanceId,
                pid: pid,
                now: now,
                leaseToken: requestedToken
            )
        } catch {
            persistenceError = error.localizedDescription
            return false
        }
        guard sessions[sessionId] != nil else {
            try? await persistence.releaseLease(
                sessionId: sessionId,
                instanceId: instanceId,
                leaseToken: lease.token
            )
            return false
        }
        _ownedLeases.insert(sessionId)
        ownedLeaseTokens[sessionId] = lease.token
        observedLeases[sessionId] = lease
        changeNotifier.post()
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
            if let row = try? await persistence.loadSession(id: sessionId),
               let remote = row.remoteSessionId, !remote.isEmpty {
                persistedRows[sessionId] = row
                session.remoteSessionId = remote
            }
            // Refresh the queue from the store so the taking-over instance
            // starts from the current persisted queue rather than whatever
            // stale/empty in-memory state the mirror cached. Queue writes
            // don't post a change notification, so the mirror's in-memory
            // queue can be stale at takeover time.
            let queue = (try? await persistence.loadQueue(sessionId: sessionId)) ?? []
            session.restoreQueue(queue)
            // Block immediate sends while the final mirror snapshot catches
            // the cached transcript up to the store before writer attach.
            session.agentState = .spawning
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.refreshMirror(sessionId: sessionId)
                self.endMirroring(sessionId: sessionId)
                guard self.sessions[sessionId] === session else { return }
                session.agentState = .idle
                await self.attach(to: sessionId, freshlyCreated: false)
            }
        } else {
            endMirroring(sessionId: sessionId)
        }
        return true
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
            await runner.flushPersistence()
            await runner.connection.shutdown()
        }
        autoReconnectTasks.removeValue(forKey: sessionId)?.cancel()
        elicitationCoordinators.removeValue(forKey: sessionId)?.stop()
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

    func ownsLeaseForTest(sessionId: ACPSession.ID) async -> Bool {
        (try? await persistence.loadLease(sessionId: sessionId))?.ownerInstance == instanceId
    }

    /// True while an `attach` coroutine holds the lease for `sessionId`
    /// but has not yet registered a runner. Used by tests to verify that
    /// `releaseAllOwnedLeases` skips attaching sessions.
    func isAttachingForTest(_ sessionId: ACPSession.ID) -> Bool {
        attachingSessions.contains(sessionId)
    }

    func heartbeatTickForTest(sessionId: ACPSession.ID) async -> Bool {
        await heartbeatTick(sessionId: sessionId)
    }

    /// True when a mirror poll task is active for `sessionId`. Used by
    /// tests to verify that eviction cancels the poll.
    func mirrorPollActiveForTest(sessionId: ACPSession.ID) -> Bool {
        mirrorPoll[sessionId] != nil
    }

    func mirrorPollIntervalNanosForTest(sessionId: ACPSession.ID) -> UInt64 {
        mirrorPollIntervalNanos(sessionId: sessionId)
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
        startMirrorPoll(sessionId: sessionId)
        mirrorDebounce[sessionId]?.cancel()
        mirrorDebounce[sessionId] = Task { [weak self] in await self?.refreshMirror(sessionId: sessionId) }
    }

    func endMirroring(sessionId: ACPSession.ID) {
        if let t = mirrorTokens.removeValue(forKey: sessionId) { changeNotifier.unsubscribe(t) }
        mirrorDebounce.removeValue(forKey: sessionId)?.cancel()
        mirrorPoll.removeValue(forKey: sessionId)?.cancel()
        inFlightMirrorRefreshes.removeValue(forKey: sessionId)?.cancel()
        dirtyMirrorRefreshes.remove(sessionId)
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
    func releaseAllOwnedLeases() async {
        for sid in Array(_ownedLeases) where !attachingSessions.contains(sid) {
            await releaseWriterLease(sessionId: sid)
        }
    }

    private func scheduleMirrorRefresh(sessionId: ACPSession.ID) {
        mirrorDebounce[sessionId]?.cancel()
        mirrorDebounce[sessionId] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: ACPMirrorRefreshPolicy.debounceNanos)
            guard !Task.isCancelled else { return }
            await self?.refreshMirror(sessionId: sessionId)
        }
    }

    private func wakeVisibleMirror(sessionId: ACPSession.ID) {
        guard mirrorTokens[sessionId] != nil else { return }
        startMirrorPoll(sessionId: sessionId)
        mirrorDebounce[sessionId]?.cancel()
        mirrorDebounce[sessionId] = Task { [weak self] in await self?.refreshMirror(sessionId: sessionId) }
    }

    private func startMirrorPoll(sessionId: ACPSession.ID) {
        mirrorPoll[sessionId]?.cancel()
        mirrorPoll[sessionId] = Task { [weak self] in
            while !Task.isCancelled {
                let interval = self?.mirrorPollIntervalNanos(sessionId: sessionId)
                    ?? ACPMirrorRefreshPolicy.inactivePollNanos
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else { return }
                await self?.refreshMirror(sessionId: sessionId)
            }
        }
    }

    private func mirrorPollIntervalNanos(sessionId: ACPSession.ID) -> UInt64 {
        (visibleSessionCounts[sessionId] ?? 0) > 0
            ? ACPMirrorRefreshPolicy.activePollNanos
            : ACPMirrorRefreshPolicy.inactivePollNanos
    }

    /// Re-read mirror state from SQLite and apply it into the cached mirror
    /// session. SQLite reads and JSON decode run through the hydrator actor
    /// when available; the main actor only materialises the visible tail.
    func refreshMirror(sessionId: ACPSession.ID) async {
        if let existing = inFlightMirrorRefreshes[sessionId] {
            dirtyMirrorRefreshes.insert(sessionId)
            await existing.value
            return
        }
        final class TaskHandle { var task: Task<Void, Never>? }
        let handle = TaskHandle()
        let task = Task { @MainActor [weak self] in
            defer {
                if let self, let me = handle.task, self.inFlightMirrorRefreshes[sessionId] == me {
                    self.inFlightMirrorRefreshes[sessionId] = nil
                    self.dirtyMirrorRefreshes.remove(sessionId)
                }
            }
            guard let self else { return }
            repeat {
                self.dirtyMirrorRefreshes.remove(sessionId)
                await self.runMirrorRefresh(sessionId: sessionId)
            } while self.dirtyMirrorRefreshes.remove(sessionId) != nil
                && self.sessions[sessionId] != nil
                && !Task.isCancelled
        }
        handle.task = task
        inFlightMirrorRefreshes[sessionId] = task
        await task.value
    }

    private func runMirrorRefresh(sessionId: ACPSession.ID) async {
        guard let session = sessions[sessionId] else { return }
        let result: HydrationResult
        do {
            result = try await persistence.mirrorSnapshot(sessionId: sessionId)
            observedLeases[sessionId] = try await persistence.loadLease(sessionId: sessionId)
        } catch {
            return
        }
        guard !Task.isCancelled, sessions[sessionId] === session else { return }
        syncMirrorSessionMetadata(result.row, to: session, recentRows: result.recent)
        // Always sync the queue — it can change (drain/clear) with no new
        // transcript rows, so this must run before any early-return below.
        session.restoreQueue(result.queue)
        guard !result.wireMessages.isEmpty else { return }
        let tailStart = replaceTranscriptWithTail(
            result.wireMessages,
            in: session,
            markCompletedBoundary: false)
        applyRememberedTranscriptScrollWindow(to: session, messageIndexOffset: tailStart)
        scheduleBackfillIfNeeded(
            olderWires: Array(result.wireMessages.prefix(tailStart)),
            sessionId: sessionId,
            session: session)
    }

    private func syncMirrorSessionMetadata(
        _ row: ACPSessionRow,
        to session: ACPSession,
        recentRows: [ACPSessionRow]? = nil
    ) {
        persistedRows[row.id] = row
        let titleChanged = session.title != row.title || session.titleSource != row.titleSource
        session.title = row.title
        session.titleSource = row.titleSource
        session.currentModel = row.currentModel
        session.currentMode = row.currentMode
        session.autoRunEnabled = row.autoRun
        if session.remoteSessionId == nil || session.remoteSessionId == row.remoteSessionId {
            session.remoteSessionId = row.remoteSessionId
        }
        if let recentRows {
            recent = recentRows
            for recentRow in recentRows {
                persistedRows[recentRow.id] = recentRow
            }
        }
        if titleChanged {
            onSessionTitleUpdated?(row.id, row.title)
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
        guard await acquireWriterLease(sessionId: sessionId) else {
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
        guard sessions[sessionId] === session else {
            await releaseWriterLease(sessionId: sessionId)
            return
        }
        // Drop any stale runner left over from a prior process (e.g. the
        // runner's stream-end branch flipped agentState to .disconnected
        // but did not unregister itself). The .ready/.spawning early-return
        // above already covers the live-runner case — a runner is only
        // registered AFTER state flips to .ready — so anything still here
        // is a zombie whose update task already exited.
        if let stale = runners[sessionId] {
            stale.stop()
            await stale.flushPersistence()
        }
        runners[sessionId] = nil
        elicitationCoordinators.removeValue(forKey: sessionId)?.stop()
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
            await releaseWriterLease(sessionId: sessionId)
            return
        }
        let setup = await evaluateSetup(for: spec)
        guard case .ready = setup else {
            session.setupState = setup.sessionSetupState
            session.agentState = .failed(setup.reasonText)
            await releaseWriterLease(sessionId: sessionId)
            return
        }
        session.setupState = .ready
        if firstRunAttach {
            session.firstRunConnectingPhase = .launchingAdapter
        }

        let connection: ACPConnection
        do {
            let host = RemoteHostRegistry.shared.host(forPath: worktreePath)
            let launchSpec = await resolvedLaunchSpec(for: spec, host: host)
            connection = try connectionFactory(launchSpec, host, worktreePath)
        } catch {
            let msg = "Failed to launch agent: \(error.localizedDescription)"
            session.lastError = msg
            session.agentState = .failed(msg)
            await releaseWriterLease(sessionId: sessionId)
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
        let elicitationCoordinator = ACPElicitationCoordinator(
            session: session,
            client: connection.client,
            onInputAwaiting: { [weak self] session, request in
                self?.onInputAwaiting?(session, request)
            },
            onInputResolved: { [weak self] in
                self?.runners[sessionId]?.flushQueueIfIdle()
            }
        )
        elicitationCoordinators[sessionId] = elicitationCoordinator
        elicitationCoordinator.start()
        var keepElicitationCoordinator = false
        defer {
            if !keepElicitationCoordinator {
                elicitationCoordinator.stop()
                if elicitationCoordinators[sessionId] === elicitationCoordinator {
                    elicitationCoordinators[sessionId] = nil
                }
            }
        }
        do {
            if firstRunAttach {
                session.firstRunConnectingPhase = .initializing
            }
            let initialized = try await connection.initialize()
            session.promptCapabilities = initialized.promptCapabilities
            session.authMethods = initialized.authMethods
            let agentEnvironment = ACPProcessEnvironment.sanitizedForACP(extra: spec.extraEnv)
            let projectContext = mcpProjectContextProvider?()
                ?? MCPProjectContext(projectDirectory: worktreePath, configuredServers: [])
            let mcpPlan = MCPAttachmentPlanner.plan(.init(
                configuredServers: projectContext.configuredServers,
                projectDirectory: projectContext.projectDirectory,
                worktreeDirectory: worktreePath,
                environment: agentEnvironment,
                capabilities: initialized.mcpCapabilities
            ))
            session.mcpAttachmentSummary = .init(plan: mcpPlan)
            let mcpSplit = RemoteHostRegistry.shared.host(forPath: worktreePath).map { _ in
                ACPRemoteMCPFilter.split(mcpPlan.wireServers)
            }
            let wireMCPServers = mcpSplit?.kept ?? mcpPlan.wireServers
            let remoteMCPNotice: String?
            if let mcpSplit, !mcpSplit.droppedStdio.isEmpty {
                remoteMCPNotice = "MCP servers unavailable on remote host: \(mcpSplit.droppedStdio.joined(separator: ", "))"
            } else {
                remoteMCPNotice = nil
            }
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
            let restoreOperation = ACPSessionRestorePolicy.operation(
                origin: session.origin,
                canLoad: initialized.loadSession,
                canResume: initialized.sessionCapabilities.supportsResume,
                hasLocalTranscript: session.hasConversationTranscript
            )
            let shouldSuppressLoadReplay = (restoreOperation == .loadWithRecovery
                || restoreOperation == .loadStrict)
                && !freshlyCreated
                && session.hydrationState == .ready
                && session.hasConversationTranscript
                && !(session.remoteSessionId ?? "").isEmpty
            let runner = ACPSessionRunner(session: session, connection: connection,
                                          sessionId: sessionId,
                                          worktreePath: worktreePath,
                                          agentEnv: agentEnvironment,
                                          suppressingLoadReplay: shouldSuppressLoadReplay,
                                          onDirtyCheck: onDirtyCheck,
                                          onLiveBufferRead: onLiveBufferRead,
                                          onUserCancel: { [weak elicitationCoordinator] in
                                              elicitationCoordinator?.cancelPendingInputs()
                                          },
                                          onAuthRequired: { [weak self] runner, _ in
                                              await self?.handleAuthRequiredRunner(
                                                runner,
                                                sessionId: sessionId
                                              )
                                          },
                                          onPersist: { [weak self] in self?.changeNotifier.post() },
                                          onSessionTitleUpdated: { [weak self] title in
                                              self?.refreshRecent()
                                              self?.onSessionTitleUpdated?(sessionId, title)
                                              self?.changeNotifier.post()
                                          },
                                          onResumeTranscriptTail: { [weak self] in
                                              self?.rememberTranscriptScrollAnchor(
                                                sessionId: sessionId,
                                                anchorMessageId: nil,
                                                anchorMessageIndex: nil,
                                                followsTail: true
                                              )
                                          },
                                          ownerInstanceId: instanceId,
                                          persistence: persistence,
                                          persistedMessageCount: session.transcript.messages.count,
                                          canWrite: { [weak self] in
                                              self?.isWriter(for: sessionId) == true
                                          },
                                          validateLease: { [weak self] in
                                              await self?.confirmedWriterLease(for: sessionId) == true
                                          },
                                          leaseFenceProvider: { [weak self] in
                                              self?.leaseFence(sessionId: sessionId)
                                          })
            runner.onUnexpectedDisconnect = { [weak self] in
                Task { @MainActor in
                    self?.scheduleAutoReconnect(sessionId: sessionId)
                }
            }
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
            let pendingRecovery = persistedRows[sessionId]?.contextRecoveryPending == true
            let result: ACPSessionNewResult
            var restoreWarning: ACPSession.ContextRestoreWarning?
            let hasRestorableContext = pendingRecovery || session.hasConversationTranscript
            var shouldHoldQueueForRecovery = pendingRecovery && session.hasConversationTranscript
            if firstRunAttach {
                session.firstRunConnectingPhase = .creatingSession
            }
            if freshlyCreated {
                result = try await connection.newSession(cwd: worktreePath, mcpServers: wireMCPServers)
            } else if let remoteId = session.remoteSessionId, !remoteId.isEmpty {
                if session.hasConversationTranscript {
                    session.contextRecoveryStatus = .restoring
                }
                switch restoreOperation {
                case .resume:
                    do {
                        result = try await connection.resumeSession(
                            cwd: worktreePath, sessionId: remoteId, mcpServers: wireMCPServers)
                        if !pendingRecovery {
                            session.contextRecoveryStatus = nil
                        }
                        if session.origin != .alasCreated, !session.hasConversationTranscript {
                            restoreWarning = .init(
                                message: "Earlier messages remain in the agent and are not available in Alas.",
                                canSendTranscript: false
                            )
                        }
                    } catch {
                        guard session.origin == .alasCreated,
                              ACPAuthFailure.message(from: error) == nil
                        else { throw error }
                        result = try await connection.newSession(cwd: worktreePath, mcpServers: wireMCPServers)
                        if session.hasConversationTranscript {
                            shouldHoldQueueForRecovery = true
                            if isWriter(for: sessionId) {
                                persistContextRecoveryPending(sessionId: sessionId, pending: true)
                            }
                        }
                        if hasRestorableContext {
                            restoreWarning = .init(
                                message: "Agent context could not be restored.",
                                canSendTranscript: session.hasConversationTranscript
                            )
                        }
                        if session.hasConversationTranscript {
                            session.contextRecoveryStatus = .sendingTranscript
                        }
                    }
                case .loadStrict:
                    do {
                        result = try await connection.loadSession(
                            cwd: worktreePath, sessionId: remoteId, mcpServers: wireMCPServers)
                        runner.finishSuppressingLoadReplay(
                            throughYieldedUpdateCount: connection.client.yieldedUpdateCount
                        )
                    } catch {
                        runner.finishSuppressingLoadReplay(
                            throughYieldedUpdateCount: connection.client.yieldedUpdateCount
                        )
                        throw error
                    }
                    if !pendingRecovery {
                        session.contextRecoveryStatus = nil
                    }
                case .loadWithRecovery:
                    do {
                        result = try await connection.loadSession(
                            cwd: worktreePath, sessionId: remoteId, mcpServers: wireMCPServers)
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
                        result = try await connection.newSession(cwd: worktreePath, mcpServers: wireMCPServers)
                        if session.hasConversationTranscript {
                            shouldHoldQueueForRecovery = true
                            // Guard the store write: if another instance took over
                            // while we were awaiting loadSession/newSession, do not
                            // persist recovery state to a session we no longer own.
                            if isWriter(for: sessionId) {
                                persistContextRecoveryPending(sessionId: sessionId, pending: true)
                            }
                        }
                        if hasRestorableContext {
                            restoreWarning = .init(
                                message: "Agent context could not be restored.",
                                canSendTranscript: session.hasConversationTranscript
                            )
                        }
                        if session.hasConversationTranscript {
                            session.contextRecoveryStatus = .sendingTranscript
                        }
                    }
                case .unavailable:
                    throw ACPSessionAttachError.remoteSessionUnsupported
                }
            } else {
                result = try await connection.newSession(cwd: worktreePath, mcpServers: wireMCPServers)
                if session.hasConversationTranscript {
                    shouldHoldQueueForRecovery = true
                    // Guard the store write: if another instance took over
                    // while we were awaiting newSession, do not persist
                    // recovery state to a session we no longer own.
                    if isWriter(for: sessionId) {
                        persistContextRecoveryPending(sessionId: sessionId, pending: true)
                    }
                }
                if hasRestorableContext {
                    restoreWarning = .init(
                        message: "Agent context could not be restored.",
                        canSendTranscript: session.hasConversationTranscript
                    )
                }
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
            let shouldAbortAttach: Bool
            if isDisposed {
                shouldAbortAttach = true
            } else {
                shouldAbortAttach = !(await confirmedWriterLease(for: sessionId))
            }
            if shouldAbortAttach {
                await connection.shutdown()
                startedRunner?.stop()
                await startedRunner?.flushPersistence()
                session.agentState = .idle
                if !isDisposed { beginMirroring(sessionId: sessionId) }   // don't start a mirror on a disposed manager
                await releaseWriterLease(sessionId: sessionId)
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
            await flushPersistence()
            startRunnerIfNeeded()
            runners[sessionId] = runner
            keepElicitationCoordinator = true
            attachSucceeded = true
            session.agentState = .ready
            if let remoteMCPNotice {
                runner.appendAndPersistSystemNotice(remoteMCPNotice)
            }
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
            let baseMessage = authReason ?? (error as? JSONRPCError)?.message ?? error.localizedDescription
            let base = "ACP session attach failed: \(baseMessage)"
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
            await startedRunner?.flushPersistence()
            await connection.shutdown()
            await releaseWriterLease(sessionId: sessionId)
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

    /// Remote SSH channel drops are commonly transient. Reuse the regular
    /// reattach path so restoration and queued-prompt handling stay identical.
    func scheduleAutoReconnect(sessionId: ACPSession.ID) {
        guard sessions[sessionId] != nil,
              RemoteHostRegistry.shared.host(forPath: worktreePath) != nil
        else { return }

        autoReconnectTasks.removeValue(forKey: sessionId)?.cancel()
        autoReconnectTasks[sessionId] = Task { @MainActor [weak self] in
            defer {
                self?.autoReconnectTasks.removeValue(forKey: sessionId)
                self?.sessions[sessionId]?.autoReconnecting = false
            }
            self?.sessions[sessionId]?.autoReconnecting = true
            var attempt = 0
            while let delay = ACPReconnectPolicy.delay(forAttempt: attempt), !Task.isCancelled {
                attempt += 1
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, !Task.isCancelled,
                      let session = self.sessions[sessionId]
                else { return }
                switch session.agentState {
                case .ready:
                    return
                case .disconnected, .failed:
                    break
                case .idle, .spawning:
                    continue
                }
                if let host = RemoteHostRegistry.shared.host(forPath: self.worktreePath),
                   RemoteHostStatusStore.shared.isOffline(host) {
                    continue
                }
                await self.reattach(to: sessionId)
                if self.sessions[sessionId]?.agentState == .ready { return }
            }
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
        let items = session.queue
        let fence = leaseFence(sessionId: sessionId)
        enqueuePersistence { persistence in
            _ = try await persistence.upsertQueue(
                sessionId: sessionId,
                items: items,
                fence: fence
            )
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

    /// Swap `spec.command` for the verified absolute launch path when one can
    /// be resolved (npm-backed adapters); otherwise return `spec` unchanged so
    /// launch falls back to PATH-based `/usr/bin/env <command>`.
    private func resolvedLaunchSpec(for spec: ACPLaunchSpec, host: String?) async -> ACPLaunchSpec {
        if let host {
            guard let command = ACPRemoteLaunch.launchPathProbeCommand(for: spec),
                  let probe = try? await RemoteExec.run(host: host, cwd: nil, command: command),
                  probe.exitCode == 0
            else {
                return spec
            }
            let path = probe.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? spec : spec.overridingCommand(path)
        } else {
            let env = ProcessInfo.processInfo.environment
            let resolver = ACPLaunchPathResolver(
                env: env,
                additionalPathDirectories: AgentPath.wellKnownDirectories,
                npmGlobalBinDirectory: ACPLaunchPathResolver.defaultNpmGlobalBinDirectory(env: env))
            guard let path = await resolver.resolvedLaunchPath(for: spec) else { return spec }
            return spec.overridingCommand(path)
        }
    }

    private func evaluateSetup(for spec: ACPLaunchSpec) async -> ACPSetupResult {
        guard let host = RemoteHostRegistry.shared.host(forPath: worktreePath) else {
            return await setupEvaluator(spec)
        }

        do {
            let probe = try await RemoteExec.run(
                host: host,
                cwd: nil,
                command: ACPRemoteLaunch.setupProbeCommand(check: spec.setupCheck)
            )
            guard probe.exitCode == 0 else {
                return .error(message: "Required agent setup for \(spec.agentID) is missing on \(host)")
            }
            return .ready
        } catch {
            return .error(message: "Could not verify \(spec.command) on \(host): \(error.localizedDescription)")
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
        await runner.flushPersistence()
        runners[sessionId] = nil
        elicitationCoordinators.removeValue(forKey: sessionId)?.stop()
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
            await runner.flushPersistence()
            await runner.connection.shutdown()
        }
        elicitationCoordinators.removeValue(forKey: sessionId)?.stop()
        stopHeartbeat(sessionId: sessionId)
        stopWriterWatch(sessionId: sessionId)
        await releaseWriterLease(sessionId: sessionId)
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

    var sessionSetupState: ACPSession.SetupState {
        switch self {
        case .ready: return .ready
        case .missing(let reason): return .needsSetup(reason: reason)
        case .error(let message): return .setupError(reason: message)
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
