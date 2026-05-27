import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACPSessionManager")
struct ACPSessionManagerTests {
    @Test("creating a session inserts it and persists the row")
    func create() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mgr-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let mgr = ACPSessionManager(worktreeId: "/tmp/wt", worktreePath: "/tmp/wt", store: store)
        let s = mgr.createSession(agentId: "claude")
        #expect(mgr.sessions[s.id] != nil)
        let row = try store.loadSession(id: s.id)
        #expect(row?.agentId == "claude")
    }
}
