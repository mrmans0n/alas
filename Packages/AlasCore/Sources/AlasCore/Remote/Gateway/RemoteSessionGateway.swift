import Foundation

/// Bridges one remote WebSocket connection to the in-process ACP world.
///
/// Transport-agnostic: it consumes decoded `RemoteClientMessage`s and emits
/// `RemoteServerMessage`s via the `send` closure, so it is fully testable
/// without sockets. Observes the live `ACPTranscript` (Combine) and, on
/// change (coalesced), consumes `ACPTranscriptChangeLog` to emit either an
/// incremental delta (only the messages the log marked dirty) or, when the
/// log reports a structural change or the connection has fallen behind, a
/// fresh tail-window snapshot under a bumped epoch. Inbound permission
/// decisions route to the existing `ACPPermissionPolicy.userDecided(...)`
/// after a first-wins staleness guard.
@MainActor
public final class RemoteSessionGateway {
    private let provider: RemoteSessionsProvider
    /// The app's windows, for the tab requests; nil where there are none.
    @_spi(AppHost) public weak var presenter: RemoteSessionPresenter?
    /// Where the lists this gateway serves come from: the host's.
    @_spi(Testing) public lazy var reads = RemoteGatewayReads.host(provider.eventHost)
    private let federation: FederatedSessionsProvider?
    /// This gateway's registration with `federation`; nil without one.
    private var downstream: FederatedDownstream?
    private let send: (RemoteServerMessage) -> Void
    /// Console channel of an authenticated Alas peer; nil for browsers.
    private let consoleLink: PeerConsoleLink?
    private var subscriptions: [String: [ChangeSubscription]] = [:]
    private var configSubscriptions: [String: ChangeSubscription] = [:]
    private var configCoalesce: [String: Task<Void, Never>] = [:]
    private var lastConfig: [String: RemoteSessionConfig] = [:]
    private var lastQueue: [String: [RemoteQueuedPrompt]] = [:]
    private var coalesce: [String: Task<Void, Never>] = [:]
    private var sessionListRefresh: Task<Void, Never>?
    private var sessionListGeneration = 0
    private var worktreeListRefresh: Task<Void, Never>?
    private var worktreeListGeneration = 0
    /// Set once the client asks for worktrees or projects: only then are
    /// they pushed.
    private var wantsWorktreeList = false
    private var wantsProjectList = false
    private var hostSubscription: HostSubscription?
    private var providerListChanges: ChangeSubscription?
    private var projectListRefresh: Task<Void, Never>?
    private var projectListGeneration = 0
    private var branchListRefresh: Task<Void, Never>?
    private var branchListGeneration = 0
    private var syncStates: [String: RemoteTranscriptSync] = [:]
    private var trackedSessions: Set<String> = []
    // Per-session request id of the permission/question prompt we last surfaced,
    // so we can tell the client to dismiss it if it gets resolved elsewhere.
    private var lastPermissionReq: [String: Int] = [:]
    private var lastQuestionReq: [String: Int] = [:]
    private var lastPlanReq: [String: JSONRPCID] = [:]
    private var lastElicitationReq: [String: String] = [:]
    /// Requests currently being served, keyed by "<verb>\0<sessionId>\0<path>".
    /// A repeat while one is in flight is dropped: the client re-renders from
    /// the response either way, and each of these spawns a git process.
    private var inFlightFileRequests: Set<String> = []
    private static let coalesceNanos: UInt64 = 80_000_000  // ~80ms

    /// The paired device this connection authenticated. Nil for a gateway
    /// built without one: its Remote requests act as the app's, and it
    /// serves no host protocol.
    private let caller: HostCaller?
    private let sendTracked: (@Sendable (RemoteServerMessage, _ onWritten: @escaping @Sendable () -> Void) -> Void)?
    private var hostConnection: HostProtocolConnection?
    /// Host messages waiting for their frame to be written. A connection that
    /// fails never reports the write, so closing releases them.
    private var pendingWrites: [UUID: CheckedContinuation<Void, Never>] = [:]

    public init(provider: RemoteSessionsProvider, federation: FederatedSessionsProvider? = nil,
         consoleLink: PeerConsoleLink? = nil,
         caller: HostCaller? = nil,
         sendTracked: (@Sendable (RemoteServerMessage, _ onWritten: @escaping @Sendable () -> Void) -> Void)? = nil,
         send: @escaping (RemoteServerMessage) -> Void) {
        self.provider = provider
        self.caller = caller
        self.sendTracked = sendTracked
        self.federation = federation
        self.consoleLink = consoleLink
        self.send = send
        if let host = provider.eventHost { pushLists(from: host) }
        providerListChanges = provider.sessionListChanges?.observe { [weak self] in self?.refreshSessionList() }
        guard let federation else { return }
        // A peer's cached list moving refreshes this client even if it has
        // never asked for the list, which matches what `renameSession`
        // already does locally.
        let downstream = FederatedDownstream(
            send: { message in send(message) },
            sessionListChanged: { [weak self] in self?.refreshSessionList() })
        self.downstream = downstream
        federation.attach(downstream)
    }

    public func handle(_ message: RemoteClientMessage) async {
        if let federation, let downstream, federation.route(message, from: downstream) { return }
        switch message {
        case .helloAck:
            // Version acknowledgement from an Alas peer; nothing to do server-side.
            break
        case .host(let request):
            serveHost(request)
        case .console(let request):
            handleConsole(request)
        case .listSessions:
            refreshSessionList()
        case .listWorktrees:
            wantsWorktreeList = true
            refreshWorktreeList()
        case .listAgents:
            send(.agentList(agents: reads.agents()))
        case .listProjects:
            wantsProjectList = true
            refreshProjectList()
        case .listBranches(let projectId):
            refreshBranchList(projectId: projectId)
        case .createWorktreeSession(let projectId, let base, let branch, let agentId, let modelId, let effortId):
            let result = await provider.createRemoteWorktreeSession(
                projectId: projectId,
                base: base,
                branch: branch,
                agentId: agentId,
                modelId: modelId,
                effortId: effortId,
                caller: caller ?? .app
            )
            switch result {
            case .success(let summary):
                send(.worktreeSessionCreated(session: summary))
                refreshSessionList()
                refreshWorktreeList()
            case .failure(let stage, let message, let worktreeId):
                send(.worktreeSessionCreationFailed(
                    stage: stage,
                    message: message,
                    worktreeId: worktreeId
                ))
                if worktreeId != nil {
                    refreshWorktreeList()
                }
            }
        case .createSession(let worktreeId, let agentId, let modelId, let effortId):
            let result = await provider.createRemoteSession(
                worktreeId: worktreeId, agentId: agentId, modelId: modelId, effortId: effortId)
            switch result {
            case .success(let summary):
                send(.sessionCreated(session: summary))
                refreshSessionList()
            case .failure(let message):
                send(.createSessionFailed(message: message))
            }
        case .subscribe(let id):
            await provider.hydrateIfNeeded(id: id)
            guard let session = provider.session(for: id) else {
                send(.sessionClosed(sessionId: id))
                return
            }
            beginTracking(id: id, session: session)
            await sendSnapshot(id: id, session: session)
            if let cfg = provider.sessionConfig(for: id) {
                send(.sessionConfig(cfg))
            }
            sendQueueState(id: id, session: session, force: true)
            observe(id: id, session: session)
        case .unsubscribe(let id):
            subscriptions[id] = nil
            configSubscriptions[id] = nil
            configCoalesce[id]?.cancel()
            configCoalesce[id] = nil
            lastConfig[id] = nil
            lastQueue[id] = nil
            coalesce[id]?.cancel()
            coalesce[id] = nil
            lastPermissionReq[id] = nil
            lastQuestionReq[id] = nil
            lastElicitationReq[id] = nil
            lastPlanReq[id] = nil
            endTracking(id: id)
            syncStates[id] = nil
        case .permissionDecision(let id, let requestId, let optionId, let persistScope):
            await applyDecision(sessionId: id, requestId: requestId, optionId: optionId, persistScope: persistScope)
        case .questionAnswer(let id, let requestId, let answers):
            applyQuestionAnswer(sessionId: id, requestId: requestId, answers: answers)
        case .visualAidResponse(let sessionId, let visualId, let action, let selectedOptionIds, let note, let requestId):
            await handleVisualAidResponse(
                sessionId: sessionId, visualId: visualId, action: action,
                selectedOptionIds: selectedOptionIds, note: note, requestId: requestId)
        case .planResponse(let id, let requestId, let action, let reason):
            applyPlanResponse(sessionId: id, requestId: requestId, action: action, reason: reason)
        case .elicitationResponse(let id, let requestId, let action, let content):
            applyElicitationResponse(
                sessionId: id,
                requestId: requestId,
                action: action,
                content: content
            )
        case .takeOver(let id):
            try? await sessions?.takeOver(id, caller: hostCaller)
            // Takeover seizes the writer lease synchronously but mostly mutates
            // lease/agent state, not the transcript — so the objectWillChange
            // delta that normally carries `canDrive` may never fire on an idle
            // session. Push a snapshot now so the client learns canDrive=true
            // immediately and the composer unlocks (otherwise the take-over
            // button stays up and sendPrompt stays blocked until some unrelated
            // transcript mutation happens to occur).
            if let session = provider.session(for: id) {
                await sendSnapshot(id: id, session: session)
            }
        case .openSessionTab(let id):
            reportTabAction(await presenter?.openSessionTab(for: id) ?? .failure("Opening session tabs is unavailable."), sessionId: id)
        case .closeSessionTab(let id):
            reportTabAction(await presenter?.closeSessionTab(for: id) ?? .failure("Closing session tabs is unavailable."), sessionId: id)
        case .sendPrompt(let id, let text, let attachments, let intent, let mentions):
            // Pre-check the lease BEFORE materializing — `materialize` writes the
            // decoded images to disk, and a non-writer must be rejected without
            // leaving orphan files under acp-attachments/. The manager re-checks
            // isWriter too (TOCTOU defense for a takeover that lands mid-flight),
            // so this is an early-out, not the authoritative gate. Auto-takeover
            // still works: the client sends `takeOver` (synchronous lease seize)
            // before `sendPrompt`, so isWriter is already true here.
            guard let sessions, sessions.isWriter(id) else {
                send(.promptRejected(sessionId: id))
                return
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasContent = !trimmed.isEmpty || !attachments.isEmpty || !mentions.isEmpty
            guard hasContent else {
                send(.promptRejected(sessionId: id))
                return
            }
            // Resolved before `materialize` writes anything, so a refused
            // mention leaves no orphan image files.
            guard mentions.count <= Self.maxMentionCount,
                  let mentioned = await provider.remoteMentionAttachments(mentions, sessionId: id)
            else {
                send(.promptRejected(sessionId: id))
                return
            }
            guard let images = materialize(attachments, for: id) else {
                send(.promptRejected(sessionId: id))   // oversize / non-image
                return
            }
            let materialized = images + mentioned
            // The host re-checks the lease and reports delivery when the turn
            // ends. Any failure — refused now (not writer, needs auth) or a
            // session/prompt RPC that fails later — emits promptRejected, so
            // the client restores the user's text instead of losing it.
            // "steer" cancels the running turn and sends immediately while
            // preserving the queue; "auto" (the default, and everything an
            // older client sends) takes the ordinary enqueue-or-send route.
            let delivery: Task<Bool, Never>
            do {
                delivery = try await sessions.submit(
                    id, prompt: trimmed, attachments: materialized, steer: intent == "steer", caller: hostCaller
                )
            } catch {
                // Refused before the session recorded the message, so the
                // image files we wrote are orphans. Mentioned files are the
                // user's own.
                send(.promptRejected(sessionId: id))
                discardAttachmentFiles(images)
                return
            }
            // A later failure keeps the files: the recorded message refers to them.
            Task { @MainActor [weak self] in
                if await !delivery.value { self?.send(.promptRejected(sessionId: id)) }
            }
        case .stop(let id):
            // Emergency brake: any authenticated subscriber may cancel the
            // running turn; no writer lease required. Ack immediately so the
            // client flips to "stopping" before the ACP round-trip completes.
            send(.stopPending(sessionId: id))
            try? await sessions?.stop(id, caller: hostCaller)
        case .setModel(let id, let modelId):
            try? await sessions?.setModel(id, modelID: modelId, caller: hostCaller)
            resendConfig(id: id)
        case .setMode(let id, let modeId):
            try? await sessions?.setMode(id, modeID: modeId, caller: hostCaller)
            resendConfig(id: id)
        case .setAutoRun(let id, let enabled):
            try? await sessions?.setAutoRun(id, enabled: enabled, caller: hostCaller)
            resendConfig(id: id)
        case .setConfigOption(let id, let configId, let value):
            try? await sessions?.setConfigOption(id, configID: configId, value: value, caller: hostCaller)
            resendConfig(id: id)
        case .renameSession(let id, let title):
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            guard (try? sessions?.rename(id, title: trimmed, caller: hostCaller)) != nil else {
                send(.error(message: "Could not rename session.", sessionId: id))
                return
            }
            presenter?.sessionRenamed(id, title: trimmed)
            send(.sessionRenamed(sessionId: id, title: trimmed))
            refreshSessionList()
        case .fetchOlder(let id, let beforeIndex, let limit):
            // Ignore pages requested before a snapshot established sync state.
            guard let session = provider.session(for: id), let state = syncStates[id] else { return }
            let clamped = min(max(limit, RemoteTranscriptSync.pageLimitRange.lowerBound),
                              RemoteTranscriptSync.pageLimitRange.upperBound)
            // A concurrent send (snapshot OR ordinary same-epoch delta) can
            // supersede this page mid-serialize the same way it supersedes a
            // dirty delta — see the capturedGeneration comment below. Unlike
            // a dropped delta/snapshot, though, the client has no fallback
            // recovery for a silently-dropped page: only a snapshot resets
            // its "loading earlier messages" state, and an ordinary delta
            // (the common case here) does not, so simply returning would
            // leave the client stuck showing a spinner forever. Retry
            // instead — bounded so pathological continuous churn can't spin
            // forever either; a truncated tool call's content fetched by an
            // earlier attempt stays cached, so a retry is cheap.
            var attempt = 0
            while true {
                let count = session.transcript.messages.count
                let hi = min(max(beforeIndex, 0), count)
                let lo = max(0, hi - clamped)
                // Capture the generation BEFORE the async serialize below —
                // not just the epoch, since a same-epoch concurrent
                // snapshot (e.g. takeOver, or a client resubscribe with no
                // structural change) also supersedes this page without
                // moving the epoch. If a snapshot lands on this same
                // session while a truncated tool call's full content is
                // being fetched, stamping the page with state read AFTER
                // the await would make it look current and be wrongly
                // accepted instead of dropped.
                let capturedGeneration = state.generation
                let wire = await wireTail(id: id, session: session, indices: lo..<hi)
                attempt += 1
                guard state.generation == capturedGeneration || attempt > Self.maxFetchOlderAttempts else {
                    continue
                }
                send(.transcriptPage(sessionId: id,
                                     epoch: state.epoch,
                                     firstIndex: wire.first?.index ?? hi,
                                     messages: wire))
                break
            }
        case .queueForceSend(let id, let itemId):
            await withQueueItem(id: id, itemId: itemId) { uuid in
                await self.editQueue(id, .forceSend(uuid))
            }
        case .queueRemove(let id, let itemId):
            await withQueueItem(id: id, itemId: itemId) { uuid in
                await self.editQueue(id, .remove(uuid))
            }
        case .queueRetry(let id, let itemId):
            await withQueueItem(id: id, itemId: itemId) { uuid in
                await self.editQueue(id, .retry(uuid))
            }
        case .queueEdit(let id, let itemId):
            await withQueueItem(id: id, itemId: itemId) { uuid in
                // No reply when the item is gone or already `.sending` —
                // `takeForEditing` refuses in-flight items so an edit can
                // never duplicate a prompt that is already on the wire.
                guard let text = await self.editQueue(id, .edit(uuid)) else { return }
                self.send(.queueEditRestored(sessionId: id, itemId: itemId, text: text))
            }
        case .queueClear(let id):
            await editQueue(id, .clear)
        case .queueMove(let id, let itemId, let targetItemId):
            guard let target = UUID(uuidString: targetItemId) else { return }
            await withQueueItem(id: id, itemId: itemId) { uuid in
                await self.editQueue(id, .move(uuid, target: target))
            }
        case .queuePromote(let id, let itemId):
            await withQueueItem(id: id, itemId: itemId) { uuid in
                await self.editQueue(id, .promote(uuid))
            }
        case .listChanges(let id, let comparisonMode):
            let key = if let comparisonMode {
                "listChanges\u{0}\(id)\u{0}\(comparisonMode.rawValue)"
            } else {
                "listChanges\u{0}\(id)"
            }
            guard inFlightFileRequests.insert(key).inserted else { return }
            defer { inFlightFileRequests.remove(key) }
            switch await provider.remoteChangeList(
                sessionId: id,
                comparisonMode: comparisonMode
            ) {
            case .success(let ref, let available, let files, let staged, let unstaged, let commits, let truncated, let commitsTruncated):
                send(.changeList(
                    sessionId: id, comparisonRef: ref, metricsAvailable: available,
                    files: files, staged: staged, unstaged: unstaged, commits: commits,
                    truncated: truncated, commitsTruncated: commitsTruncated))
            case .failure(let reason, let message):
                send(.changeListFailed(sessionId: id, reason: reason, message: message))
            }
        case .fileDiff(let id, let path, let stage, let comparisonMode):
            let key = if let comparisonMode {
                "fileDiff\u{0}\(id)\u{0}\(path)\u{0}\(stage ?? "")\u{0}\(comparisonMode.rawValue)"
            } else {
                "fileDiff\u{0}\(id)\u{0}\(path)\u{0}\(stage ?? "")"
            }
            guard inFlightFileRequests.insert(key).inserted else { return }
            defer { inFlightFileRequests.remove(key) }
            switch await provider.remoteFileDiff(
                sessionId: id,
                path: path,
                stage: stage,
                comparisonMode: comparisonMode
            ) {
            case .success(let hunks, let truncated, let metadataNote):
                send(.fileDiffResult(
                    sessionId: id, path: path, stage: stage, hunks: hunks, truncated: truncated,
                    metadataNote: metadataNote))
            case .failure(let reason, let message):
                send(.fileDiffFailed(sessionId: id, path: path, stage: stage, reason: reason, message: message))
            }
        case .listCommitFiles(let id, let sha):
            guard let key = message.fileRequestDedupKey,
                  inFlightFileRequests.insert(key).inserted else { return }
            defer { inFlightFileRequests.remove(key) }
            switch await provider.remoteCommitFiles(sessionId: id, sha: sha) {
            case .success(let files, let truncated):
                send(.commitFiles(sessionId: id, sha: sha, files: files, truncated: truncated))
            case .failure(let reason, let message):
                send(.commitFilesFailed(sessionId: id, sha: sha, reason: reason, message: message))
            }
        case .commitFileDiff(let id, let sha, let path):
            guard let key = message.fileRequestDedupKey,
                  inFlightFileRequests.insert(key).inserted else { return }
            defer { inFlightFileRequests.remove(key) }
            switch await provider.remoteCommitDiff(sessionId: id, sha: sha, path: path) {
            case .success(let hunks, let truncated, let metadataNote):
                send(.commitDiffResult(sessionId: id, sha: sha, path: path, hunks: hunks,
                                       truncated: truncated, metadataNote: metadataNote))
            case .failure(let reason, let message):
                send(.commitDiffFailed(sessionId: id, sha: sha, path: path, reason: reason, message: message))
            }
        case .listFiles(let id, let path, let comparisonMode):
            let key = if let comparisonMode {
                "listFiles\u{0}\(id)\u{0}\(path ?? "")\u{0}\(comparisonMode.rawValue)"
            } else {
                "listFiles\u{0}\(id)\u{0}\(path ?? "")"
            }
            guard inFlightFileRequests.insert(key).inserted else { return }
            defer { inFlightFileRequests.remove(key) }
            switch await provider.remoteFileTree(
                sessionId: id,
                path: path,
                comparisonMode: comparisonMode
            ) {
            case .success(let nodes, let truncated):
                send(.fileTree(sessionId: id, path: path, nodes: nodes, truncated: truncated))
            case .failure(let reason, let message):
                send(.fileTreeFailed(sessionId: id, path: path, reason: reason, message: message))
            }
        case .searchMentions(let id, let query):
            // Ungated by the writer lease, like the file reads: seeing a
            // session is enough to read its project.
            // An overlong query gets no rows rather than rows for a prefix
            // the viewer would take as the answer to the whole query.
            let candidates = query.count > Self.maxMentionQueryLength
                ? [] : await provider.remoteMentionCandidates(sessionId: id, query: query)
            send(.mentionCandidates(sessionId: id, query: query, candidates: candidates))
        case .readFile(let id, let path):
            let key = "readFile\u{0}\(id)\u{0}\(path)"
            guard inFlightFileRequests.insert(key).inserted else { return }
            defer { inFlightFileRequests.remove(key) }
            switch await provider.remoteFileContents(sessionId: id, path: path) {
            case .success(let text, let truncated):
                send(.fileContents(sessionId: id, path: path, text: text, truncated: truncated))
            case .failure(let reason, let byteSize, let message):
                send(.fileUnavailable(
                    sessionId: id, path: path, reason: reason,
                    byteSize: byteSize, message: message))
            }
        }
    }

    /// Success refreshes the list now, as session creation does, so clients
    /// see the new `isActive` without waiting for the poll.
    private func reportTabAction(_ result: RemoteSessionTabActionResult, sessionId: String) {
        switch result {
        case .success:
            send(.sessionTabActionSucceeded(sessionId: sessionId))
            refreshSessionList()
        case .failure(let message):
            send(.sessionTabActionFailed(sessionId: sessionId, message: message))
        }
    }

    /// Bound on retrying a superseded `fetchOlder` page before sending
    /// whatever was last computed anyway — the client must always get a
    /// response, never an unbounded wait.
    private static let maxFetchOlderAttempts = 5

    private func beginTracking(id: String, session: ACPSession) {
        guard !trackedSessions.contains(id) else { return }
        trackedSessions.insert(id)
        session.transcript.changeLog.retainTracking()
    }

    private func endTracking(id: String) {
        guard trackedSessions.remove(id) != nil else { return }
        provider.session(for: id)?.transcript.changeLog.releaseTracking()
    }

    /// The lists `events` make stale. Session rows carry their worktree and
    /// project, so changes to those refresh the session list too.
    nonisolated static func listsChanged(by events: [HostEvent]) -> (sessions: Bool, worktrees: Bool, projects: Bool) {
        var lists = (sessions: false, worktrees: false, projects: false)
        for event in events {
            switch event {
            case .sessionChanged, .sessionRemoved:
                lists.sessions = true
            case .worktreeChanged, .worktreeRemoved:
                lists.sessions = true
                lists.worktrees = true
            case .projectChanged, .projectRemoved, .resync:
                return (true, true, true)
            case .workspaceCheckoutChanged, .workspaceCheckoutRemoved, .runChanged, .runRemoved,
                 .transcript, .pendingRequest, .pendingRequestResolved:
                break
            }
        }
        return lists
    }

    /// Lists are rebuilt at most this often; changes in between coalesce.
    private static let listPushInterval: Duration = .milliseconds(500)

    private func pushLists(from host: AlasHost) {
        let subscription = host.subscribe()
        hostSubscription = subscription
        Task { @MainActor [weak self] in
            while let events = await subscription.next() {
                guard let self else { return }
                let lists = Self.listsChanged(by: events)
                if lists.sessions { refreshSessionList() }
                if lists.worktrees, wantsWorktreeList { refreshWorktreeList() }
                if lists.projects, wantsProjectList { refreshProjectList() }
                // ponytail: fixed rate limit; each list runs git per worktree.
                try? await Task.sleep(for: Self.listPushInterval)
            }
        }
    }

    private func refreshSessionList() {
        sessionListGeneration += 1
        let generation = sessionListGeneration
        sessionListRefresh?.cancel()
        sessionListRefresh = Task { @MainActor [weak self] in
            guard let self else { return }
            let summaries = await provider.sessionSummaries() + (federation?.peerSessionSummaries ?? [])
            guard !Task.isCancelled, generation == sessionListGeneration else { return }
            send(.sessionList(sessions: summaries))
        }
    }

    private func refreshWorktreeList() {
        worktreeListGeneration += 1
        let generation = worktreeListGeneration
        worktreeListRefresh?.cancel()
        worktreeListRefresh = Task { @MainActor [weak self] in
            guard let self else { return }
            let worktrees = await reads.worktrees()
            guard !Task.isCancelled, generation == worktreeListGeneration else { return }
            send(.worktreeList(worktrees: worktrees))
        }
    }

    private func refreshProjectList() {
        projectListGeneration += 1
        let generation = projectListGeneration
        projectListRefresh?.cancel()
        projectListRefresh = Task { @MainActor [weak self] in
            guard let self else { return }
            let projects = await reads.projects()
            guard !Task.isCancelled, generation == projectListGeneration else { return }
            send(.projectList(projects: projects))
        }
    }

    private func refreshBranchList(projectId: String) {
        branchListGeneration += 1
        let generation = branchListGeneration
        branchListRefresh?.cancel()
        branchListRefresh = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await reads.branches(projectId)
            guard !Task.isCancelled, generation == branchListGeneration else { return }
            switch result {
            case .success(let branches, let preferredBase):
                send(.branchList(
                    projectId: projectId,
                    branches: branches,
                    preferredBase: preferredBase
                ))
            case .failure(let message):
                send(.branchListFailed(projectId: projectId, message: message))
            }
        }
    }

    // MARK: attachment materialization

    public nonisolated static let maxAttachmentsBytes = 10_000_000
    /// Max images per prompt — parity with the native composer's limit.
    public nonisolated static let maxAttachmentCount = 10
    /// Caps the mentions one prompt resolves, as the image cap does.
    public nonisolated static let maxMentionCount = 50
    public nonisolated static let maxMentionQueryLength = 256

    /// Decode wire attachments to files under acp-attachments/. Returns nil if the
    /// batch violates the size cap or any entry isn't a real image (caller rejects
    /// the send).
    ///
    /// The bytes are sniffed for real PNG/JPEG/GIF/WebP magic — parity with the
    /// native composer's `ACPImageStaging`, instead of trusting the client MIME —
    /// and the sniffed type is what we store. The whole batch is validated +
    /// decoded BEFORE any file is written, so a later bad/oversize entry can't
    /// leave earlier files orphaned; a mid-batch write failure rolls back what
    /// it wrote.
    private func materialize(_ wire: [RemoteAttachment], for sessionId: String) -> [ACPMessage.Attachment]? {
        // Cap the count before decoding/writing (parity with the native composer's
        // maxImagesPerMessage) so one prompt can't spray thousands of tiny files.
        guard wire.count <= Self.maxAttachmentCount else { return nil }
        var decoded: [(data: Data, mimeType: String, name: String?)] = []
        var total = 0
        for a in wire {
            guard let data = Data(base64Encoded: a.dataBase64) else { return nil }
            total += data.count
            guard total <= Self.maxAttachmentsBytes else { return nil }
            guard let mime = ACPImageStaging.sniffMIME(data) else { return nil }   // real image only
            decoded.append((data, mime, a.name))
        }
        var written: [URL] = []
        var out: [ACPMessage.Attachment] = []
        for d in decoded {
            guard let url = try? sessions?.storeImage(d.data, mimeType: d.mimeType, for: sessionId) else {
                written.forEach { try? FileManager.default.removeItem(at: $0) }
                return nil
            }
            written.append(url)
            out.append(.init(uri: url.absoluteString, name: d.name, mimeType: d.mimeType))
        }
        return out
    }

    /// Best-effort delete of attachment files we wrote but that never made it
    /// into the conversation (the manager refused the prompt after materialize).
    private func discardAttachmentFiles(_ attachments: [ACPMessage.Attachment]) {
        for a in attachments {
            if let url = URL(string: a.uri), url.isFileURL {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func handleConsole(_ request: PeerConsoleRequest) {
        if let consoleLink, let host = provider.peerConsoleHost {
            host.handle(request, from: consoleLink)
            return
        }
        // Browsers and hosts without console support: refuse attaches
        // explicitly so the client does not wait for a snapshot.
        if case .attach(_, let attachmentId, _) = request {
            send(.console(.detached(attachmentId: attachmentId, reason: .unauthorized)))
        }
    }

    /// Hands a host protocol message to this connection's host connection,
    /// opened on first use for the caller the transport authenticated.
    private func serveHost(_ request: HostClientMessage) {
        if hostConnection == nil, let host = provider.eventHost, let caller {
            hostConnection = HostProtocolServer(host: host).connect(caller: caller) { [weak self] reply in
                await self?.sendWritten(.host(reply))
            }
        }
        guard let hostConnection else {
            send(.host(.response(id: request.id, result: .failure(error: .invalidRequest(
                reason: "This connection does not serve the host protocol."
            )))))
            return
        }
        // Answers are matched by id, so a slow verb need not hold the
        // connection's ordered work.
        Task { await hostConnection.receive(request) }
    }

    /// Returns once the frame is written, so a slow peer holds back its own
    /// host events, where they coalesce.
    private func sendWritten(_ message: RemoteServerMessage) async {
        guard let sendTracked else {
            send(message)
            return
        }
        let id = UUID()
        await withCheckedContinuation { continuation in
            pendingWrites[id] = continuation
            sendTracked(message) {
                Task { @MainActor [weak self] in self?.pendingWrites.removeValue(forKey: id)?.resume() }
            }
        }
    }

    /// Tear down all observation (called when the connection closes).
    public func close() {
        hostConnection?.close()
        hostConnection = nil
        for continuation in pendingWrites.values { continuation.resume() }
        pendingWrites.removeAll()
        if let consoleLink { provider.peerConsoleHost?.close(consoleLink) }
        if let federation, let downstream { federation.detach(downstream) }
        self.downstream = nil
        hostSubscription?.cancel()
        hostSubscription = nil
        providerListChanges = nil
        sessionListRefresh?.cancel()
        sessionListRefresh = nil
        worktreeListRefresh?.cancel()
        worktreeListRefresh = nil
        projectListRefresh?.cancel()
        projectListRefresh = nil
        branchListRefresh?.cancel()
        branchListRefresh = nil
        subscriptions.removeAll()
        configSubscriptions.removeAll()
        configCoalesce.values.forEach { $0.cancel() }
        configCoalesce.removeAll()
        lastConfig.removeAll()
        lastQueue.removeAll()
        coalesce.values.forEach { $0.cancel() }
        coalesce.removeAll()
        lastPermissionReq.removeAll()
        lastQuestionReq.removeAll()
        lastElicitationReq.removeAll()
        for id in trackedSessions {
            provider.session(for: id)?.transcript.changeLog.releaseTracking()
        }
        trackedSessions.removeAll()
        syncStates.removeAll()
    }

    // MARK: snapshot / delta

    private func sendSnapshot(id: String, session: ACPSession) async {
        let state = syncState(for: id)
        let log = session.transcript.changeLog
        let count = session.transcript.messages.count
        let first = max(0, count - RemoteTranscriptSync.tailWindow)
        // Capture epoch/version BEFORE the async serialize, but do NOT yet
        // commit sentVersion to `state` — see below. Bumping `generation`
        // here — even when `epoch` itself is unchanged (e.g. a same-epoch
        // takeOver or client resubscribe) — lets a concurrently-suspended
        // delta/page detect that THIS snapshot already superseded it.
        state.epoch = log.epoch
        // Defer committing sentVersion, matching the dirty-delta fix above:
        // writing it now would make the change log treat everything dirty
        // up to this point as "already sent" even if this snapshot ends up
        // discarded below (superseded by a same-epoch dirty delta that
        // raced in during the await) — the pre-snapshot dirty indices would
        // then be silently absent from both sends, never re-offered, since
        // sentVersion already covers them. Only commit once we know this
        // snapshot is actually going out.
        let newSentVersion = log.latestVersion
        // Also defer resetting revision — the same hazard as sentVersion,
        // but on the send side instead of the change-log side. A `.none`
        // content-free delta doesn't participate in the generation ticket
        // (it has no reason to — no message content raced it), so it can
        // still complete and send WHILE this snapshot is suspended, bumping
        // `state.revision` past 0. If we'd already reset it to 0 here, and
        // this snapshot then wins (generation unaffected by a `.none`
        // send), its wire payload hardcodes `revision: 0` while
        // `state.revision` is left at whatever the intervening delta bumped
        // it to — the server's internal counter desyncs from what it
        // actually told the client, and every subsequent delta fails the
        // client's `revision === transcriptMeta.revision + 1` check until
        // another full resync happens. Reset it atomically with the send.
        state.generation += 1
        let capturedGeneration = state.generation
        let superseded = Self.supersededBackgroundRows(in: session.transcript.messages)
        let wire = await wireTail(id: id, session: session, indices: first..<count, superseded: superseded)
        // If another send (a concurrent snapshot or dirty delta) claimed a
        // later generation while this one was suspended fetching truncated
        // tool-call content, THIS snapshot's payload is now stale relative
        // to what the client already has or is about to receive. Sending it
        // anyway would roll the client back — snapshots are applied
        // unconditionally client-side (no epoch/revision ordering check),
        // unlike deltas/pages. Discard; whatever claimed the later
        // generation read fresher state and is authoritative.
        if state.generation == capturedGeneration {
            state.sentVersion = newSentVersion
            state.revision = 0
            state.sentBackgroundWorkCancellable = session.hasCancellableBackgroundWork
            state.sentSupersededBackgroundRows = superseded
            send(.transcriptSnapshot(sessionId: id,
                                     streamingState: Self.stateString(session.transcript.streamingState),
                                     canDrive: provider.isWriter(for: id),
                                     messages: wire,
                                     firstIndex: wire.first?.index ?? count,
                                     totalCount: count,
                                     epoch: state.epoch,
                                     revision: 0,
                                     hasCancellableBackgroundWork: session.hasCancellableBackgroundWork))
        }
        emitPendingPermissionIfAny(id: id, session: session)
        emitPendingQuestionIfAny(id: id, session: session)
        emitPendingPlanIfAny(id: id, session: session)
        emitPendingElicitationIfAny(id: id, session: session)
    }

    private func syncState(for id: String) -> RemoteTranscriptSync {
        if let s = syncStates[id] { return s }
        let s = RemoteTranscriptSync()
        syncStates[id] = s
        return s
    }

    private func observe(id: String, session: ACPSession) {
        // Replace any existing subscription / pending coalesce for this id so a
        // re-subscribe can't leave an orphaned timer firing one stray delta.
        subscriptions[id]?.forEach { $0.cancel() }
        coalesce[id]?.cancel()
        // The transcript's `willChange` fires on any `@Tracked` mutation (new
        // message, pending permission). Streaming chunks that grow an existing
        // row send only `streamingTicks`.
        let onChange: () -> Void = { [weak self, weak session] in
            guard let self, let session else { return }
            // Coalesce bursts of streaming chunks into one delta.
            self.coalesce[id]?.cancel()
            self.coalesce[id] = Task { @MainActor [weak self, weak session] in
                try? await Task.sleep(nanoseconds: Self.coalesceNanos)
                guard !Task.isCancelled, let self, let session else { return }
                await self.sendDelta(id: id, session: session)
            }
        }
        subscriptions[id] = [
            session.transcript.willChange.observe(onChange),
            session.transcript.streamingTicks.observe(onChange),
        ]
        // Re-emit sessionConfig when the session's config publishers change.
        // ACPSession.willChange fires for ANY @Tracked change (agentState,
        // queue, etc.), not just config — and BEFORE the value settles. Coalesce
        // a run-loop turn's worth of fires into one next-tick read (zero-delay,
        // mirroring the transcript coalesce above) and dedupe against the last
        // config so non-config churn never reaches the wire.
        configSubscriptions[id]?.cancel()
        configCoalesce[id]?.cancel()
        configSubscriptions[id] = session.willChange.observe { [weak self, weak session] in
            guard let self, let session else { return }
            self.configCoalesce[id]?.cancel()
            self.configCoalesce[id] = Task { @MainActor [weak self, weak session] in
                guard !Task.isCancelled, let self, let session else { return }
                // Same publisher, independently deduped: ACPSession's
                // willChange fires for queue mutations too, and the
                // queue changes far more often than the config does.
                self.sendQueueState(id: id, session: session)
                if self.syncStates[id]?.sentBackgroundWorkCancellable != session.hasCancellableBackgroundWork {
                    await self.sendDelta(id: id, session: session)
                }
                let cfg = RemoteSessionConfigProjection.config(sessionId: id, session: session)
                guard self.lastConfig[id] != cfg else { return }
                self.lastConfig[id] = cfg
                self.send(.sessionConfig(cfg))
            }
        }
    }

    /// Viewers update their config optimistically. When the host refuses or
    /// ignores a config verb nothing changes, so the observation-driven
    /// emission never fires; re-send the authoritative config so the viewer
    /// reverts. Recording it in `lastConfig` keeps the coalesced emission from
    /// sending a duplicate.
    private func resendConfig(id: String) {
        guard let cfg = provider.sessionConfig(for: id) else { return }
        lastConfig[id] = cfg
        send(.sessionConfig(cfg))
    }

    /// Emits an incremental delta: only messages the change log marked
    /// dirty since the last send. Structural transcript changes (prepend,
    /// removal, wholesale replacement) resync via a fresh tail snapshot.
    private func sendDelta(id: String, session: ACPSession) async {
        guard let state = syncStates[id] else { return }
        let log = session.transcript.changeLog
        switch log.changes(since: state.sentVersion) {
        case .resync:
            await sendSnapshot(id: id, session: session)
            return
        case .none:
            // No transcript content changed — this tick was a state flip
            // (streamingState / pending prompt). Send a content-free delta
            // so the client still tracks state.
            state.revision += 1
            state.sentBackgroundWorkCancellable = session.hasCancellableBackgroundWork
            send(.transcriptDelta(sessionId: id,
                                  streamingState: Self.stateString(session.transcript.streamingState),
                                  canDrive: provider.isWriter(for: id),
                                  upserts: [],
                                  epoch: state.epoch,
                                  revision: state.revision,
                                  hasCancellableBackgroundWork: session.hasCancellableBackgroundWork))
        case .dirty(let dirtyIndices):
            let superseded = Self.supersededBackgroundRows(in: session.transcript.messages)
            // Appending a task snapshot also retires its earlier positional
            // rows, even though the change log only dirtied the new index.
            let indices = Set(dirtyIndices).union(superseded.symmetricDifference(state.sentSupersededBackgroundRows)).sorted()
            guard indices.count <= RemoteTranscriptSync.dirtyResnapshotThreshold else {
                await sendSnapshot(id: id, session: session)
                return
            }
            // Capture — but do NOT yet commit — the version this delta will
            // cover. Committing it now (before the await) would make the
            // change log treat `indices` as "already sent" even if this
            // delta ends up discarded below: a later dirty mutation would
            // then compute `changes(since:)` against an already-advanced
            // sentVersion and never re-offer these indices, silently losing
            // them until a full resync. Only write it once we know we're
            // actually sending (see the guard below).
            let newSentVersion = log.latestVersion
            // Claim a generation for this send BEFORE the async serialize
            // below — not just on sendSnapshot. Two overlapping dirty
            // deltas can race the same way a delta and a snapshot can: a
            // still-running (cancelled-but-not-stopped) coalesce Task can
            // suspend on a tool-content fetch while a LATER mutation spawns
            // its own coalesce Task that completes and sends first. Without
            // bumping generation here too, the earlier delta would resume,
            // pass an unchanged-generation check, and send its now-stale
            // content at a higher revision — rolling the client back after
            // it already received the newer delta. Bumping on every send
            // attempt (snapshot OR dirty) makes generation a strict
            // "did anyone else claim a send after me" ticket.
            state.generation += 1
            let capturedGeneration = state.generation
            // A dirty tool call's persisted content may have grown past the
            // cached copy — drop it so serialization re-fetches.
            for index in indices where session.transcript.messages.indices.contains(index) {
                if case .toolCall(let tc) = session.transcript.messages[index] {
                    state.invalidateToolContent(tc.toolCallId)
                }
            }
            let batches = await wireBatches(id: id, session: session, indices: indices, superseded: superseded)
            guard state.generation == capturedGeneration else { return }
            state.sentVersion = newSentVersion
            state.sentSupersededBackgroundRows = superseded
            // Send all batches without suspension, preserving the generation
            // check and giving each frame the next revision clients expect.
            for wire in batches {
                state.revision += 1
                state.sentBackgroundWorkCancellable = session.hasCancellableBackgroundWork
                send(.transcriptDelta(sessionId: id,
                                      streamingState: Self.stateString(session.transcript.streamingState),
                                      canDrive: provider.isWriter(for: id),
                                      upserts: wire,
                                      epoch: state.epoch,
                                      revision: state.revision,
                                      hasCancellableBackgroundWork: session.hasCancellableBackgroundWork))
            }
        }
        emitPendingPermissionIfAny(id: id, session: session)
        emitPendingQuestionIfAny(id: id, session: session)
        emitPendingPlanIfAny(id: id, session: session)
        emitPendingElicitationIfAny(id: id, session: session)
    }

    /// Push the session's queue to the client. `force` bypasses the dedupe so
    /// a fresh subscribe always gets a baseline — otherwise an unchanged
    /// (typically empty) queue would be suppressed and the client would show
    /// nothing until the next mutation.
    private func sendQueueState(id: String, session: ACPSession, force: Bool = false) {
        let items = RemoteQueueProjection.project(session.queue)
        guard force || lastQueue[id] != items else { return }
        lastQueue[id] = items
        send(.queueState(sessionId: id, items: items))
    }

    /// Shared preamble for the per-item queue verbs: writer gate plus item-id
    /// parsing. A non-writer or an unparseable id is dropped silently — the
    /// next `queueState` re-asserts server truth, so there is nothing for the
    /// client to reconcile.
    private func withQueueItem(id: String, itemId: String, _ body: (UUID) async -> Void) async {
        guard let uuid = UUID(uuidString: itemId) else { return }
        await body(uuid)
    }

    /// The host refuses a non-writer's edit; the next `queueState` re-asserts
    /// the queue, so there is nothing to report.
    @discardableResult
    private func editQueue(_ id: String, _ edit: SessionQueueEdit) async -> String? {
        (try? await sessions?.editQueue(id, edit, caller: hostCaller)) ?? nil
    }

    /// The host's session verbs; nil without a host, which refuses them all.
    private var sessions: SessionsAPI? { provider.eventHost?.sessions }

    /// Who the host verbs act for: the authenticated device, or this app.
    private var hostCaller: HostCaller { caller ?? .app }

    /// Build the newest contiguous suffix that fits. Older rows remain
    /// reachable through fetchOlder instead of disappearing from history.
    private func wireTail(
        id: String, session: ACPSession, indices: Range<Int>, superseded: Set<Int>? = nil
    ) async -> [RemoteWireMessage] {
        let superseded = superseded ?? Self.supersededBackgroundRows(in: session.transcript.messages)
        var wire: [RemoteWireMessage] = []
        var remaining = RemoteTranscriptSync.payloadBudget(sessionId: id)
        for index in indices.reversed() {
            guard let row = await wireMessage(id: id, session: session, index: index, superseded: superseded.contains(index)) else { continue }
            guard row.byteCount + 1 <= remaining else { break }
            remaining -= row.byteCount + 1
            wire.append(row.message)
        }
        wire.reverse()
        return wire
    }

    private func wireBatches(
        id: String, session: ACPSession, indices: [Int], superseded: Set<Int>
    ) async -> [[RemoteWireMessage]] {
        let budget = RemoteTranscriptSync.payloadBudget(sessionId: id)
        var batches: [[RemoteWireMessage]] = []
        var batch: [RemoteWireMessage] = []
        var remaining = budget
        for index in indices {
            guard let row = await wireMessage(id: id, session: session, index: index, superseded: superseded.contains(index)) else { continue }
            if row.byteCount + 1 > remaining {
                batches.append(batch)
                batch = []
                remaining = budget
            }
            batch.append(row.message)
            remaining -= row.byteCount + 1
        }
        if !batch.isEmpty { batches.append(batch) }
        return batches
    }

    private func wireMessage(
        id: String, session: ACPSession, index: Int, superseded: Bool
    ) async -> (message: RemoteWireMessage, byteCount: Int)? {
        // Re-check across awaits: a structural mutation can shrink the array;
        // the caller's generation check will discard the stale serialization.
        guard session.transcript.messages.indices.contains(index) else { return nil }
        let message = session.transcript.messages[index]
        // A visual aid's answer prompt stays a positional marker: the phone's card shows the answer.
        if superseded || ACPVisualAidQuestionForm.isAnswerPrompt(message) {
            return RemoteWireMessage(stableId: "m\(index)", kind: message.kind, text: nil, json: nil,
                                     index: index, isHidden: true)
                .boundedForTransport(maximumBytes: RemoteTranscriptSync.maxMessageBytes)
        }
        return Self.toWire(
            message, index: index,
            fullToolCallContent: await cachedFullToolCallContent(sessionId: id, message: message)
        ).boundedForTransport(maximumBytes: RemoteTranscriptSync.maxMessageBytes)
    }

    /// Inspect the full transcript so an older page cannot revive a task
    /// superseded outside that page. Keep positional IDs and paging cursors.
    private static func supersededBackgroundRows(in messages: [ACPMessage]) -> Set<Int> {
        var latest: [String: Int] = [:]
        var backgroundIds: Set<String> = []
        for (index, message) in messages.enumerated() {
            guard case .toolCall(let call) = message else { continue }
            latest[call.toolCallId] = index
            if ACPBackgroundTask(toolCall: call) != nil { backgroundIds.insert(call.toolCallId) }
        }
        return Set(messages.enumerated().compactMap { index, message in
            guard case .toolCall(let call) = message, backgroundIds.contains(call.toolCallId),
                  latest[call.toolCallId] != index else { return nil }
            return index
        })
    }

    private func cachedFullToolCallContent(sessionId: String, message: ACPMessage) async -> String? {
        guard case .toolCall(let toolCall) = message, toolCall.isContentTruncated,
              !ACPToolCallPresentation.isVisualShow(toolCall) else { return nil }
        let state = syncState(for: sessionId)
        if let cached = state.cachedToolContent(toolCall.toolCallId) { return cached }
        guard let full = await provider.fullToolCallContent(sessionId: sessionId, toolCallId: toolCall.toolCallId)
        else { return nil }
        state.storeToolContent(toolCall.toolCallId, full)
        return full
    }

    private func emitPendingPermissionIfAny(id: String, session: ACPSession) {
        // Only surface a prompt when the session is genuinely awaiting it. A
        // read-only mirror (no runner) can carry a stale pending* while idle —
        // surfacing that would show a prompt the remote can't actually answer.
        if session.transcript.streamingState == .awaitingPermission,
           let pending = session.transcript.pendingPermission {
            let rid = Self.requestIdInt(pending.id)
            lastPermissionReq[id] = rid
            let tc = pending.params.toolCall
            let isVisualShow = ACPToolCallPresentation.isVisualShow(name: tc.name, title: tc.title)
            let presentation = ACPPermissionPresentation(metadata: pending.params.metadata)
            let payload = RemotePermissionPayload(
                requestId: rid,
                toolName: isVisualShow ? Self.visualAidToolName : tc.title ?? tc.kind ?? "tool",
                options: pending.params.options.map {
                    RemotePermissionOption(
                        optionId: $0.optionId, name: $0.name, kind: $0.kind,
                        description: isVisualShow ? nil : $0.presentationDescription)
                },
                // `defaultToNo` carries no agent text, so it survives the redaction of a visual's permission.
                title: isVisualShow ? nil : presentation?.title,
                reason: isVisualShow ? nil : presentation?.description,
                defaultToNo: presentation?.defaultToNo ?? false,
                mcpServerName: tc.mcpServerName,
                commandSummary: isVisualShow ? nil : tc.content?.compactMap { block -> String? in
                    guard case .content(.text(let text)) = block else { return nil }
                    return text
                }.first)
            send(.permissionRequest(sessionId: id, payload: payload))
        } else if let rid = lastPermissionReq.removeValue(forKey: id) {
            // A prompt we surfaced was resolved elsewhere (the Mac or another
            // client) — tell the client to dismiss it so it doesn't hang.
            send(.permissionResolved(sessionId: id, requestId: rid))
        }
    }

    private func emitPendingQuestionIfAny(id: String, session: ACPSession) {
        if let pending = ACPRequestAnswers.pendingQuestion(in: session),
           !pending.params.questions.isEmpty {
            let rid = Self.requestIdInt(pending.id)
            lastQuestionReq[id] = rid
            let payload = RemoteQuestionPayload(
                requestId: rid,
                title: pending.params.title,
                questions: pending.params.questions.map { q in
                    RemoteQuestion(
                        id: q.id,
                        prompt: q.prompt,
                        options: q.options.map { RemoteQuestionOption(id: $0.id, label: $0.label) },
                        allowMultiple: q.allowMultiple == true)
                })
            send(.questionRequest(sessionId: id, payload: payload))
        } else if let rid = lastQuestionReq.removeValue(forKey: id) {
            send(.questionResolved(sessionId: id, requestId: rid))
        }
    }

    private func emitPendingPlanIfAny(id: String, session: ACPSession) {
        if let pending = session.transcript.pendingPlan {
            guard lastPlanReq[id] != pending.id else { return }
            lastPlanReq[id] = pending.id
            let params = pending.params
            let todos = params.todos.map {
                RemotePlanTodo(id: $0.id, content: $0.content, status: $0.status)
            }
            let phases = params.phases.map { phase in
                RemotePlanPhase(
                    name: phase.name,
                    todos: phase.todos.map {
                        RemotePlanTodo(id: $0.id, content: $0.content, status: $0.status)
                    }
                )
            }
            send(.planRequest(
                sessionId: id,
                payload: .init(
                    requestId: pending.id,
                    toolCallId: params.toolCallId,
                    name: params.name,
                    overview: params.overview,
                    plan: params.plan,
                    todos: todos,
                    isProject: params.isProject,
                    phases: phases
                )
            ))
        } else if let requestId = lastPlanReq.removeValue(forKey: id) {
            send(.planResolved(sessionId: id, requestId: requestId))
        }
    }

    private func emitPendingElicitationIfAny(id: String, session: ACPSession) {
        if let pending = session.transcript.pendingUserInputs.first,
           case .elicitation = pending.source {
            let requestId = pending.id.uuidString
            guard lastElicitationReq[id] != requestId else { return }
            lastElicitationReq[id] = requestId
            let mode: String
            let elicitationId: String?
            let url: String?
            switch pending.mode {
            case .form:
                mode = "form"
                elicitationId = nil
                url = nil
            case .url(let request):
                mode = "url"
                elicitationId = request.elicitationId
                url = request.url.absoluteString
            }
            let fields = pending.fields.map { field in
                RemoteElicitationField(
                    key: field.key,
                    type: field.schema.type,
                    title: field.label,
                    description: field.schema.description,
                    required: field.required,
                    minLength: field.schema.minLength,
                    maxLength: field.schema.maxLength,
                    minimum: field.schema.minimum,
                    maximum: field.schema.maximum,
                    minItems: field.schema.minItems,
                    maxItems: field.schema.maxItems,
                    format: field.schema.format,
                    pattern: field.schema.pattern,
                    isSecret: field.schema.isSecret,
                    options: field.schema.options.map {
                        .init(value: $0.const, title: $0.title, description: $0.description)
                    },
                    defaultValue: Self.remoteDefault(field.schema.defaultValue)
                )
            }
            send(.elicitationRequest(
                sessionId: id,
                payload: .init(
                    requestId: requestId,
                    title: pending.title,
                    message: pending.message,
                    mode: mode,
                    fields: fields,
                    elicitationId: elicitationId,
                    url: url
                )
            ))
        } else if let requestId = lastElicitationReq.removeValue(forKey: id) {
            send(.elicitationResolved(sessionId: id, requestId: requestId))
        }
    }

    // MARK: decision

    private func applyDecision(sessionId: String, requestId: Int, optionId: String, persistScope: String?) async {
        guard let session = provider.session(for: sessionId),
              let policy = provider.permissionPolicy(for: sessionId),
              let pending = session.transcript.pendingPermission,
              Self.requestIdInt(pending.id) == requestId          // first-wins guard
        else { return }
        let scope: ACPRequestAnswers.PermissionScope = switch persistScope {
        case nil: .optionDefault
        case "session": .session
        case "project": .project
        default: .once
        }
        guard let answer = ACPRequestAnswers.permission(pending, optionId: optionId, scope: scope) else { return }
        // Dismissed before answering: once the agent has the answer it may
        // park its next request, under the same placeholder id, while the
        // decision is still being recorded, and that one must stay up.
        lastPermissionReq[sessionId] = nil
        send(.permissionResolved(sessionId: sessionId, requestId: requestId))
        await policy.userDecided(
            scopeKey: answer.scopeKey, optionId: answer.optionId, decision: answer.decision, persistScope: answer.persistScope
        )
    }

    private func handleVisualAidResponse(
        sessionId: String, visualId: String, action: String, selectedOptionIds: [String], note: String?,
        requestId: String?
    ) async {
        // An over-long token is hostile or broken; drop it instead of echoing it back to every phone.
        let echoedRequestId = requestId.flatMap { $0.utf8.count <= RemoteVisualAidLimits.maxRequestIdBytes ? $0 : nil }
        func reject(_ reason: String) {
            send(.visualAidRejected(sessionId: sessionId, visualId: visualId, reason: reason, requestId: echoedRequestId))
        }
        guard provider.isWriter(for: sessionId) else { return reject("notWriter") }
        guard let id = UUID(uuidString: visualId),
              let session = provider.session(for: sessionId),
              let visual = session.transcript.visualAid(id: id)
        else { return reject("notFound") }
        guard let question = visual.question, visual.answer == nil else { return reject("alreadyAnswered") }

        guard !RemoteVisualAidLimits.exceedsBounds(ids: selectedOptionIds, note: note) else { return reject("invalid") }

        guard let answer = Self.visualAidAnswer(to: question, action: action, selectedOptionIds: selectedOptionIds, note: note) else {
            return reject("invalid")
        }
        guard (try? await sessions?.answerVisualAid(sessionId, visualID: id, answer: answer, caller: hostCaller)) != nil else {
            return reject("failed")
        }
    }

    /// The answer a viewer's response to a visual aid's question stands for,
    /// or nil when it does not fit the question: choices in question order,
    /// the note trimmed like the phone trims it.
    public nonisolated static func visualAidAnswer(
        to question: ACPVisualAid.Question,
        action: String,
        selectedOptionIds: [String],
        note: String?,
        at date: Date = Date()
    ) -> ACPVisualAid.Answer? {
        switch action {
        case "dismiss":
            return .dismissed(at: date)
        case "answer":
            let known = Set(question.options.map(\.id))
            let picked = Set(selectedOptionIds)
            guard picked.count == selectedOptionIds.count, !picked.isEmpty, picked.isSubset(of: known),
                  question.allowMultiple || picked.count == 1
            else { return nil }
            let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, trimmed.count > ACPVisualAidQuestionForm.noteMaxLength { return nil }
            // Question order, like a native answer.
            let ordered = question.options.map(\.id).filter(picked.contains)
            return .answered(selectedOptionIds: ordered, note: (trimmed?.isEmpty ?? true) ? nil : trimmed, at: date)
        default:
            return nil
        }
    }

    private func applyQuestionAnswer(sessionId: String, requestId: Int, answers: [RemoteQuestionAnswer]) {
        guard let session = provider.session(for: sessionId),
              let pending = ACPRequestAnswers.pendingQuestion(in: session),
              Self.requestIdInt(pending.id) == requestId,         // first-wins guard
              let response = ACPRequestAnswers.question(
                  pending,
                  answers: answers.map { ACPQuestionAnswer(questionId: $0.questionId, selectedOptionIds: $0.selectedOptionIds) }
              )
        else { return }
        provider.answerQuestion(for: sessionId, requestId: pending.id, response)
        lastQuestionReq[sessionId] = nil
        send(.questionResolved(sessionId: sessionId, requestId: requestId))
    }

    private func applyPlanResponse(sessionId: String, requestId: JSONRPCID, action: String, reason: String?) {
        guard let session = provider.session(for: sessionId),
              let pending = session.transcript.pendingPlan,
              pending.id == requestId
        else { return }
        let planAction: ACPRequestAnswers.PlanAction
        switch action {
        case "accept": planAction = .accept
        case "reject": planAction = .reject(reason: reason ?? "")
        case "cancel": planAction = .cancel
        default: return
        }
        guard let response = ACPRequestAnswers.plan(pending, action: planAction) else { return }
        provider.respondToPlan(for: sessionId, requestId: requestId, response)
        lastPlanReq[sessionId] = nil
        send(.planResolved(sessionId: sessionId, requestId: requestId))
    }

    private func applyElicitationResponse(
        sessionId: String,
        requestId: String,
        action: String,
        content: [String: ACPElicitationValue]?
    ) {
        guard let token = UUID(uuidString: requestId),
              let session = provider.session(for: sessionId),
              let pending = session.transcript.pendingUserInputs.first,
              pending.id == token,
              case .elicitation = pending.source
        else { return }
        let answer: ACPRequestAnswers.UserInputAnswer
        switch action {
        case "accept": answer = .submit(content: content ?? [:])
        case "decline": answer = .decline
        case "cancel": answer = .cancel
        default: return
        }
        guard let resolvedAction = ACPRequestAnswers.userInput(pending, answer: answer) else { return }
        provider.respondToUserInput(for: sessionId, token: token, action: resolvedAction)
        lastElicitationReq[sessionId] = nil
        send(.elicitationResolved(sessionId: sessionId, requestId: requestId))
    }

    private static func remoteDefault(_ value: AnyCodable?) -> ACPElicitationValue? {
        guard let raw = value?.value else { return nil }
        if let value = raw as? Bool { return .boolean(value) }
        if let value = raw as? Int { return .integer(value) }
        if let value = raw as? Double { return .number(value) }
        if let value = raw as? String { return .string(value) }
        if let value = raw as? [String] { return .strings(value) }
        if let value = raw as? [AnyCodable] {
            return .strings(value.compactMap { $0.value as? String })
        }
        return nil
    }

    // MARK: serialization helpers

    public static func stateString(_ s: ACPSession.StreamingState) -> String {
        switch s {
        case .idle: return "idle"
        case .sending, .streaming: return "streaming"
        case .awaitingPermission: return "awaitingPermission"
        case .awaitingInput: return "awaitingInput"
        }
    }

    /// Extracts the integer request id. In practice `pendingPermission.id` is
    /// always `.number(0)` (set by ACPPermissionPolicy), so the first-wins guard
    /// distinguishes "this prompt is still pending" from "already resolved"
    /// (pending goes nil) rather than telling sequential requests apart — which
    /// is fine because the agent blocks on each prompt before issuing the next.
    public static func requestIdInt(_ id: JSONRPCID) -> Int {
        if case .number(let n) = id { return n }
        return -1
    }

    /// scopeKey used to record a permission decision. Replicates the exact
    /// derivation in `ACPTabView.scopeKey(for:)` so remote and local decisions
    /// land on the same key in `permission_decisions`.
    public static func scopeKey(for params: ACPPermissionRequestParams) -> String {
        ACPRequestAnswers.scopeKey(for: params)
    }

    /// Maps a live ACPMessage to the wire DTO. Simple kinds carry `text`;
    /// structured kinds carry a JSON blob the web client renders specially.
    ///
    /// The id is the message's POSITION, not `ACPMessage.stableId`: a read-only
    /// mirror re-decodes the transcript on every refresh, minting fresh UUIDs
    /// each time (`ACPMessageWire.toMessage`), so the per-message id is not
    /// stable across our full re-snapshots. Position is — the Nth message stays
    /// the Nth — so the client can upsert idempotently by `index` instead of
    /// accumulating duplicate copies. Positional ids stay valid across
    /// incremental deltas too: every index-shifting mutation (prepend,
    /// removal, wholesale replacement) is recorded as *structural* by
    /// `ACPTranscriptChangeLog`, which forces a fresh tail snapshot under a
    /// bumped epoch rather than a delta that could otherwise upsert a stale
    /// index against shifted content.
    /// A user row's wire text: the prompt, then one labelled line per image
    /// and per mention. Viewers rebuild it to recognise their own prompt in
    /// the transcript.
    public nonisolated static func userRowText(
        text: String, attachmentNames: [String?], resourceNames: [String?] = []
    ) -> String {
        var parts: [String] = []
        if !text.isEmpty { parts.append(text) }
        parts.append(contentsOf: attachmentNames.map { "🖼 \($0 ?? "Image")" })
        parts.append(contentsOf: resourceNames.map { "📎 \($0 ?? "Resource")" })
        return parts.joined(separator: "\n\n")
    }

    public static func toWire(
        _ message: ACPMessage,
        index: Int,
        fullToolCallContent: String? = nil
    ) -> RemoteWireMessage {
        let sid = "m\(index)"
        switch message {
        case .user(_, _, let text, let attachments, _, _):
            // The wire carries user text only; surface attachments as a labelled
            // placeholder so an image-only prompt isn't a blank bubble on the
            // phone (we don't serve the image bytes to the client in v1).
            // The runner sends only `image/` attachments as images; the
            // rest are resource links (mentions).
            let shown = attachments.filter { !$0.isCheckpointReference }
            let isImage = { (a: ACPMessage.Attachment) in a.mimeType?.hasPrefix("image/") == true }
            let rowText = userRowText(text: text, attachmentNames: shown.filter(isImage).map(\.name),
                                      resourceNames: shown.filter { !isImage($0) }.map(\.name))
            return .init(stableId: sid, kind: "user", text: rowText,
                         json: nil, index: index)
        case .agent(_, _, let streaming):
            return .init(stableId: sid, kind: "agent", text: streaming.value, json: nil, index: index)
        case .thought(_, _, let streaming):
            return .init(stableId: sid, kind: "thought", text: streaming.value, json: nil, index: index)
        case .systemNotice(_, let text):
            return .init(stableId: sid, kind: "systemNotice", text: text, json: nil, index: index)
        case .toolCall(let call):
            if ACPBackgroundTask(toolCall: call)?.showInTranscript == false {
                // Keep a positional marker so deltas can hide an existing row
                // and an entirely hidden page still advances its history cursor.
                return .init(stableId: sid, kind: "toolCall", text: nil, json: nil, index: index, isHidden: true)
            }
            return .init(
                stableId: sid,
                kind: "toolCall",
                text: nil,
                json: Self.encodeJSON(remoteToolCall(call, fullContent: fullToolCallContent)),
                index: index
            )
        case .fileEdit(_, let edit):
            return .init(
                stableId: sid,
                kind: "fileEdit",
                text: "\(edit.path)  +\(edit.added) -\(edit.removed)",
                json: Self.encodeJSON(edit),
                index: index
            )
        case .plan(_, let items):
            return .init(stableId: sid, kind: "plan", text: nil, json: Self.encodeJSON(items), index: index)
        case .visualAid(let visual):
            // Without json the phone falls back to a plain-text row with the title.
            return .init(
                stableId: sid, kind: "visualAid", text: visual.title,
                json: Self.encodeJSON(RemoteVisualAid(visual)), index: index)
        }
    }

    private static let visualAidToolName = "Visual aid"

    private static func remoteToolCall(
        _ call: ACPMessage.ToolCall,
        fullContent: String? = nil
    ) -> ACPMessage.ToolCall {
        var remote = call
        if let fullContent {
            remote.content = fullContent
        }
        remote.rawOutput = nil
        if ACPToolCallPresentation.isVisualShow(remote) {
            // The call's title, content, raw input and locations are agent
            // text that can carry the visual's HTML, which reaches the phone
            // as a `visualAid` row instead.
            remote.title = Self.visualAidToolName
            remote.content = ""
            remote.rawInput = nil
            remote.preview = nil
            remote.locations = []
        }
        remote.metadata = nil
        remote.assets = call.assets.map { asset in
            ACPMessage.ToolCallAsset(
                kind: asset.kind,
                data: nil,
                uri: Self.remoteAssetURI(asset.uri),
                mimeType: asset.mimeType,
                name: asset.name
            )
        }
        return remote
    }

    private static func remoteAssetURI(_ uri: String?) -> String? {
        guard let uri else { return nil }
        let normalized = uri.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("data:") ? nil : uri
    }

    private static func encodeJSON<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Cheap size bounds for a `visualAidResponse`, checked before the handler builds a `Set` or trims the
/// note, so a hostile client cannot make the main actor hash or scan megabytes. `utf8.count` is O(1) for
/// native strings. Option ids are ASCII, so four bytes per allowed character is generous. The note cap is a
/// transport limit, not a grapheme limit: a valid note of multi-scalar graphemes (family emoji) is far
/// larger than `noteMaxLength` bytes, and the exact `String.count` check follows in the handler.
public enum RemoteVisualAidLimits: Sendable {
    public static let maxNoteBytes = 256 * 1024
    public static let maxIdUTF8Bytes = ACPVisualAid.Limits.optionIdMaxCharacters * 4
    /// Longest correlation token a rejection echoes; a phone's UUID is 36 bytes.
    public static let maxRequestIdBytes = 64

    public static func exceedsBounds(ids: [String], note: String?) -> Bool {
        ids.count > ACPVisualAid.Limits.optionCount.upperBound
            || ids.contains { $0.utf8.count > maxIdUTF8Bytes }
            || (note?.utf8.count ?? 0) > maxNoteBytes
    }
}
