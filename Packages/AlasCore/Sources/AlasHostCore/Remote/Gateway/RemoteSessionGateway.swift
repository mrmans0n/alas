import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasAgents
import AlasACP
import AlasAgentKit
import AlasSessions

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
    /// Whose sessions this gateway serves, and whose events push session and
    /// worktree lists to clients; without one, clients get lists only when
    /// they ask.
    private let host: AlasHost?
    /// The app's windows, for the tab requests; nil where there are none.
    @_spi(AppHost) public weak var presenter: RemoteSessionPresenter? {
        didSet {
            presenterListChanges = presenter?.sessionListChanges?.observe { [weak self] in self?.refreshSessionList() }
        }
    }
    /// What this gateway asks of the host besides session verbs.
    @_spi(Testing) public lazy var hostCalls = RemoteGatewayHostCalls.host(host)
    /// The sessions a mention search listed, per session, reused while the
    /// query grows.
    private var mentionSessions: [String: [ACPSessionMentionCandidate]] = [:]
    private let federation: FederatedSessionsProvider?
    /// This gateway's registration with `federation`; nil without one.
    private var downstream: FederatedDownstream?
    private let send: (RemoteServerMessage) -> Void
    /// Console channel of an authenticated Alas peer; nil for browsers.
    private let consoleLink: PeerConsoleLink?
    private var sessionListRefresh: Task<Void, Never>?
    private var sessionListGeneration = 0
    private var worktreeListRefresh: Task<Void, Never>?
    private var worktreeListGeneration = 0
    /// Set once the client asks for worktrees or projects: only then are
    /// they pushed.
    private var wantsWorktreeList = false
    private var wantsProjectList = false
    private var hostSubscription: HostSubscription?
    /// Where the client's subscribed sessions are followed.
    private var follows: HostSubscription?
    private var presenterListChanges: ChangeSubscription?
    private var projectListRefresh: Task<Void, Never>?
    private var projectListGeneration = 0
    private var branchListRefresh: Task<Void, Never>?
    private var branchListGeneration = 0
    private var syncStates: [String: RemoteTranscriptSync] = [:]
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

    public init(host: AlasHost?, federation: FederatedSessionsProvider? = nil,
         consoleLink: PeerConsoleLink? = nil,
         caller: HostCaller? = nil,
         sendTracked: (@Sendable (RemoteServerMessage, _ onWritten: @escaping @Sendable () -> Void) -> Void)? = nil,
         send: @escaping (RemoteServerMessage) -> Void) {
        self.host = host
        self.caller = caller
        self.sendTracked = sendTracked
        self.federation = federation
        self.consoleLink = consoleLink
        self.send = send
        if let host { pushLists(from: host) }
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
            send(.agentList(agents: hostCalls.agents()))
        case .listProjects:
            wantsProjectList = true
            refreshProjectList()
        case .listBranches(let projectId):
            refreshBranchList(projectId: projectId)
        case .createWorktreeSession(let projectId, let base, let branch, let agentId, let modelId, let effortId):
            let result = await hostCalls.createWorktreeSession(RemoteWorktreeSessionCreation(
                projectID: projectId, base: base, branch: branch, agentID: agentId, modelID: modelId, effortID: effortId
            ), hostCaller)
            switch result {
            case .success(let summary):
                presentCreated(summary)
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
            let result = await hostCalls.createSession(RemoteSessionCreation(
                worktreeID: worktreeId, agentID: agentId, modelID: modelId, effortID: effortId
            ), hostCaller)
            switch result {
            case .success(let summary):
                presentCreated(summary)
                send(.sessionCreated(session: summary))
                refreshSessionList()
            case .failure(let message):
                send(.createSessionFailed(message: message))
            }
        case .subscribe(let id):
            // A listed session the Mac has not opened is read back from its
            // store first, as opening it there does.
            guard let sessions, (try? await sessions.load(id)) != nil, let follows = followSubscription() else {
                send(.sessionClosed(sessionId: id))
                return
            }
            // A new follow resets: the client gets a snapshot, its pending
            // requests, config and queue.
            do {
                try followAgain(id, on: follows)
            } catch {
                syncStates[id] = nil
                send(.sessionClosed(sessionId: id))
            }
        case .unsubscribe(let id):
            follows?.unfollow(id)
            lastPermissionReq[id] = nil
            lastQuestionReq[id] = nil
            lastElicitationReq[id] = nil
            lastPlanReq[id] = nil
            syncStates[id] = nil
        case .permissionDecision(let id, let requestId, let optionId, let persistScope):
            await applyDecision(sessionId: id, requestId: requestId, optionId: optionId, persistScope: persistScope)
        case .questionAnswer(let id, let requestId, let answers):
            await applyQuestionAnswer(sessionId: id, requestId: requestId, answers: answers)
        case .visualAidResponse(let sessionId, let visualId, let action, let selectedOptionIds, let note, let requestId):
            await handleVisualAidResponse(
                sessionId: sessionId, visualId: visualId, action: action,
                selectedOptionIds: selectedOptionIds, note: note, requestId: requestId)
        case .planResponse(let id, let requestId, let action, let reason):
            await applyPlanResponse(sessionId: id, requestId: requestId, action: action, reason: reason)
        case .elicitationResponse(let id, let requestId, let action, let content):
            await applyElicitationResponse(
                sessionId: id,
                requestId: requestId,
                action: action,
                content: content
            )
        case .takeOver(let id):
            try? await sessions?.takeOver(id, caller: hostCaller)
            // Takeover mostly changes the lease, not the transcript: following
            // again resets, so the client gets a snapshot that says it can
            // drive and its composer unlocks at once.
            if syncStates[id] != nil, let follows {
                try? followAgain(id, on: follows)
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
                rejectPrompt(id)
                return
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasContent = !trimmed.isEmpty || !attachments.isEmpty || !mentions.isEmpty
            guard hasContent else {
                rejectPrompt(id)
                return
            }
            // Resolved before `materialize` writes anything, so a refused
            // mention leaves no orphan image files.
            guard mentions.count <= Self.maxMentionCount,
                  let mentioned = await hostCalls.mentionAttachments(mentions, id)
            else {
                rejectPrompt(id)
                return
            }
            guard let images = materialize(attachments, for: id) else {
                rejectPrompt(id)   // oversize / non-image
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
                rejectPrompt(id)
                discardAttachmentFiles(images)
                return
            }
            // A later failure keeps the files: the recorded message refers to them.
            Task { @MainActor [weak self] in
                if await !delivery.value { self?.rejectPrompt(id) }
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
            guard let sessions, syncStates[id]?.snapshotSent == true else { return }
            let clamped = min(max(limit, RemoteTranscriptSync.pageLimitRange.lowerBound),
                              RemoteTranscriptSync.pageLimitRange.upperBound)
            // A snapshot or delta can supersede this page while a truncated
            // tool call's content is fetched. The client has no other way out
            // of its "loading earlier messages" state, so retry, bounded, rather
            // than drop it; content an earlier attempt fetched stays cached.
            // A resubscribe or takeover meanwhile replaces the state, and the
            // retry reads for the one that replaced it.
            var attempt = 0
            while true {
                guard let state = syncStates[id], state.snapshotSent,
                      let page = try? sessions.transcriptPage(id, before: beforeIndex, limit: clamped)
                else { return }
                // A page from another epoch is labelled with it, so the client
                // drops it; the follow's reset follows.
                if page.revision.epoch == state.epoch {
                    for message in page.messages {
                        if let decoded = Self.decode(message) { state.messages[message.index] = decoded }
                    }
                }
                let hi = min(max(beforeIndex, 0), page.messageCount)
                let capturedGeneration = state.generation
                let wire = await wireTail(id: id, state: state, indices: page.messages.map(\.index))
                attempt += 1
                guard (state.generation == capturedGeneration && syncStates[id] === state)
                    || attempt > Self.maxFetchOlderAttempts else {
                    continue
                }
                send(.transcriptPage(sessionId: id,
                                     epoch: page.revision.epoch,
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
            send(await hostCalls.inspection.remoteRead(.changes(comparisonMode: comparisonMode), sessionId: id))
        case .fileDiff(let id, let path, let stage, let comparisonMode):
            let key = if let comparisonMode {
                "fileDiff\u{0}\(id)\u{0}\(path)\u{0}\(stage ?? "")\u{0}\(comparisonMode.rawValue)"
            } else {
                "fileDiff\u{0}\(id)\u{0}\(path)\u{0}\(stage ?? "")"
            }
            guard inFlightFileRequests.insert(key).inserted else { return }
            defer { inFlightFileRequests.remove(key) }
            send(await hostCalls.inspection.remoteRead(
                .fileDiff(path: path, stage: stage, comparisonMode: comparisonMode), sessionId: id))
        case .listCommitFiles(let id, let sha):
            guard let key = message.fileRequestDedupKey,
                  inFlightFileRequests.insert(key).inserted else { return }
            defer { inFlightFileRequests.remove(key) }
            send(await hostCalls.inspection.remoteRead(.commitFiles(sha: sha), sessionId: id))
        case .commitFileDiff(let id, let sha, let path):
            guard let key = message.fileRequestDedupKey,
                  inFlightFileRequests.insert(key).inserted else { return }
            defer { inFlightFileRequests.remove(key) }
            send(await hostCalls.inspection.remoteRead(.commitDiff(sha: sha, path: path), sessionId: id))
        case .listFiles(let id, let path, let comparisonMode):
            let key = if let comparisonMode {
                "listFiles\u{0}\(id)\u{0}\(path ?? "")\u{0}\(comparisonMode.rawValue)"
            } else {
                "listFiles\u{0}\(id)\u{0}\(path ?? "")"
            }
            guard inFlightFileRequests.insert(key).inserted else { return }
            defer { inFlightFileRequests.remove(key) }
            send(await hostCalls.inspection.remoteRead(.files(path: path, comparisonMode: comparisonMode), sessionId: id))
        case .searchMentions(let id, let query):
            // Ungated by the writer lease, like the file reads: seeing a
            // session is enough to read its project.
            // An overlong query gets no rows rather than rows for a prefix
            // the viewer would take as the answer to the whole query.
            var candidates: [RemoteMention] = []
            if query.count <= Self.maxMentionQueryLength {
                let found = await hostCalls.mentionCandidates(id, query, mentionSessions[id])
                mentionSessions[id] = found.sessions
                candidates = found.mentions
            }
            send(.mentionCandidates(sessionId: id, query: query, candidates: candidates))
        case .readFile(let id, let path):
            let key = "readFile\u{0}\(id)\u{0}\(path)"
            guard inFlightFileRequests.insert(key).inserted else { return }
            defer { inFlightFileRequests.remove(key) }
            send(await hostCalls.inspection.remoteRead(.file(path: path), sessionId: id))
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
                 .transcript, .pendingRequest, .pendingRequestResolved, .sessionState:
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
            let summaries = await hostCalls.sessionSummaries { [weak presenter] id, owner in
                presenter?.sessionTabIndex(id, owner: owner)
            } + (federation?.peerSessionSummaries ?? [])
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
            let worktrees = await hostCalls.worktrees()
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
            let projects = await hostCalls.projects()
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
            let result = await hostCalls.branches(projectId)
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
        if let consoleLink, let host = presenter?.peerConsoleHost {
            host.handle(request, from: consoleLink)
            return
        }
        // Browsers and hosts without console support: refuse attaches and
        // opens explicitly so the client does not wait for an answer.
        switch request {
        case .attach(_, let attachmentId, _):
            send(.console(.detached(attachmentId: attachmentId, reason: .unauthorized)))
        case .open(let requestId, _):
            send(.console(.openFailed(requestId: requestId, message: PeerConsoleOpenError.unsupported.message)))
        default:
            break
        }
    }

    /// Hands a host protocol message to this connection's host connection,
    /// opened on first use for the caller the transport authenticated.
    private func serveHost(_ request: HostClientMessage) {
        if hostConnection == nil, let host, let caller {
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
        if let consoleLink { presenter?.peerConsoleHost?.close(consoleLink) }
        if let federation, let downstream { federation.detach(downstream) }
        self.downstream = nil
        hostSubscription?.cancel()
        hostSubscription = nil
        presenterListChanges = nil
        sessionListRefresh?.cancel()
        sessionListRefresh = nil
        worktreeListRefresh?.cancel()
        worktreeListRefresh = nil
        projectListRefresh?.cancel()
        projectListRefresh = nil
        branchListRefresh?.cancel()
        branchListRefresh = nil
        // Ends every follow, releasing the transcripts it held.
        follows?.cancel()
        follows = nil
        lastPermissionReq.removeAll()
        lastQuestionReq.removeAll()
        lastElicitationReq.removeAll()
        lastPlanReq.removeAll()
        syncStates.removeAll()
    }

    // MARK: following

    /// The host subscription this gateway follows its client's sessions on,
    /// apart from the list one, which rate-limits its reads.
    private func followSubscription() -> HostSubscription? {
        if let follows { return follows }
        guard let host else { return nil }
        let subscription = host.subscribe()
        follows = subscription
        Task { @MainActor [weak self] in
            while let events = await subscription.next() {
                guard let self else { return }
                await receiveFollowed(events)
                // Streaming chunks that land meanwhile coalesce into one delta.
                try? await Task.sleep(nanoseconds: Self.coalesceNanos)
            }
        }
        return subscription
    }

    /// Follows `id` afresh under a new sync state. What the client was shown
    /// is dismissed first: the new follow knows nothing of a request
    /// resolved meanwhile, and surfaces again those still pending.
    private func followAgain(_ id: String, on follows: HostSubscription) throws {
        if let rid = lastPermissionReq.removeValue(forKey: id) { send(.permissionResolved(sessionId: id, requestId: rid)) }
        if let rid = lastQuestionReq.removeValue(forKey: id) { send(.questionResolved(sessionId: id, requestId: rid)) }
        if let rid = lastPlanReq.removeValue(forKey: id) { send(.planResolved(sessionId: id, requestId: rid)) }
        if let rid = lastElicitationReq.removeValue(forKey: id) { send(.elicitationResolved(sessionId: id, requestId: rid)) }
        syncStates[id] = RemoteTranscriptSync()
        try follows.follow(id)
    }

    /// Sends what the follow reports, in the order a client expects: the
    /// transcript, the requests waiting on it, then config and queue.
    private func receiveFollowed(_ events: [HostEvent]) async {
        // A resubscribe or takeover while this batch waits on a fetch follows
        // again, and the reset that follows carries what this batch holds;
        // nothing of it is sent against the state that replaced it.
        let batchStates = syncStates
        func current(_ id: String) -> RemoteTranscriptSync? {
            guard let sync = syncStates[id], sync === batchStates[id] else { return nil }
            return sync
        }
        var previousStates: [String: HostSessionState?] = [:]
        for case .sessionState(_, let id, let state) in events {
            guard let sync = current(id) else { continue }
            if previousStates[id] == nil { previousStates[id] = .some(sync.sessionState) }
            sync.sessionState = state
        }
        var transcriptSent: Set<String> = []
        for case .transcript(_, let id, let delta) in events {
            guard current(id) != nil else { continue }
            await applyTranscript(delta, id: id)
            transcriptSent.insert(id)
        }
        for event in events {
            switch event {
            case .pendingRequest(_, let id, let request) where current(id) != nil: surfaceRequest(request, sessionId: id)
            case .pendingRequestResolved(_, let id, let requestID) where current(id) != nil: resolveRequest(requestID, sessionId: id)
            default: break
            }
        }
        for (id, previous) in previousStates {
            guard let sync = current(id), let state = sync.sessionState else { continue }
            if previous?.config != state.config { send(.sessionConfig(state.config)) }
            if previous?.queue != state.queue { send(.queueState(sessionId: id, items: state.queue)) }
            // Who drives the session, or what it can stop, changed without
            // the transcript: a content-free delta carries it.
            if let previous, sync.snapshotSent, !transcriptSent.contains(id),
               previous.isWriter != state.isWriter
                || previous.hasCancellableBackgroundWork != state.hasCancellableBackgroundWork {
                sendStateDelta(id: id, state: sync)
            }
        }
    }

    private func applyTranscript(_ delta: HostTranscriptDelta, id: String) async {
        guard let state = syncStates[id] else { return }
        if delta.reset { state.messages.removeAll() }
        for message in delta.messages {
            if let decoded = Self.decode(message) { state.messages[message.index] = decoded }
        }
        state.messages = state.messages.filter { $0.key < delta.messageCount }
        state.messageCount = delta.messageCount
        state.streamingState = delta.streamingState
        if delta.reset {
            await sendSnapshot(id: id, state: state, epoch: delta.revision.epoch)
        } else {
            await sendDelta(id: id, state: state, changed: delta.messages.map(\.index))
        }
    }

    private func canDrive(_ state: RemoteTranscriptSync, id: String) -> Bool {
        state.sessionState?.isWriter ?? sessions?.isWriter(id) ?? false
    }

    private func sendSnapshot(id: String, state: RemoteTranscriptSync, epoch: Int) async {
        state.epoch = epoch
        // Claimed before the wire is built: a delta or snapshot that claims a
        // later generation meanwhile read fresher state, so this one is dropped.
        state.generation += 1
        let capturedGeneration = state.generation
        let hidden = Self.hiddenRows(in: state.messages)
        let wire = await wireTail(id: id, state: state, indices: state.messages.keys.sorted(), hidden: hidden)
        // A resubscribe or takeover that followed again meanwhile replaced
        // this state, and its own snapshot is the current one.
        guard state.generation == capturedGeneration, syncStates[id] === state else { return }
        let cancellable = state.sessionState?.hasCancellableBackgroundWork ?? false
        state.revision = 0
        state.snapshotSent = true
        state.sentBackgroundWorkCancellable = cancellable
        state.sentHiddenRows = hidden
        send(.transcriptSnapshot(sessionId: id,
                                 streamingState: Self.stateString(state.streamingState),
                                 canDrive: canDrive(state, id: id),
                                 messages: wire,
                                 firstIndex: wire.first?.index ?? state.messageCount,
                                 totalCount: state.messageCount,
                                 epoch: state.epoch,
                                 revision: 0,
                                 hasCancellableBackgroundWork: cancellable))
    }

    private func syncState(for id: String) -> RemoteTranscriptSync {
        if let s = syncStates[id] { return s }
        let s = RemoteTranscriptSync()
        syncStates[id] = s
        return s
    }

    /// Tells the client its prompt was not taken, with why the session's
    /// agent cannot run when there is a reason: the coalesced sessionConfig
    /// carrying it may arrive later, or not at all once the client stops
    /// following.
    private func rejectPrompt(_ id: String) {
        send(.promptRejected(sessionId: id, reason: sessions?.agentIssue(id)?.message))
    }

    /// Viewers update their config optimistically. When the host refuses or
    /// ignores a config verb nothing changes, so no state reaches the follow;
    /// re-send the last config so the viewer reverts.
    private func resendConfig(id: String) {
        guard let config = syncStates[id]?.sessionState?.config else { return }
        send(.sessionConfig(config))
    }

    /// A delta with no messages, for a change of state alone.
    private func sendStateDelta(id: String, state: RemoteTranscriptSync) {
        let cancellable = state.sessionState?.hasCancellableBackgroundWork ?? false
        state.revision += 1
        state.sentBackgroundWorkCancellable = cancellable
        send(.transcriptDelta(sessionId: id,
                              streamingState: Self.stateString(state.streamingState),
                              canDrive: canDrive(state, id: id),
                              upserts: [],
                              epoch: state.epoch,
                              revision: state.revision,
                              hasCancellableBackgroundWork: cancellable))
    }

    /// Sends the messages the follow reported changed, and the rows whose
    /// hidden state flipped: a background task row a newer snapshot retired,
    /// or a `visual_show` call its embedded visual now stands in for.
    private func sendDelta(id: String, state: RemoteTranscriptSync, changed: [Int]) async {
        guard state.snapshotSent else { return }
        let hidden = Self.hiddenRows(in: state.messages)
        let indices = Set(changed).union(hidden.symmetricDifference(state.sentHiddenRows))
            .filter { state.messages[$0] != nil }
            .sorted()
        guard !indices.isEmpty else {
            sendStateDelta(id: id, state: state)
            return
        }
        guard indices.count <= RemoteTranscriptSync.dirtyResnapshotThreshold else {
            // Cheaper as a fresh snapshot: following again resets.
            if let follows { try? followAgain(id, on: follows) }
            return
        }
        // Claimed before the wire is built, as a snapshot does: two
        // overlapping deltas must not send out of order.
        state.generation += 1
        let capturedGeneration = state.generation
        // A dirty tool call's stored content may have grown past the cached copy.
        for index in indices {
            if case .toolCall(let call)? = state.messages[index] { state.invalidateToolContent(call.toolCallId) }
        }
        let batches = await wireBatches(id: id, state: state, indices: indices, hidden: hidden)
        guard state.generation == capturedGeneration, syncStates[id] === state else { return }
        state.sentHiddenRows = hidden
        let cancellable = state.sessionState?.hasCancellableBackgroundWork ?? false
        // Sent without suspension, each frame with the next revision.
        for wire in batches {
            state.revision += 1
            state.sentBackgroundWorkCancellable = cancellable
            send(.transcriptDelta(sessionId: id,
                                  streamingState: Self.stateString(state.streamingState),
                                  canDrive: canDrive(state, id: id),
                                  upserts: wire,
                                  epoch: state.epoch,
                                  revision: state.revision,
                                  hasCancellableBackgroundWork: cancellable))
        }
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

    /// The app shows a session a client created, as it shows one it creates.
    private func presentCreated(_ summary: RemoteSessionSummary) {
        guard let worktreeID = summary.worktreeId else { return }
        presenter?.sessionCreated(summary.id, worktreeID: worktreeID)
    }

    /// The host's session verbs; nil without a host, which refuses them all.
    private var sessions: SessionsAPI? { host?.sessions }

    /// Who the host verbs act for: the authenticated device, or this app.
    private var hostCaller: HostCaller { caller ?? .app }

    /// Build the newest contiguous suffix that fits. Older rows remain
    /// reachable through fetchOlder instead of disappearing from history.
    private func wireTail(
        id: String, state: RemoteTranscriptSync, indices: [Int], hidden: Set<Int>? = nil
    ) async -> [RemoteWireMessage] {
        let hidden = hidden ?? Self.hiddenRows(in: state.messages)
        var wire: [RemoteWireMessage] = []
        var remaining = RemoteTranscriptSync.payloadBudget(sessionId: id)
        for index in indices.reversed() {
            guard let row = await wireMessage(id: id, state: state, index: index, hidden: hidden.contains(index)) else { continue }
            guard row.byteCount + 1 <= remaining else { break }
            remaining -= row.byteCount + 1
            wire.append(row.message)
        }
        wire.reverse()
        return wire
    }

    private func wireBatches(
        id: String, state: RemoteTranscriptSync, indices: [Int], hidden: Set<Int>
    ) async -> [[RemoteWireMessage]] {
        let budget = RemoteTranscriptSync.payloadBudget(sessionId: id)
        var batches: [[RemoteWireMessage]] = []
        var batch: [RemoteWireMessage] = []
        var remaining = budget
        for index in indices {
            guard let row = await wireMessage(id: id, state: state, index: index, hidden: hidden.contains(index)) else { continue }
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
        id: String, state: RemoteTranscriptSync, index: Int, hidden: Bool
    ) async -> (message: RemoteWireMessage, byteCount: Int)? {
        // Re-read across awaits: a reset can replace what the gateway holds;
        // the caller's generation check discards the stale serialization.
        guard let message = state.messages[index] else { return nil }
        // A visual aid's answer prompt stays a positional marker: the phone's card shows the answer.
        if hidden || ACPVisualAidQuestionForm.isAnswerPrompt(message) {
            return RemoteWireMessage(stableId: "m\(index)", kind: message.kind, text: nil, json: nil,
                                     index: index, isHidden: true)
                .boundedForTransport(maximumBytes: RemoteTranscriptSync.maxMessageBytes)
        }
        return Self.toWire(
            message, index: index,
            fullToolCallContent: await cachedFullToolCallContent(sessionId: id, state: state, message: message)
        ).boundedForTransport(maximumBytes: RemoteTranscriptSync.maxMessageBytes)
    }

    /// Rows sent as positional markers: background task rows a newer snapshot
    /// of the same task retired, and the `visual_show` calls whose embedded
    /// visual stands in for their chip. Inspect every message the gateway holds
    /// so an older page cannot revive a row hidden by something outside that
    /// page. Keep positional IDs and paging cursors.
    private static func hiddenRows(in messages: [Int: ACPMessage]) -> Set<Int> {
        let ordered = messages.sorted(by: { $0.key < $1.key })
        return supersededBackgroundRows(in: ordered)
            .union(embeddedVisualShowRows(in: ordered))
    }

    private static func supersededBackgroundRows(in ordered: [(key: Int, value: ACPMessage)]) -> Set<Int> {
        var latest: [String: Int] = [:]
        var backgroundIds: Set<String> = []
        for (index, message) in ordered {
            guard case .toolCall(let call) = message else { continue }
            latest[call.toolCallId] = index
            if ACPBackgroundTask(toolCall: call) != nil { backgroundIds.insert(call.toolCallId) }
        }
        return Set(ordered.compactMap { index, message in
            guard case .toolCall(let call) = message, backgroundIds.contains(call.toolCallId),
                  latest[call.toolCallId] != index else { return nil }
            return index
        })
    }

    /// The local transcript hides these chips the same way; the phone and peer
    /// Macs drop a hidden row.
    private static func embeddedVisualShowRows(in ordered: [(key: Int, value: ACPMessage)]) -> Set<Int> {
        let ids = ACPToolCallPresentation.hiddenVisualShowToolCallIds(in: ordered.map(\.value))
        guard !ids.isEmpty else { return [] }
        return Set(ordered.compactMap { index, message in
            guard case .toolCall(let call) = message, ids.contains(call.toolCallId) else { return nil }
            return index
        })
    }

    private func cachedFullToolCallContent(sessionId: String, state: RemoteTranscriptSync, message: ACPMessage) async -> String? {
        guard case .toolCall(let toolCall) = message, toolCall.isContentTruncated,
              !ACPToolCallPresentation.isVisualShow(toolCall) else { return nil }
        if let cached = state.cachedToolContent(toolCall.toolCallId) { return cached }
        guard let full = await hostCalls.fullToolCallContent(sessionId, toolCall.toolCallId) else { return nil }
        state.storeToolContent(toolCall.toolCallId, full)
        return full
    }

    /// A transcript message as the session store encodes it, decoded.
    static func decode(_ message: HostTranscriptMessage) -> ACPMessage? {
        guard let decoded = try? ACPMessageCodec.decode(kind: message.kind, payload: Data(message.payload.utf8)) else { return nil }
        // The store's encoding drops the in-memory truncation mark.
        if message.truncated == true, case .toolCall(var call) = decoded {
            call.isContentTruncated = true
            return .toolCall(call)
        }
        return decoded
    }

    // MARK: pending requests

    /// Shows the client a request the follow reports waiting on a person.
    private func surfaceRequest(_ request: HostPendingRequest, sessionId id: String) {
        guard let state = syncStates[id] else { return }
        switch request {
        case .permission(let requestID, let params):
            let rid = state.wireID(for: requestID)
            lastPermissionReq[id] = rid
            send(.permissionRequest(sessionId: id, payload: Self.permissionPayload(params, requestId: rid)))
        case .question(let requestID, let params):
            guard !params.questions.isEmpty else { return }
            let rid = state.wireID(for: requestID)
            lastQuestionReq[id] = rid
            send(.questionRequest(sessionId: id, payload: RemoteQuestionPayload(
                requestId: rid,
                title: params.title,
                questions: params.questions.map { q in
                    RemoteQuestion(
                        id: q.id,
                        prompt: q.prompt,
                        options: q.options.map { RemoteQuestionOption(id: $0.id, label: $0.label) },
                        allowMultiple: q.allowMultiple == true)
                })))
        case .plan(let requestID, let params):
            lastPlanReq[id] = requestID
            let todos = params.todos.map { RemotePlanTodo(id: $0.id, content: $0.content, status: $0.status) }
            let phases = params.phases.map { phase in
                RemotePlanPhase(name: phase.name, todos: phase.todos.map {
                    RemotePlanTodo(id: $0.id, content: $0.content, status: $0.status)
                })
            }
            send(.planRequest(sessionId: id, payload: .init(
                requestId: requestID, toolCallId: params.toolCallId, name: params.name, overview: params.overview,
                plan: params.plan, todos: todos, isProject: params.isProject, phases: phases
            )))
        case .userInput(let token, let params):
            // Rebuilt from the agent's parameters for its fields; the id the
            // client answers by is the host's.
            guard let input = ACPUserInputRequest.elicitation(ACPElicitationRequest(id: .number(0), params: params)) else { return }
            let requestId = token.uuidString
            lastElicitationReq[id] = requestId
            send(.elicitationRequest(sessionId: id, payload: Self.elicitationPayload(input, requestId: requestId)))
        }
    }

    /// Tells the client a request it was shown was answered, here or
    /// elsewhere, or withdrawn, so its prompt does not hang.
    private func resolveRequest(_ requestID: HostPendingRequestID, sessionId id: String) {
        guard let state = syncStates[id] else { return }
        switch requestID {
        case .permission(let agentID):
            let rid = state.wireID(for: agentID)
            guard lastPermissionReq[id] == rid else { return }
            lastPermissionReq[id] = nil
            send(.permissionResolved(sessionId: id, requestId: rid))
        case .question(let agentID):
            let rid = state.wireID(for: agentID)
            guard lastQuestionReq[id] == rid else { return }
            lastQuestionReq[id] = nil
            send(.questionResolved(sessionId: id, requestId: rid))
        case .plan(let agentID):
            guard lastPlanReq[id] == agentID else { return }
            lastPlanReq[id] = nil
            send(.planResolved(sessionId: id, requestId: agentID))
        case .userInput(let token):
            guard lastElicitationReq[id] == token.uuidString else { return }
            lastElicitationReq[id] = nil
            send(.elicitationResolved(sessionId: id, requestId: token.uuidString))
        }
    }

    private static func permissionPayload(_ params: ACPPermissionRequestParams, requestId: Int) -> RemotePermissionPayload {
        let tc = params.toolCall
        let isVisualShow = ACPToolCallPresentation.isVisualShow(name: tc.name, title: tc.title)
        let presentation = ACPPermissionPresentation(metadata: params.metadata)
        return RemotePermissionPayload(
            requestId: requestId,
            toolName: isVisualShow ? Self.visualAidToolName : tc.title ?? tc.kind ?? "tool",
            options: params.options.map {
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
    }

    private static func elicitationPayload(_ pending: ACPUserInputRequest, requestId: String) -> RemoteElicitationPayload {
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
        return .init(
            requestId: requestId, title: pending.title, message: pending.message, mode: mode,
            fields: fields, elicitationId: elicitationId, url: url
        )
    }

    // MARK: decision

    /// Answers the permission the client was shown under `requestId`. The
    /// host checks it is still the pending one; the follow then reports it
    /// resolved, which dismisses the prompt.
    private func applyDecision(sessionId: String, requestId: Int, optionId: String, persistScope: String?) async {
        guard let sessions, let requestID = syncStates[sessionId]?.requestIDs[requestId] else { return }
        let scope: ACPRequestAnswers.PermissionScope = switch persistScope {
        case nil: .optionDefault
        case "session": .session
        case "project": .project
        default: .once
        }
        try? await sessions.answerPermission(sessionId, requestID: requestID, optionID: optionId, scope: scope, caller: hostCaller)
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
        guard let sessions, sessions.isWriter(sessionId) else { return reject("notWriter") }
        guard let id = UUID(uuidString: visualId), let visual = sessions.visualAid(sessionId, id: id) else {
            return reject("notFound")
        }
        guard let question = visual.question, visual.answer == nil else { return reject("alreadyAnswered") }

        guard !RemoteVisualAidLimits.exceedsBounds(ids: selectedOptionIds, note: note) else { return reject("invalid") }

        guard let answer = Self.visualAidAnswer(to: question, action: action, selectedOptionIds: selectedOptionIds, note: note) else {
            return reject("invalid")
        }
        guard (try? await sessions.answerVisualAid(sessionId, visualID: id, answer: answer, caller: hostCaller)) != nil else {
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

    private func applyQuestionAnswer(sessionId: String, requestId: Int, answers: [RemoteQuestionAnswer]) async {
        guard let sessions, let requestID = syncStates[sessionId]?.requestIDs[requestId] else { return }
        try? await sessions.answerQuestion(
            sessionId, requestID: requestID,
            answers: answers.map { ACPQuestionAnswer(questionId: $0.questionId, selectedOptionIds: $0.selectedOptionIds) },
            caller: hostCaller
        )
    }

    private func applyPlanResponse(sessionId: String, requestId: JSONRPCID, action: String, reason: String?) async {
        guard let sessions else { return }
        let planAction: ACPRequestAnswers.PlanAction
        switch action {
        case "accept": planAction = .accept
        case "reject": planAction = .reject(reason: reason ?? "")
        case "cancel": planAction = .cancel
        default: return
        }
        try? await sessions.respondToPlan(sessionId, requestID: requestId, action: planAction, caller: hostCaller)
    }

    private func applyElicitationResponse(
        sessionId: String,
        requestId: String,
        action: String,
        content: [String: ACPElicitationValue]?
    ) async {
        guard let sessions, let token = UUID(uuidString: requestId) else { return }
        let answer: ACPRequestAnswers.UserInputAnswer
        switch action {
        case "accept": answer = .submit(content: content ?? [:])
        case "decline": answer = .decline
        case "cancel": answer = .cancel
        default: return
        }
        try? await sessions.respondToUserInput(sessionId, requestID: token, answer: answer, caller: hostCaller)
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
