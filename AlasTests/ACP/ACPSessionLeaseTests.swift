import Testing
import Foundation
@testable import Alas

@Suite struct ACPSessionLeaseTests {
    private func tempStore() throws -> ACPSessionStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lease-\(UUID()).sqlite")
        return try ACPSessionStore(path: url.path)
    }

    @Test("schema reaches version 7")
    func schemaV7() throws {
        let store = try tempStore()
        #expect(try store.currentSchemaVersion() == 7)
    }

    @Test("session_leases table exists and is empty")
    func leaseTableExists() throws {
        let store = try tempStore()
        let rows = try store.db.query("SELECT COUNT(*) AS c FROM session_leases")
        #expect((rows.first?["c"] as? Int64) == 0)
    }

    private func seedSession(_ store: ACPSessionStore, id: String) throws {
        let now = Int64(Date().timeIntervalSince1970)
        try store.upsertSession(ACPSessionRow(
            id: id, agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: now, updatedAt: now, lastOpenedAt: now, archived: false))
    }

    @Test("first claimer wins, second becomes mirror")
    func firstClaimWins() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lease-\(UUID()).sqlite")
        let a = try ACPSessionStore(path: url.path)
        try seedSession(a, id: "s1")
        let b = try ACPSessionStore(path: url.path)
        let now = Int64(Date().timeIntervalSince1970)

        #expect(try a.claimLease(sessionId: "s1", instanceId: "A", pid: Int64(getpid()), now: now, staleAfter: 15) == true)
        #expect(try b.claimLease(sessionId: "s1", instanceId: "B", pid: Int64(getpid()), now: now, staleAfter: 15) == false)
        #expect(try b.loadLease(sessionId: "s1")?.ownerInstance == "A")
    }

    @Test("re-claiming my own lease succeeds")
    func reclaimOwn() throws {
        let store = try tempStore()
        try seedSession(store, id: "s1")
        let now = Int64(Date().timeIntervalSince1970)
        #expect(try store.claimLease(sessionId: "s1", instanceId: "A", pid: Int64(getpid()), now: now, staleAfter: 15) == true)
        #expect(try store.claimLease(sessionId: "s1", instanceId: "A", pid: Int64(getpid()), now: now + 1, staleAfter: 15) == true)
    }

    @Test("stale-heartbeat lease is reclaimable even with a live pid")
    func staleHeartbeatReclaim() throws {
        let store = try tempStore()
        try seedSession(store, id: "s1")
        let now = Int64(Date().timeIntervalSince1970)
        _ = try store.claimLease(sessionId: "s1", instanceId: "A", pid: Int64(getpid()), now: now - 100, staleAfter: 15)
        #expect(try store.claimLease(sessionId: "s1", instanceId: "B", pid: Int64(getpid()), now: now, staleAfter: 15) == true)
        #expect(try store.loadLease(sessionId: "s1")?.ownerInstance == "B")
    }

    @Test("dead-pid lease is reclaimed immediately even with fresh heartbeat")
    func deadPidReclaim() throws {
        let store = try tempStore()
        try seedSession(store, id: "s1")
        let now = Int64(Date().timeIntervalSince1970)
        _ = try store.claimLease(sessionId: "s1", instanceId: "A", pid: 999_999_99, now: now, staleAfter: 15)
        #expect(try store.claimLease(sessionId: "s1", instanceId: "B", pid: Int64(getpid()), now: now, staleAfter: 15) == true)
        #expect(try store.loadLease(sessionId: "s1")?.ownerInstance == "B")
    }

    @Test("live lease is not stealable by a normal claim")
    func liveLeaseHeld() throws {
        let store = try tempStore()
        try seedSession(store, id: "s1")
        let now = Int64(Date().timeIntervalSince1970)
        _ = try store.claimLease(sessionId: "s1", instanceId: "A", pid: Int64(getpid()), now: now, staleAfter: 15)
        #expect(try store.claimLease(sessionId: "s1", instanceId: "B", pid: Int64(getpid()), now: now, staleAfter: 15) == false)
    }

    @Test("release frees the lease")
    func releaseFrees() throws {
        let store = try tempStore()
        try seedSession(store, id: "s1")
        let now = Int64(Date().timeIntervalSince1970)
        _ = try store.claimLease(sessionId: "s1", instanceId: "A", pid: Int64(getpid()), now: now, staleAfter: 15)
        try store.releaseLease(sessionId: "s1", instanceId: "A")
        #expect(try store.loadLease(sessionId: "s1") == nil)
    }
}
