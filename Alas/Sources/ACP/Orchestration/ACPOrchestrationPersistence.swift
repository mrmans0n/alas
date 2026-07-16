import Foundation

actor ACPOrchestrationPersistence {
    nonisolated let path: String

    private let busyTimeoutMilliseconds: Int32
    private var store: ACPOrchestrationStore?

    init(path: String = Paths.acpOrchestrationDB.path, busyTimeoutMilliseconds: Int32 = 5_000) {
        self.path = path
        self.busyTimeoutMilliseconds = busyTimeoutMilliseconds
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

    func prepare() throws {
        _ = try openedStore()
    }

    func insert(_ record: ACPDelegationRecord) throws {
        try openedStore().insert(record)
    }

    func delegation(childSessionId: String) throws -> ACPDelegationRecord? {
        try openedStore().delegation(childSessionId: childSessionId)
    }

    func children(parentSessionId: String) throws -> [ACPDelegationRecord] {
        try openedStore().children(parentSessionId: parentSessionId)
    }

    func parent(childSessionId: String) throws -> ACPDelegationRecord? {
        try openedStore().parent(childSessionId: childSessionId)
    }

    func updatePhase(
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

    func updateChildWorktree(
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

    func clearPendingInitialPrompt(childSessionId: String, updatedAt: Int64) throws {
        try openedStore().clearPendingInitialPrompt(childSessionId: childSessionId, updatedAt: updatedAt)
    }

    func enqueue(_ message: ACPDelegatedMessage) throws {
        try openedStore().enqueue(message)
    }

    func pendingMessages(targetSessionId: String) throws -> [ACPDelegatedMessage] {
        try openedStore().pendingMessages(targetSessionId: targetSessionId)
    }

    func pendingMessageTargetSessionIds() throws -> [String] {
        try openedStore().pendingMessageTargetSessionIds()
    }

    func incompleteDelegations() throws -> [ACPDelegationRecord] {
        try openedStore().incompleteDelegations()
    }

    func claimMessage(
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

    func removeDeliveredMessage(id: String, claim: ACPDelegatedMessageClaim) throws {
        try openedStore().removeDeliveredMessage(id: id, claim: claim)
    }

    func releaseMessageClaim(id: String, claim: ACPDelegatedMessageClaim) throws {
        try openedStore().releaseMessageClaim(id: id, claim: claim)
    }
}
