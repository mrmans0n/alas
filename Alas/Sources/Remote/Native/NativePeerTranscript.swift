import Foundation

/// The currently selected peer transcript. Frames are already namespaced by
/// federation, but this model still rejects frames for any other selection.
struct NativePeerTranscript: Equatable {
    let sessionId: String

    private(set) var epoch: Int?
    private(set) var revision: Int?
    private var messagesByStableID: [String: RemoteWireMessage] = [:] {
        didSet { rebuildMessages() }
    }
    private var driveAllowed = false

    private(set) var streamingState = "idle"
    private(set) var hasCancellableBackgroundWork = false
    private(set) var firstIndex = 0
    private(set) var totalCount = 0
    private(set) var isClosed = false
    private(set) var needsResubscribe = false
    private(set) var pendingPermission: RemotePermissionPayload?
    private(set) var pendingQuestion: RemoteQuestionPayload?
    private(set) var pendingPlan: RemotePlanPayload?
    private(set) var pendingElicitation: RemoteElicitationPayload?
    private(set) var config: RemoteSessionConfig?
    private(set) var queue: [RemoteQueuedPrompt] = []
    /// One counter per request kind, bumped when a request frame carries a
    /// request that is not the one already pending for that kind. Wire
    /// request ids can repeat back to back (string JSON-RPC ids all forward
    /// as the same int), so views key their per-request state on this
    /// instead of the id alone. A resubscribe replaying the identical
    /// outstanding request, or an unrelated kind arriving alongside, leaves
    /// a counter untouched so the user's half-filled form survives.
    private var requestGenerations: [PendingRequestKind: Int] = [:]

    enum PendingRequestKind: Hashable {
        case permission, question, plan, elicitation
    }

    func requestGeneration(for kind: PendingRequestKind) -> Int {
        requestGenerations[kind] ?? 0
    }

    init(sessionId: String) { self.sessionId = sessionId }

    var canDrive: Bool { epoch != nil && driveAllowed && !isClosed }
    var olderPageBeforeIndex: Int? { firstIndex > 0 ? firstIndex : nil }
    /// Rows in transcript order, rebuilt only when a frame changes them so
    /// the view never re-sorts on read.
    private(set) var messages: [RemoteWireMessage] = []
    /// Bumped whenever `messages` changes; a cheap memo key for anything
    /// derived from the row list.
    private(set) var messagesGeneration: UInt64 = 0

    mutating func markUnavailable() {
        isClosed = true
        driveAllowed = false
        clearPendingRequests()
    }

    @discardableResult
    mutating func apply(_ message: RemoteServerMessage) -> Bool {
        guard message.sessionId == sessionId else { return false }
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

    /// Reflects a chip change locally until the host's next `sessionConfig`
    /// frame overwrites it.
    mutating func applyOptimistic(_ spec: ChipSpec, itemId: String) {
        guard var config else { return }
        switch spec.source {
        case .model:
            config.currentModel = itemId
            config.chips?.model?.currentId = itemId
        case .mode:
            config.currentMode = itemId
            config.chips?.mode?.currentId = itemId
        case .configOption(let id):
            if config.chips?.model?.configId == id { config.chips?.model?.currentId = itemId }
            if config.chips?.thinking?.configId == id { config.chips?.thinking?.currentId = itemId }
            if config.chips?.mode?.configId == id { config.chips?.mode?.currentId = itemId }
            if let chips = config.chips {
                for index in chips.parameters.indices where chips.parameters[index].chip.configId == id {
                    config.chips?.parameters[index].chip.currentId = itemId
                }
            }
        }
        self.config = config
    }

    mutating func applyOptimistic(configId: String, value: Bool) {
        guard var config, let chips = config.chips else { return }
        for index in chips.booleans.indices where chips.booleans[index].id == configId {
            config.chips?.booleans[index].value = value
        }
        self.config = config
    }

    mutating func applyOptimisticAutoRun(_ enabled: Bool) {
        config?.autoRunEnabled = enabled
    }

    mutating func resetResubscribeRequest() {
        needsResubscribe = false
    }

    private mutating func rebuildMessages() {
        messages = messagesByStableID.values.filter { $0.isHidden != true }.sorted {
            if $0.index != $1.index { return $0.index < $1.index }
            return $0.stableId < $1.stableId
        }
        messagesGeneration &+= 1
    }

    private mutating func clearPendingRequests() {
        pendingPermission = nil
        pendingQuestion = nil
        pendingPlan = nil
        pendingElicitation = nil
    }
}
