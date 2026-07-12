import Foundation

struct ACPPermissionDecisionLog: @unchecked Sendable {
    let persistence: ACPSessionPersistence
    /// Optional gate: when provided, `record` becomes a no-op if the
    /// closure returns `false`. Used by `ACPSessionRunner` to prevent
    /// writes to the `permission_decisions` table after another instance
    /// has seized the session lease.
    let canWrite: (() -> Bool)?
    let leaseFence: (() -> ACPSessionLeaseFence?)?

    init(
        store: ACPSessionStore,
        canWrite: (() -> Bool)? = nil,
        leaseFence: (() -> ACPSessionLeaseFence?)? = nil
    ) {
        self.persistence = ACPSessionPersistence(path: store.path)
        self.canWrite = canWrite
        self.leaseFence = leaseFence
    }

    init(
        persistence: ACPSessionPersistence,
        canWrite: (() -> Bool)? = nil,
        leaseFence: (() -> ACPSessionLeaseFence?)? = nil
    ) {
        self.persistence = persistence
        self.canWrite = canWrite
        self.leaseFence = leaseFence
    }

    func record(
        sessionId: String,
        scopeKey: String,
        decision: ACPPermissionDecision,
        scope: ACPPermissionScopeKind
    ) async throws {
        if let canWrite, !canWrite() { return }
        _ = try await persistence.recordPermissionDecision(
            sessionId: sessionId,
            scopeKey: scopeKey,
            decision: decision,
            scope: scope,
            fence: leaseFence?()
        )
    }

    /// Returns the matching decision for this session, prefer session-scoped
    /// then project-scoped (any session in this worktree).
    func lookup(sessionId: String, scopeKey: String) async throws -> ACPPermissionDecision? {
        try await persistence.lookupPermissionDecision(sessionId: sessionId, scopeKey: scopeKey)
    }
}
