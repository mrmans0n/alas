import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACPSessionManager plan sidebar layout memory")
struct ACPSessionManagerPlanSidebarLayoutTests {
    private func makeManager() throws -> ACPSessionManager {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mgr-plan-layout-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        return ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
    }

    @Test("remembered visibility survives idle session eviction")
    func rememberedVisibilitySurvivesIdleEviction() throws {
        let manager = try makeManager()
        let session = manager.createSession(agentId: "claude")

        manager.rememberPlanSidebarVisibility(false, for: session.id)
        manager.retainSession(id: session.id)
        manager.releaseSession(id: session.id)

        #expect(manager.sessions[session.id] == nil)
        #expect(manager.rememberedPlanSidebarVisibility(for: session.id) == false)
    }

    @Test("remembered visibility is scoped by session id")
    func rememberedVisibilityIsScopedBySessionId() throws {
        let manager = try makeManager()
        let first = manager.createSession(agentId: "claude")
        let second = manager.createSession(agentId: "claude")

        manager.rememberPlanSidebarVisibility(false, for: first.id)
        manager.rememberPlanSidebarVisibility(true, for: second.id)

        #expect(manager.rememberedPlanSidebarVisibility(for: first.id) == false)
        #expect(manager.rememberedPlanSidebarVisibility(for: second.id) == true)
    }

    @Test("close clears remembered visibility")
    func closeClearsRememberedVisibility() throws {
        let manager = try makeManager()
        let session = manager.createSession(agentId: "claude")

        manager.rememberPlanSidebarVisibility(false, for: session.id)
        manager.closeSession(id: session.id)

        #expect(manager.rememberedPlanSidebarVisibility(for: session.id) == nil)
    }

    @Test("delete clears remembered visibility")
    func deleteClearsRememberedVisibility() throws {
        let manager = try makeManager()
        let session = manager.createSession(agentId: "claude")

        manager.rememberPlanSidebarVisibility(true, for: session.id)
        manager.deleteSession(id: session.id)

        #expect(manager.rememberedPlanSidebarVisibility(for: session.id) == nil)
    }
}
