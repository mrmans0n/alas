import Foundation
import Testing
@testable import Alas

@Suite("ACPSessionStore — schema + migrations")
struct ACPSessionStoreSchemaTests {
    private func tmpStore() throws -> ACPSessionStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("acp-store-\(UUID()).sqlite")
        return try ACPSessionStore(path: url.path)
    }

    @Test("opens a fresh DB at schema version 2")
    func freshSchema() throws {
        let store = try tmpStore()
        #expect(try store.currentSchemaVersion() == ACPSessionStore.targetSchemaVersion)
        #expect(ACPSessionStore.targetSchemaVersion == 2)
    }

    @Test("re-opening doesn't double-apply migrations")
    func idempotent() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("acp-store-\(UUID()).sqlite")
        _ = try ACPSessionStore(path: url.path)
        _ = try ACPSessionStore(path: url.path) // must not throw
    }
}
