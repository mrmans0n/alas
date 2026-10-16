import Foundation

/// A position in one session's transcript, from its `ACPTranscriptChangeLog`.
/// Deltas after a revision describe every change since it, as long as the
/// epoch is the same: a new epoch means the transcript was rebuilt.
public struct TranscriptRevision: Codable, Hashable, Sendable {
    public var epoch: Int
    public var version: Int

    public init(epoch: Int, version: Int) {
        self.epoch = epoch
        self.version = version
    }
}

/// One transcript message, encoded as the session store keeps it.
public struct HostTranscriptMessage: Codable, Equatable, Sendable {
    /// Its position in the transcript.
    public var index: Int
    public var stableID: String
    /// The store's kind: `user`, `agent`, `thought`, `tool_call`, `file_edit`,
    /// `plan`, `system` or `visual_aid`.
    public var kind: String
    /// The store's JSON payload for `kind`.
    public var payload: String
}

/// What changed in a followed transcript since the last delta.
public struct HostTranscriptDelta: Codable, Equatable, Sendable {
    /// Where this delta leaves the transcript; follow from it to resume.
    public var revision: TranscriptRevision
    /// Whether `messages` replaces everything held before: the newest
    /// messages of the transcript, from `messages.first?.index`. Otherwise
    /// `messages` are the ones that changed, by index.
    public var reset: Bool
    public var messages: [HostTranscriptMessage]
    public var messageCount: Int
    public var streamingState: ACPSession.StreamingState
}

/// A request from the agent waiting on a person. Each kind is answered by
/// the matching `SessionsAPI` verb with the same id.
public enum HostPendingRequest: Codable, Equatable, Sendable {
    case permission(requestID: JSONRPCID, params: ACPPermissionRequestParams)
    case question(requestID: JSONRPCID, params: ACPQuestionRequestParams)
    case plan(requestID: JSONRPCID, params: ACPCursorCreatePlanParams)
    case userInput(requestID: UUID, params: ACPElicitationRequestParams)

    public var id: HostPendingRequestID {
        switch self {
        case .permission(let id, _): .permission(id)
        case .question(let id, _): .question(id)
        case .plan(let id, _): .plan(id)
        case .userInput(let id, _): .userInput(id)
        }
    }
}

public enum HostPendingRequestID: Codable, Hashable, Sendable {
    case permission(JSONRPCID)
    case question(JSONRPCID)
    case plan(JSONRPCID)
    case userInput(UUID)
}

/// A session a subscription follows, and what it has sent of it. Following
/// keeps the session loaded, as an open tab does, and retains its
/// transcript's change log; `release()` lets both go.
@MainActor
final class FollowedSession {
    let owner: SessionOwnerID
    let id: String
    private let transcript: ACPTranscript
    private weak var session: ACPSession?
    private weak var manager: ACPSessionManager?
    private var signals: [ChangeSubscription] = []
    private var sent: TranscriptRevision?
    private var sentState: ACPSession.StreamingState?
    private var sentRequests: [HostPendingRequestID: HostPendingRequest] = [:]
    private(set) var isDirty = true

    init(owner: SessionOwnerID, session: ACPSession, manager: ACPSessionManager, from revision: TranscriptRevision?, changed: @escaping () -> Void) {
        self.owner = owner
        id = session.id
        transcript = session.transcript
        self.session = session
        self.manager = manager
        sent = revision
        manager.retainSession(id: id)
        transcript.changeLog.retainTracking()
        let mark: () -> Void = { [weak self] in
            self?.isDirty = true
            changed()
        }
        signals = [transcript.willChange.observe(mark), transcript.streamingTicks.observe(mark)]
    }

    func release() {
        signals.forEach { $0.cancel() }
        signals.removeAll()
        transcript.changeLog.releaseTracking()
        manager?.releaseSession(id: id)
    }

    /// The transcript delta and request changes since the last call.
    func events() -> [HostEvent] {
        isDirty = false
        var events: [HostEvent] = []
        let log = transcript.changeLog
        let messages = transcript.messages
        let current = TranscriptRevision(epoch: log.epoch, version: log.latestVersion)
        var changed: [Int]?
        if let sent, sent.epoch == log.epoch, sent.version <= log.latestVersion {
            switch log.changes(since: sent.version) {
            case .none: changed = []
            case .dirty(let indices): changed = indices.filter { messages.indices.contains($0) }
            case .resync: changed = nil
            }
        }
        let indices = changed ?? Array(max(0, messages.count - ACPTranscript.maxVisibleRows)..<messages.count)
        let state = transcript.streamingState
        if changed == nil || !indices.isEmpty || state != sentState {
            events.append(.transcript(owner: owner, id: id, delta: HostTranscriptDelta(
                revision: current,
                reset: changed == nil,
                messages: indices.compactMap { Self.message(messages[$0], at: $0) },
                messageCount: messages.count,
                streamingState: state
            )))
        }
        sent = current
        sentState = state

        let requests = pendingRequests()
        for (key, request) in requests where sentRequests[key] != request {
            events.append(.pendingRequest(owner: owner, id: id, request: request))
        }
        for key in sentRequests.keys where requests[key] == nil {
            events.append(.pendingRequestResolved(owner: owner, id: id, requestID: key))
        }
        sentRequests = requests
        return events
    }

    /// The requests a person can answer now, under the ids the verbs take.
    private func pendingRequests() -> [HostPendingRequestID: HostPendingRequest] {
        var requests: [HostPendingRequest] = []
        if let pending = transcript.pendingPermission,
           let requestID = manager?.permissionPolicy(for: id)?.pendingPermissionRequestID {
            requests.append(.permission(requestID: requestID, params: pending.params))
        }
        if let session, let question = ACPRequestAnswers.pendingQuestion(in: session) {
            requests.append(.question(requestID: question.id, params: question.params))
        }
        if let plan = transcript.pendingPlan {
            requests.append(.plan(requestID: plan.id, params: plan.params))
        }
        if let input = transcript.pendingUserInputs.first, case .elicitation(_, let params) = input.source {
            requests.append(.userInput(requestID: input.id, params: params))
        }
        return Dictionary(requests.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    private static func message(_ message: ACPMessage, at index: Int) -> HostTranscriptMessage? {
        guard let payload = try? ACPMessageCodec.encode(message) else { return nil }
        return HostTranscriptMessage(index: index, stableID: message.stableId, kind: message.kind, payload: String(decoding: payload, as: UTF8.self))
    }
}
