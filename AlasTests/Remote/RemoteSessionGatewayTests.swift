import Testing
import Foundation
@testable import Alas

@MainActor
final class FakeSessionsProvider: RemoteSessionsProvider {
    var summaries: [RemoteSessionSummary] = []
    var sessions: [String: ACPSession] = [:]
    var policies: [String: ACPPermissionPolicy] = [:]
    func sessionSummaries() -> [RemoteSessionSummary] { summaries }
    func session(for id: String) -> ACPSession? { sessions[id] }
    func permissionPolicy(for id: String) -> ACPPermissionPolicy? { policies[id] }
    func hydrateIfNeeded(id: String) async {}
}

#if DEBUG
extension ACPPermissionRequestParams {
    /// Test factory: one tool call named "Bash" with an allow_once +
    /// reject_once option, matching the real ACPPermissionToolCall /
    /// ACPPermissionOption initializers.
    static func stub(sessionId: String = "remote", toolTitle: String = "Bash") -> ACPPermissionRequestParams {
        ACPPermissionRequestParams(
            sessionId: sessionId,
            toolCall: ACPPermissionToolCall(
                toolCallId: "tc-stub",
                title: toolTitle,
                kind: "execute",
                status: nil,
                content: nil,
                locations: nil,
                rawInput: nil,
                rawOutput: nil),
            options: [
                ACPPermissionOption(optionId: "allow_once", name: "Allow once", kind: "allow_once"),
                ACPPermissionOption(optionId: "reject_once", name: "Reject once", kind: "reject_once"),
            ])
    }
}
#endif

@MainActor
struct RemoteSessionGatewayTests {
    private func makeManager() throws -> ACPSessionManager {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-gw-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        return ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp", store: store)
    }

    private func makeSessionWithAgentText(_ text: String) throws -> ACPSession {
        let mgr = try makeManager()
        let s = mgr.createSession(agentId: "claude")
        s.transcript.messages = [.agent(id: UUID(), StreamingText(text))]
        return s
    }

    private func makeLog() throws -> ACPPermissionDecisionLog {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-gw-log-\(UUID()).sqlite")
        return ACPPermissionDecisionLog(store: try ACPSessionStore(path: url.path))
    }

    @Test func listSessionsEmitsSummaries() async {
        let provider = FakeSessionsProvider()
        provider.summaries = [RemoteSessionSummary(id: "s1", title: "T", agentId: "claude", status: "idle")]
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gw.handle(.listSessions)
        #expect(sent == [.sessionList(sessions: provider.summaries)])
    }

    @Test func subscribeEmitsSnapshot() async throws {
        let provider = FakeSessionsProvider()
        let s = try makeSessionWithAgentText("hello")
        provider.sessions["s1"] = s
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gw.handle(.subscribe(sessionId: "s1"))
        guard case .transcriptSnapshot(let id, _, let msgs)? = sent.first else {
            Issue.record("expected snapshot, got \(sent)"); return
        }
        #expect(id == "s1")
        #expect(msgs.contains { $0.kind == "agent" && $0.text == "hello" })
    }

    @Test func permissionDecisionCallsPolicyWhenRequestMatches() async throws {
        let provider = FakeSessionsProvider()
        let s = try makeSessionWithAgentText("x")
        let policy = ACPPermissionPolicy(session: s, log: try makeLog())
        provider.sessions["s1"] = s
        provider.policies["s1"] = policy
        // Simulate a pending permission with requestId 0.
        s.transcript.pendingPermission = .init(id: .number(0), params: .stub())
        let gw = RemoteSessionGateway(provider: provider) { _ in }
        await gw.handle(.subscribe(sessionId: "s1"))
        await gw.handle(.permissionDecision(sessionId: "s1", requestId: 0, optionId: "allow_once", persistScope: nil))
        // After a matching decision, the policy clears the pending permission.
        #expect(s.transcript.pendingPermission == nil)
    }

    @Test func staleDecisionIsNoOp() async throws {
        let provider = FakeSessionsProvider()
        let s = try makeSessionWithAgentText("x")
        provider.sessions["s1"] = s
        provider.policies["s1"] = ACPPermissionPolicy(session: s, log: try makeLog())
        s.transcript.pendingPermission = .init(id: .number(5), params: .stub())  // current request is 5
        let gw = RemoteSessionGateway(provider: provider) { _ in }
        await gw.handle(.subscribe(sessionId: "s1"))
        await gw.handle(.permissionDecision(sessionId: "s1", requestId: 0, optionId: "allow_once", persistScope: nil))
        #expect(s.transcript.pendingPermission != nil)  // unchanged: stale requestId ignored
    }

    @Test func transcriptMutationEmitsCoalescedDelta() async throws {
        let provider = FakeSessionsProvider()
        let s = try makeSessionWithAgentText("hello")
        provider.sessions["s1"] = s
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gw.handle(.subscribe(sessionId: "s1"))
        s.transcript.messages.append(.agent(id: UUID(), StreamingText("more")))  // fires objectWillChange
        try await Task.sleep(nanoseconds: 250_000_000)  // > coalesce window
        let delta = sent.compactMap { msg -> [RemoteWireMessage]? in
            if case .transcriptDelta(_, _, let upserts) = msg { return upserts }
            return nil
        }.last
        let delta2 = try #require(delta, "expected a transcriptDelta after mutation")
        #expect(delta2.contains { $0.text == "more" })
    }

    @Test func closeStopsFurtherDeltas() async throws {
        let provider = FakeSessionsProvider()
        let s = try makeSessionWithAgentText("hello")
        provider.sessions["s1"] = s
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gw.handle(.subscribe(sessionId: "s1"))
        gw.close()
        s.transcript.messages.append(.agent(id: UUID(), StreamingText("after-close")))
        try await Task.sleep(nanoseconds: 250_000_000)
        #expect(!sent.contains { if case .transcriptDelta = $0 { return true }; return false })
    }
}
