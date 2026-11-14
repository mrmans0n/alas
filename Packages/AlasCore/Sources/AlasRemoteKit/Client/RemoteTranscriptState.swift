import Foundation

/// The currently selected peer transcript. Frames are already namespaced by
/// federation, but this model still rejects frames for any other selection.
public struct RemoteTranscriptState<ServerHost: Codable & Equatable & Sendable, ClientHost: Codable & Equatable & Sendable>: Equatable {
    public let sessionId: String

    public private(set) var epoch: Int?
    public private(set) var revision: Int?
    private var messagesByStableID: [String: RemoteWireMessage] = [:] {
        didSet { rebuildMessages() }
    }
    private var driveAllowed = false

    public private(set) var streamingState = "idle"
    public private(set) var hasCancellableBackgroundWork = false
    public private(set) var firstIndex = 0
    public private(set) var totalCount = 0
    public private(set) var isClosed = false
    public private(set) var needsResubscribe = false
    public private(set) var pendingPermission: RemotePermissionPayload?
    public private(set) var pendingQuestion: RemoteQuestionPayload?
    public private(set) var pendingPlan: RemotePlanPayload?
    public private(set) var pendingElicitation: RemoteElicitationPayload?
    public private(set) var config: RemoteSessionConfig?
    public private(set) var queue: [RemoteQueuedPrompt] = []
    /// One counter per request kind, bumped when a request frame carries a
    /// request that is not the one already pending for that kind. Wire
    /// request ids can repeat back to back (string JSON-RPC ids all forward
    /// as the same int), so views key their per-request state on this
    /// instead of the id alone. A resubscribe replaying the identical
    /// outstanding request, or an unrelated kind arriving alongside, leaves
    /// a counter untouched so the user's half-filled form survives.
    private var requestGenerations: [PendingRequestKind: Int] = [:]

    public enum PendingRequestKind: Hashable {
        case permission, question, plan, elicitation
    }

    public func requestGeneration(for kind: PendingRequestKind) -> Int {
        requestGenerations[kind] ?? 0
    }

    public init(sessionId: String) { self.sessionId = sessionId }

    public var canDrive: Bool { epoch != nil && driveAllowed && !isClosed }
    public var olderPageBeforeIndex: Int? { firstIndex > 0 ? firstIndex : nil }
    /// Rows in transcript order, rebuilt only when a frame changes them so
    /// the view never re-sorts on read.
    public private(set) var messages: [RemoteWireMessage] = []
    /// Bumped whenever `messages` changes; a cheap memo key for anything
    /// derived from the row list.
    public private(set) var messagesGeneration: UInt64 = 0

    public mutating func markUnavailable() {
        isClosed = true
        driveAllowed = false
        clearPendingRequests()
    }

    @discardableResult
    public mutating func apply(_ message: RemoteServerMessageOf<ServerHost, ClientHost>) -> Bool {
        guard message.transcriptSessionId == sessionId else { return false }
        switch message {
        case .transcriptSnapshot(_, let state, let drive, let rows,
                                 let first, let total, let incomingEpoch, let incomingRevision, let backgroundWork):
            guard epoch == nil || incomingEpoch >= epoch! else { return false }
            epoch = incomingEpoch
            revision = incomingRevision
            streamingState = state
            hasCancellableBackgroundWork = backgroundWork
            driveAllowed = drive
            firstIndex = first
            totalCount = total
            isClosed = false
            needsResubscribe = false
            messagesByStableID = Dictionary(rows.map { ($0.stableId, $0) }, uniquingKeysWith: { _, newer in newer })
            return false

        case .transcriptDelta(_, let state, let drive, let upserts, let incomingEpoch, let incomingRevision, let backgroundWork):
            guard !isClosed else { return false }
            guard let epoch, let revision,
                  incomingEpoch == epoch, incomingRevision == revision + 1 else {
                guard !needsResubscribe else { return false }
                needsResubscribe = true
                driveAllowed = false
                return true
            }
            self.revision = incomingRevision
            streamingState = state
            hasCancellableBackgroundWork = backgroundWork
            driveAllowed = drive
            needsResubscribe = false
            if !upserts.isEmpty {
                // One assignment, so the sorted list rebuilds once per frame.
                var updated = messagesByStableID
                for row in upserts { updated[row.stableId] = row }
                messagesByStableID = updated
            }
            if let last = upserts.map(\.index).max() { totalCount = max(totalCount, last + 1) }
            return false

        case .transcriptPage(_, let incomingEpoch, let first, let rows):
            guard let epoch, incomingEpoch == epoch, first < firstIndex, !isClosed else { return false }
            var updated = messagesByStableID
            for row in rows where row.index < firstIndex {
                if let current = updated[row.stableId], current.index >= row.index { continue }
                updated[row.stableId] = row
            }
            messagesByStableID = updated
            firstIndex = first
            return false

        case .permissionRequest(_, let payload):
            if pendingPermission != payload { requestGenerations[.permission, default: 0] += 1 }
            pendingPermission = payload
        case .permissionResolved(_, let requestId):
            if pendingPermission?.requestId == requestId { pendingPermission = nil }
        case .questionRequest(_, let payload):
            if pendingQuestion != payload { requestGenerations[.question, default: 0] += 1 }
            pendingQuestion = payload
        case .questionResolved(_, let requestId):
            if pendingQuestion?.requestId == requestId { pendingQuestion = nil }
        case .planRequest(_, let payload):
            if pendingPlan != payload { requestGenerations[.plan, default: 0] += 1 }
            pendingPlan = payload
        case .planResolved(_, let requestId):
            if pendingPlan?.requestId == requestId { pendingPlan = nil }
        case .elicitationRequest(_, let payload):
            if pendingElicitation != payload { requestGenerations[.elicitation, default: 0] += 1 }
            pendingElicitation = payload
        case .elicitationResolved(_, let requestId):
            if pendingElicitation?.requestId == requestId { pendingElicitation = nil }
        case .sessionConfig(let incoming):
            config = incoming
        case .queueState(_, let items):
            queue = items
        case .sessionClosed:
            markUnavailable()
        default: break
        }
        return false
    }

    public mutating func applyOptimistic(configId: String, value: Bool) {
        guard var config, let chips = config.chips else { return }
        for index in chips.booleans.indices where chips.booleans[index].id == configId {
            config.chips?.booleans[index].value = value
        }
        self.config = config
    }

    public mutating func applyOptimisticAutoRun(_ enabled: Bool) {
        config?.autoRunEnabled = enabled
    }

    public mutating func updateConfig(_ transform: (inout RemoteSessionConfig) -> Void) {
        guard var config else { return }
        transform(&config)
        self.config = config
    }

    public mutating func resetResubscribeRequest() {
        needsResubscribe = false
    }

    private mutating func rebuildMessages() {
        messages = messagesByStableID.values.filter { $0.isHidden != true }.sorted {
            if $0.index != $1.index { return $0.index < $1.index }
            return $0.stableId < $1.stableId
        }
        messagesGeneration &+= 1
    }

    /// The host re-sends only the requests still outstanding when a client subscribes, so a
    /// client drops what it holds before subscribing again.
    public mutating func clearPendingRequests() {
        pendingPermission = nil
        pendingQuestion = nil
        pendingPlan = nil
        pendingElicitation = nil
    }
}

private extension RemoteServerMessageOf {
    /// The session a frame belongs to, for the frames the transcript state
    /// reacts to; every other frame is irrelevant to it and reports nil.
    var transcriptSessionId: String? {
        switch self {
        case .transcriptSnapshot(let id, _, _, _, _, _, _, _, _), .transcriptDelta(let id, _, _, _, _, _, _),
             .transcriptPage(let id, _, _, _), .permissionRequest(let id, _), .permissionResolved(let id, _),
             .questionRequest(let id, _), .questionResolved(let id, _), .planRequest(let id, _),
             .planResolved(let id, _), .elicitationRequest(let id, _), .elicitationResolved(let id, _),
             .queueState(let id, _), .sessionClosed(let id):
            return id
        case .sessionConfig(let config):
            return config.sessionId
        default:
            return nil
        }
    }
}
