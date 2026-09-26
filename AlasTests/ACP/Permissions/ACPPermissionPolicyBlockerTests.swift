import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACP permission policy blocker callback")
struct ACPPermissionPolicyBlockerTests {
    private func makeStore() throws -> ACPSessionStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pol-blocker-\(UUID()).sqlite")
        let s = try ACPSessionStore(path: url.path)
        try s.upsertSession(.init(id: "s", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        return s
    }

    private func stubParams() -> ACPPermissionRequestParams {
        .init(sessionId: "s",
              toolCall: .init(toolCallId: "tc", title: "Write file", kind: "edit", status: "pending",
                              content: nil, locations: nil, rawInput: nil, rawOutput: nil, name: "write"),
              options: [
                .init(optionId: "allow", name: "Allow", kind: "allow_once"),
                .init(optionId: "deny", name: "Deny", kind: "reject_once"),
              ])
    }

    @Test("parking for a human reports the block exactly once with the real request id")
    func parkingReportsBlock() async throws {
        let store = try makeStore()
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "wt", title: "t")
        var blocked: [(JSONRPCID, String?)] = []
        let policy = ACPPermissionPolicy(
            session: session,
            log: .init(store: store),
            onBlocked: { id, params in blocked.append((id, params.toolCall.name)) }
        )

        async let decision = policy.evaluate(
            scopeKey: "tool:write", options: stubParams().options,
            params: stubParams(), requestID: .number(42)
        )
        try? await Task.sleep(for: .milliseconds(100))

        #expect(blocked.count == 1)
        #expect(blocked.first?.0 == .number(42))
        #expect(blocked.first?.1 == "write")
        // The transcript's own id is a placeholder, which is why the callback
        // carries the real one.
        #expect(session.transcript.pendingPermission?.id == .number(0))
        #expect(policy.pendingPermissionRequestID == .number(42))

        await policy.userDecided(
            scopeKey: "tool:write", optionId: "allow", decision: .allow, persistScope: nil
        )
        _ = await decision
        #expect(policy.pendingPermissionRequestID == nil)
    }

    @Test("auto-run resolves without ever reporting a block")
    func autoRunDoesNotReportBlock() async throws {
        let store = try makeStore()
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "wt", title: "t")
        session.autoRunEnabled = true
        var blockedCount = 0
        let policy = ACPPermissionPolicy(
            session: session, log: .init(store: store), onBlocked: { _, _ in blockedCount += 1 }
        )

        _ = await policy.evaluate(
            scopeKey: "tool:write", options: stubParams().options,
            params: stubParams(), requestID: .number(1)
        )

        #expect(blockedCount == 0)
        #expect(session.transcript.pendingPermission == nil)
    }

    @Test("a remembered decision resolves without ever reporting a block")
    func rememberedDecisionDoesNotReportBlock() async throws {
        let store = try makeStore()
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "wt", title: "t")
        let log = ACPPermissionDecisionLog(store: store)
        try await log.record(
            sessionId: "s", scopeKey: "tool:write", decision: .allow, scope: .session
        )
        var blockedCount = 0
        let policy = ACPPermissionPolicy(
            session: session, log: log, onBlocked: { _, _ in blockedCount += 1 }
        )

        _ = await policy.evaluate(
            scopeKey: "tool:write", options: stubParams().options,
            params: stubParams(), requestID: .number(2)
        )

        #expect(blockedCount == 0)
        #expect(session.transcript.pendingPermission == nil)
    }
}
