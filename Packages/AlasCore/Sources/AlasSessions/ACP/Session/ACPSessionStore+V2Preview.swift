import Foundation
import AlasACP
import AlasPlatform

public enum ACPV2PreviewStoreError: Error { case invalidInput, existingSession, invalidated }

extension ACPSessionStore {
    /// Inserts the marker and initial lease in one transaction before any helper I/O.
    public func createV2PreviewSession(row: ACPSessionRow, ownerInstance: String, pid: Int64,
        now: Int64, leaseToken: String) throws -> ACPSessionLeaseFence {
        guard !row.id.isEmpty, !ownerInstance.isEmpty, !leaseToken.isEmpty,
              row.remoteSessionId == nil, row.acpBrokerId == nil, row.acpBrokerGeneration == nil,
              row.acpBrokerAcknowledgedCursor == 0, row.acpBrokerWireContextJSON == nil,
              !row.archived, row.recoveryProcId == nil, !row.contextRecoveryPending,
              !row.autoRun, !row.directTurnInFlight, row.ephemeralParentId == nil else { throw ACPV2PreviewStoreError.invalidInput }
        try db.exec("BEGIN IMMEDIATE")
        do {
            guard try loadSession(id: row.id) == nil,
                  try loadLease(sessionId: row.id) == nil else { throw ACPV2PreviewStoreError.existingSession }
            var marked = row
            marked.runtimeKind = .v2FreshPreview
            // Older readers already fail closed on a raw context with no descriptor.
            marked.acpBrokerWireContextJSON = try ACPBrokerWireContext.rawV2.persistedJSON()
            try upsertSession(marked)
            try db.exec("""
            INSERT INTO session_leases (session_id, owner_instance, pid, heartbeat_at, status, lease_token)
            VALUES (?, ?, ?, ?, 'idle', ?)
            """, bindings: [row.id, ownerInstance, pid, now, leaseToken])
            try db.exec("COMMIT")
            return .init(sessionId: row.id, ownerInstance: ownerInstance, token: leaseToken)
        } catch {
            try? db.exec("ROLLBACK")
            throw error
        }
    }
}
