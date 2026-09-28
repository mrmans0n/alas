import Foundation
import Observation

/// Native, app-scoped consumer of the existing federated session feed.
@MainActor @Observable
final class NativePeerSessions {
    private let federation: FederatedSessionsProvider
    private let peers: @MainActor () -> [RemoteHelloPeer]
    @ObservationIgnored private var downstream: FederatedDownstream?
    @ObservationIgnored private var pendingPromptExpectedIndex: Int?
    private(set) var pendingPrompt: String?

    private(set) var snapshot = NativePeerSidebarSnapshot(groups: [], attentionRows: [])
    private(set) var selectedSessionId: String?
    private(set) var transcript: NativePeerTranscript?
    var draft = ""
    private(set) var deliveryError: String?
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

    init(federation: FederatedSessionsProvider,
         peers: @escaping @MainActor () -> [RemoteHelloPeer]) {
        self.federation = federation
        self.peers = peers
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
        selectedSessionId = nil
        transcript = nil
        snapshot = .init(groups: [], attentionRows: [])
        draft = ""
        pendingPrompt = nil
        pendingPromptExpectedIndex = nil
        deliveryError = nil
        workspace = NativePeerWorkspace()
        workspaceSummary = nil
        fileTreeRequestOutdated = false
        changesRequestInFlight = false
        changesRequestOutdated = false
        fileTreeRequestInFlight = false
    }

    func refresh() {
        guard downstream != nil else { return }
        snapshot = .build(peers: peers(), rows: federation.peerSessionSummaries, enabled: true)
        guard selectedSessionId != nil else { return }
        guard let group = selectedPeer else {
            clearSelection()
            return
        }
        if !group.state.carriesSessions || selectedRow == nil {
            transcript?.markUnavailable()
            workspace.markUnavailable()
        } else if transcript?.isClosed == true, let selectedSessionId, let downstream {
            // The provider discarded subscriptions when this peer went away.
            // Its new transcript may also have a lower epoch after a restart.
            transcript = NativePeerTranscript(sessionId: selectedSessionId)
            pendingPrompt = nil
            pendingPromptExpectedIndex = nil
            _ = federation.route(.subscribe(sessionId: selectedSessionId), from: downstream)
            workspace = NativePeerWorkspace()
            // Whatever was in flight before the peer went away will never
            // get a reply now — without this, reloadWorkspace() below would
            // find both still "in flight" and gate its own fresh requests.
            changesRequestInFlight = false
            changesRequestOutdated = false
            fileTreeRequestInFlight = false
            fileTreeRequestOutdated = false
            reloadWorkspace()
        } else if selectedRow?.worktree != workspaceSummary {
            // A request already in flight for either skips its send; queue a
            // retry so the eventual (now-stale) reply doesn't stand in as
            // current — the peer silently drops a duplicate in-flight request.
            if !requestChanges() { changesRequestOutdated = true }
            // The summary only signals that the peer's worktree changed, not
            // which files — a rename or delete only shows up by re-listing.
            if !loadFileTree() { fileTreeRequestOutdated = true }
        }
    }

    func select(_ sessionId: String) {
        guard let downstream,
              snapshot.groups.contains(where: { group in
                  group.state.carriesSessions && group.sessions.contains { $0.id == sessionId }
              }) else { return }
        if selectedSessionId == sessionId {
            workspace.closeDocument()
            refresh()
            return
        }
        clearSelection()
        selectedSessionId = sessionId
        transcript = NativePeerTranscript(sessionId: sessionId)
        _ = federation.route(.subscribe(sessionId: sessionId), from: downstream)
        reloadWorkspace()
    }

    func clearSelection() {
        if let selectedSessionId, let downstream {
            _ = federation.route(.unsubscribe(sessionId: selectedSessionId), from: downstream)
        }
        selectedSessionId = nil
        transcript = nil
        draft = ""
        pendingPrompt = nil
        pendingPromptExpectedIndex = nil
        deliveryError = nil
        workspace = NativePeerWorkspace()
        workspaceSummary = nil
        fileTreeRequestOutdated = false
        changesRequestInFlight = false
        changesRequestOutdated = false
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

    /// Re-asks the peer for the selected session's changes and file tree.
    /// Replies land through `receive`.
    func reloadWorkspace() {
        requestChanges()
        loadFileTree()
    }

    @discardableResult
    func requestChanges() -> Bool {
        guard selectedSessionId != nil else { return false }
        workspaceSummary = selectedRow?.worktree
        guard !changesRequestInFlight else { return false }
        changesRequestInFlight = true
        workspace.beginChangesLoad()
        if !routeWhileOnline({ .listChanges(sessionId: $0) }) {
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
        if !routeWhileOnline({ .listFiles(sessionId: $0, path: nil) }) {
            fileTreeRequestInFlight = false
            workspace.markUnavailable()
            return false
        }
        return true
    }

    func loadFileTreeChildren(path: String) {
        guard selectedSessionId != nil, workspace.beginChildrenLoad(path: path) else { return }
        if !routeWhileOnline({ .listFiles(sessionId: $0, path: path) }) { workspace.markUnavailable() }
    }

    func open(_ document: NativePeerWorkspace.Document) {
        guard selectedSessionId != nil else { return }
        workspace.beginDocument(document)
        let sent = switch document {
        case .diff(let path, let stage):
            routeWhileOnline { .fileDiff(sessionId: $0, path: path, stage: stage?.rawValue) }
        case .file(let path):
            routeWhileOnline { .readFile(sessionId: $0, path: path) }
        }
        if !sent { workspace.markUnavailable() }
    }

    func closeDocument() {
        workspace.closeDocument()
    }

    func fetchOlder() {
        guard let before = transcript?.olderPageBeforeIndex else { return }
        routeWhileOnline { .fetchOlder(sessionId: $0, beforeIndex: before,
                                      limit: RemoteTranscriptSync.tailWindow) }
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
        guard let selectedSessionId, message.sessionId == selectedSessionId else { return }
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
        let handled = workspace.apply(message)
        if isChangesReply, changesRequestOutdated {
            changesRequestOutdated = false
            requestChanges()
        }
        if isRootFileTreeReply, fileTreeRequestOutdated {
            fileTreeRequestOutdated = false
            loadFileTree()
        }
        if handled { return }
        let needsResubscribe = transcript?.apply(message) == true
        if needsResubscribe, let downstream,
           !federation.route(.subscribe(sessionId: selectedSessionId), from: downstream) {
            transcript?.resetResubscribeRequest()
        }
        let promptConfirmationRows: [RemoteWireMessage]
        switch message {
        case .transcriptSnapshot(_, _, _, let rows, _, _, let epoch, let revision)
            where transcript?.epoch == epoch && transcript?.revision == revision:
            promptConfirmationRows = rows
        case .transcriptDelta(_, _, _, let upserts, let epoch, let revision)
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
