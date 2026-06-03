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
}
