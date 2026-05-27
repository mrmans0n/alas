import Foundation
import Testing
@testable import Alas

@Suite("ACPPermissionDecisionLog")
struct ACPPermissionDecisionLogTests {
    @Test("session-scoped allow is found by exact session id only")
    func sessionScope() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("perm-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(id: "s1", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        try store.upsertSession(.init(id: "s2", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))

        let log = ACPPermissionDecisionLog(store: store)
        try log.record(sessionId: "s1", scopeKey: "tool:bash", decision: .allow, scope: .session)
        #expect(try log.lookup(sessionId: "s1", scopeKey: "tool:bash") == .allow)
        #expect(try log.lookup(sessionId: "s2", scopeKey: "tool:bash") == nil)
    }

    @Test("project-scoped allow is found across any session")
    func projectScope() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("perm-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(id: "s1", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        try store.upsertSession(.init(id: "s2", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))

        let log = ACPPermissionDecisionLog(store: store)
        try log.record(sessionId: "s1", scopeKey: "tool:bash", decision: .allow, scope: .project)
        #expect(try log.lookup(sessionId: "s2", scopeKey: "tool:bash") == .allow)
    }
}
