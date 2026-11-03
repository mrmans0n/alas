import Foundation
import AlasACP
import AlasPlatform

public struct ACPV2FreshSessionBinding: Equatable, Sendable {
    public let sessionId: String
    public let upstreamSessionId: String
    public let source: ACPV2InboundLedgerSource
    public let storePath: String
    public let fence: ACPSessionLeaseFence
}

public enum ACPV2FreshSessionBindingError: Error, Equatable, Sendable { case staleLease, conflict }

extension ACPSessionStore {
    public func bindV2FreshSession(upstreamSessionId: String, source: ACPV2InboundLedgerSource,
        fence: ACPSessionLeaseFence) throws -> ACPV2FreshSessionBinding {
        guard !upstreamSessionId.isEmpty else { throw ACPV2FreshSessionBindingError.conflict }
        guard let receipt = try withLeaseFence(fence, {
            guard let lease = try db.query("""
            SELECT CAST(owner_instance AS BLOB) AS owner, CAST(lease_token AS BLOB) AS token
            FROM session_leases WHERE session_id = ?
            """, bindings: [fence.sessionId]).first,
                  lease["owner"] as? Data == Data(fence.ownerInstance.utf8),
                  lease["token"] as? Data == Data(fence.token.utf8) else { throw ACPV2FreshSessionBindingError.staleLease }
            _ = try requireCurrentInboundSource(source, sessionId: fence.sessionId)
            guard let row = try db.query("""
            SELECT remote_session_id, archived, recovery_proc_id, context_recovery_pending
            FROM sessions WHERE id = ?
            """, bindings: [fence.sessionId]).first,
                  row["remote_session_id"] == nil, row["archived"] as? Int64 == 0,
                  row["recovery_proc_id"] == nil, row["context_recovery_pending"] as? Int64 == 0 else { throw ACPV2FreshSessionBindingError.conflict }
            for table in ["acp_v2_update_streams", "acp_v2_inbound_streams", "acp_v2_submissions"] {
                guard try db.query("SELECT 1 FROM \(table) WHERE session_id = ? LIMIT 1", bindings: [fence.sessionId]).isEmpty else { throw ACPV2FreshSessionBindingError.conflict }
            }
            try db.exec("UPDATE sessions SET remote_session_id = ? WHERE id = ?", bindings: [upstreamSessionId, fence.sessionId])
            return ACPV2FreshSessionBinding(sessionId: fence.sessionId, upstreamSessionId: upstreamSessionId, source: source, storePath: path, fence: fence)
        }) else { throw ACPV2FreshSessionBindingError.staleLease }
        return receipt
    }
}
