import Testing
import Foundation
@testable import Alas

@MainActor
final class FakeSessionsProvider: RemoteSessionsProvider {
    var summaries: [RemoteSessionSummary] = []
    var sessions: [String: ACPSession] = [:]
    var policies: [String: ACPPermissionPolicy] = [:]
    var lastQuestionResponse: (id: String, response: ACPQuestionResponse)?
    func sessionSummaries() -> [RemoteSessionSummary] { summaries }
    func session(for id: String) -> ACPSession? { sessions[id] }
    func permissionPolicy(for id: String) -> ACPPermissionPolicy? { policies[id] }
    func hydrateIfNeeded(id: String) async {}
    func answerQuestion(for id: String, _ response: ACPQuestionResponse) {
        lastQuestionResponse = (id, response)
    }
}

#if DEBUG
extension ACPQuestionRequestParams {
    /// Test factory: a single question with two options.
    static func stub(title: String? = "Pick one") -> ACPQuestionRequestParams {
        ACPQuestionRequestParams(
            toolCallId: "tc-q-stub",
            title: title,
            questions: [
                ACPQuestion(
                    id: "q1",
                    prompt: "Which approach?",
                    options: [
                        ACPQuestionOption(id: "o1", label: "A"),
                        ACPQuestionOption(id: "o2", label: "B"),
                    ],
                    allowMultiple: false)
            ])
    }
}
#endif

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
            Issue.record("expected snapshot, got \(sent)")
            return
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

    @Test func resolvesPermissionWhenClearedElsewhere() async throws {
        let provider = FakeSessionsProvider()
        let s = try makeSessionWithAgentText("x")
        provider.sessions["s1"] = s
        s.transcript.streamingState = .awaitingPermission
        s.transcript.pendingPermission = .init(id: .number(0), params: .stub())
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gw.handle(.subscribe(sessionId: "s1"))   // surfaces the prompt
        #expect(sent.contains { if case .permissionRequest = $0 { return true }
        return false })
        // Resolve it "on the Mac": clear the pending prompt, then nudge the transcript.
        s.transcript.pendingPermission = nil
        s.transcript.streamingState = .idle
        s.transcript.messages.append(.agent(id: UUID(), StreamingText("done")))
        try await Task.sleep(nanoseconds: 250_000_000)   // > coalesce window
        #expect(sent.contains { if case .permissionResolved(_, 0) = $0 { return true }
        return false })
    }

    @Test func subscribeEmitsQuestionRequest() async throws {
        let provider = FakeSessionsProvider()
        let s = try makeSessionWithAgentText("x")
        provider.sessions["s1"] = s
        s.transcript.streamingState = .awaitingInput   // gateway only surfaces prompts when actually awaiting
        s.transcript.pendingQuestion = .init(id: .number(0), params: .stub())
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gw.handle(.subscribe(sessionId: "s1"))
        let req = sent.compactMap { msg -> RemoteQuestionPayload? in
            if case .questionRequest(_, let p) = msg { return p }
            return nil
        }.first
        let payload = try #require(req, "expected a questionRequest")
        #expect(payload.requestId == 0)
        #expect(payload.title == "Pick one")
        #expect(payload.questions.count == 1)
        #expect(payload.questions[0].id == "q1")
        #expect(payload.questions[0].prompt == "Which approach?")
        #expect(payload.questions[0].allowMultiple == false)
        #expect(payload.questions[0].options == [
            RemoteQuestionOption(id: "o1", label: "A"),
            RemoteQuestionOption(id: "o2", label: "B"),
        ])
    }

    @Test func questionAnswerCallsProviderWhenRequestMatches() async throws {
        let provider = FakeSessionsProvider()
        let s = try makeSessionWithAgentText("x")
        provider.sessions["s1"] = s
        s.transcript.pendingQuestion = .init(id: .number(0), params: .stub())
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gw.handle(.subscribe(sessionId: "s1"))
        await gw.handle(.questionAnswer(
            sessionId: "s1",
            requestId: 0,
            answers: [RemoteQuestionAnswer(questionId: "q1", selectedOptionIds: ["o1"])]))
        let last = try #require(provider.lastQuestionResponse, "expected answerQuestion call")
        #expect(last.id == "s1")
        #expect(last.response == .init(outcome: .answered(answers: [
            ACPQuestionAnswer(questionId: "q1", selectedOptionIds: ["o1"])
        ])))
        #expect(sent.contains { if case .questionResolved(_, 0) = $0 { return true }
        return false })
    }

    @Test func staleQuestionAnswerIsNoOp() async throws {
        let provider = FakeSessionsProvider()
        let s = try makeSessionWithAgentText("x")
        provider.sessions["s1"] = s
        s.transcript.pendingQuestion = .init(id: .number(5), params: .stub())  // current request is 5
        let gw = RemoteSessionGateway(provider: provider) { _ in }
        await gw.handle(.subscribe(sessionId: "s1"))
        await gw.handle(.questionAnswer(
            sessionId: "s1",
            requestId: 0,
            answers: [RemoteQuestionAnswer(questionId: "q1", selectedOptionIds: ["o1"])]))
        #expect(provider.lastQuestionResponse == nil)  // stale requestId ignored
    }

    @Test func incompleteQuestionAnswerIsNoOp() async throws {
        let provider = FakeSessionsProvider()
        let s = try makeSessionWithAgentText("x")
        provider.sessions["s1"] = s
        s.transcript.pendingQuestion = .init(id: .number(0), params: .stub())
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gw.handle(.subscribe(sessionId: "s1"))
        // Empty selection for the only question — must not resume the agent.
        await gw.handle(.questionAnswer(
            sessionId: "s1",
            requestId: 0,
            answers: [RemoteQuestionAnswer(questionId: "q1", selectedOptionIds: [])]))
        #expect(provider.lastQuestionResponse == nil)
        #expect(!sent.contains { if case .questionResolved = $0 { return true }
        return false })
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
        #expect(!sent.contains { if case .transcriptDelta = $0 { return true }
        return false })
    }
}
