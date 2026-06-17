import Testing
import Foundation
@testable import Alas

@MainActor
final class FakeSessionsProvider: RemoteSessionsProvider {
    var summaries: [RemoteSessionSummary] = []
    var worktrees: [RemoteWorktreeOption] = []
    var agents: [RemoteAgentOption] = []
    var createResults: [String: RemoteCreateSessionResult] = [:]
    var sessions: [String: ACPSession] = [:]
    var policies: [String: ACPPermissionPolicy] = [:]
    var lastQuestionResponse: (id: String, response: ACPQuestionResponse)?
    var writers: Set<String> = []
    var tookOver: [String] = []
    var prompts: [(id: String, text: String)] = []
    var lastAttachments: [ACPMessage.Attachment] = []
    var sendPromptAccepts = true   // simulate the manager refusing a submit (e.g. needs auth)
    var stopped: [String] = []
    var models: [(id: String, model: String)] = []
    var modes: [(id: String, mode: String)] = []
    var autoRuns: [(id: String, enabled: Bool)] = []
    var renamed: [(id: String, title: String)] = []
    var renameSucceeds = true
    var configs: [String: RemoteSessionConfig] = [:]
    var sessionSummariesCallCount = 0
    var remoteWorktreesCallCount = 0
    var remoteAgentsCallCount = 0
    var createRequests: [(worktreeId: String, agentId: String)] = []
    var pauseSessionSummaries = false
    var pauseRemoteWorktrees = false
    private var sessionSummariesContinuation: CheckedContinuation<[RemoteSessionSummary], Never>?
    private var remoteWorktreesContinuation: CheckedContinuation<[RemoteWorktreeOption], Never>?
    func sessionSummaries() async -> [RemoteSessionSummary] {
        sessionSummariesCallCount += 1
        if pauseSessionSummaries {
            return await withCheckedContinuation { continuation in
                sessionSummariesContinuation = continuation
            }
        }
        return summaries
    }
    func remoteWorktrees() async -> [RemoteWorktreeOption] {
        remoteWorktreesCallCount += 1
        if pauseRemoteWorktrees {
            return await withCheckedContinuation { continuation in
                remoteWorktreesContinuation = continuation
            }
        }
        return worktrees
    }
    func remoteAgents() -> [RemoteAgentOption] {
        remoteAgentsCallCount += 1
        return agents
    }
    func createRemoteSession(worktreeId: String, agentId: String) async -> RemoteCreateSessionResult {
        createRequests.append((worktreeId, agentId))
        return createResults["\(worktreeId)|\(agentId)"] ?? .failure("Could not create session.")
    }
    func resumeSessionSummaries() {
        sessionSummariesContinuation?.resume(returning: summaries)
        sessionSummariesContinuation = nil
    }
    func resumeRemoteWorktrees() {
        remoteWorktreesContinuation?.resume(returning: worktrees)
        remoteWorktreesContinuation = nil
    }
    func session(for id: String) -> ACPSession? { sessions[id] }
    func permissionPolicy(for id: String) -> ACPPermissionPolicy? { policies[id] }
    func hydrateIfNeeded(id: String) async {}
    func answerQuestion(for id: String, _ response: ACPQuestionResponse) {
        lastQuestionResponse = (id, response)
    }

    func isWriter(for id: String) -> Bool { writers.contains(id) }
    func takeOver(for id: String) {
        tookOver.append(id)
        writers.insert(id)
    }

    var sendPromptResultIsAsync = false   // deliver onResult on a later tick (models a late delivery failure)
    func sendPrompt(for id: String, text: String, attachments: [ACPMessage.Attachment], onResult: @escaping @MainActor (Bool) -> Void) {
        let accepted = writers.contains(id) && sendPromptAccepts
        if accepted {
            prompts.append((id, text))
            lastAttachments = attachments
        }
        if sendPromptResultIsAsync {
            Task { @MainActor in onResult(accepted) }
        } else {
            onResult(accepted)
        }
    }

    var writtenAttachmentURLs: [URL] = []
    func writeAttachment(_ data: Data, mimeType: String, name: String?, for id: String) -> URL? {
        let ext = mimeType == "image/png" ? "png" : (mimeType == "image/jpeg" ? "jpg" : "img")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).\(ext)")
        do { try data.write(to: url) } catch { return nil }
        writtenAttachmentURLs.append(url)
        return url
    }

    func stop(for id: String) { stopped.append(id) }
    func setModel(for id: String, modelId: String) { models.append((id, modelId)) }
    func setMode(for id: String, modeId: String) { modes.append((id, modeId)) }
    func setAutoRun(for id: String, enabled: Bool) { autoRuns.append((id, enabled)) }
    func renameSession(for id: String, title: String) -> Bool {
        renamed.append((id, title))
        return renameSucceeds
    }
    func sessionConfig(for id: String) -> RemoteSessionConfig? { configs[id] }
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
        provider.summaries = [RemoteSessionSummary(id: "s1", title: "T", agentId: "claude", status: "idle", canDrive: false)]
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gw.handle(.listSessions)
        await Task.yield()
        #expect(provider.sessionSummariesCallCount == 1)
        #expect(sent == [.sessionList(sessions: provider.summaries)])
    }

    @Test func listSessionsPreservesIsActiveFlag() async {
        let provider = FakeSessionsProvider()
        let active = RemoteSessionSummary(id: "active", title: "Active", agentId: "claude", status: "idle", canDrive: true, isActive: true)
        let inactive = RemoteSessionSummary(id: "inactive", title: "Inactive", agentId: "codex", status: "idle", canDrive: false, isActive: false)
        provider.summaries = [active, inactive]
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gw.handle(.listSessions)
        await Task.yield()
        #expect(provider.sessionSummariesCallCount == 1)
        guard case .sessionList(let sessions)? = sent.first else {
            Issue.record("expected sessionList, got \(sent)")
            return
        }
        #expect(sessions.count == 2)
        #expect(sessions.first { $0.id == "active" }?.isActive == true)
        #expect(sessions.first { $0.id == "inactive" }?.isActive == false)
    }

    @Test func listWorktreesEmitsWorktreeList() async {
        let provider = FakeSessionsProvider()
        provider.worktrees = [
            RemoteWorktreeOption(
                id: "wt1",
                projectName: "alas",
                worktreeName: "feature-a",
                branch: "nacho/feature-a",
                path: "/tmp/alas-feature-a",
                metricsAvailable: false,
                comparisonRef: nil,
                commitCount: 0,
                changedFileCount: 0,
                addedLines: 0,
                deletedLines: 0,
                conflictCount: 0
            )
        ]
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }

        await gw.handle(.listWorktrees)
        for _ in 0..<10 {
            if !sent.isEmpty { break }
            await Task.yield()
        }

        #expect(provider.remoteWorktreesCallCount == 1)
        #expect(sent == [.worktreeList(worktrees: provider.worktrees)])
    }

    @Test func listAgentsEmitsAgentList() async {
        let provider = FakeSessionsProvider()
        provider.agents = [RemoteAgentOption(id: "claude", name: "Claude", isDefault: true)]
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }

        await gw.handle(.listAgents)

        #expect(provider.remoteAgentsCallCount == 1)
        #expect(sent == [.agentList(agents: provider.agents)])
    }

    @Test func createSessionEmitsCreatedSession() async {
        let provider = FakeSessionsProvider()
        let summary = RemoteSessionSummary(id: "s1", title: "New session", agentId: "claude", status: "idle", canDrive: true)
        provider.summaries = [summary]
        provider.createResults["wt1|claude"] = .success(summary)
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }

        await gw.handle(.createSession(worktreeId: "wt1", agentId: "claude"))
        for _ in 0..<10 {
            if provider.sessionSummariesCallCount == 1,
               sent.contains(.sessionList(sessions: provider.summaries)) { break }
            await Task.yield()
        }

        #expect(provider.createRequests.count == 1)
        #expect(provider.createRequests.first?.worktreeId == "wt1")
        #expect(provider.createRequests.first?.agentId == "claude")
        #expect(sent.contains(.sessionCreated(session: summary)))
        #expect(provider.sessionSummariesCallCount == 1)
        #expect(sent.contains(.sessionList(sessions: provider.summaries)))
    }

    @Test func createSessionEmitsFailure() async {
        let provider = FakeSessionsProvider()
        provider.createResults["missing|claude"] = .failure("Worktree is no longer available.")
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }

        await gw.handle(.createSession(worktreeId: "missing", agentId: "claude"))

        #expect(sent == [.createSessionFailed(message: "Worktree is no longer available.")])
    }

    @Test func listSessionsDoesNotBlockFollowingSubscribe() async throws {
        let provider = FakeSessionsProvider()
        provider.summaries = [RemoteSessionSummary(id: "s1", title: "T", agentId: "claude", status: "idle", canDrive: false)]
        provider.pauseSessionSummaries = true
        provider.sessions["s1"] = try makeSessionWithAgentText("hello")
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }

        var listHandleReturned = false
        let listTask = Task { @MainActor in
            await gw.handle(.listSessions)
            listHandleReturned = true
        }
        for _ in 0..<10 {
            if provider.sessionSummariesCallCount == 1 { break }
            await Task.yield()
        }

        #expect(provider.sessionSummariesCallCount == 1)
        #expect(listHandleReturned == true)
        #expect(sent.isEmpty)

        await gw.handle(.subscribe(sessionId: "s1"))
        #expect(sent.contains { message in
            if case .transcriptSnapshot(let id, _, _, _) = message {
                return id == "s1"
            }
            return false
        })

        provider.resumeSessionSummaries()
        await listTask.value
        for _ in 0..<10 {
            if sent.last == .sessionList(sessions: provider.summaries) { break }
            await Task.yield()
        }
        #expect(sent.last == .sessionList(sessions: provider.summaries))
    }

    @Test func listWorktreesDoesNotBlockFollowingStop() async {
        let provider = FakeSessionsProvider()
        provider.worktrees = [
            RemoteWorktreeOption(
                id: "wt1",
                projectName: "alas",
                worktreeName: "feature-a",
                branch: "nacho/feature-a",
                path: "/tmp/alas-feature-a",
                metricsAvailable: false,
                comparisonRef: nil,
                commitCount: 0,
                changedFileCount: 0,
                addedLines: 0,
                deletedLines: 0,
                conflictCount: 0
            )
        ]
        provider.pauseRemoteWorktrees = true
        provider.writers = ["s1"]
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }

        var listHandleReturned = false
        let listTask = Task { @MainActor in
            await gw.handle(.listWorktrees)
            listHandleReturned = true
        }
        for _ in 0..<10 {
            if provider.remoteWorktreesCallCount == 1 { break }
            await Task.yield()
        }

        #expect(provider.remoteWorktreesCallCount == 1)
        #expect(listHandleReturned == true)
        #expect(sent.isEmpty)

        await gw.handle(.stop(sessionId: "s1"))
        #expect(provider.stopped == ["s1"])

        provider.resumeRemoteWorktrees()
        await listTask.value
        for _ in 0..<10 {
            if sent.last == .worktreeList(worktrees: provider.worktrees) { break }
            await Task.yield()
        }
        #expect(sent.last == .worktreeList(worktrees: provider.worktrees))
    }

    @Test func subscribeEmitsSnapshot() async throws {
        let provider = FakeSessionsProvider()
        let s = try makeSessionWithAgentText("hello")
        provider.sessions["s1"] = s
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gw.handle(.subscribe(sessionId: "s1"))
        guard case .transcriptSnapshot(let id, _, _, let msgs)? = sent.first else {
            Issue.record("expected snapshot, got \(sent)")
            return
        }
        #expect(id == "s1")
        #expect(msgs.contains { $0.kind == "agent" && $0.text == "hello" })
    }

    @Test func takeOverPushesSnapshotWithCanDrive() async throws {
        // Regression: takeover seizes the writer lease synchronously but mutates
        // lease/agent state rather than the transcript, so the objectWillChange
        // delta may never fire on an idle session. The gateway must push a
        // snapshot itself so the client learns canDrive=true and unlocks the
        // composer instead of waiting for an unrelated transcript mutation.
        let provider = FakeSessionsProvider()
        let s = try makeSessionWithAgentText("hi")
        provider.sessions["s1"] = s
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gw.handle(.takeOver(sessionId: "s1"))
        #expect(provider.tookOver == ["s1"])
        let snap = sent.last { msg in
            if case .transcriptSnapshot = msg { return true }
            return false
        }
        guard case .transcriptSnapshot(let id, _, let canDrive, _)? = snap else {
            Issue.record("expected a snapshot after takeOver, got \(sent)")
            return
        }
        #expect(id == "s1")
        #expect(canDrive == true)
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

    @Test func questionAnswerWithUnknownOptionsIsNoOp() async throws {
        let provider = FakeSessionsProvider()
        let s = try makeSessionWithAgentText("x")
        provider.sessions["s1"] = s
        s.transcript.pendingQuestion = .init(id: .number(0), params: .stub())
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gw.handle(.subscribe(sessionId: "s1"))
        // Non-empty selection, but the ids aren't real options ("o1"/"o2") — must
        // not resume the agent with a vacuous (empty after filtering) answer.
        await gw.handle(.questionAnswer(
            sessionId: "s1",
            requestId: 0,
            answers: [RemoteQuestionAnswer(questionId: "q1", selectedOptionIds: ["bogus"])]))
        #expect(provider.lastQuestionResponse == nil)
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
            if case .transcriptDelta(_, _, _, let upserts) = msg { return upserts }
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

    @Test func closeCancelsPendingSessionListRefresh() async {
        let provider = FakeSessionsProvider()
        provider.summaries = [RemoteSessionSummary(id: "s1", title: "T", agentId: "claude", status: "idle", canDrive: false)]
        provider.pauseSessionSummaries = true
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }

        await gw.handle(.listSessions)
        for _ in 0..<10 {
            if provider.sessionSummariesCallCount == 1 { break }
            await Task.yield()
        }
        gw.close()
        provider.resumeSessionSummaries()
        for _ in 0..<10 {
            if !sent.isEmpty { break }
            await Task.yield()
        }

        #expect(provider.sessionSummariesCallCount == 1)
        #expect(sent.isEmpty)
    }

    @Test func takeOverRoutesToProvider() async {
        let provider = FakeSessionsProvider()
        let gw = RemoteSessionGateway(provider: provider) { _ in }
        await gw.handle(.takeOver(sessionId: "s1"))
        #expect(provider.tookOver == ["s1"])
    }

    @Test func sendPromptRoutesOnlyWhenWriter() async {
        let provider = FakeSessionsProvider()
        let gw = RemoteSessionGateway(provider: provider) { _ in }
        await gw.handle(.sendPrompt(sessionId: "s1", text: "hi", attachments: [])) // not writer → ignored
        #expect(provider.prompts.isEmpty)
        provider.writers.insert("s1")
        await gw.handle(.sendPrompt(sessionId: "s1", text: "hi", attachments: []))
        #expect(provider.prompts.map(\.text) == ["hi"])
    }

    @Test func sendPromptTrimsAndIgnoresBlankEvenWhenWriter() async {
        let provider = FakeSessionsProvider()
        provider.writers.insert("s1")
        let gw = RemoteSessionGateway(provider: provider) { _ in }
        await gw.handle(.sendPrompt(sessionId: "s1", text: "   \n  ", attachments: [])) // blank → ignored
        #expect(provider.prompts.isEmpty)
        await gw.handle(.sendPrompt(sessionId: "s1", text: "  hi  ", attachments: [])) // trimmed before forwarding
        #expect(provider.prompts.map(\.text) == ["hi"])
    }

    @Test func droppedSendPromptEmitsRejection() async {
        // A non-writer sendPrompt must tell the client it was dropped so the
        // composer can restore the text instead of silently losing the message.
        let provider = FakeSessionsProvider()
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gw.handle(.sendPrompt(sessionId: "s1", text: "hi", attachments: [])) // not writer
        #expect(provider.prompts.isEmpty)
        #expect(sent.contains(.promptRejected(sessionId: "s1")))
        // When we ARE the writer and the manager accepts, the prompt routes
        // and no rejection is sent.
        sent.removeAll()
        provider.writers.insert("s1")
        await gw.handle(.sendPrompt(sessionId: "s1", text: "hi", attachments: []))
        #expect(provider.prompts.map(\.text) == ["hi"])
        #expect(!sent.contains { if case .promptRejected = $0 { return true } else { return false } })
        // Writer, but the manager refuses the submit (e.g. needs auth) — the
        // client must still be told so it can restore the text.
        sent.removeAll()
        provider.sendPromptAccepts = false
        await gw.handle(.sendPrompt(sessionId: "s1", text: "later", attachments: []))
        #expect(sent.contains(.promptRejected(sessionId: "s1")))
    }

    @Test func stopRoutesOnlyWhenWriter() async {
        let provider = FakeSessionsProvider()
        let gw = RemoteSessionGateway(provider: provider) { _ in }
        await gw.handle(.stop(sessionId: "s1"))
        #expect(provider.stopped.isEmpty)
        provider.writers.insert("s1")
        await gw.handle(.stop(sessionId: "s1"))
        #expect(provider.stopped == ["s1"])
    }

    @Test func snapshotCarriesCanDrive() async throws {
        let provider = FakeSessionsProvider()
        let s = try makeSessionWithAgentText("hello")
        provider.sessions["s1"] = s
        provider.writers.insert("s1")
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gw.handle(.subscribe(sessionId: "s1"))
        let drive = sent.compactMap { msg -> Bool? in
            if case .transcriptSnapshot(_, _, let canDrive, _) = msg { return canDrive }
            return nil
        }.first
        #expect(drive == true)
    }

    @Test func configVerbsRouteOnlyWhenWriter() async {
        let provider = FakeSessionsProvider()
        let gw = RemoteSessionGateway(provider: provider) { _ in }
        await gw.handle(.setModel(sessionId: "s1", modelId: "opus"))   // not writer
        await gw.handle(.setAutoRun(sessionId: "s1", enabled: true))
        #expect(provider.models.isEmpty && provider.autoRuns.isEmpty)
        provider.writers.insert("s1")
        await gw.handle(.setModel(sessionId: "s1", modelId: "opus"))
        await gw.handle(.setMode(sessionId: "s1", modeId: "ask"))
        await gw.handle(.setAutoRun(sessionId: "s1", enabled: true))
        #expect(provider.models.map(\.model) == ["opus"])
        #expect(provider.modes.map(\.mode) == ["ask"])
        #expect(provider.autoRuns.map(\.enabled) == [true])
    }

    @Test func renameSessionTrimsTitleDoesNotRequireWriterAndRefreshesList() async {
        let provider = FakeSessionsProvider()
        provider.summaries = [RemoteSessionSummary(id: "s1", title: "Renamed", agentId: "claude", status: "idle", canDrive: false)]
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }

        await gw.handle(.renameSession(sessionId: "s1", title: "  Renamed  "))
        await Task.yield()

        #expect(provider.renamed.map(\.id) == ["s1"])
        #expect(provider.renamed.map(\.title) == ["Renamed"])
        #expect(sent.contains(.sessionRenamed(sessionId: "s1", title: "Renamed")))
        #expect(sent.contains(.sessionList(sessions: provider.summaries)))
        #expect(provider.sessionSummariesCallCount == 1)
    }

    @Test func renameSessionIgnoresEmptyTitle() async {
        let provider = FakeSessionsProvider()
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }

        await gw.handle(.renameSession(sessionId: "s1", title: " \n\t "))
        await Task.yield()

        #expect(provider.renamed.isEmpty)
        #expect(sent.isEmpty)
    }

    @Test func renameSessionFailureEmitsError() async {
        let provider = FakeSessionsProvider()
        provider.renameSucceeds = false
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }

        await gw.handle(.renameSession(sessionId: "missing", title: "Name"))
        await Task.yield()

        #expect(provider.renamed.map(\.id) == ["missing"])
        #expect(provider.renamed.map(\.title) == ["Name"])
        #expect(sent.contains { if case .error(let message) = $0 { return message.contains("rename") } else { return false } })
    }

    @Test func subscribeEmitsSessionConfig() async throws {
        let provider = FakeSessionsProvider()
        let s = try makeSessionWithAgentText("hi")
        provider.sessions["s1"] = s
        provider.configs["s1"] = .init(sessionId: "s1", models: [.init(id: "opus", name: "Opus")],
            modes: [], currentModel: "opus", currentMode: nil, autoRunEnabled: false, acceptsImages: true)
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gw.handle(.subscribe(sessionId: "s1"))
        #expect(sent.contains { if case .sessionConfig = $0 { return true } else { return false } })
    }

    @Test func sessionConfigChangeEmitsUpdate() async throws {
        let provider = FakeSessionsProvider()
        let s = try makeSessionWithAgentText("hi")
        s.availableModels = [.init(id: "opus", name: "Opus", description: nil)]
        provider.sessions["s1"] = s
        provider.configs["s1"] = .init(sessionId: "s1", models: [], modes: [], currentModel: nil,
            currentMode: nil, autoRunEnabled: false, acceptsImages: false)
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gw.handle(.subscribe(sessionId: "s1"))
        sent.removeAll()
        s.currentModel = "opus"                    // mutate config
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(sent.contains { if case .sessionConfig = $0 { return true } else { return false } })
    }

    @Test func oversizeAttachmentRejected() async {
        let provider = FakeSessionsProvider()
        provider.writers.insert("s1")
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        let big = String(repeating: "A", count: 14_000_000)   // ~10.5MB decoded > cap
        await gw.handle(.sendPrompt(sessionId: "s1", text: "x", attachments: [.init(name: nil, mimeType: "image/png", dataBase64: big)]))
        #expect(provider.lastAttachments.isEmpty)
        #expect(sent.contains(.promptRejected(sessionId: "s1")))
    }

    @Test func nonImageAttachmentRejected() async {
        let provider = FakeSessionsProvider()
        provider.writers.insert("s1")
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gw.handle(.sendPrompt(sessionId: "s1", text: "x", attachments: [.init(name: "f.txt", mimeType: "text/plain", dataBase64: "AAAA")]))
        #expect(sent.contains(.promptRejected(sessionId: "s1")))
    }

    @Test func imageOnlyUserMessageRendersPlaceholder() {
        // An image-only prompt (empty text) must not serialize to a blank bubble.
        let msg = ACPMessage.user(id: UUID(), text: "",
            attachments: [.init(uri: "file:///tmp/shot.png", name: "shot.png", mimeType: "image/png")])
        let wire = RemoteSessionGateway.toWire(msg, index: 0)
        #expect(wire.kind == "user")
        #expect(wire.text?.contains("shot.png") == true)
        #expect((wire.text ?? "").isEmpty == false)
    }

    @Test func tooManyAttachmentsRejected() async {
        // Count cap (parity with ACPComposer.maxImagesPerMessage) — a single
        // prompt can't write an unbounded number of tiny files.
        let provider = FakeSessionsProvider()
        provider.writers.insert("s1")
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        let many = (0..<(RemoteSessionGateway.maxAttachmentCount + 1)).map { _ in
            RemoteAttachment(name: "a.png", mimeType: "image/png", dataBase64: "iVBORw0KGgo=")
        }
        await gw.handle(.sendPrompt(sessionId: "s1", text: "x", attachments: many))
        #expect(sent.contains(.promptRejected(sessionId: "s1")))
        #expect(provider.writtenAttachmentURLs.isEmpty)   // rejected before any write
    }

    @Test func renamedNonImageWithImageMimeRejected() async {
        // Client claims image/png but the bytes aren't a real image — the byte
        // sniff must reject it rather than trusting the MIME, and write no file.
        let provider = FakeSessionsProvider()
        provider.writers.insert("s1")
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gw.handle(.sendPrompt(sessionId: "s1", text: "x", attachments: [.init(name: "evil.png", mimeType: "image/png", dataBase64: "AAAAAAAAAAA=")]))
        #expect(sent.contains(.promptRejected(sessionId: "s1")))
        #expect(provider.writtenAttachmentURLs.isEmpty)
    }

    @Test func validImageAttachmentSends() async {
        let provider = FakeSessionsProvider()
        provider.writers.insert("s1")
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gw.handle(.sendPrompt(sessionId: "s1", text: "look", attachments: [.init(name: "a.png", mimeType: "image/png", dataBase64: "iVBORw0KGgo=")]))
        #expect(provider.lastAttachments.count == 1)
        #expect(!sent.contains { if case .promptRejected = $0 { return true } else { return false } })
    }

    @Test func refusedSendDiscardsAttachmentFiles() async {
        // Writer at gateway time, but the manager refuses the submit (e.g. a
        // takeover landed mid-flight / needs auth). The files we wrote during
        // materialize must be cleaned up rather than orphaned on disk.
        let provider = FakeSessionsProvider()
        provider.writers.insert("s1")
        provider.sendPromptAccepts = false
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gw.handle(.sendPrompt(sessionId: "s1", text: "look", attachments: [.init(name: "a.png", mimeType: "image/png", dataBase64: "iVBORw0KGgo=")]))
        #expect(sent.contains(.promptRejected(sessionId: "s1")))
        #expect(!provider.writtenAttachmentURLs.isEmpty)
        for url in provider.writtenAttachmentURLs {
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func lateFailureKeepsAttachmentFiles() async throws {
        // A LATE (async) delivery failure means sendNow already recorded the
        // user message referencing these file URIs — the gateway must NOT
        // delete them (only synchronous refusals, never recorded, are cleaned).
        let provider = FakeSessionsProvider()
        provider.writers.insert("s1")
        provider.sendPromptAccepts = false
        provider.sendPromptResultIsAsync = true
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gw.handle(.sendPrompt(sessionId: "s1", text: "look", attachments: [.init(name: "a.png", mimeType: "image/png", dataBase64: "iVBORw0KGgo=")]))
        try await Task.sleep(nanoseconds: 30_000_000)   // let the async onResult land
        #expect(sent.contains(.promptRejected(sessionId: "s1")))
        #expect(!provider.writtenAttachmentURLs.isEmpty)
        for url in provider.writtenAttachmentURLs {
            #expect(FileManager.default.fileExists(atPath: url.path))   // kept
        }
        // cleanup
        for url in provider.writtenAttachmentURLs { try? FileManager.default.removeItem(at: url) }
    }
}
