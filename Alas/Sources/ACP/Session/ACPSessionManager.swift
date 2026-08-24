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

private struct ACPForkFallbackPersistenceError: LocalizedError {
    let underlying: any Error

    var errorDescription: String? {
        "Failed to persist fork fallback: \(underlying.localizedDescription)"
    }
}

enum ACPSessionForkCreationError: Error, Equatable {
    case sourceUnavailable
    case sourceReadOnly
}

@MainActor
final class ACPSessionManager: ObservableObject {
    typealias ACPSetupEvaluator = @MainActor (_ spec: ACPLaunchSpec) async -> ACPSetupResult
    typealias ACPRemoteAdapterResolver = @MainActor (
        _ host: String,
        _ descriptor: ACPManagedAdapterDescriptor,
        _ setupCheck: ACPSetupCheck
    ) async -> ACPRemoteAdapterResolution
    typealias ACPConnectionFactory = @MainActor (
        _ spec: ACPLaunchSpec,
        _ host: String?,
        _ worktreePath: String
    ) throws -> ACPConnection
    typealias ACPBrokerServiceFactory = @MainActor () async throws -> ACPBrokerServicing
    typealias MCPProjectContextProvider = @MainActor () -> MCPProjectContext?
    typealias BuiltInMCPProvider = @MainActor (
        _ worktreePath: String,
        _ sessionId: ACPSession.ID,
        _ adapterSupportsHTTP: Bool
    ) async -> BuiltInAlasMCP.Injection?
    /// Builds the gg-mcp server entry for a worktree path, or nil when gg
    /// integration is disabled/unavailable for that worktree. Mirrors
    /// `BuiltInMCPProvider` but is synchronous — gg gating needs no async work.
    typealias GGMCPProvider = @MainActor (_ worktreePath: String) -> GGMCPInjection.Injection?
    /// Reports the gg stack state (or lack thereof) for the preamble. Mirrors
    /// `GGMCPProvider`'s gating so the preamble stays consistent with whether
    /// gg-mcp was actually attached.
    typealias GGPreambleProvider = @MainActor (_ worktreePath: String) -> GGPreambleSignal
    typealias IssuePreambleProvider = @MainActor (_ worktreeID: String) -> IssuePreambleContext?
    /// Extra process env for locally spawned adapters so any agent's shell
    /// can drive the `alas` CLI. Nil (or a nil return) skips injection.
    typealias AlasCLIEnvProvider = @MainActor (
        _ worktreePath: String,
        _ sessionId: ACPSession.ID
    ) async -> [String: String]?
    /// For `.external` adapters (which ignore ACP MCP config), inspects the
    /// agent-side adapter and syncs its managed config file. Called once per
    /// attach, after the built-in MCP composition, so `attach` can populate
    /// `session.mcpExternalStatus` before the first-prompt preamble is built.
    typealias ExternalMCPStatusProvider = @MainActor (_ worktreePath: String) async
        -> (
            adapterState: PiMCPAdapterInspector.State,
            configOutcome: PiMCPConfigWriter.Outcome?,
            userServerNames: [String],
            skippedServerStatuses: [MCPAttachmentServerStatus]
        )

    let instanceId: String
    let pid: Int64
    let worktreeId: String
    let worktreePath: String
    let persistence: ACPSessionPersistence
    let changeNotifier: ACPChangeNotifier
    private let delegatedMessageNotifier: ACPChangeNotifier
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
    private let onDelegatedMessageAvailable: ((ACPSession.ID) -> Void)?
    private let mcpProjectContextProvider: MCPProjectContextProvider?
    /// Builds the app-provided "alas" MCP server entry for a worktree path
    /// and local ACP session id,
    /// or nil when injection is disabled/unavailable. Fetched per attach so
    /// the settings toggle applies to the next (re)connect.
    private let builtInMCPProvider: BuiltInMCPProvider?
    /// Reports whether the built-in MCP server announced itself (hello) for a
    /// local session id. Read after the post-attach grace to decide between
    /// `.registered` and `.notRegistered`.
    private let isBuiltInMCPRegistered: (@MainActor (String) -> Bool)?
    /// Clears any recorded hello for a local session id so each attach epoch
    /// re-proves registration.
    private let clearMCPRegistration: (@MainActor (String) -> Void)?
    /// Invoked when a session is permanently removed (`deleteSession`) so the
    /// owner can release per-session resources — e.g. terminating a supervised
    /// `alas mcp --http` process. Not called on `closeSession` (a transient
    /// in-memory unload where a later reattach is expected).
    private let onSessionEnded: (@MainActor (ACPSession.ID) -> Void)?
    /// Builds the gg-mcp server entry for a worktree path, or nil when gg
    /// integration is disabled/unavailable. Fetched per attach, mirroring
    /// `builtInMCPProvider`.
    private let ggMCPProvider: GGMCPProvider?
    /// Reports gg stack state for the first-prompt preamble. Fetched per
    /// attach, mirroring `builtInMCPProvider`.
    private let ggPreambleProvider: GGPreambleProvider?
    private let issuePreambleProvider: IssuePreambleProvider?
    /// Builds extra env for locally spawned adapter processes so the agent's
    /// shell can drive the `alas` CLI. Set post-init (unlike
    /// `builtInMCPProvider`) so AppState can wire it without threading it
    /// through every manager construction call site. Local sessions only;
    /// remote hosts skip it in `attach`.
    var alasCLIEnvProvider: AlasCLIEnvProvider?
    /// Builds the `.external` adapter status (adapter inspection + managed
    /// config sync) for a worktree path. Set post-init, mirroring
    /// `alasCLIEnvProvider`, so AppState can wire it without threading it
    /// through every manager construction call site.
    var externalMCPStatusProvider: ExternalMCPStatusProvider?
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
    /// Per-session attach counter. The built-in MCP registration grace timer
    /// captures the epoch at attach and only writes the row if it still matches,
    /// so a timer from a superseded attach can never clobber the current state.
    private var mcpRegistrationAttachEpoch: [ACPSession.ID: Int] = [:]
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

    /// Remote-web emergency brake: cancel this instance's in-flight turn
    /// WITHOUT confirming the writer lease. `session/cancel` is idempotent
    /// and only reaches this instance's own adapter — if another instance
    /// took the lease and drives the session, our runner has no active
    /// prompt and the cancel is a harmless no-op there.
    func interruptBypassingLease(for id: ACPSession.ID) async {
        guard let runner = runners[id] else { return }
        await runner.userCancel(confirmingLease: false)
    }

    // MARK: - Remote queue control

    /// Promote a queued item to the head (or steer to it when a turn is
    /// running) — the remote-web twin of the queued bubble's "send now".
    func queueForceSend(for id: ACPSession.ID, itemId: UUID) async {
        guard await confirmedWriterLease(for: id) else { return }
        runners[id]?.forceSendQueuedItem(id: itemId)
    }

    func queueRemove(for id: ACPSession.ID, itemId: UUID) async {
        guard await confirmedWriterLease(for: id), let session = sessions[id] else { return }
        session.removeFromQueue(id: itemId)
        persistQueue(for: session)
        runners[id]?.flushQueueIfIdle()
    }

    /// Clear a failed item's error so the flusher re-attempts it.
    func queueRetry(for id: ACPSession.ID, itemId: UUID) async {
        guard await confirmedWriterLease(for: id), let session = sessions[id] else { return }
        guard let idx = session.queue.firstIndex(where: { $0.id == itemId }) else { return }
        session.queue[idx].lastError = nil
        persistQueue(for: session)
        runners[id]?.flushQueueIfIdle()
    }

    /// Pull a queued item out for editing and hand its text back. `nil` when
    /// the item is gone or `.sending` — `takeForEditing` refuses in-flight
    /// items so an edit can never duplicate a prompt already on the wire —
    /// or when its draft carries a mention or an image.
    ///
    /// The web composer is plain text: it has no authenticated way to
    /// re-stage a mention's URI or an image's bytes, so editing such an item
    /// there would silently drop that content once the user resubmits. The
    /// web client already hides Edit when `imageCount > 0 || resourceCount >
    /// 0` for exactly this reason; this mirrors that rule server-side so a
    /// client that doesn't know it (or a hand-rolled one) can't cause the
    /// same loss. The draft is inspected BEFORE calling `takeForEditing`,
    /// which removes-and-returns atomically — refusing after removal would
    /// strand the prompt outside the queue instead of just leaving it be.
    func queueEdit(for id: ACPSession.ID, itemId: UUID) async -> String? {
        guard await confirmedWriterLease(for: id), let session = sessions[id] else { return nil }
        guard let idx = session.queue.firstIndex(where: { $0.id == itemId }) else { return nil }
        let hasUnrepresentableSegment = session.queue[idx].restorableDraft.segments.contains { segment in
            switch segment {
            case .text: return false
            case .mention, .image: return true
            }
        }
        guard !hasUnrepresentableSegment else { return nil }
        guard let draft = session.takeForEditing(id: itemId) else { return nil }
        persistQueue(for: session)
        runners[id]?.flushQueueIfIdle()
        return RemoteQueueProjection.plainText(from: draft)
    }

    func queueClear(for id: ACPSession.ID) async {
        guard await confirmedWriterLease(for: id), let session = sessions[id] else { return }
        session.clearPendingQueue()
        persistQueue(for: session)
        runners[id]?.flushQueueIfIdle()
    }

    func queueSteerUndo(for id: ACPSession.ID) async {
        guard await confirmedWriterLease(for: id) else { return }
        runners[id]?.steerUndo()
    }

    /// Steer from the remote client: same route the composer's ⌥⏎ takes.
    /// `ACPSubmitRoute.resolve` handles the degenerate idle+empty case by
    /// falling back to a plain send.
    func steerPrompt(for id: ACPSession.ID, text: String, attachments: [ACPMessage.Attachment], onResult: @escaping @MainActor (Bool) -> Void) async {
        guard await confirmedWriterLease(for: id) else {
            onResult(false)
            return
        }
        let accepted = submit(sessionId: id, text: text, attachments: attachments, intent: .steer,
                              onCompleted: { ok in onResult(ok) })
        if !accepted { onResult(false) }
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
    private let remoteAdapterResolver: ACPRemoteAdapterResolver
    private let connectionFactory: ACPConnectionFactory
    private let injectedConnectionFactory: ACPConnectionFactory?
    private let brokerServiceFactory: ACPBrokerServiceFactory?
    private var resolvedRemoteAdapters: [String: ACPResolvedRemoteAdapter] = [:]
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
    /// Runtime-only transcript scroll memory. Kept on the manager because
    /// idle ACP sessions can be evicted on tab switches, but returning to the
    /// tab should not reset a user-paused transcript to the top of whatever
    /// render window hydrates first.
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
    private var delegatedMessageWatchTokens: [ACPSession.ID: Int32] = [:]

    init(worktreeId: String, worktreePath: String, store: ACPSessionStore? = nil,
         persistence: ACPSessionPersistence? = nil,
         instanceId: String = UUID().uuidString,
         pid: Int64 = Int64(ProcessInfo.processInfo.processIdentifier),
         hydratorPath: String? = nil,
         onDirtyCheck: ((String) -> Bool)? = nil,
         onLiveBufferRead: ((String) -> String?)? = nil,
         onSessionTitleUpdated: ((ACPSession.ID, String) -> Void)? = nil,
         onInputAwaiting: ((ACPSession, ACPUserInputRequest) -> Void)? = nil,
         onDelegatedMessageAvailable: ((ACPSession.ID) -> Void)? = nil,
         changeNotifier: ACPChangeNotifier? = nil,
         delegatedMessageNotifier: ACPChangeNotifier? = nil,
         setupEvaluator: ACPSetupEvaluator? = nil,
         remoteAdapterResolver: ACPRemoteAdapterResolver? = nil,
         connectionFactory: ACPConnectionFactory? = nil,
         brokerServiceFactory: ACPBrokerServiceFactory? = nil,
         mcpProjectContextProvider: MCPProjectContextProvider? = nil,
         builtInMCPProvider: BuiltInMCPProvider? = nil,
         isBuiltInMCPRegistered: (@MainActor (String) -> Bool)? = nil,
         clearMCPRegistration: (@MainActor (String) -> Void)? = nil,
         onSessionEnded: (@MainActor (ACPSession.ID) -> Void)? = nil,
         ggMCPProvider: GGMCPProvider? = nil,
         ggPreambleProvider: GGPreambleProvider? = nil,
         issuePreambleProvider: IssuePreambleProvider? = nil)
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
        self.onDelegatedMessageAvailable = onDelegatedMessageAvailable
        self.mcpProjectContextProvider = mcpProjectContextProvider
        self.builtInMCPProvider = builtInMCPProvider
        self.isBuiltInMCPRegistered = isBuiltInMCPRegistered
        self.clearMCPRegistration = clearMCPRegistration
        self.onSessionEnded = onSessionEnded
        self.ggMCPProvider = ggMCPProvider
        self.ggPreambleProvider = ggPreambleProvider
        self.issuePreambleProvider = issuePreambleProvider
        self.changeNotifier = changeNotifier ?? DarwinChangeNotifier(worktreeId: worktreeId)
        self.delegatedMessageNotifier = delegatedMessageNotifier
            ?? DarwinChangeNotifier(worktreeId: worktreeId, channel: "delegated-inbox")
        _ = hydratorPath
        self.setupEvaluator = setupEvaluator ?? { spec in
            let checker = ACPSetupChecker(env: ProcessInfo.processInfo.environment)
            return await checker.evaluate(spec.setupCheck)
        }
        self.remoteAdapterResolver = remoteAdapterResolver ?? { host, descriptor, setupCheck in
            await ACPRemoteAdapterManagement().resolve(
                host: host,
                descriptor: descriptor,
                setupCheck: setupCheck
            )
        }
        self.injectedConnectionFactory = connectionFactory
        self.connectionFactory = connectionFactory ?? Self.makeStdioConnection
        self.brokerServiceFactory = brokerServiceFactory
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

    private func enqueuePersistenceResult<Result: Sendable>(
        _ operation: @escaping @Sendable (ACPSessionPersistence) async throws -> Result
    ) -> Task<Result?, Never> {
        let previous = persistenceTail
        let persistence = persistence
        persistenceGeneration += 1
        let resultTask = Task<Result?, Never> { @MainActor [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return nil }
            do {
                return try await operation(persistence)
            } catch {
                self?.persistenceError = error.localizedDescription
                return nil
            }
        }
        persistenceTail = Task { @MainActor in
            _ = await resultTask.value
        }
        return resultTask
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
        return createSession(id: id, agentId: agentId, autoRunDefault: autoRunDefault)
    }

    func createSession(id: String, agentId: String, autoRunDefault: Bool = false) -> ACPSession {
        precondition(sessions[id] == nil && persistedRows[id] == nil, "ACP session id already exists")
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

    func createFork(
        sourceSessionID: ACPSession.ID,
        boundary: ACPForkMessageBoundary,
        targetAgentID: String,
        autoRunDefault: Bool
    ) async throws -> ACPSession {
        guard let source = sessions[sourceSessionID], source.hydrationState == .ready else {
            throw ACPSessionForkCreationError.sourceUnavailable
        }
        let acquiredSnapshotLease: Bool
        if !_ownedLeases.contains(sourceSessionID) {
            guard await acquireWriterLease(sessionId: sourceSessionID) else {
                throw ACPSessionForkCreationError.sourceReadOnly
            }
            acquiredSnapshotLease = true
        } else {
            guard await confirmedWriterLease(for: sourceSessionID) else {
                throw ACPSessionForkCreationError.sourceReadOnly
            }
            acquiredSnapshotLease = false
        }

        let result: Result<ACPSession, Error>
        do {
            await awaitBackfill(id: sourceSessionID)
            await flushAllPersistence()
            let storedMessages = try await persistence.loadMessages(sessionId: sourceSessionID)
            let snapshot = try ACPSessionForkSnapshotResolver.resolve(
                boundary: boundary,
                liveMessages: source.transcript.messages,
                storedMessages: storedMessages
            )
            let boundaryIsRemoteHead = snapshot.sourceBoundarySequence == storedMessages.last?.seq
            let sourceContextDeliveryPending = source.forkRecord?.mechanism == .transcriptTransfer
                && source.forkRecord?.contextDeliveryPending == true
            let candidate = sourceContextDeliveryPending
                ? ACPSessionForkCandidate.transcript
                : ACPSessionForkCandidatePolicy.candidate(
                    sourceAgentID: source.agentId,
                    targetAgentID: targetAgentID,
                    boundaryIsRemoteHead: boundaryIsRemoteHead,
                    sourceRemoteSessionID: source.remoteSessionId,
                    forkCapability: source.sessionCapabilities?.supportsFork
                )

            let targetID = UUID().uuidString
            let now = Int64(Date().timeIntervalSince1970)
            let copiedMessages = try snapshot.copiedMessages(targetSessionID: targetID, createdAt: now)
            let targetTitle = source.title == "New session"
                ? "New session (fork)"
                : "\(source.title) (fork)"
            let targetRow = ACPSessionRow(
                id: targetID,
                agentId: targetAgentID,
                title: targetTitle,
                titleSource: .generated,
                currentModel: nil,
                currentMode: nil,
                autoRun: autoRunDefault,
                createdAt: now,
                updatedAt: now,
                lastOpenedAt: now,
                archived: false
            )
            let forkRecord = ACPSessionForkRecord(
                targetSessionID: targetID,
                sourceSessionID: sourceSessionID,
                sourceAgentID: source.agentId,
                sourceBoundarySequence: snapshot.sourceBoundarySequence,
                inheritedMessageCount: copiedMessages.count,
                phase: candidate == .native ? .negotiatingNative : .ready,
                mechanism: candidate == .native ? nil : .transcriptTransfer,
                contextDeliveryPending: candidate == .transcript
            )

            try await persistence.createFork(
                session: targetRow,
                messages: copiedMessages,
                record: forkRecord
            )

            let target = ACPSession(
                id: targetRow.id,
                agentId: targetRow.agentId,
                worktreeId: worktreeId,
                title: targetRow.title,
                titleSource: targetRow.titleSource,
                origin: targetRow.origin,
                createdAt: Date(timeIntervalSince1970: TimeInterval(targetRow.createdAt)),
                hydrationState: .ready
            )
            target.autoRunEnabled = targetRow.autoRun
            target.forkRecord = forkRecord
            for message in copiedMessages {
                target.transcript.appendMessage(try ACPMessageCodec.decode(
                    kind: message.kind,
                    payload: message.payload
                ))
            }
            sessions[targetID] = target
            persistedRows[targetID] = targetRow
            recent.removeAll { $0.id == targetID }
            recent.insert(targetRow, at: 0)
            result = .success(target)
        } catch {
            result = .failure(error)
        }
        if acquiredSnapshotLease {
            await releaseWriterLease(sessionId: sourceSessionID)
        }
        return try result.get()
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
        session.forkRecord = result.forkRecord
        if session.remoteSessionId == nil || session.remoteSessionId == result.row.remoteSessionId {
            session.remoteSessionId = result.row.remoteSessionId
        }
        let forkContextPending = result.forkRecord?.phase == .ready
            && result.forkRecord?.mechanism == .transcriptTransfer
            && result.forkRecord?.contextDeliveryPending == true
        if result.row.contextRecoveryPending, !forkContextPending {
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
        session.pendingMCPPreamble = result.row.mcpPreamblePending
        session.mcpPreambleSent = result.row.mcpPreambleSent
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
        session.replaceTranscriptMessages(tail, messageIndexOffset: tailStart)
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
            case let .user(_, text, _, _):
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
        transcriptScrollMemory.removeValue(forKey: id)
        pendingModel.removeValue(forKey: id)
        pendingMode.removeValue(forKey: id)
    }

    func deleteSession(id: ACPSession.ID) {
        killRemoteHelperACPProcIfPossible(sessionId: id)
        onSessionEnded?(id)
        autoReconnectTasks.removeValue(forKey: id)?.cancel()
        cancelPendingDraftWrite(for: id)
        inFlightBackfills[id]?.cancel()
        inFlightBackfills[id] = nil
        pendingBackfillOlderWires[id] = nil
        sessions[id]?.transcript.resetMarkdownCaches()
        sessions[id] = nil
        sessionRefCounts.removeValue(forKey: id)
        visibleSessionCounts.removeValue(forKey: id)
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

    private func persistSessionRemoteId(_ s: ACPSession) async -> Bool {
        guard var row = persistedRows[s.id] else { return false }
        row.remoteSessionId = s.remoteSessionId
        let rowToPersist = row
        let fence = leaseFence(sessionId: s.id)
        let result = await enqueuePersistenceResult { persistence in
            try await persistence.upsertSession(rowToPersist, fence: fence)
        }.value
        guard result == true else { return false }
        if var currentRow = persistedRows[s.id] {
            currentRow.remoteSessionId = s.remoteSessionId
            persistedRows[s.id] = currentRow
            replaceRecentRow(currentRow)
        }
        return true
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

    private func persistMCPPreamble(sessionId: ACPSession.ID, pendingText: String?, sent: Bool) {
        if var row = persistedRows[sessionId] {
            row.mcpPreamblePending = pendingText
            row.mcpPreambleSent = sent
            persistedRows[sessionId] = row
        }
        let fence = leaseFence(sessionId: sessionId)
        enqueuePersistence { persistence in
            _ = try await persistence.setMCPPreamble(
                sessionId: sessionId,
                pendingText: pendingText,
                sent: sent,
                fence: fence
            )
        }
    }

    private func persistHelperProcOffsets(
        sessionId: ACPSession.ID,
        offsets: RemoteHelperACPTransport.OutputOffsets
    ) {
        guard !isMirror(sessionId: sessionId) else { return }
        let stdoutOffset = offsets.stdout.flatMap(Self.sqliteOffset)
        let stderrOffset = offsets.stderr.flatMap(Self.sqliteOffset)
        guard stdoutOffset != nil || stderrOffset != nil else { return }
        if var row = persistedRows[sessionId] {
            if let stdoutOffset,
               row.helperProcStdoutOffset == nil || row.helperProcStdoutOffset! < stdoutOffset {
                row.helperProcStdoutOffset = stdoutOffset
            }
            if let stderrOffset,
               row.helperProcStderrOffset == nil || row.helperProcStderrOffset! < stderrOffset {
                row.helperProcStderrOffset = stderrOffset
            }
            persistedRows[sessionId] = row
        }
        let fence = leaseFence(sessionId: sessionId)
        enqueuePersistence { persistence in
            _ = try await persistence.updateHelperProcOffsets(
                sessionId: sessionId,
                stdoutOffset: stdoutOffset,
                stderrOffset: stderrOffset,
                fence: fence
            )
        }
    }

    private static func sqliteBrokerInt64(_ value: UInt64) -> Int64? {
        guard value <= UInt64(Int64.max) else { return nil }
        return Int64(value)
    }

    private func resetHelperProcOffsets(sessionId: ACPSession.ID) async {
        guard !isMirror(sessionId: sessionId) else { return }
        if var row = persistedRows[sessionId] {
            row.helperProcStdoutOffset = 0
            row.helperProcStderrOffset = 0
            persistedRows[sessionId] = row
        }
        let fence = leaseFence(sessionId: sessionId)
        let task = enqueuePersistence { persistence in
            _ = try await persistence.resetHelperProcOffsets(
                sessionId: sessionId,
                fence: fence
            )
        }
        await task.value
    }

    private func persistACPBrokerState(sessionId: ACPSession.ID, state: ACPBrokerDurableState) {
        guard !isMirror(sessionId: sessionId) else { return }
        guard let generation = Self.sqliteBrokerInt64(state.generation.rawValue),
              let acknowledgedCursor = Self.sqliteBrokerInt64(state.acknowledgedCursor.rawValue)
        else {
            persistenceError = "ACP broker cursor state is out of SQLite Int64 range."
            return
        }
        let matchesCurrentGeneration: Bool
        if var row = persistedRows[sessionId] {
            matchesCurrentGeneration = row.acpBrokerId == state.brokerId.rawValue
                && row.acpBrokerGeneration == generation
            row.acpBrokerId = state.brokerId.rawValue
            row.acpBrokerGeneration = generation
            row.acpBrokerAcknowledgedCursor = matchesCurrentGeneration
                ? max(row.acpBrokerAcknowledgedCursor, acknowledgedCursor)
                : acknowledgedCursor
            persistedRows[sessionId] = row
            replaceRecentRow(row)
        } else {
            matchesCurrentGeneration = false
        }
        let fence = leaseFence(sessionId: sessionId)
        enqueuePersistence { persistence in
            if matchesCurrentGeneration {
                _ = try await persistence.updateACPBrokerAcknowledgedCursor(
                    sessionId: sessionId,
                    state: state,
                    fence: fence
                )
            } else {
                _ = try await persistence.updateACPBrokerState(
                    sessionId: sessionId,
                    state: state,
                    fence: fence
                )
            }
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

    private func killRemoteHelperACPProcIfPossible(sessionId: ACPSession.ID) {
        guard let host = RemoteHostRegistry.shared.host(forPath: worktreePath) else { return }
        let procId = Self.helperACPProcId(sessionId: sessionId)
        Task {
            let client = await RemoteHelperClientPool.shared.client(for: host)
            try? await client.killProc(procId: procId)
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

    private static func makeStdioConnection(
        spec: ACPLaunchSpec,
        host: String?,
        worktreePath: String
    ) throws -> ACPConnection {
        try makeDefaultConnection(
            spec: spec,
            host: host,
            worktreePath: worktreePath,
            sessionId: nil,
            useHelperProc: false
        )
    }

    private func makeBrokerConnection(
        service: ACPBrokerServicing,
        launchSpec: ACPLaunchSpec,
        sessionId: ACPSession.ID,
        session: ACPSession,
        environment: [String: String]
    ) async throws -> ACPConnection {
        let brokerId = ACPBrokerID(rawValue: persistedRows[sessionId]?.acpBrokerId ?? Self.defaultBrokerId(
            for: sessionId
        ))
        let client = ACPBrokerClient(
            service: service,
            brokerId: brokerId,
            sessionId: sessionId,
            command: launchSpec.command,
            args: launchSpec.arguments,
            cwd: worktreePath,
            env: environment,
            operationKeyPrefix: "\(instanceId):\(sessionId):\(UUID().uuidString)",
            initialBrokerGeneration: Self.brokerGeneration(from: persistedRows[sessionId]),
            initialAcknowledgedCursor: Self.brokerCursor(from: persistedRows[sessionId]),
            onDurableStateChanged: { [weak self] state in
                Task { @MainActor [weak self] in
                    self?.persistACPBrokerState(sessionId: sessionId, state: state)
                }
            },
            onTurnStateChanged: { [weak self] turnState in
                Task { @MainActor [weak self] in
                    guard let self, let session = self.sessions[sessionId] else { return }
                    Self.applyBrokerTurnState(turnState, to: session)
                    if Self.brokerTurnStateAllowsQueueFlush(turnState) {
                        self.runners[sessionId]?.flushQueueIfIdle()
                    }
                }
            }
        )
        // The restored queue may still hold a `.pending` item that was
        // `.sending` when the app last quit (see `QueuedPrompt.
        // normalizedAfterRestore()`) — its `brokerOperationKey` didn't
        // change, and the broker may have already completed it before the
        // crash. Register it before start() so that replay can't have its
        // completion cursor acked past before the queue flusher (which only
        // runs once this function returns and the runner is registered)
        // gets a chance to claim it. A negotiating fork has the same replay
        // gap: its stable startup key must be protected until attach calls
        // `session/fork` and persists the final mechanism.
        var awaitedOperationKeys = session.queue.map(\.brokerOperationKey)
        var negotiatingForkOperationKey: String?
        if let fork = session.forkRecord,
           fork.phase == .negotiatingNative,
           let source = try await persistence.loadSession(id: fork.sourceSessionID),
           let sourceRemoteSessionID = source.remoteSessionId,
           !sourceRemoteSessionID.isEmpty {
            let operationKey = Self.brokerStartupOperationKey(
                sessionId: sessionId,
                method: "session/fork",
                remoteSessionId: sourceRemoteSessionID
            )
            awaitedOperationKeys.append(operationKey)
            negotiatingForkOperationKey = operationKey
        }
        client.preRegisterAwaitedOperationKeys(awaitedOperationKeys)
        do {
            try await client.start()
        } catch {
            // `open` may reveal a completed fork in its operation snapshot
            // before the following replay fails. Preserve that terminal
            // classification across this construction boundary: otherwise
            // the caller sees an ordinary launch failure and durably selects
            // transcript fallback even when the native fork already exists.
            let terminalOutcome = negotiatingForkOperationKey.flatMap {
                client.terminalOutcome(forPreRegisteredOperationKey: $0)
            }
            await client.detach()
            if let terminalOutcome {
                throw ACPBrokerDurableCompletionReplayError(
                    outcome: terminalOutcome,
                    underlying: error
                )
            }
            throw error
        }
        Self.applyBrokerTurnState(client.currentTurnState, to: session)
        return ACPConnection(client: client)
    }

    private static func defaultBrokerId(for sessionId: ACPSession.ID) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let sanitized = sessionId.map { allowed.contains($0) ? $0 : "_" }
        return String(("local-" + String(sanitized)).prefix(160))
    }

    private static func brokerStartupOperationKey(
        sessionId: ACPSession.ID,
        method: String,
        remoteSessionId: String? = nil
    ) -> String {
        if let remoteSessionId, !remoteSessionId.isEmpty {
            return "startup:\(sessionId):\(method):\(remoteSessionId)"
        }
        return "startup:\(sessionId):\(method)"
    }

    @discardableResult
    private func downgradeNegotiatingForkToTranscript(session: ACPSession) async throws -> Bool {
        guard var fork = session.forkRecord, fork.phase == .negotiatingNative else { return false }
        do {
            try await persistence.finalizeFork(
                targetSessionID: session.id,
                mechanism: .transcriptTransfer,
                remoteSessionID: nil
            )
        } catch {
            persistenceError = error.localizedDescription
            throw ACPForkFallbackPersistenceError(underlying: error)
        }
        fork.phase = .ready
        fork.mechanism = .transcriptTransfer
        fork.contextDeliveryPending = true
        session.forkRecord = fork
        return true
    }

    private func surfaceForkFallbackPersistenceFailure(
        _ error: any Error,
        on session: ACPSession
    ) {
        let message = (error as? ACPForkFallbackPersistenceError)?.localizedDescription
            ?? ACPForkFallbackPersistenceError(underlying: error).localizedDescription
        session.lastError = message
        session.contextRecoveryStatus = nil
        session.agentState = .failed(message)
    }

    private func releaseReplayedForkCompletionForTranscriptFallback(
        targetSessionID: ACPSession.ID,
        sourceRemoteSessionID: String,
        connection: ACPConnection
    ) async {
        guard let brokerClient = connection.client as? ACPBrokerClient else { return }
        let operationKey = Self.brokerStartupOperationKey(
            sessionId: targetSessionID,
            method: "session/fork",
            remoteSessionId: sourceRemoteSessionID
        )
        guard let replayed = brokerClient.replayedCompletion(
            forPreRegisteredOperationKey: operationKey
        ) else {
            return
        }
        if replayed.outcome.error == nil,
           let result = replayed.outcome.result,
           let forked = try? JSONDecoder().decode(
               ACPSessionNewResult.self,
               from: result.data
           ),
           !forked.sessionId.isEmpty {
            try? await connection.closeSession(sessionId: forked.sessionId)
        }
        replayed.acknowledgeDurableConsumption()
    }

    private func startTranscriptFallbackSession(
        targetSessionID: ACPSession.ID,
        sourceRemoteSessionID: String,
        connection: ACPConnection,
        wireMCPServers: [ACPMCPServer]
    ) async throws -> ACPSessionNewResult {
        await releaseReplayedForkCompletionForTranscriptFallback(
            targetSessionID: targetSessionID,
            sourceRemoteSessionID: sourceRemoteSessionID,
            connection: connection
        )
        do {
            let result = try await connection.newSession(
                cwd: worktreePath,
                mcpServers: wireMCPServers,
                brokerOperationKey: Self.brokerStartupOperationKey(
                    sessionId: targetSessionID,
                    method: "session/new"
                )
            )
            await releaseReplayedForkCompletionForTranscriptFallback(
                targetSessionID: targetSessionID,
                sourceRemoteSessionID: sourceRemoteSessionID,
                connection: connection
            )
            return result
        } catch {
            await releaseReplayedForkCompletionForTranscriptFallback(
                targetSessionID: targetSessionID,
                sourceRemoteSessionID: sourceRemoteSessionID,
                connection: connection
            )
            throw error
        }
    }

    private func startForkTarget(
        session: ACPSession,
        fork: ACPSessionForkRecord,
        initialized: ACPInitializeOutcome,
        connection: ACPConnection,
        wireMCPServers: [ACPMCPServer]
    ) async throws -> (result: ACPSessionNewResult, createdFreshRemoteSession: Bool) {
        var fork = fork
        let canAttemptNativeFork = initialized.sessionCapabilities.supportsFork
            && connection.client.providesDurableOperationKeyDeduplication
        let source = canAttemptNativeFork
            ? try await persistence.loadSession(id: fork.sourceSessionID)
            : nil
        let sourceRemoteSessionID = source?.remoteSessionId
        let forkOperationKey = sourceRemoteSessionID.flatMap { remoteSessionID in
            remoteSessionID.isEmpty ? nil : Self.brokerStartupOperationKey(
                sessionId: session.id,
                method: "session/fork",
                remoteSessionId: remoteSessionID
            )
        }
        let hasReplayedForkCompletion = if let forkOperationKey,
                                           let brokerClient = connection.client as? ACPBrokerClient {
            brokerClient.replayedCompletion(
                forPreRegisteredOperationKey: forkOperationKey
            ) != nil
        } else {
            false
        }
        let sourceRunner = runners[fork.sourceSessionID]
        let nativeForkBarrierAcquired = canAttemptNativeFork && !hasReplayedForkCompletion
            ? await sourceRunner?.beginNativeForkBarrier() ?? false
            : false
        defer {
            if nativeForkBarrierAcquired {
                sourceRunner?.endNativeForkBarrier()
            }
        }
        if nativeForkBarrierAcquired {
            await sourceRunner?.flushPersistence()
        }
        let sourceBoundaryMatches = if canAttemptNativeFork {
            try await persistence.latestMessageSeq(sessionId: fork.sourceSessionID)
                == fork.sourceBoundarySequence
        } else {
            false
        }
        let hasNativeForkAuthority = if hasReplayedForkCompletion {
            true
        } else if nativeForkBarrierAcquired,
                  let sourceRunner,
                  runners[fork.sourceSessionID] === sourceRunner {
            await sourceRunner.confirmNativeForkBarrier()
        } else {
            false
        }
        if canAttemptNativeFork,
           hasNativeForkAuthority,
           let sourceRemoteSessionID,
           !sourceRemoteSessionID.isEmpty,
           sourceBoundaryMatches {
            let result: ACPSessionNewResult
            do {
                result = try await connection.forkSession(
                    cwd: worktreePath,
                    sessionId: sourceRemoteSessionID,
                    mcpServers: wireMCPServers,
                    brokerOperationKey: Self.brokerStartupOperationKey(
                        sessionId: session.id,
                        method: "session/fork",
                        remoteSessionId: sourceRemoteSessionID
                    )
                )
            } catch {
                // A successful durable broker completion must retry the
                // stable fork key so its returned session can be persisted.
                // A terminal JSON-RPC completion is equally durable, but it
                // selects transcript fallback and its replayed cursor must be
                // consumed there. A plain transport error may have happened
                // before the broker accepted the send and also falls back.
                let durableReplay = error as? ACPBrokerDurableCompletionReplayError
                if let durableReplay, durableReplay.outcome.error == nil {
                    throw error
                }
                try await persistence.finalizeFork(
                    targetSessionID: session.id,
                    mechanism: .transcriptTransfer,
                    remoteSessionID: nil
                )
                fork.phase = .ready
                fork.mechanism = .transcriptTransfer
                fork.contextDeliveryPending = true
                session.forkRecord = fork
                connection.acknowledgeDurableSessionResponses()
                await releaseReplayedForkCompletionForTranscriptFallback(
                    targetSessionID: session.id,
                    sourceRemoteSessionID: sourceRemoteSessionID,
                    connection: connection
                )
                let fallbackError: any Error
                if let terminalError = durableReplay?.outcome.error {
                    fallbackError = ACPClientError.jsonrpc(terminalError)
                } else {
                    fallbackError = error
                }
                if ACPAuthFailure.message(from: fallbackError) != nil {
                    throw fallbackError
                }
                let fallback = try await startTranscriptFallbackSession(
                    targetSessionID: session.id,
                    sourceRemoteSessionID: sourceRemoteSessionID,
                    connection: connection,
                    wireMCPServers: wireMCPServers
                )
                return (fallback, true)
            }

            do {
                try await persistence.finalizeFork(
                    targetSessionID: session.id,
                    mechanism: .nativeACP,
                    remoteSessionID: result.sessionId
                )
            } catch {
                try? await connection.closeSession(sessionId: result.sessionId)
                let transcriptFinalized: Bool
                do {
                    try await persistence.finalizeFork(
                        targetSessionID: session.id,
                        mechanism: .transcriptTransfer,
                        remoteSessionID: nil
                    )
                    transcriptFinalized = true
                } catch {
                    persistenceError = error.localizedDescription
                    transcriptFinalized = false
                }
                if transcriptFinalized {
                    fork.phase = .ready
                    fork.mechanism = .transcriptTransfer
                    fork.contextDeliveryPending = true
                    session.forkRecord = fork
                    connection.acknowledgeDurableSessionResponses()
                }
                throw error
            }
            fork.phase = .ready
            fork.mechanism = .nativeACP
            fork.contextDeliveryPending = false
            session.forkRecord = fork
            session.markAsAgentForked()
            if var row = persistedRows[session.id] {
                row.remoteSessionId = result.sessionId
                row.origin = .agentForked
                persistedRows[session.id] = row
                replaceRecentRow(row)
            }
            connection.acknowledgeDurableSessionResponses()
            return (result, false)
        }

        try await persistence.finalizeFork(
            targetSessionID: session.id,
            mechanism: .transcriptTransfer,
            remoteSessionID: nil
        )
        fork.phase = .ready
        fork.mechanism = .transcriptTransfer
        fork.contextDeliveryPending = true
        session.forkRecord = fork
        if let source = try await persistence.loadSession(id: fork.sourceSessionID),
           let sourceRemoteSessionID = source.remoteSessionId,
           !sourceRemoteSessionID.isEmpty {
            let result = try await startTranscriptFallbackSession(
                targetSessionID: session.id,
                sourceRemoteSessionID: sourceRemoteSessionID,
                connection: connection,
                wireMCPServers: wireMCPServers
            )
            return (result, true)
        }
        let result = try await connection.newSession(
            cwd: worktreePath,
            mcpServers: wireMCPServers,
            brokerOperationKey: Self.brokerStartupOperationKey(
                sessionId: session.id,
                method: "session/new"
            )
        )
        return (result, true)
    }

    private static func applyBrokerTurnState(_ turnState: ACPBrokerTurnState, to session: ACPSession) {
        switch turnState {
        case .sending, .cancelling:
            session.transcript.streamingState = .sending
        case .streaming:
            session.transcript.streamingState = .streaming
        case .awaitingInput:
            session.transcript.streamingState = .awaitingInput
        case .idle, .completed, .ambiguous, .unknown:
            session.transcript.streamingState = .idle
        }
    }

    private static func brokerTurnStateAllowsQueueFlush(_ turnState: ACPBrokerTurnState) -> Bool {
        switch turnState {
        case .idle, .completed, .ambiguous, .unknown:
            return true
        case .sending, .streaming, .awaitingInput, .cancelling:
            return false
        }
    }

    private static func brokerCursor(from row: ACPSessionRow?) -> ACPBrokerEventCursor {
        let raw = row?.acpBrokerAcknowledgedCursor ?? 0
        guard raw > 0 else { return ACPBrokerEventCursor(rawValue: 0) }
        return ACPBrokerEventCursor(rawValue: UInt64(raw))
    }

    private static func brokerGeneration(from row: ACPSessionRow?) -> ACPBrokerGeneration? {
        guard let raw = row?.acpBrokerGeneration, raw > 0 else { return nil }
        return ACPBrokerGeneration(rawValue: UInt64(raw))
    }

    private static func makeDefaultConnection(
        spec: ACPLaunchSpec,
        host: String?,
        worktreePath: String,
        sessionId: ACPSession.ID?,
        useHelperProc: Bool,
        initialHelperProcOffsets: RemoteHelperACPTransport.OutputOffsets? = nil,
        onFreshHelperProcSpawn: @escaping @MainActor @Sendable () async -> Void = {},
        onHelperProcOffsetsChanged: @escaping @MainActor @Sendable (RemoteHelperACPTransport.OutputOffsets) -> Void = { _ in }
    ) throws -> ACPConnection {
        let client: ACPStdioClient
        if let host, useHelperProc, let sessionId {
            let transport = RemoteHelperACPTransport(
                host: host,
                procId: helperACPProcId(sessionId: sessionId),
                command: spec.command,
                arguments: spec.arguments,
                cwd: worktreePath,
                environment: ACPProcessEnvironment.remoteOverridesForACP(extra: spec.extraEnv),
                pathPrefixDirectories: spec.remoteNodeBinDirectory.map { [$0] } ?? [],
                initialOutputOffsets: initialHelperProcOffsets,
                onFreshProcSpawn: onFreshHelperProcSpawn,
                onOutputOffsetsChanged: onHelperProcOffsetsChanged
            )
            client = ACPStdioClient.makeForTesting(transport: transport)
        } else if let host {
            let invocation = ACPRemoteLaunch.channelInvocation(
                host: host,
                worktreePath: worktreePath,
                command: spec.command,
                arguments: spec.arguments,
                nodeBinDirectory: spec.remoteNodeBinDirectory
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

    private static func helperACPProcId(sessionId: ACPSession.ID) -> String {
        let allowed = sessionId.map { char -> Character in
            if char.isLetter || char.isNumber || char == "-" || char == "_" {
                return char
            }
            return "-"
        }
        return "acp-" + String(allowed)
    }

    private static func helperProcOffsets(from row: ACPSessionRow?) -> RemoteHelperACPTransport.OutputOffsets? {
        guard let row else { return nil }
        let stdout = row.helperProcStdoutOffset.flatMap { $0 >= 0 ? UInt64($0) : nil }
        let stderr = row.helperProcStderrOffset.flatMap { $0 >= 0 ? UInt64($0) : nil }
        guard stdout != nil || stderr != nil else { return nil }
        return RemoteHelperACPTransport.OutputOffsets(stdout: stdout, stderr: stderr)
    }

    private static func sqliteOffset(_ offset: UInt64) -> Int64? {
        guard offset <= UInt64(Int64.max) else { return nil }
        return Int64(offset)
    }

    private func remoteHelperSupportsProc(host: String) async -> Bool {
        if await RemoteHostCapabilityStore.shared.capabilities(for: host)?.helperHandshake == nil {
            return false
        }
        do {
            let client = await RemoteHelperClientPool.shared.client(for: host)
            return try await client.hello().capabilities.proc == true
        } catch {
            return false
        }
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
        let delegatedMessageToken = delegatedMessageNotifier.subscribe { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self._ownedLeases.contains(sessionId) else { return }
                self.onDelegatedMessageAvailable?(sessionId)
            }
        }
        delegatedMessageWatchTokens[sessionId] = delegatedMessageToken
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
        if let t = delegatedMessageWatchTokens.removeValue(forKey: sessionId) {
            delegatedMessageNotifier.unsubscribe(t)
        }
        writerWatchDebounce.removeValue(forKey: sessionId)?.cancel()
    }

    /// Wake the active owner of this worktree to drain delegated messages.
    /// This uses a dedicated channel so normal transcript persistence does not
    /// trigger inbox scans.
    func notifyDelegatedMessagesAvailable() {
        delegatedMessageNotifier.post()
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
            await runner.connection.detach()
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
        let persistedModel = freshlyCreated ? nil : session.currentModel
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
                // A failed/aborted attach may have already spawned the supervised
                // `alas mcp --http` helper (the provider runs before session
                // creation). Tear it down so it doesn't linger bound on
                // localhost; a later reattach respawns it. No-op for stdio sessions.
                onSessionEnded?(sessionId)
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
        session.providerCapabilities = nil
        session.availableProviders = []
        session.agentState = .spawning

        guard let spec = ACPLaunchCatalog.spec(for: session.agentId) else {
            do {
                try await downgradeNegotiatingForkToTranscript(session: session)
            } catch {
                surfaceForkFallbackPersistenceFailure(error, on: session)
                await releaseWriterLease(sessionId: sessionId)
                return
            }
            let reason = "No ACP launch spec for \(session.agentId)"
            session.setupState = .needsSetup(reason: reason)
            session.agentState = .failed(reason)
            await releaseWriterLease(sessionId: sessionId)
            return
        }
        let setup = await evaluateSetup(for: spec)
        guard case .ready = setup else {
            do {
                try await downgradeNegotiatingForkToTranscript(session: session)
            } catch {
                surfaceForkFallbackPersistenceFailure(error, on: session)
                await releaseWriterLease(sessionId: sessionId)
                return
            }
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
        // Set inside the do-block below when the alas CLI env was merged
        // into the launch spec (local sessions only). Consumed further down
        // to decide whether the first-prompt preamble should mention the
        // CLI alongside any injected MCP servers.
        var cliEnvActive = false
        // Set alongside `cliEnvActive`, from the merged launch spec's
        // `ALAS_PARENT_SESSION_ID` (see `AlasCLIEnvInjection.environment`).
        // Consumed by the CLI-mode preamble below to decide whether this is
        // a delegated session (`launchSpec` itself is scoped to this
        // `do` block, so its `extraEnv` is captured here for later use).
        var cliParentSessionId: String?
        let agentEnvironment: [String: String]
        do {
            let host = RemoteHostRegistry.shared.host(forPath: worktreePath)
            var launchSpec = await resolvedLaunchSpec(for: spec, host: host)
            if host == nil, let cliEnv = await alasCLIEnvProvider?(worktreePath, sessionId) {
                launchSpec = launchSpec.mergingExtraEnv(cliEnv)
                cliEnvActive = true
                cliParentSessionId = launchSpec.extraEnv["ALAS_PARENT_SESSION_ID"]
            }
            agentEnvironment = ACPProcessEnvironment.sanitizedForACP(extra: launchSpec.extraEnv)
            if let injectedConnectionFactory {
                connection = try injectedConnectionFactory(launchSpec, host, worktreePath)
            } else if host == nil, let brokerServiceFactory {
                connection = try await makeBrokerConnection(
                    service: try await brokerServiceFactory(),
                    launchSpec: launchSpec,
                    sessionId: sessionId,
                    session: session,
                    environment: agentEnvironment
                )
            } else {
                let useHelperProc = if let host {
                    await remoteHelperSupportsProc(host: host)
                } else {
                    false
                }
                connection = try Self.makeDefaultConnection(
                    spec: launchSpec,
                    host: host,
                    worktreePath: worktreePath,
                    sessionId: sessionId,
                    useHelperProc: useHelperProc,
                    initialHelperProcOffsets: Self.helperProcOffsets(from: persistedRows[sessionId]),
                    onFreshHelperProcSpawn: { [weak self] in
                        await self?.resetHelperProcOffsets(sessionId: sessionId)
                    },
                    onHelperProcOffsetsChanged: { [weak self] offsets in
                        self?.persistHelperProcOffsets(sessionId: sessionId, offsets: offsets)
                    }
                )
            }
        } catch {
            let durableForkRetry = (error as? ACPBrokerDurableCompletionReplayError).flatMap {
                $0.outcome.error == nil ? $0 : nil
            }
            if durableForkRetry == nil {
                do {
                    try await downgradeNegotiatingForkToTranscript(session: session)
                } catch {
                    surfaceForkFallbackPersistenceFailure(error, on: session)
                    await releaseWriterLease(sessionId: sessionId)
                    return
                }
            }
            let surfacedError = durableForkRetry?.underlying ?? error
            let msg = "Failed to launch agent: \(surfacedError.localizedDescription)"
            session.lastError = msg
            session.agentState = .failed(msg)
            await releaseWriterLease(sessionId: sessionId)
            return
        }
        // `cliEnvActive` / `cliParentSessionId` are consumed below, once we
        // know whether this attach created a fresh remote session (the
        // preamble is only sent once, on first prompt).
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
            let initialized = try await connection.initialize(
                brokerOperationKey: Self.brokerStartupOperationKey(
                    sessionId: sessionId,
                    method: "initialize"
                )
            )
            session.promptCapabilities = initialized.promptCapabilities
            session.sessionCapabilities = initialized.sessionCapabilities
            session.authMethods = initialized.authMethods
            session.adapterSupportsHTTPMCP = initialized.mcpCapabilities.http
            let projectContext = mcpProjectContextProvider?()
                ?? MCPProjectContext(projectDirectory: worktreePath, configuredServers: [])
            let mcpPlan = MCPAttachmentPlanner.plan(.init(
                configuredServers: projectContext.configuredServers,
                projectDirectory: projectContext.projectDirectory,
                worktreeDirectory: worktreePath,
                environment: agentEnvironment,
                capabilities: initialized.mcpCapabilities
            ))
            // The built-in alas server composes after planning (it is not
            // user configuration). It is local-only by construction — its
            // command and socket live on this machine — so remote sessions
            // skip it entirely instead of reporting it unavailable on every
            // connect.
            let remoteHost = RemoteHostRegistry.shared.host(forPath: worktreePath)
            let builtInMCP = remoteHost == nil
                ? await builtInMCPProvider?(worktreePath, sessionId, initialized.mcpCapabilities.http)
                : nil
            // `.external` adapters (e.g. Pi) ignore the ACP `mcpServers` wire
            // config entirely and reach Alas tools through the injected CLI
            // environment instead, so the built-in server never spawns/connects
            // and no `mcp_hello` ever arrives. Running the detection there would
            // always resolve `.notRegistered` and wrongly offer an HTTP switch
            // the adapter would also ignore — so skip registration tracking for
            // external adapters.
            let usesWireMCP: Bool = {
                if case .external = spec.mcpInjection { return false }
                return true
            }()
            let shouldTrackBuiltInRegistration = builtInMCP != nil && usesWireMCP
            // Bump the attach epoch so a grace timer left over from a previous
            // attach of this session can never write the current row.
            let mcpRegistrationEpoch = (mcpRegistrationAttachEpoch[sessionId] ?? 0) + 1
            mcpRegistrationAttachEpoch[sessionId] = mcpRegistrationEpoch
            if shouldTrackBuiltInRegistration {
                clearMCPRegistration?(sessionId)
            }
            // Reset to `.unknown` on every attach: either we are about to track
            // (the grace timer starts after session creation succeeds, below),
            // or the built-in server isn't requested this attach (disabled,
            // user-overridden, or an external adapter), in which case any stale
            // `.notRegistered` from a prior attach must be cleared so the status
            // control stops warning about a server that is no longer requested.
            session.builtInMCPRegistration = .unknown
            var plannedWireServers = mcpPlan.wireServers
            var plannedStatuses = mcpPlan.statuses
            if let builtInMCP {
                plannedWireServers.append(builtInMCP.server)
                plannedStatuses.append(builtInMCP.status)
            }
            // gg-mcp composes the same way as the alas built-in: after
            // planning, local-only, suppressed by a user-configured server
            // of the same name (checked inside the injection).
            let ggMCP = remoteHost == nil ? ggMCPProvider?(worktreePath) : nil
            if let ggMCP {
                plannedWireServers.append(ggMCP.server)
                plannedStatuses.append(ggMCP.status)
            }
            session.mcpAttachmentSummary = .init(
                statuses: plannedStatuses,
                configurationFingerprint: mcpPlan.configurationFingerprint
            )
            // `.external` adapters ignore the ACP MCP config above and need
            // agent-side setup instead (config files, plugins). Recomputed on
            // every attach so a freshly installed adapter or an edited
            // server list is picked up on the next reconnect.
            if case let .external(hint) = spec.mcpInjection {
                if remoteHost == nil {
                    let external = await externalMCPStatusProvider?(worktreePath)
                    session.mcpExternalStatus = ACPMCPExternalStatus(
                        cliActive: cliEnvActive,
                        adapterState: external?.adapterState ?? .unknown,
                        configOutcome: external?.configOutcome,
                        hint: hint,
                        userServerNames: external?.userServerNames ?? [],
                        skippedServerStatuses: external?.skippedServerStatuses ?? []
                    )
                } else {
                    // Remote pi session: the worktree lives on the remote host, so
                    // there is no local `.pi/agent` to inspect and no local
                    // `.pi/mcp.json` to write. Report an honest "unavailable"
                    // status instead of calling the (local-only) status provider.
                    session.mcpExternalStatus = ACPMCPExternalStatus(
                        cliActive: false,
                        adapterState: .unknown,
                        configOutcome: nil,
                        hint: hint,
                        userServerNames: mcpPlan.statuses.map(\.name),
                        skippedServerStatuses: mcpPlan.statuses.filter {
                            if case .skipped = $0.disposition { return true }
                            return false
                        },
                        canInstallAdapterLocally: false
                    )
                }
            } else {
                session.mcpExternalStatus = nil
            }
            let mcpSplit = remoteHost.map { _ in
                ACPRemoteMCPFilter.split(plannedWireServers)
            }
            let wireMCPServers = mcpSplit?.kept ?? plannedWireServers
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
                    do {
                        try await downgradeNegotiatingForkToTranscript(session: session)
                    } catch {
                        surfaceForkFallbackPersistenceFailure(error, on: session)
                        if connection.client is ACPBrokerClient {
                            await connection.detach()
                        } else {
                            await connection.shutdown()
                        }
                        return
                    }
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
                || restoreOperation == .loadStrict
                || restoreOperation == .resume)
                && !freshlyCreated
                && session.hydrationState == .ready
                && !session.transcript.messages.isEmpty
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
            let hasPendingForkContext = session.forkRecord?.phase == .ready
                && session.forkRecord?.mechanism == .transcriptTransfer
                && session.forkRecord?.contextDeliveryPending == true
            let pendingRecovery = !hasPendingForkContext
                && persistedRows[sessionId]?.contextRecoveryPending == true
            var createdFreshRemoteSession = false
            let result: ACPSessionNewResult
            var restoreWarning: ACPSession.ContextRestoreWarning?
            let hasRestorableContext = pendingRecovery
                || (!hasPendingForkContext && session.hasConversationTranscript)
            var shouldHoldQueueForRecovery = pendingRecovery
                && !hasPendingForkContext
                && session.hasConversationTranscript
            if firstRunAttach {
                session.firstRunConnectingPhase = .creatingSession
            }
            if let fork = session.forkRecord, fork.phase == .negotiatingNative {
                let started = try await startForkTarget(
                    session: session,
                    fork: fork,
                    initialized: initialized,
                    connection: connection,
                    wireMCPServers: wireMCPServers
                )
                result = started.result
                createdFreshRemoteSession = started.createdFreshRemoteSession
            } else if freshlyCreated {
                result = try await connection.newSession(
                    cwd: worktreePath,
                    mcpServers: wireMCPServers,
                    brokerOperationKey: Self.brokerStartupOperationKey(
                        sessionId: sessionId,
                        method: "session/new"
                    )
                )
                createdFreshRemoteSession = true
            } else if let remoteId = session.remoteSessionId, !remoteId.isEmpty {
                if !hasPendingForkContext, session.hasConversationTranscript {
                    session.contextRecoveryStatus = .restoring
                }
                switch restoreOperation {
                case .resume:
                    do {
                        result = try await connection.resumeSession(
                            cwd: worktreePath,
                            sessionId: remoteId,
                            mcpServers: wireMCPServers,
                            brokerOperationKey: Self.brokerStartupOperationKey(
                                sessionId: sessionId,
                                method: "session/resume",
                                remoteSessionId: remoteId
                            )
                        )
                        runner.finishSuppressingLoadReplay(
                            throughYieldedUpdateCount: connection.client.yieldedUpdateCount
                        )
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
                        runner.finishSuppressingLoadReplay(
                            throughYieldedUpdateCount: connection.client.yieldedUpdateCount
                        )
                        guard session.origin == .alasCreated,
                              ACPAuthFailure.message(from: error) == nil
                        else { throw error }
                        result = try await connection.newSession(
                            cwd: worktreePath,
                            mcpServers: wireMCPServers,
                            brokerOperationKey: Self.brokerStartupOperationKey(
                                sessionId: sessionId,
                                method: "session/new"
                            )
                        )
                        createdFreshRemoteSession = true
                        if !hasPendingForkContext, session.hasConversationTranscript {
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
                        if !hasPendingForkContext, session.hasConversationTranscript {
                            session.contextRecoveryStatus = .sendingTranscript
                        }
                    }
                case .loadStrict:
                    let loadOperationKey = Self.brokerStartupOperationKey(
                        sessionId: sessionId,
                        method: "session/load",
                        remoteSessionId: remoteId
                    )
                    func resumeAfterLoadFailure(_ error: any Error) async throws
                        -> ACPSessionNewResult {
                        guard initialized.sessionCapabilities.supportsResume,
                              ACPAuthFailure.message(from: error) == nil
                        else { throw error }
                        return try await connection.resumeSession(
                            cwd: worktreePath,
                            sessionId: remoteId,
                            mcpServers: wireMCPServers,
                            brokerOperationKey: Self.brokerStartupOperationKey(
                                sessionId: sessionId,
                                method: "session/resume",
                                remoteSessionId: remoteId
                            )
                        )
                    }
                    func suppressFailedLoadReplayIfNeeded() {
                        guard !shouldSuppressLoadReplay else { return }
                        let target = connection.client.yieldedUpdateCount
                        guard target > 0 else { return }
                        runner.suppressLoadReplay(throughYieldedUpdateCount: target)
                        startRunnerIfNeeded()
                    }
                    func restoreStrictly() async throws -> (ACPSessionNewResult, resumed: Bool) {
                        do {
                            return (try await connection.loadSession(
                                cwd: worktreePath,
                                sessionId: remoteId,
                                mcpServers: wireMCPServers,
                                brokerOperationKey: loadOperationKey
                            ), false)
                        } catch {
                            suppressFailedLoadReplayIfNeeded()
                            guard error is ACPBrokerDurableCompletionReplayError else {
                                return (try await resumeAfterLoadFailure(error), true)
                            }
                        }
                        do {
                            // Reusing the stable key recovers successful results and lets
                            // ACPBrokerClient consume terminal completion cursors.
                            return (try await connection.loadSession(
                                cwd: worktreePath,
                                sessionId: remoteId,
                                mcpServers: wireMCPServers,
                                brokerOperationKey: loadOperationKey
                            ), false)
                        } catch {
                            guard !(error is ACPBrokerDurableCompletionReplayError) else {
                                throw error
                            }
                            suppressFailedLoadReplayIfNeeded()
                            return (try await resumeAfterLoadFailure(error), true)
                        }
                    }
                    let restored = try await restoreStrictly()
                    result = restored.0
                    if restored.resumed {
                        restoreWarning = .init(
                            message: "Earlier messages remain in the agent and are not available in Alas.",
                            canSendTranscript: false
                        )
                    }
                    if shouldSuppressLoadReplay {
                        runner.finishSuppressingLoadReplay(
                            throughYieldedUpdateCount: connection.client.yieldedUpdateCount
                        )
                    }
                    if !pendingRecovery {
                        session.contextRecoveryStatus = nil
                    }
                case .loadWithRecovery:
                    do {
                        result = try await connection.loadSession(
                            cwd: worktreePath,
                            sessionId: remoteId,
                            mcpServers: wireMCPServers,
                            brokerOperationKey: Self.brokerStartupOperationKey(
                                sessionId: sessionId,
                                method: "session/load",
                                remoteSessionId: remoteId
                            )
                        )
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
                        result = try await connection.newSession(
                            cwd: worktreePath,
                            mcpServers: wireMCPServers,
                            brokerOperationKey: Self.brokerStartupOperationKey(
                                sessionId: sessionId,
                                method: "session/new"
                            )
                        )
                        createdFreshRemoteSession = true
                        if !hasPendingForkContext, session.hasConversationTranscript {
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
                        if !hasPendingForkContext, session.hasConversationTranscript {
                            session.contextRecoveryStatus = .sendingTranscript
                        }
                    }
                case .unavailable:
                    throw ACPSessionAttachError.remoteSessionUnsupported
                }
            } else {
                result = try await connection.newSession(
                    cwd: worktreePath,
                    mcpServers: wireMCPServers,
                    brokerOperationKey: Self.brokerStartupOperationKey(
                        sessionId: sessionId,
                        method: "session/new"
                    )
                )
                createdFreshRemoteSession = true
                if !hasPendingForkContext, session.hasConversationTranscript {
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
                if !hasPendingForkContext, session.hasConversationTranscript {
                    session.contextRecoveryStatus = .sendingTranscript
                }
            }
            if restoreWarning == nil, pendingRecovery {
                restoreWarning = .init(
                    message: "Agent context could not be restored.",
                    canSendTranscript: session.hasConversationTranscript
                )
                if !hasPendingForkContext, session.hasConversationTranscript {
                    session.contextRecoveryStatus = .sendingTranscript
                }
            }
            let providers: [ACPProviderInfo] = if initialized.providerCapabilities != nil {
                (try? await connection.listProviders()) ?? []
            } else {
                []
            }
            // Start the built-in MCP registration grace ONLY now — session
            // creation/restoration above has succeeded, which is when the
            // adapter actually received `wireMCPServers` and could spawn or
            // connect the built-in server. Arming it at composition time risks a
            // slow auth or a >12s restore marking a healthy session
            // `.notRegistered` before the harness ever saw the config. Guarded
            // by the attach epoch so a stale timer cannot clobber a newer row; a
            // late hello still heals the row via AppState.onMCPHello.
            if shouldTrackBuiltInRegistration {
                Task { @MainActor [weak self, weak session] in
                    try? await Task.sleep(for: .seconds(12))
                    guard let self, let session,
                          self.mcpRegistrationAttachEpoch[sessionId] == mcpRegistrationEpoch
                    else { return }
                    // Don't downgrade a row that already registered.
                    if session.builtInMCPRegistration == .registered { return }
                    let helloSeen = self.isBuiltInMCPRegistered?(sessionId) ?? false
                    session.builtInMCPRegistration = MCPRegistrationDecision.resolve(
                        helloSeen: helloSeen, graceElapsed: true)
                }
            }
            if createdFreshRemoteSession {
                let preambleMode: ACPMCPPreambleMode
                let userServerNames: [String]
                if case .external = spec.mcpInjection {
                    // The `.external` (pi) status provider resolves an
                    // all-transports plan (http/sse force-enabled) because
                    // pi-mcp-adapter — unlike pi-acp's own ACP MCP support —
                    // can reach those transports. `wireMCPServers` here was
                    // planned against pi's real (http/sse-less)
                    // capabilities and would drop them, so the preamble must
                    // use the external status's resolved names instead.
                    userServerNames = session.mcpExternalStatus?.userServerNames ?? []
                    let serverAvailability = session.mcpExternalStatus?.adapterServerAvailability ?? .notInstalled
                    preambleMode = .cli(serverAvailability: serverAvailability)
                } else {
                    userServerNames = wireMCPServers.map(\.name)
                        .filter { !(builtInMCP != nil && $0 == BuiltInAlasMCP.serverName) }
                        .filter { !(ggMCP != nil && $0 == GGMCPInjection.serverName) }
                    preambleMode = .mcp
                }
                let ggSignal = ggPreambleProvider?(worktreePath) ?? GGPreambleSignal.none
                let ggStackContext: GGPreambleStackContext? = {
                    switch ggSignal {
                    case .none: return nil
                    case .generic:
                        return .init(stackName: nil, entryCount: nil, ggMCPAttached: ggMCP != nil)
                    case let .stack(name, entryCount):
                        return .init(stackName: name, entryCount: entryCount, ggMCPAttached: ggMCP != nil)
                    }
                }()
                let preamble = ACPMCPPromptPreamble.text(
                    builtInInjected: preambleMode == .mcp ? (builtInMCP != nil) : cliEnvActive,
                    isDelegated: preambleMode == .mcp
                        ? (builtInMCP?.isDelegated == true)
                        : (cliParentSessionId != nil),
                    userServerNames: userServerNames,
                    mode: preambleMode,
                    ggStack: ggStackContext,
                    issue: issuePreambleProvider?(worktreeId)
                )
                if isWriter(for: sessionId) {
                    session.pendingMCPPreamble = preamble
                    session.mcpPreambleSent = false
                    persistMCPPreamble(sessionId: sessionId, pendingText: preamble, sent: false)
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
                if isDisposed {
                    await connection.shutdown()
                } else {
                    await connection.detach()
                }
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
            session.providerCapabilities = initialized.providerCapabilities
            session.availableProviders = providers
            session.contextRestoreWarning = restoreWarning
            guard await persistSessionRemoteId(session) else {
                session.remoteSessionId = persistedRows[sessionId]?.remoteSessionId
                if isDisposed {
                    await connection.shutdown()
                } else {
                    await connection.detach()
                }
                startedRunner?.stop()
                await startedRunner?.flushPersistence()
                session.agentState = .idle
                if !isDisposed { beginMirroring(sessionId: sessionId) }
                await releaseWriterLease(sessionId: sessionId)
                return
            }
            let localModelAfterRemoteIdPersist = session.currentModel
            connection.acknowledgeDurableSessionResponses()
            startRunnerIfNeeded()
            runners[sessionId] = runner
            keepElicitationCoordinator = true
            attachSucceeded = true
            // Drain a pending model/mode picked during the post-takeover window.
            // The load result just above overwrote `currentModel`/`currentMode`
            // with the agent's restored values. Reapply + persist the user's
            // choice before dispatching queued or transcript-recovery prompts.
            let loadedMode = session.currentMode
            let modelToRestore = pendingModel.removeValue(forKey: sessionId)
                ?? (localModelAfterRemoteIdPersist != result.currentModel ? localModelAfterRemoteIdPersist : persistedModel)
            if let m = modelToRestore,
               m != result.currentModel {
                let loadedModel = session.currentModel
                let remoteId = session.remoteSessionId ?? sessionId
                do {
                    try await runner.connection.setModel(sessionId: remoteId, modelId: m)
                    if session.currentModel == loadedModel {
                        session.currentModel = m
                        persist(session)
                    }
                } catch {
                    if session.currentModel == loadedModel {
                        persist(session)
                    }
                }
            }
            if let m = pendingMode.removeValue(forKey: sessionId),
               session.currentMode == loadedMode {
                session.currentMode = m
                persist(session)
                let remoteId = session.remoteSessionId ?? sessionId
                try? await runner.connection.setMode(sessionId: remoteId, modeId: m)
            }
            guard session.agentState == .spawning else { return }
            let attachmentStillCurrent: Bool
            if isDisposed || sessions[sessionId] !== session || runners[sessionId] !== runner {
                attachmentStillCurrent = false
            } else {
                attachmentStillCurrent = await confirmedWriterLease(for: sessionId)
                    && sessions[sessionId] === session
                    && runners[sessionId] === runner
                    && !isDisposed
            }
            guard attachmentStillCurrent else {
                attachSucceeded = false
                if runners[sessionId] === runner {
                    runners[sessionId] = nil
                    runner.stop()
                    await runner.flushPersistence()
                    if isDisposed {
                        await runner.connection.shutdown()
                    } else {
                        await runner.connection.detach()
                        session.agentState = .idle
                        beginMirroring(sessionId: sessionId)
                    }
                    await releaseWriterLease(sessionId: sessionId)
                }
                return
            }
            session.agentState = .ready
            if let remoteMCPNotice {
                runner.appendAndPersistSystemNotice(remoteMCPNotice)
            }
            if shouldHoldQueueForRecovery {
                sendTranscriptAsContext(sessionId: sessionId, agentName: nil)
            } else {
                runner.flushQueueIfIdle()
            }
            stderrTask.cancel()
        } catch {
            let durableReplay = error as? ACPBrokerDurableCompletionReplayError
            let durableRetry = durableReplay.flatMap {
                $0.outcome.error == nil ? $0 : nil
            }
            let terminalReplayError: (any Error)? = durableReplay?.outcome.error.map {
                ACPClientError.jsonrpc($0)
            }
            let wasNegotiatingFork = session.forkRecord?.phase == .negotiatingNative
            var downgradePersistenceError: (any Error)?
            if durableRetry == nil {
                do {
                    try await downgradeNegotiatingForkToTranscript(session: session)
                    if wasNegotiatingFork, session.forkRecord?.phase == .ready {
                        connection.acknowledgeDurableSessionResponses()
                    }
                } catch {
                    downgradePersistenceError = error
                }
            }
            // Give stderr a moment to drain so the message is the real cause.
            try? await Task.sleep(nanoseconds: 200_000_000)
            stderrTask.cancel()
            let tail = stderrBuffer.tail()
            let surfacedError = downgradePersistenceError
                ?? terminalReplayError
                ?? durableRetry?.underlying
                ?? error
            let authReason = ACPAuthFailure.message(from: surfacedError)
            let baseMessage = authReason
                ?? (surfacedError as? JSONRPCError)?.message
                ?? surfacedError.localizedDescription
            let base = downgradePersistenceError == nil
                ? "ACP session attach failed: \(baseMessage)"
                : baseMessage
            let full = tail.isEmpty ? base : base + "\nstderr: " + tail
            session.lastError = full
            session.contextRecoveryStatus = nil
            if downgradePersistenceError != nil {
                session.agentState = .failed(full)
            } else if let authReason {
                session.setupState = .needsAuth(methods: session.authMethods, reason: authReason)
                session.agentState = .failed(authReason)
            } else {
                session.agentState = .failed(full)
            }
            startedRunner?.stop()
            await startedRunner?.flushPersistence()
            let shouldPreserveBroker = connection.client is ACPBrokerClient
                && session.forkRecord?.phase == .negotiatingNative
            if durableRetry != nil || shouldPreserveBroker {
                await connection.detach()
            } else {
                await connection.shutdown()
            }
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

        guard runner.sendRecoveryContext(prompt, onCompleted: { delivered in
            if delivered {
                self.persistContextRecoveryPending(sessionId: sessionId, pending: false)
                session.contextRestoreWarning = nil
                session.markContextRecoveryRestored()
            } else {
                session.contextRecoveryStatus = .failed("Transcript recovery failed.")
            }
        }) else { return false }
        session.contextRecoveryStatus = .sendingTranscript
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

    @discardableResult
    func enqueueDelegatedPrompt(
        text: String,
        source: ACPDelegatedPromptSource,
        into sessionId: ACPSession.ID
    ) async -> Bool {
        guard var session = sessions[sessionId] else { return false }
        guard !session.queue.contains(where: { $0.delegatedSource?.messageId == source.messageId }) else {
            return true
        }
        await awaitBackfill(id: sessionId)
        guard let currentSession = sessions[sessionId] else { return false }
        session = currentSession
        guard !session.queue.contains(where: { $0.delegatedSource?.messageId == source.messageId }) else {
            return true
        }
        guard !session.transcript.messages.contains(where: { message in
            guard case .user(_, _, _, _, let recordedSource) = message else { return false }
            return recordedSource == source
        }) else {
            return true
        }
        let blocks = ACPSessionRunner.blocks(text: text, attachments: [])
        session.enqueue(blocks: blocks, delegatedSource: source)
        let fence = leaseFence(sessionId: sessionId)
        let items = session.queue
        let task = enqueuePersistenceResult { persistence in
            try await persistence.upsertQueue(sessionId: sessionId, items: items, fence: fence)
        }
        guard await task.value == true else {
            session.queue.removeAll { $0.delegatedSource == source }
            return false
        }
        runners[sessionId]?.flushQueueIfIdle()
        return true
    }

    @discardableResult
    func enqueuePrompt(
        id: UUID,
        text: String,
        into sessionId: ACPSession.ID
    ) async -> Bool {
        guard var session = sessions[sessionId] else { return false }
        let source = ACPDelegatedPromptSource(
            sessionId: "mission:\(sessionId)",
            messageId: id.uuidString
        )
        guard !session.queue.contains(where: {
            $0.id == id || $0.delegatedSource?.messageId == source.messageId
        }) else { return true }
        await awaitBackfill(id: sessionId)
        guard let currentSession = sessions[sessionId] else { return false }
        session = currentSession
        guard !session.queue.contains(where: {
            $0.id == id || $0.delegatedSource?.messageId == source.messageId
        }) else { return true }
        guard !session.transcript.messages.contains(where: { message in
            guard case .user(_, _, _, _, let recordedSource) = message else { return false }
            return recordedSource == source
        }) else { return true }

        let item = QueuedPrompt(
            id: id,
            blocks: ACPSessionRunner.blocks(text: text, attachments: []),
            delegatedSource: source
        )
        session.queue.append(item)
        let fence = leaseFence(sessionId: sessionId)
        let items = session.queue
        let task = enqueuePersistenceResult { persistence in
            try await persistence.upsertQueue(sessionId: sessionId, items: items, fence: fence)
        }
        guard await task.value == true else {
            if let index = session.queue.firstIndex(where: { $0.id == item.id }) {
                session.queue.remove(at: index)
            }
            return false
        }
        runners[sessionId]?.flushQueueIfIdle()
        return true
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
            if ACPManagedAdapterDescriptor.descriptor(for: spec.agentID) != nil {
                let key = remoteAdapterKey(host: host, agentID: spec.agentID)
                guard let resolved = resolvedRemoteAdapters[key] else {
                    return spec
                }
                return spec.overridingCommand(
                    resolved.adapterPath,
                    remoteNodeBinDirectory: resolved.nodeBinDirectory
                )
            }
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

        if let descriptor = ACPManagedAdapterDescriptor.descriptor(for: spec.agentID) {
            let key = remoteAdapterKey(host: host, agentID: spec.agentID)
            let resolution = await remoteAdapterResolver(host, descriptor, spec.setupCheck)
            switch resolution {
            case .ready(let resolved):
                resolvedRemoteAdapters[key] = resolved
                return .ready
            case .missing(let reason):
                resolvedRemoteAdapters.removeValue(forKey: key)
                return .missing(reason: reason)
            case .error(let message):
                resolvedRemoteAdapters.removeValue(forKey: key)
                return .error(message: message)
            }
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

    private func remoteAdapterKey(host: String, agentID: String) -> String {
        "\(host)\u{0}\(agentID)"
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
