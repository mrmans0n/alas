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

extension ACPSessionStore {
    func createV2PreviewDisplaySchema() throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS acp_v2_preview_display (
          session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
          installation_id TEXT NOT NULL, owner_instance TEXT NOT NULL, lease_token TEXT NOT NULL,
          sequence INTEGER NOT NULL CHECK(sequence > 0), payload BLOB NOT NULL
        )
        """)
    }

    public func persistV2PreviewDisplay(_ snapshot: ACPV2PreviewDisplaySnapshot, fence: ACPSessionLeaseFence,
        authorize: @Sendable () -> Bool) throws -> Bool {
        try snapshot.validate()
        guard snapshot.sessionId.utf8.elementsEqual(fence.sessionId.utf8), authorize(), !Task.isCancelled else { return false }
        let payload = try JSONEncoder().encode(snapshot)
        do {
            return try withLeaseFence(fence, {
                guard authorize(), !Task.isCancelled,
                      try loadSession(id: fence.sessionId)?.runtimeKind == .v2FreshPreview,
                      let lease = try loadLease(sessionId: fence.sessionId),
                      lease.ownerInstance.utf8.elementsEqual(fence.ownerInstance.utf8),
                      lease.token.utf8.elementsEqual(fence.token.utf8) else { return false }
                if let old = try db.query("SELECT * FROM acp_v2_preview_display WHERE session_id = ?", bindings: [fence.sessionId]).first {
                    guard old["installation_id"] as? String == snapshot.installationID.uuidString,
                          (old["owner_instance"] as? String)?.utf8.elementsEqual(fence.ownerInstance.utf8) == true,
                          (old["lease_token"] as? String)?.utf8.elementsEqual(fence.token.utf8) == true,
                          let sequence = old["sequence"] as? Int64, snapshot.sequence > sequence else { return false }
                }
                try db.exec("""
                INSERT INTO acp_v2_preview_display (session_id, installation_id, owner_instance, lease_token, sequence, payload)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(session_id) DO UPDATE SET sequence=excluded.sequence, payload=excluded.payload
                """, bindings: [fence.sessionId, snapshot.installationID.uuidString, fence.ownerInstance, fence.token, snapshot.sequence, payload])
                guard authorize(), !Task.isCancelled else { throw ACPV2PreviewStoreError.invalidated }
                return true
            }) ?? false
        } catch ACPV2PreviewStoreError.invalidated { return false }
    }

    public func loadV2PreviewDisplay(sessionId: String) throws -> ACPV2PreviewDisplaySnapshot? {
        guard try loadSession(id: sessionId)?.runtimeKind == .v2FreshPreview,
              let row = try db.query("SELECT installation_id, sequence, payload FROM acp_v2_preview_display WHERE session_id = ?", bindings: [sessionId]).first else { return nil }
        guard let payload = row["payload"] as? Data else { throw ACPV2PreviewStoreError.invalidInput }
        let snapshot = try JSONDecoder().decode(ACPV2PreviewDisplaySnapshot.self, from: payload)
        try snapshot.validate()
        guard snapshot.sessionId.utf8.elementsEqual(sessionId.utf8),
              snapshot.installationID.uuidString == row["installation_id"] as? String,
              snapshot.sequence == row["sequence"] as? Int64 else { throw ACPV2PreviewStoreError.invalidInput }
        return snapshot
    }
}
