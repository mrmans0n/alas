import Testing
import Foundation
@testable import Alas

@Suite struct ACPSessionStoreDedupTests {
    @Test("duplicate (session_id, seq) rows are collapsed keeping newest")
    func dedupMessages() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("recover-\(UUID()).sqlite")
        // First open creates schema + recovery (no-op on empty DB).
        do {
            let store = try ACPSessionStore(path: url.path)
            let now = Int64(Date().timeIntervalSince1970)
            try store.upsertSession(ACPSessionRow(
                id: "s1", agentId: "claude", title: "t",
                currentModel: nil, currentMode: nil, autoRun: false,
                createdAt: now, updatedAt: now, lastOpenedAt: now, archived: false))
            // Two writers clobbered seq 0 — inject duplicate seq rows by hand.
            try store.db.exec("""
            INSERT INTO messages (id, session_id, kind, seq, payload, created_at)
            VALUES ('old', 's1', 'text', 0, ?, 100), ('new', 's1', 'text', 0, ?, 200)
            """, bindings: [Data("old".utf8), Data("new".utf8)])
        }
        // Re-open triggers the recovery pass.
        let store = try ACPSessionStore(path: url.path)
        let msgs = try store.loadMessages(sessionId: "s1")
        let seqZero = msgs.filter { $0.seq == 0 }
        #expect(seqZero.count == 1)
        #expect(seqZero.first?.id == "new")   // newest created_at kept
    }

    @Test("recovery is idempotent on a clean DB")
    func idempotentClean() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("recover-clean-\(UUID()).sqlite")
        _ = try ACPSessionStore(path: url.path)
        let store = try ACPSessionStore(path: url.path)   // second open, no crash
        #expect(try store.currentSchemaVersion() == 7)
    }
}
