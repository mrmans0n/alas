import Foundation
import Observation

/// Native, app-scoped consumer of the existing federated session feed.
@MainActor @Observable
final class NativePeerSessions {
    private let federation: FederatedSessionsProvider
    private let peers: @MainActor () -> [RemoteHelloPeer]
    private let comparisonMode: @MainActor () -> AppConfig.Changes.ChangesComparisonMode?
    /// Peer consoles. Selecting one clears the selected session and vice
    /// versa, so the center pane shows exactly one peer surface.
    let consoles: NativePeerConsoles?
    @ObservationIgnored private var downstream: FederatedDownstream?
    @ObservationIgnored private var pendingPromptExpectedIndex: Int?
    private(set) var isFetchingOlderMessages = false
    private(set) var pendingPrompt: String?

    private(set) var snapshot = NativePeerSidebarSnapshot(groups: [], attentionRows: [])
    /// The peer worktree shown in the center pane. Set with no selected tab
    /// when the worktree has none open.
    private(set) var selectedWorktree: NativePeerWorktreeSelection?
    /// The selected worktree's tabs as of the last snapshot, so a tab the
    /// host closes can be replaced by its neighbour.
    @ObservationIgnored private var selectedWorktreeTabs: [NativePeerTab] = []
    /// The tab last used in each worktree during this app run.
    @ObservationIgnored private var lastTabs: [NativePeerWorktreeSelection: NativePeerTab] = [:]
    /// The attached tab: only this session is subscribed, only this console
    /// has a viewer.
    private(set) var selectedSessionId: String?
    private(set) var transcript: NativePeerTranscript?
    var draft = ""
    private(set) var deliveryError: String?
    static let peerUnavailableMessage = FederatedSessionsProvider.peerUnavailableMessage
    private(set) var newSession: NativePeerNewSession?
    /// A session the peer just created or opened for us, selected once the
    /// peer's session list reports it as an open tab.
    @ObservationIgnored private var pendingSessionId: String?
    /// Why the peer refused to open or close a tab.
    private(set) var sessionTabError: String?
    private(set) var workspace = NativePeerWorkspace()
    /// The selected row's worktree summary when changes were last requested.
    /// Peers re-send it with every session list, so a change here is the
    /// cue that the agent touched the worktree.
    @ObservationIgnored private var workspaceSummary: RemoteWorktreeSummary?
    /// Whether a root `listFiles` request is currently awaiting a reply.
    /// `workspace.beginRootLoad()` only distinguishes "never loaded" from
    /// "loaded"; once loaded it permits sending on every call, so this is
    /// the only thing that stops a second refresh from racing the first
    /// past the peer's in-flight request dedup, which would silently drop it.
    @ObservationIgnored private var fileTreeRequestInFlight = false
    /// Set when a summary change asks for the root file tree while one is
    /// already in flight — either blocked by `beginRootLoad()` returning
    /// false (never loaded yet) or by `fileTreeRequestInFlight` (already
    /// loaded, refreshing). Without this the reply that eventually lands
    /// would look current even though a later edit already invalidated it.
    /// Cleared once the retry it queues has been sent.
    @ObservationIgnored private var fileTreeRequestOutdated = false
    /// Same pair as `fileTreeRequestInFlight`/`fileTreeRequestOutdated`, for
    /// `listChanges`: `requestChanges()` has no equivalent to
    /// `beginRootLoad()`'s loaded/not-loaded gate, so without this every
    /// summary change would fire its own request and the peer's in-flight
    /// dedup would silently drop all but the first.
    @ObservationIgnored private var changesRequestInFlight = false
    @ObservationIgnored private var changesRequestOutdated = false
    /// Documents (by their own identity, not just "the open one") with a
    /// `readFile`/`fileDiff` request currently outstanding. Keyed per
    /// document, not a single flag, because switching away from a document
    /// before its reply arrives and then back to it (A→B→A) leaves that
    /// original request outstanding on the peer under the same dedup key a
    /// fresh one would use — a single scalar can't tell "opening A is a
    /// brand-new request" from "opening A again means waiting on the one
    /// still out there."
    @ObservationIgnored private var documentRequestsInFlight: Set<NativePeerWorkspace.Document> = []
    /// Set when the *currently open* document's request is skipped because
    /// one is already in `documentRequestsInFlight`. Cleared once the retry
    /// it queues has been sent.
    @ObservationIgnored private var documentRequestOutdated = false

    init(
        federation: FederatedSessionsProvider,
        peers: @escaping @MainActor () -> [RemoteHelloPeer],
        comparisonMode: @escaping @MainActor () -> AppConfig.Changes.ChangesComparisonMode? = { nil },
        consoles: NativePeerConsoles? = nil
    ) {
        self.federation = federation
        self.peers = peers
        self.comparisonMode = comparisonMode
        self.consoles = consoles
        consoles?.onListChanged = { [weak self] in self?.rebuildSnapshot() }
    }

    /// Only the sidebar model: console lists change nothing a selected
    /// session depends on, so the rest of `refresh()` is not needed.
    private func rebuildSnapshot() {
        guard downstream != nil else { return }
        snapshot = .build(peers: peers(), rows: federation.peerSessionSummaries, consoles: consoles?.consoles ?? [:])
        reconcileSelectedTab()
    }

    var selectedTab: NativePeerTab? {
        if let selectedSessionId { return .session(selectedSessionId) }
        return consoles?.viewer.map { .console($0.consoleId) }
    }

    private func worktrees(on serverId: String) -> [NativePeerWorktreeGroup] {
        snapshot.groups.first { $0.serverId == serverId }?.repos(ordering: .manual).flatMap(\.worktrees) ?? []
    }

    private func worktree(_ selection: NativePeerWorktreeSelection) -> NativePeerWorktreeGroup? {
        worktrees(on: selection.serverId).first { $0.id == selection.worktreeId }
    }

    /// Opens the tab last used in the worktree, else its first tab, else
    /// nothing: the center pane shows the worktree's empty state.
    func selectWorktree(_ selection: NativePeerWorktreeSelection) {
        guard let worktree = worktree(selection) else { return }
        let tabs = worktree.tabs
        if let tab = lastTabs[selection].flatMap({ tabs.contains($0) ? $0 : nil }) ?? tabs.first {
            selectTab(tab, in: selection)
        } else {
            clearSelection()
            selectedWorktree = selection
        }
    }

    func selectTab(_ tab: NativePeerTab, in selection: NativePeerWorktreeSelection) {
        switch tab {
        case .session(let id): select(id)
        case .console(let id): selectConsole(serverId: selection.serverId, consoleId: id)
        }
    }

    /// Points the worktree selection at whichever worktree holds `tab`.
    private func noteSelected(_ tab: NativePeerTab, serverId: String) {
        let worktree = worktrees(on: serverId).first { group in
            switch tab {
            case .session(let id): group.sessions.contains { $0.id == id }
            case .console(let id): group.consoles.contains { $0.consoleId == id }
            }
        }
        guard let worktree else { return }
        let selection = NativePeerWorktreeSelection(serverId: serverId, worktreeId: worktree.id)
        selectedWorktree = selection
        selectedWorktreeTabs = worktree.tabs
        if selectedWorktreeTabs.contains(tab) { lastTabs[selection] = tab }
    }

    /// Follows the host closing tabs in the selected worktree.
    private func reconcileSelectedTab() {
        guard let selection = selectedWorktree,
              snapshot.groups.first(where: { $0.serverId == selection.serverId })?.state.carriesSessions == true
        else { return }
        let selected = selectedTab
        // Until the peer's console list arrives, its consoles are unknown, not closed.
        if case .console = selected, consoles?.consoles[selection.serverId] == nil { return }
        let current: [NativePeerTab]
        if let worktree = worktree(selection) {
            current = worktree.tabs
        } else if case .console = selected {
            // The console list is known (checked above), so its last console closed.
            current = []
        } else {
            // Missing session rows mean the peer's list dropped, not that its
            // tabs closed; `refresh()` marks the selection unavailable.
            return
        }
        let previous = selectedWorktreeTabs
        selectedWorktreeTabs = current
        let next = NativePeerWorktreeGroup.reconciledTab(selected, previous: previous, current: selectedWorktreeTabs)
        guard next != selected else { return }
        if let next {
            selectTab(next, in: selection)
        } else {
            clearSelection()
            selectedWorktree = selection
        }
    }

    var selectedWorktreeGroup: NativePeerWorktreeGroup? {
        selectedWorktree.flatMap(worktree)
    }

    var selectedWorktreePeer: NativePeerGroup? {
        guard let selectedWorktree else { return nil }
        return snapshot.groups.first { $0.serverId == selectedWorktree.serverId }
    }

    /// Whether the peer serves `openSessionTab`, so a history session can be
    /// opened from here.
    func canOpenSessionTabs(serverId: String) -> Bool {
        federation.peerSupports(PeerSessionTabsCapability.v1, serverId: serverId)
    }

    /// Selects an open session's tab, or asks the peer to open a history
    /// session and selects it once the peer lists it as open.
    func openSession(_ sessionId: String) {
        guard let downstream,
              let row = snapshot.groups.lazy.flatMap(\.sessions).first(where: { $0.id == sessionId })
        else { return }
        sessionTabError = nil
        if row.isActive {
            select(sessionId)
            return
        }
        pendingSessionId = sessionId
        if !federation.route(.openSessionTab(sessionId: sessionId), from: downstream) {
            pendingSessionId = nil
            sessionTabError = Self.peerUnavailableMessage
        }
    }

    var selectedRow: RemoteSessionSummary? {
        guard let selectedSessionId else { return nil }
        return snapshot.groups.flatMap(\.sessions).first { $0.id == selectedSessionId }
    }

    var isPromptPending: Bool { pendingPrompt != nil }

    var selectedPeer: NativePeerGroup? {
        guard let selectedSessionId else { return nil }
        return snapshot.groups.first { selectedSessionId.hasPrefix($0.serverId + ":") }
    }

    func start() {
        guard downstream == nil else { return }
        let client = FederatedDownstream(
            send: { [weak self] message in self?.receive(message) },
            sessionListChanged: { [weak self] in self?.refresh() }
        )
        downstream = client
        federation.attach(client)
        consoles?.start()
        refresh()
        _ = federation.route(.listSessions, from: client)
    }

    func stop() {
        if let downstream {
            if let selectedSessionId {
                _ = federation.route(.unsubscribe(sessionId: selectedSessionId), from: downstream)
            }
            federation.detach(downstream)
        }
        downstream = nil
        consoles?.stop()
        selectedWorktree = nil
        selectedWorktreeTabs = []
        selectedSessionId = nil
        transcript = nil
        snapshot = .init(groups: [], attentionRows: [])
        draft = ""
        pendingPrompt = nil
        pendingPromptExpectedIndex = nil
        isFetchingOlderMessages = false
        deliveryError = nil
        sessionTabError = nil
        newSession = nil
        pendingSessionId = nil
        workspace = NativePeerWorkspace()
        workspaceSummary = nil
        fileTreeRequestOutdated = false
        changesRequestInFlight = false
        changesRequestOutdated = false
        documentRequestsInFlight = []
        documentRequestOutdated = false
        fileTreeRequestInFlight = false
    }

    func refresh() {
        guard downstream != nil else { return }
        rebuildSnapshot()
        consoles?.peersChanged(online: Set(snapshot.groups.filter(\.state.carriesSessions).map(\.serverId)))
        reconcileNewSession()
        if let pending = pendingSessionId,
           snapshot.groups.contains(where: { $0.sessions.contains { $0.id == pending && $0.isActive } }) {
            pendingSessionId = nil
            select(pending)
            return
        }
        guard selectedSessionId != nil else { return }
        guard let group = selectedPeer else {
            clearSelection()
            return
        }
        if !group.state.carriesSessions || selectedRow == nil {
            transcript?.markUnavailable()
            isFetchingOlderMessages = false
            workspace.markUnavailable()
        } else if transcript?.isClosed == true, let selectedSessionId, let downstream {
            // The provider discarded subscriptions when this peer went away.
            // Its new transcript may also have a lower epoch after a restart.
            transcript = NativePeerTranscript(sessionId: selectedSessionId)
            pendingPrompt = nil
            pendingPromptExpectedIndex = nil
            isFetchingOlderMessages = false
            _ = federation.route(.subscribe(sessionId: selectedSessionId), from: downstream)
            // Preserved across the reset below: losing it would silently
            // drop the center pane back to the transcript on every
            // reconnect, discarding whatever the user had open.
            let openDocument = workspace.document
            workspace = NativePeerWorkspace()
            // Whatever was in flight before the peer went away will never
            // get a reply now — without this, reloadWorkspace() below would
            // find both still "in flight" and gate its own fresh requests.
            changesRequestInFlight = false
            changesRequestOutdated = false
            fileTreeRequestInFlight = false
            fileTreeRequestOutdated = false
            documentRequestsInFlight = []
            documentRequestOutdated = false
            reloadWorkspace()
            if let openDocument { open(openDocument) }
        } else if selectedRow?.worktree != workspaceSummary {
            // The summary only signals that the peer's worktree changed, not
            // which files — a rename or delete only shows up by re-listing.
            reloadWorkspace()
        }
    }

    func select(_ sessionId: String) {
        guard let downstream,
              let peer = snapshot.groups.first(where: { group in
                  group.state.carriesSessions && group.sessions.contains { $0.id == sessionId }
              }) else { return }
        if selectedSessionId == sessionId {
            workspace.closeDocument()
            refresh()
            return
        }
        clearSelection()
        noteSelected(.session(sessionId), serverId: peer.serverId)
        selectedSessionId = sessionId
        transcript = NativePeerTranscript(sessionId: sessionId)
        _ = federation.route(.subscribe(sessionId: sessionId), from: downstream)
        reloadWorkspace()
    }

    func selectConsole(serverId: String, consoleId: String) {
        if let viewer = consoles?.viewer, viewer.serverId == serverId, viewer.consoleId == consoleId,
           !viewer.isEnded { return }
        clearSelection()
        noteSelected(.console(consoleId), serverId: serverId)
        consoles?.select(serverId: serverId, consoleId: consoleId)
    }

    func clearSelection() {
        selectedWorktree = nil
        selectedWorktreeTabs = []
        consoles?.clearSelection()
        if let selectedSessionId, let downstream {
            _ = federation.route(.unsubscribe(sessionId: selectedSessionId), from: downstream)
        }
        selectedSessionId = nil
        // Any explicit navigation away (another peer session, a local
        // worktree) outranks auto-selecting a session created earlier.
        pendingSessionId = nil
        transcript = nil
        draft = ""
        pendingPrompt = nil
        pendingPromptExpectedIndex = nil
        isFetchingOlderMessages = false
        deliveryError = nil
        sessionTabError = nil
        workspace = NativePeerWorkspace()
        workspaceSummary = nil
        fileTreeRequestOutdated = false
        changesRequestInFlight = false
        changesRequestOutdated = false
        documentRequestsInFlight = []
        documentRequestOutdated = false
        fileTreeRequestInFlight = false
    }

    func sendPrompt() {
        guard pendingPrompt == nil,
              let selectedSessionId, let downstream, selectedPeer?.state.carriesSessions == true,
              transcript?.canDrive == true else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        pendingPrompt = text
        pendingPromptExpectedIndex = transcript?.totalCount ?? 0
        if federation.route(.sendPrompt(sessionId: selectedSessionId, text: text,
                                        attachments: [], intent: "auto"), from: downstream) {
            deliveryError = nil
        } else {
            pendingPrompt = nil
            pendingPromptExpectedIndex = nil
            deliveryError = "Peer is unavailable. Your draft was kept."
        }
    }

    func stopSelected() { routeWhileOnline { .stop(sessionId: $0) } }
    func takeOver() { routeWhileOnline { .takeOver(sessionId: $0) } }

    func beginNewSession(peer: NativePeerGroup, repo: NativePeerRepoGroup) {
        guard downstream != nil, peer.state.carriesSessions else { return }
        pendingSessionId = nil
        newSession = NativePeerNewSession(
            serverId: peer.serverId, peerName: peer.name, projectId: repo.projectId, repoName: repo.name
        )
        requestNewSessionOptions()
    }

    /// The peer and repo a new session in `selection` belongs to. Nil while
    /// the peer is offline or for a worktree outside any of its projects.
    func newSessionTarget(in selection: NativePeerWorktreeSelection) -> (peer: NativePeerGroup, repo: NativePeerRepoGroup)? {
        guard let peer = snapshot.groups.first(where: { $0.serverId == selection.serverId }),
              peer.state.carriesSessions,
              let repo = peer.repos(ordering: .manual).first(where: { repo in
                  repo.worktrees.contains { $0.id == selection.worktreeId }
              }),
              repo.projectId != nil
        else { return nil }
        return (peer, repo)
    }

    /// Opens the new-session sheet on the selected worktree's repo, which
    /// preselects that worktree.
    func beginNewSession(in selection: NativePeerWorktreeSelection) {
        guard let target = newSessionTarget(in: selection) else { return }
        beginNewSession(peer: target.peer, repo: target.repo)
    }

    func createNewSession(worktreeId: String, agentId: String, modelId: String?, effortId: String?) {
        guard let request = newSession, request.phase != .creating, let downstream else { return }
        newSession?.phase = .creating
        let token = request.id
        let sent = federation.request(
            .createSession(worktreeId: worktreeId, agentId: agentId, modelId: modelId, effortId: effortId),
            toPeer: request.serverId, from: downstream
        ) { [weak self] reply in self?.applyNewSessionReply(reply, token: token) }
        if !sent { newSession?.phase = .failed(Self.peerUnavailableMessage) }
    }

    /// Asks the peer to create a worktree from `base` and start the session
    /// in it, as one request.
    func createNewWorktreeSession(base: String, branch: String, agentId: String, modelId: String?, effortId: String?) {
        guard let request = newSession, request.phase != .creating, let projectId = request.projectId,
              let downstream else { return }
        newSession?.phase = .creating
        let token = request.id
        let sent = federation.request(
            .createWorktreeSession(
                projectId: projectId, base: base, branch: branch, agentId: agentId,
                modelId: modelId, effortId: effortId),
            toPeer: request.serverId, from: downstream
        ) { [weak self] reply in self?.applyNewSessionReply(reply, token: token) }
        if !sent { newSession?.phase = .failed(Self.peerUnavailableMessage) }
    }

    func cancelNewSession() {
        newSession = nil
    }

    /// The selected worktree, when it belongs to the sheet's peer.
    var newSessionDefaultWorktreeId: String? {
        guard let request = newSession, let selectedWorktree, selectedWorktree.serverId == request.serverId
        else { return nil }
        return worktree(selectedWorktree)?.peerWorktreeId
    }

    private func requestNewSessionOptions() {
        guard let request = newSession, let downstream else { return }
        let token = request.id
        var messages: [RemoteClientMessage] = [.listWorktrees, .listAgents]
        if let projectId = request.projectId { messages.append(.listBranches(projectId: projectId)) }
        let sent = messages.allSatisfy { message in
            federation.request(message, toPeer: request.serverId, from: downstream) { [weak self] reply in
                self?.applyNewSessionReply(reply, token: token)
            }
        }
        if !sent { newSession?.phase = .failed(Self.peerUnavailableMessage) }
    }

    private func applyNewSessionReply(_ reply: RemoteServerMessage, token: UUID) {
        guard let request = newSession, request.id == token else { return }
        switch reply {
        case .worktreeList(let all):
            newSession?.worktrees = NativePeerNewSession.worktrees(
                all, projectId: request.projectId, repoName: request.repoName
            )
        case .agentList(let agents):
            newSession?.agents = agents
        case .branchList(let projectId, let names, let preferredBase) where projectId == request.projectId:
            newSession?.branches = .loaded(names: names, preferredBase: preferredBase)
        case .branchListFailed(let projectId, let message) where projectId == request.projectId:
            newSession?.branches = .failed(message)
        case .createSessionFailed(let message):
            newSession?.phase = .failed(message)
        case .worktreeSessionCreationFailed(_, let message, let worktreeId):
            newSession?.phase = .failed(message)
            // The worktree exists without its session: list it, so the sheet
            // can offer it instead of creating a second one.
            guard let worktreeId, let downstream else { return }
            newSession?.recoveredWorktreeId = worktreeId
            _ = federation.request(.listWorktrees, toPeer: request.serverId, from: downstream) { [weak self] reply in
                self?.applyNewSessionReply(reply, token: token)
            }
        case .sessionCreated(let summary), .worktreeSessionCreated(let summary):
            newSession = nil
            pendingSessionId = summary.id
            refresh()
        default:
            break
        }
    }

    /// Fails the open sheet while its peer is away, and reloads its options
    /// when the peer is back.
    private func reconcileNewSession() {
        guard let request = newSession else { return }
        let online = snapshot.groups.first { $0.serverId == request.serverId }?.state.carriesSessions == true
        let unavailable = NativePeerNewSession.Phase.failed(Self.peerUnavailableMessage)
        if !online, request.phase != unavailable {
            newSession?.phase = unavailable
        } else if online, request.phase == unavailable {
            newSession?.phase = .editing
            requestNewSessionOptions()
        }
    }

    /// Re-asks the peer for the selected session's changes and file tree.
    /// Replies land through `receive`.
    func reloadWorkspace() {
        // A request already in flight (e.g. the user hit refresh while the
        // initial load was still out) skips its send; queue a retry so the
        // eventual reply doesn't stand in as current.
        if !requestChanges() { changesRequestOutdated = true }
        if !loadFileTree() { fileTreeRequestOutdated = true }
        // An open diff or file is otherwise left showing its old snapshot —
        // neither a summary change nor the toolbar's manual refresh touches
        // it, since both only route through this method.
        if let document = workspace.document, !open(document) {
            documentRequestOutdated = true
        }
    }

    @discardableResult
    func requestChanges() -> Bool {
        guard selectedSessionId != nil else { return false }
        workspaceSummary = selectedRow?.worktree
        guard !changesRequestInFlight else { return false }
        changesRequestInFlight = true
        workspace.beginChangesLoad()
        if !routeWhileOnline({
            .listChanges(sessionId: $0, comparisonMode: comparisonMode())
        }) {
            changesRequestInFlight = false
            workspace.markUnavailable()
            return false
        }
        return true
    }

    @discardableResult
    func loadFileTree() -> Bool {
        guard selectedSessionId != nil, workspace.beginRootLoad() else { return false }
        guard !fileTreeRequestInFlight else { return false }
        fileTreeRequestInFlight = true
        if !routeWhileOnline({
            .listFiles(sessionId: $0, path: nil, comparisonMode: comparisonMode())
        }) {
            fileTreeRequestInFlight = false
            workspace.markUnavailable()
            return false
        }
        return true
    }

    func loadFileTreeChildren(path: String) {
        guard selectedSessionId != nil, workspace.beginChildrenLoad(path: path) else { return }
        if !routeWhileOnline({
            .listFiles(sessionId: $0, path: path, comparisonMode: comparisonMode())
        }) {
            workspace.markUnavailable()
        }
    }

    func loadCommitFiles(sha: String) {
        guard selectedSessionId != nil, workspace.beginCommitFilesLoad(sha: sha) else { return }
        if !routeWhileOnline({ .listCommitFiles(sessionId: $0, sha: sha) }) {
            workspace.markUnavailable()
        }
    }

    /// Opens `document`, or — when it's already the open one — refreshes it.
    /// A refresh is gated the same way changes/file-tree refreshes are: a
    /// request already in flight for this same document skips the send, and
    /// `reloadWorkspace()` queues a retry. Opening a genuinely different
    /// document always proceeds; whatever was in flight for the previous one
    /// no longer matters.
    @discardableResult
    func open(_ document: NativePeerWorkspace.Document) -> Bool {
        guard selectedSessionId != nil else { return false }
        if document != workspace.document { documentRequestOutdated = false }
        workspace.beginDocument(document)
        guard !documentRequestsInFlight.contains(document) else {
            // A request for this exact document is already outstanding —
            // whether it's the one already open (a refresh) or one just
            // returned to (A→B→A, sharing the peer's still-outstanding
            // request key) — so don't resend a duplicate the peer would
            // drop; queue a retry for when that reply lands instead.
            documentRequestOutdated = true
            return false
        }
        documentRequestsInFlight.insert(document)
        let sent = switch document {
        case .diff(let path, let stage):
            routeWhileOnline {
                .fileDiff(
                    sessionId: $0,
                    path: path,
                    stage: stage?.rawValue,
                    comparisonMode: comparisonMode()
                )
            }
        case .commitDiff(let path, let sha):
            routeWhileOnline { .commitFileDiff(sessionId: $0, sha: sha, path: path) }
        case .file(let path):
            routeWhileOnline { .readFile(sessionId: $0, path: path) }
        }
        if !sent {
            documentRequestsInFlight.remove(document)
            workspace.markUnavailable()
            return false
        }
        return true
    }

    func closeDocument() {
        workspace.closeDocument()
    }

    @discardableResult
    func fetchOlder() -> Bool {
        guard !isFetchingOlderMessages,
              let before = transcript?.olderPageBeforeIndex
        else { return false }
        isFetchingOlderMessages = true
        guard routeWhileOnline({
            .fetchOlder(
                sessionId: $0, beforeIndex: before, limit: RemoteTranscriptSync.tailWindow
            )
        }) else {
            isFetchingOlderMessages = false
            return false
        }
        return true
    }

    func decidePermission(requestId: Int, optionId: String) {
        guard transcript?.pendingPermission?.requestId == requestId else { return }
        routeDrive { .permissionDecision(sessionId: $0, requestId: requestId,
                                          optionId: optionId, persistScope: nil) }
    }

    func answerQuestion(requestId: Int, answers: [RemoteQuestionAnswer]) {
        guard transcript?.pendingQuestion?.requestId == requestId else { return }
        routeDrive { .questionAnswer(sessionId: $0, requestId: requestId, answers: answers) }
    }

    func respondToPlan(requestId: JSONRPCID, action: String, reason: String? = nil) {
        guard transcript?.pendingPlan?.requestId == requestId else { return }
        let responseReason: String?
        if action == "reject" {
            let trimmed = (reason ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            responseReason = trimmed
        } else {
            responseReason = reason
        }
        routeDrive { .planResponse(sessionId: $0, requestId: requestId, action: action, reason: responseReason) }
    }

    func respondToElicitation(requestId: String, action: String,
                               content: [String: ACPElicitationValue]? = nil) {
        guard let pending = transcript?.pendingElicitation,
              pending.requestId == requestId,
              pending.mode != "url" || action != "accept"
        else { return }
        sendElicitationResponse(requestId: requestId, action: action, content: content)
    }

    func openElicitationURL(
        requestId: String,
        openURL: @MainActor (URL, @escaping @MainActor (Bool) -> Void) -> Void,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        guard let pending = transcript?.pendingElicitation,
              pending.requestId == requestId,
              pending.mode == "url",
              let rawURL = pending.url,
              let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil
        else {
            completion(false)
            return
        }

        openURL(url) { [weak self] didOpen in
            guard didOpen else {
                completion(false)
                return
            }
            self?.sendElicitationResponse(requestId: requestId, action: "accept", content: [:])
            completion(true)
        }
    }

    private func sendElicitationResponse(requestId: String, action: String,
                                          content: [String: ACPElicitationValue]?) {
        guard transcript?.pendingElicitation?.requestId == requestId else { return }
        routeDrive { .elicitationResponse(sessionId: $0, requestId: requestId,
                                           action: action, content: content) }
    }

    private func routeDrive(_ makeMessage: (String) -> RemoteClientMessage) {
        guard transcript?.canDrive == true else { return }
        routeWhileOnline(makeMessage)
    }

    @discardableResult
    private func routeWhileOnline(_ makeMessage: (String) -> RemoteClientMessage) -> Bool {
        guard let selectedSessionId, let downstream,
              selectedPeer?.state.carriesSessions == true else { return false }
        return federation.route(makeMessage(selectedSessionId), from: downstream)
    }

    private func receive(_ message: RemoteServerMessage) {
        // Tab actions answer for any session, not just the selected one. A
        // reply to a request the user has since moved on from is dropped.
        if case .sessionTabActionFailed(let sessionId, let text) = message {
            if pendingSessionId == sessionId {
                pendingSessionId = nil
                sessionTabError = text
            }
            return
        }
        guard let selectedSessionId, message.sessionId == selectedSessionId else { return }
        switch message {
        case .transcriptSnapshot, .transcriptPage:
            isFetchingOlderMessages = false
        default:
            break
        }
        if case .promptRejected = message {
            pendingPrompt = nil
            pendingPromptExpectedIndex = nil
            deliveryError = "Prompt was not delivered. Your draft was kept."
            return
        }
        let isChangesReply: Bool = switch message {
        case .changeList, .changeListFailed: true
        default: false
        }
        if isChangesReply { changesRequestInFlight = false }
        let isRootFileTreeReply: Bool = switch message {
        case .fileTree(_, let path, _, _), .fileTreeFailed(_, let path, _, _): path == nil
        default: false
        }
        if isRootFileTreeReply { fileTreeRequestInFlight = false }
        // The document this reply is about, regardless of what's currently
        // open — an A→B→A round trip leaves A's original request in flight
        // under a peer dedup key a fresh one would collide with, so its
        // reply must clear A's entry even while B (or nothing) is showing.
        let replyDocument: NativePeerWorkspace.Document? = switch message {
        case .fileDiffResult(_, let path, let stage, _, _, _), .fileDiffFailed(_, let path, let stage, _, _):
            .diff(path: path, stage: stage.flatMap(ChangeStage.init(rawValue:)))
        case .commitDiffResult(_, let sha, let path, _, _, _), .commitDiffFailed(_, let sha, let path, _, _):
            .commitDiff(path: path, sha: sha)
        case .fileContents(_, let path, _, _), .fileUnavailable(_, let path, _, _, _):
            .file(path: path)
        default: nil
        }
        if let replyDocument { documentRequestsInFlight.remove(replyDocument) }
        let isDocumentReply = replyDocument != nil && replyDocument == workspace.document
        let handled = workspace.apply(message)
        if isChangesReply, changesRequestOutdated {
            changesRequestOutdated = false
            requestChanges()
        }
        if isRootFileTreeReply, fileTreeRequestOutdated {
            fileTreeRequestOutdated = false
            loadFileTree()
        }
        if isDocumentReply, documentRequestOutdated, let document = workspace.document {
            documentRequestOutdated = false
            open(document)
        }
        if handled { return }
        let needsResubscribe = transcript?.apply(message) == true
        if needsResubscribe, let downstream,
           !federation.route(.subscribe(sessionId: selectedSessionId), from: downstream) {
            transcript?.resetResubscribeRequest()
        }
        let promptConfirmationRows: [RemoteWireMessage]
        switch message {
        case .transcriptSnapshot(_, _, _, let rows, _, _, let epoch, let revision, _)
            where transcript?.epoch == epoch && transcript?.revision == revision:
            promptConfirmationRows = rows
        case .transcriptDelta(_, _, _, let upserts, let epoch, let revision, _)
            where transcript?.epoch == epoch && transcript?.revision == revision:
            promptConfirmationRows = upserts
        default:
            promptConfirmationRows = []
        }
        if let pendingPrompt, let expectedIndex = pendingPromptExpectedIndex,
           promptConfirmationRows.contains(where: {
               $0.kind == "user" && $0.text == pendingPrompt && $0.index >= expectedIndex
           }) {
            if draft.trimmingCharacters(in: .whitespacesAndNewlines) == pendingPrompt { draft = "" }
            self.pendingPrompt = nil
            pendingPromptExpectedIndex = nil
        }
    }
}
