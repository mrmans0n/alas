import Testing
import Foundation
@testable import Alas

@MainActor
@Suite("ACPSessionManager - remote accessors")
struct ACPManagerAccessorsTests {
    private func makeManager() throws -> ACPSessionManager {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-accessors-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        return ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp", store: store)
    }

    @Test func liveSessionReturnsCachedSession() throws {
        let mgr = try makeManager()
        let session = mgr.createSession(agentId: "claude")
        #expect(mgr.liveSession(for: session.id) === session)  // exact cached instance
    }

    @Test func liveSessionReturnsNilForUnknownId() throws {
        let mgr = try makeManager()
        #expect(mgr.liveSession(for: "missing") == nil)
    }

    @Test func permissionPolicyIsNilWithoutAttachedRunner() throws {
        let mgr = try makeManager()
        let session = mgr.createSession(agentId: "claude")
        // No runner attached for a freshly-created session.
        #expect(mgr.permissionPolicy(for: session.id) == nil)
        #expect(mgr.permissionPolicy(for: "missing") == nil)
    }

    @Test func sessionRowsExposesRecent() throws {
        let mgr = try makeManager()
        let session = mgr.createSession(agentId: "claude")
        #expect(mgr.sessionRows.contains { $0.id == session.id })
    }
}
