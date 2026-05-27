import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACPPermissionPolicy")
struct ACPPermissionPolicyTests {
    private func makeStore() throws -> ACPSessionStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pol-\(UUID()).sqlite")
        let s = try ACPSessionStore(path: url.path)
        try s.upsertSession(.init(id: "s", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        return s
    }

    @Test("auto-run short-circuits with allow_once")
    func autoRun() async throws {
        let store = try makeStore()
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "wt", title: "t")
        session.autoRunEnabled = true
        let policy = ACPPermissionPolicy(session: session, log: .init(store: store))
        let opts: [ACPPermissionOption] = [
            .init(optionId: "allow", name: "Allow", kind: "allow_once"),
            .init(optionId: "deny", name: "Deny", kind: "reject_once")
        ]
        let resp = await policy.evaluate(scopeKey: "tool:bash", options: opts, params: stubParams())
        #expect(resp.outcome == .selected(optionId: "allow"))
    }

    @Test("logged session-scope decision is replayed without UI")
    func remembered() async throws {
        let store = try makeStore()
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "wt", title: "t")
        let log = ACPPermissionDecisionLog(store: store)
        try log.record(sessionId: "s", scopeKey: "tool:bash", decision: .deny, scope: .session)
        let policy = ACPPermissionPolicy(session: session, log: log)
        let opts: [ACPPermissionOption] = [
            .init(optionId: "allow", name: "Allow", kind: "allow_once"),
            .init(optionId: "deny", name: "Deny", kind: "reject_once")
        ]
        let resp = await policy.evaluate(scopeKey: "tool:bash", options: opts, params: stubParams())
        #expect(resp.outcome == .selected(optionId: "deny"))
    }

    private func stubParams() -> ACPPermissionRequestParams {
        .init(sessionId: "s",
              toolCall: .init(toolCallId: "tc", title: "bash", kind: "execute", status: "pending",
                              content: nil, locations: nil, rawInput: nil, rawOutput: nil),
              options: [])
    }
}
