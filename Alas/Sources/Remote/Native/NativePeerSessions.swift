import Foundation
import Observation

/// Native, app-scoped consumer of the existing federated session feed.
@MainActor @Observable
final class NativePeerSessions {
    private let federation: FederatedSessionsProvider
    private let peers: @MainActor () -> [RemoteHelloPeer]
    @ObservationIgnored private var downstream: FederatedDownstream?
    private(set) var pendingPrompt: String?
    @ObservationIgnored private var knownUserMessageIDs: Set<String> = []

    private(set) var snapshot = NativePeerSidebarSnapshot(groups: [], attentionRows: [])
    private(set) var selectedSessionId: String?
    private(set) var transcript: NativePeerTranscript?
    var draft = ""
    private(set) var deliveryError: String?

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
        knownUserMessageIDs = []
        deliveryError = nil
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
        } else if transcript?.isClosed == true, let selectedSessionId, let downstream {
            // The provider discarded subscriptions when this peer went away.
            // Its new transcript may also have a lower epoch after a restart.
            transcript = NativePeerTranscript(sessionId: selectedSessionId)
            pendingPrompt = nil
            knownUserMessageIDs = []
            _ = federation.route(.subscribe(sessionId: selectedSessionId), from: downstream)
        }
    }

    func select(_ sessionId: String) {
        guard let downstream,
              snapshot.groups.contains(where: { group in
                  group.state.carriesSessions && group.sessions.contains { $0.id == sessionId }
              }) else { return }
        if selectedSessionId == sessionId {
            refresh()
            return
        }
        clearSelection()
        selectedSessionId = sessionId
        transcript = NativePeerTranscript(sessionId: sessionId)
        _ = federation.route(.subscribe(sessionId: sessionId), from: downstream)
    }

    func clearSelection() {
        if let selectedSessionId, let downstream {
            _ = federation.route(.unsubscribe(sessionId: selectedSessionId), from: downstream)
        }
        selectedSessionId = nil
        transcript = nil
        draft = ""
        pendingPrompt = nil
        knownUserMessageIDs = []
        deliveryError = nil
    }

    func sendPrompt() {
        guard pendingPrompt == nil,
              let selectedSessionId, let downstream, selectedPeer?.state.carriesSessions == true,
              transcript?.canDrive == true else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        knownUserMessageIDs = Set(transcript?.messages.filter { $0.kind == "user" }.map(\.stableId) ?? [])
        if federation.route(.sendPrompt(sessionId: selectedSessionId, text: text,
                                        attachments: [], intent: "auto"), from: downstream) {
            pendingPrompt = text
            deliveryError = nil
        } else {
            deliveryError = "Peer is unavailable. Your draft was kept."
        }
    }

    func stopSelected() { routeWhileOnline { .stop(sessionId: $0) } }
    func takeOver() { routeWhileOnline { .takeOver(sessionId: $0) } }

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

    private func routeWhileOnline(_ makeMessage: (String) -> RemoteClientMessage) {
        guard let selectedSessionId, let downstream,
              selectedPeer?.state.carriesSessions == true else { return }
        _ = federation.route(makeMessage(selectedSessionId), from: downstream)
    }

    private func receive(_ message: RemoteServerMessage) {
        guard let selectedSessionId, message.sessionId == selectedSessionId else { return }
        if case .promptRejected = message {
            pendingPrompt = nil
            deliveryError = "Prompt was not delivered. Your draft was kept."
            return
        }
        transcript?.apply(message)
        if let pendingPrompt,
           let confirmed = transcript?.messages.first(where: {
               $0.kind == "user" && $0.text == pendingPrompt && !knownUserMessageIDs.contains($0.stableId)
           }), confirmed.text != nil {
            if draft.trimmingCharacters(in: .whitespacesAndNewlines) == pendingPrompt { draft = "" }
            self.pendingPrompt = nil
            knownUserMessageIDs = []
        }
    }
}
