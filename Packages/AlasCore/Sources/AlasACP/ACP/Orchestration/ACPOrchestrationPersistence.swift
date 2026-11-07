import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

public actor ACPOrchestrationPersistence {
    public nonisolated let path: String

    private let busyTimeoutMilliseconds: Int32
    private var store: ACPOrchestrationStore?
    /// Off the cooperative pool: SQLite blocks its thread for every statement.
    private nonisolated let queue: DispatchSerialQueue
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    public init(path: String = Paths.acpOrchestrationDB.path, busyTimeoutMilliseconds: Int32 = 5_000) {
        self.path = path
        self.busyTimeoutMilliseconds = busyTimeoutMilliseconds
        queue = DispatchSerialQueue(label: "io.nlopez.alas.acp-orchestration \(path)")
    }

    private func openedStore() throws -> ACPOrchestrationStore {
        if let store { return store }
        let opened = try ACPOrchestrationStore(
            path: path,
            busyTimeoutMilliseconds: busyTimeoutMilliseconds
        )
        store = opened
        return opened
    }

    public func prepare() throws {
        _ = try openedStore()
    }

    public func insert(_ record: ACPDelegationRecord) throws {
        try openedStore().insert(record)
    }

    public func delegation(childSessionId: String) throws -> ACPDelegationRecord? {
        try openedStore().delegation(childSessionId: childSessionId)
    }

    public func children(parentSessionId: String) throws -> [ACPDelegationRecord] {
        try openedStore().children(parentSessionId: parentSessionId)
    }

    public func parent(childSessionId: String) throws -> ACPDelegationRecord? {
        try openedStore().parent(childSessionId: childSessionId)
    }

    public func delegationParents() throws -> [String: String] {
        try openedStore().delegationParents()
    }

    @discardableResult
    public func markReadyIfStarting(childSessionId: String, updatedAt: Int64) throws -> Bool {
        try openedStore().markReadyIfStarting(childSessionId: childSessionId, updatedAt: updatedAt)
    }

    public func updatePhase(
        childSessionId: String,
        phase: ACPDelegationPhase,
        failureMessage: String?,
        updatedAt: Int64
    ) throws {
        try openedStore().updatePhase(
            childSessionId: childSessionId,
            phase: phase,
            failureMessage: failureMessage,
            updatedAt: updatedAt
        )
    }

    public func claimFailedPhase(
        childSessionId: String,
        failureMessage: String,
        updatedAt: Int64,
        outcome: ACPDelegatedMessage,
        discardingHeldMessages: Bool = false
    ) throws -> Bool {
        try openedStore().claimFailedPhase(
            childSessionId: childSessionId,
            failureMessage: failureMessage,
            updatedAt: updatedAt,
            outcome: outcome,
            discardingHeldMessages: discardingHeldMessages
        )
    }

    public func updateChildWorktree(
        childSessionId: String,
        worktreeId: String,
        phase: ACPDelegationPhase,
        updatedAt: Int64
    ) throws {
        try openedStore().updateChildWorktree(
            childSessionId: childSessionId,
            worktreeId: worktreeId,
            phase: phase,
            updatedAt: updatedAt
        )
    }

    public func updateWorktreeRequest(
        childSessionId: String,
        request: ACPDelegatedWorktreeRequest,
        updatedAt: Int64
    ) throws {
        try openedStore().updateWorktreeRequest(childSessionId: childSessionId, request: request, updatedAt: updatedAt)
    }

    public func clearPendingInitialPrompt(childSessionId: String, updatedAt: Int64) throws {
        try openedStore().clearPendingInitialPrompt(childSessionId: childSessionId, updatedAt: updatedAt)
    }

    public func markParentReport(childSessionId: String, at reportedAt: Int64) throws {
        try openedStore().markParentReport(childSessionId: childSessionId, at: reportedAt)
    }

    public func enqueue(_ message: ACPDelegatedMessage) throws {
        try openedStore().enqueue(message)
    }

    public func enqueueUnlessTargetEnded(_ message: ACPDelegatedMessage) throws -> Bool {
        try openedStore().enqueueUnlessTargetEnded(message)
    }

    public func pendingMessages(targetSessionId: String) throws -> [ACPDelegatedMessage] {
        try openedStore().pendingMessages(targetSessionId: targetSessionId)
    }

    public func pendingMessageTargetSessionIds() throws -> [String] {
        try openedStore().pendingMessageTargetSessionIds()
    }

    public func outbox(
        peerServerId: String,
        after: Int64,
        maxBytes: Int
    ) throws -> (entries: [ACPPeerOutboxEntry], hasMore: Bool) {
        try openedStore().outbox(peerServerId: peerServerId, after: after, maxBytes: maxBytes)
    }

    public func acknowledgeOutbox(peerServerId: String, through: Int64) throws {
        try openedStore().acknowledgeOutbox(peerServerId: peerServerId, through: through)
    }

    public func deleteOutbox(peerServerId: String) throws {
        try openedStore().deleteOutbox(peerServerId: peerServerId)
    }

    public func collectPeerEntry(
        _ entry: ACPPeerOutboxEntry,
        peerServerId: String,
        parentSessionId: String,
        store: String?
    ) throws -> Bool {
        try openedStore().collectPeerEntry(entry, peerServerId: peerServerId, parentSessionId: parentSessionId, store: store)
    }

    @discardableResult
    public func advancePeerCursor(
        peerServerId: String, to seq: Int64, store: String?, settling entry: ACPPeerOutboxEntry? = nil
    ) throws -> Bool {
        try openedStore().advancePeerCursor(peerServerId: peerServerId, to: seq, store: store, settling: entry)
    }

    public func claimLostPeerTurn(childSessionId: String, awaitingSince: Int64?, outcome: ACPDelegatedMessage) throws -> Bool {
        try openedStore().claimLostPeerTurn(childSessionId: childSessionId, awaitingSince: awaitingSince, outcome: outcome)
    }

    public func markPeerAwaiting(childSessionId: String, since: Int64) throws {
        try openedStore().markPeerAwaiting(childSessionId: childSessionId, since: since)
    }

    public func storeIdentity() throws -> String {
        try openedStore().storeIdentity()
    }

    public func peerPosition(peerServerId: String) throws -> ACPPeerCursorPosition {
        try openedStore().peerPosition(peerServerId: peerServerId)
    }

    @discardableResult
    public func adoptPeerStore(peerServerId: String, storeId: String) throws -> Bool {
        try openedStore().adoptPeerStore(peerServerId: peerServerId, storeId: storeId)
    }

    public func peerCursor(peerServerId: String) throws -> Int64 {
        try openedStore().peerCursor(peerServerId: peerServerId)
    }

    public func peerChildren(peerServerId: String) throws -> [ACPDelegationRecord] {
        try openedStore().peerChildren(peerServerId: peerServerId)
    }

    public func incompleteDelegations() throws -> [ACPDelegationRecord] {
        try openedStore().incompleteDelegations()
    }

    public func readyDelegations() throws -> [ACPDelegationRecord] {
        try openedStore().readyDelegations()
    }

    public func claimMessage(
        id: String,
        instanceId: String,
        token: String,
        now: Int64,
        staleAfter: Int64
    ) throws -> ACPClaimedDelegatedMessage? {
        try openedStore().claimMessage(
            id: id,
            instanceId: instanceId,
            token: token,
            now: now,
            staleAfter: staleAfter
        )
    }

    public func removeDeliveredMessage(id: String, claim: ACPDelegatedMessageClaim) throws {
        try openedStore().removeDeliveredMessage(id: id, claim: claim)
    }

    public func releaseMessageClaim(id: String, claim: ACPDelegatedMessageClaim) throws {
        try openedStore().releaseMessageClaim(id: id, claim: claim)
    }
}
