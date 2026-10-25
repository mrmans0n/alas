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
