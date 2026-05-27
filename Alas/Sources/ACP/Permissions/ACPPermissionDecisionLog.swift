import Foundation

struct ACPPermissionDecisionLog {
    let store: ACPSessionStore

    func record(sessionId: String, scopeKey: String, decision: ACPPermissionDecision, scope: ACPPermissionScopeKind) throws {
        let now = Int64(Date().timeIntervalSince1970)
        try store.db.exec("""
        INSERT INTO permission_decisions (session_id, scope_key, decision, scope, decided_at)
        VALUES (?,?,?,?,?)
        ON CONFLICT(session_id, scope_key) DO UPDATE SET
            decision = excluded.decision,
            scope = excluded.scope,
            decided_at = excluded.decided_at
        """, bindings: [sessionId, scopeKey, decision.rawValue, scope.rawValue, now])
    }

    /// Returns the matching decision for this session, prefer session-scoped
    /// then project-scoped (any session in this worktree).
    func lookup(sessionId: String, scopeKey: String) throws -> ACPPermissionDecision? {
        let sessionRows = try store.db.query("""
        SELECT decision FROM permission_decisions WHERE session_id = ? AND scope_key = ?
        """, bindings: [sessionId, scopeKey])
        if let d = sessionRows.first?["decision"] as? String { return ACPPermissionDecision(rawValue: d) }

        let projectRows = try store.db.query("""
        SELECT decision FROM permission_decisions
        WHERE scope_key = ? AND scope = 'project' LIMIT 1
        """, bindings: [scopeKey])
        if let d = projectRows.first?["decision"] as? String { return ACPPermissionDecision(rawValue: d) }

        return nil
    }
}
