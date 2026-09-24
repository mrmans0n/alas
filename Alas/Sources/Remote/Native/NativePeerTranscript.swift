import Foundation

/// The currently selected peer transcript. Frames are already namespaced by
/// federation, but this model still rejects frames for any other selection.
struct NativePeerTranscript {
    let sessionId: String

    private(set) var epoch: Int?
    private(set) var revision: Int?
    private var messagesByStableID: [String: RemoteWireMessage] = [:]
    private var driveAllowed = false

    private(set) var streamingState = "idle"
    private(set) var firstIndex = 0
    private(set) var totalCount = 0
    private(set) var isClosed = false
    private(set) var pendingPermission: RemotePermissionPayload?
    private(set) var pendingQuestion: RemoteQuestionPayload?
    private(set) var pendingPlan: RemotePlanPayload?
    private(set) var pendingElicitation: RemoteElicitationPayload?

    init(sessionId: String) { self.sessionId = sessionId }

    var canDrive: Bool { epoch != nil && driveAllowed && !isClosed }
    var olderPageBeforeIndex: Int? { firstIndex > 0 ? firstIndex : nil }
    var messages: [RemoteWireMessage] {
        messagesByStableID.values.sorted {
            if $0.index != $1.index { return $0.index < $1.index }
            return $0.stableId < $1.stableId
        }
    }

    mutating func markUnavailable() {
        isClosed = true
        driveAllowed = false
        clearPendingRequests()
    }

    mutating func apply(_ message: RemoteServerMessage) {
        guard message.sessionId == sessionId else { return }
        switch message {
        case .transcriptSnapshot(_, let state, let drive, let rows,
                                 let first, let total, let incomingEpoch, let incomingRevision):
            guard epoch == nil || incomingEpoch >= epoch! else { return }
            if epoch != incomingEpoch { clearPendingRequests() }
            epoch = incomingEpoch
            revision = incomingRevision
            streamingState = state
            driveAllowed = drive
            firstIndex = first
            totalCount = total
            isClosed = false
            messagesByStableID = Dictionary(rows.map { ($0.stableId, $0) }, uniquingKeysWith: { _, newer in newer })

        case .transcriptDelta(_, let state, let drive, let upserts, let incomingEpoch, let incomingRevision):
            guard let epoch, let revision,
                  incomingEpoch == epoch, incomingRevision == revision + 1,
                  !isClosed else { return }
            self.revision = incomingRevision
            streamingState = state
            driveAllowed = drive
            for row in upserts { messagesByStableID[row.stableId] = row }
            if let last = upserts.map(\.index).max() { totalCount = max(totalCount, last + 1) }

        case .transcriptPage(_, let incomingEpoch, let first, let rows):
            guard let epoch, incomingEpoch == epoch, first < firstIndex, !isClosed else { return }
            for row in rows where row.index < firstIndex {
                messagesByStableID[row.stableId] = row
            }
            firstIndex = first

        case .permissionRequest(_, let payload): pendingPermission = payload
        case .permissionResolved(_, let requestId):
            if pendingPermission?.requestId == requestId { pendingPermission = nil }
        case .questionRequest(_, let payload): pendingQuestion = payload
        case .questionResolved(_, let requestId):
            if pendingQuestion?.requestId == requestId { pendingQuestion = nil }
        case .planRequest(_, let payload): pendingPlan = payload
        case .planResolved(_, let requestId):
            if pendingPlan?.requestId == requestId { pendingPlan = nil }
        case .elicitationRequest(_, let payload): pendingElicitation = payload
        case .elicitationResolved(_, let requestId):
            if pendingElicitation?.requestId == requestId { pendingElicitation = nil }
        case .sessionClosed:
            markUnavailable()
        default: break
        }
    }

    private mutating func clearPendingRequests() {
        pendingPermission = nil
        pendingQuestion = nil
        pendingPlan = nil
        pendingElicitation = nil
    }
}
