import Testing
import Foundation
@testable import Alas

@MainActor
final class FakeSessionsProvider: RemoteSessionsProvider {
    var summaries: [RemoteSessionSummary] = []
    var worktrees: [RemoteWorktreeOption] = []
    var projects: [RemoteProjectOption] = []
    var branchResults: [String: RemoteBranchListResult] = [:]
    var agents: [RemoteAgentOption] = []
    var createResults: [String: RemoteCreateSessionResult] = [:]
    var sessions: [String: ACPSession] = [:]
    var policies: [String: ACPPermissionPolicy] = [:]
    var lastQuestionResponse: (id: String, requestId: JSONRPCID, response: ACPQuestionResponse)?
    var lastUserInputResponse: (id: String, token: UUID, action: ACPUserInputAction)?
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
    var queueForceSends: [(id: String, itemId: UUID)] = []
    var queueRemoves: [(id: String, itemId: UUID)] = []
    var queueRetries: [(id: String, itemId: UUID)] = []
    var queueEdits: [(id: String, itemId: UUID)] = []
    var queueClears: [String] = []
    var queueSteerUndos: [String] = []
    var steerPrompts: [(id: String, text: String)] = []
    var queueEditText: String?            // what queueEdit hands back
    /// When set, `queueEdit` delegates to this real manager instead of
    /// returning `queueEditText`, so a test can exercise the manager's own
    /// guard logic (e.g. refusing an item with a mention/image) through the
    /// gateway rather than a canned stub.
    var manager: ACPSessionManager?
    var steerPromptAccepts = true
    var fullToolCallContents: [String: String] = [:]
    var fullToolCallContentCallCount = 0
    var sessionSummariesCallCount = 0
    var remoteWorktreesCallCount = 0
    var remoteProjectsCallCount = 0
    var remoteBranchesCallCount = 0
    var remoteBranchRequests: [String] = []
    var remoteAgentsCallCount = 0
    var createRequests: [(worktreeId: String, agentId: String)] = []
    var pauseSessionSummaries = false
    var pauseRemoteWorktrees = false
    var pauseRemoteProjects = false
    var pauseRemoteBranches = false
    /// 1-indexed call number of `fullToolCallContent` to suspend on (nil = never pause).
    /// Lets a test freeze exactly one in-flight fetch while later calls proceed normally.
    var pauseFullToolCallContentOnCall: Int?
    private var sessionSummariesContinuation: CheckedContinuation<[RemoteSessionSummary], Never>?
    private var remoteWorktreesContinuation: CheckedContinuation<[RemoteWorktreeOption], Never>?
    private var remoteProjectsContinuation: CheckedContinuation<[RemoteProjectOption], Never>?
    private var remoteBranchesContinuation: CheckedContinuation<RemoteBranchListResult, Never>?
    private var fullToolCallContentContinuation: CheckedContinuation<String?, Never>?
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
    func remoteProjects() async -> [RemoteProjectOption] {
        remoteProjectsCallCount += 1
        if pauseRemoteProjects {
            return await withCheckedContinuation { continuation in
                remoteProjectsContinuation = continuation
            }
        }
        return projects
    }
    func remoteBranches(projectId: String) async -> RemoteBranchListResult {
        remoteBranchesCallCount += 1
        remoteBranchRequests.append(projectId)
        if pauseRemoteBranches {
            return await withCheckedContinuation { continuation in
                remoteBranchesContinuation = continuation
            }
        }
        return branchResults[projectId] ?? .failure("Could not load branches.")
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
    func resumeRemoteProjects() {
        remoteProjectsContinuation?.resume(returning: projects)
        remoteProjectsContinuation = nil
    }
    func resumeRemoteBranches(projectId: String) {
        remoteBranchesContinuation?.resume(
            returning: branchResults[projectId] ?? .failure("Could not load branches.")
        )
        remoteBranchesContinuation = nil
    }
    func session(for id: String) -> ACPSession? { sessions[id] }
    func permissionPolicy(for id: String) -> ACPPermissionPolicy? { policies[id] }
    func hydrateIfNeeded(id: String) async {}
    func answerQuestion(for id: String, requestId: JSONRPCID, _ response: ACPQuestionResponse) {
        lastQuestionResponse = (id, requestId, response)
    }
    func respondToUserInput(for id: String, token: UUID, action: ACPUserInputAction) {
        lastUserInputResponse = (id, token, action)
    }

    func fullToolCallContent(sessionId: String, toolCallId: String) async -> String? {
        fullToolCallContentCallCount += 1
        if pauseFullToolCallContentOnCall == fullToolCallContentCallCount {
            return await withCheckedContinuation { continuation in
                fullToolCallContentContinuation = continuation
            }
        }
        return fullToolCallContents["\(sessionId)|\(toolCallId)"]
    }
    func resumeFullToolCallContent(_ value: String?) {
        fullToolCallContentContinuation?.resume(returning: value)
        fullToolCallContentContinuation = nil
    }

    func isWriter(for id: String) -> Bool { writers.contains(id) }
    var pauseTakeOver = false   // suspends INSIDE the gateway's own await, unlike pauseSessionSummaries's detached fetch
    var takeOverCallCount = 0
    private var takeOverContinuation: CheckedContinuation<Void, Never>?
    func takeOver(for id: String) async {
        takeOverCallCount += 1
        tookOver.append(id)
        writers.insert(id)
        if pauseTakeOver {
            await withCheckedContinuation { continuation in
                takeOverContinuation = continuation
            }
        }
    }
    func resumeTakeOver() {
        takeOverContinuation?.resume()
        takeOverContinuation = nil
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

    func queueForceSend(for id: String, itemId: UUID) { queueForceSends.append((id, itemId)) }
    func queueRemove(for id: String, itemId: UUID) { queueRemoves.append((id, itemId)) }
    func queueRetry(for id: String, itemId: UUID) { queueRetries.append((id, itemId)) }
    func queueEdit(for id: String, itemId: UUID) async -> String? {
        queueEdits.append((id, itemId))
        if let manager { return await manager.queueEdit(for: id, itemId: itemId) }
        return queueEditText
    }
    func queueClear(for id: String) { queueClears.append(id) }
    func queueSteerUndo(for id: String) { queueSteerUndos.append(id) }
    func steerPrompt(for id: String, text: String, attachments: [ACPMessage.Attachment], onResult: @escaping @MainActor (Bool) -> Void) {
        let accepted = writers.contains(id) && steerPromptAccepts
        if accepted { steerPrompts.append((id, text)) }
        onResult(accepted)
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
            if case .transcriptSnapshot(let id, _, _, _, _, _, _, _) = message {
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
        guard case .transcriptSnapshot(let id, _, _, let msgs, _, _, _, _)? = sent.first else {
            Issue.record("expected snapshot, got \(sent)")
            return
        }
        #expect(id == "s1")
        #expect(msgs.contains { $0.kind == "agent" && $0.text == "hello" })
    }

    @Test func snapshotRestoresFullTruncatedToolCallContent() async throws {
        let provider = FakeSessionsProvider()
        let fullContent = String(repeating: "abcdef0123456789", count: 400)
        var toolCall = ACPMessage.ToolCall(
            toolCallId: "old",
            title: "read",
            status: "completed",
            content: fullContent,
            preview: "abcdef"
        )
        toolCall.truncateForOffWindow()
        let session = try makeSessionWithAgentText("tail")
        session.transcript.messages = [.toolCall(toolCall)]
        provider.sessions["s1"] = session
        provider.fullToolCallContents["s1|old"] = fullContent
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }

        await gw.handle(.subscribe(sessionId: "s1"))

        guard case .transcriptSnapshot(_, _, _, let msgs, _, _, _, _)? = sent.first,
              let json = msgs.first(where: { $0.kind == "toolCall" })?.json,
              let data = json.data(using: .utf8)
        else {
            Issue.record("expected tool-call snapshot, got \(sent)")
            return
        }
        let remoteToolCall = try JSONDecoder().decode(ACPMessage.ToolCall.self, from: data)
        #expect(remoteToolCall.content == fullContent)
        if case .toolCall(let localToolCall) = session.transcript.messages[0] {
            #expect(localToolCall.isContentTruncated)
        } else {
            Issue.record("expected local tool call")
        }
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
        guard case .transcriptSnapshot(let id, _, let canDrive, _, _, _, _, _)? = snap else {
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
        #expect(last.requestId == .number(0))
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

    @Test func subscribeEmitsStandardElicitationAndAcceptRoutesByOpaqueToken() async throws {
        let provider = FakeSessionsProvider()
        let session = try makeSessionWithAgentText("x")
        provider.sessions["s1"] = session
        let params = try JSONDecoder().decode(
            ACPElicitationRequestParams.self,
            from: Data(#"""
            {"sessionId":"remote","mode":"form","message":"Pick", "requestedSchema":{
              "properties":{"strategy":{"type":"string","enum":["safe","fast"]}},
              "required":["strategy"]
            }}
            """#.utf8)
        )
        let pending = try #require(ACPUserInputRequest.elicitation(.init(id: .number(4), params: params)))
        session.transcript.pendingUserInputs = [pending]
        var sent: [RemoteServerMessage] = []
        let gateway = RemoteSessionGateway(provider: provider) { sent.append($0) }

        await gateway.handle(.subscribe(sessionId: "s1"))
        let payload = try #require(sent.compactMap { message -> RemoteElicitationPayload? in
            if case .elicitationRequest(_, let payload) = message { return payload }
            return nil
        }.first)
        #expect(payload.requestId == pending.id.uuidString)
        #expect(payload.fields.first?.options.map(\.value) == ["safe", "fast"])

        session.transcript.messages.append(.agent(id: UUID(), StreamingText("still waiting")))
        try await Task.sleep(nanoseconds: 250_000_000)
        #expect(sent.filter {
            if case .elicitationRequest = $0 { return true }
            return false
        }.count == 1)

        await gateway.handle(.elicitationResponse(
            sessionId: "s1",
            requestId: payload.requestId,
            action: "accept",
            content: ["strategy": .string("safe")]
        ))
        let response = try #require(provider.lastUserInputResponse)
        #expect(response.id == "s1")
        #expect(response.token == pending.id)
        #expect(response.action == .submit(["strategy": .string("safe")]))
    }

    @Test func remoteInputSurfaceDoesNotSkipPastSharedQueueHead() async throws {
        let provider = FakeSessionsProvider()
        let session = try makeSessionWithAgentText("x")
        provider.sessions["s1"] = session
        let cursorParams = ACPQuestionRequestParams.stub(title: "First")
        let cursor = ACPUserInputRequest.cursor(.init(id: .number(1), params: cursorParams))
        let params = try JSONDecoder().decode(
            ACPElicitationRequestParams.self,
            from: Data(#"""
            {"sessionId":"remote","mode":"form","message":"Second", "requestedSchema":{"properties":{}}}
            """#.utf8)
        )
        let elicitation = try #require(ACPUserInputRequest.elicitation(.init(id: .number(2), params: params)))
        session.transcript.pendingUserInputs = [cursor, elicitation]
        session.transcript.pendingQuestion = .init(id: .number(1), params: cursorParams)
        var sent: [RemoteServerMessage] = []
        let gateway = RemoteSessionGateway(provider: provider) { sent.append($0) }

        await gateway.handle(.subscribe(sessionId: "s1"))

        #expect(sent.contains {
            if case .questionRequest = $0 { return true }
            return false
        })
        #expect(!sent.contains {
            if case .elicitationRequest = $0 { return true }
            return false
        })
    }

    @Test func elicitationResponseMustSatisfySchemaConstraints() async throws {
        let provider = FakeSessionsProvider()
        let session = try makeSessionWithAgentText("x")
        provider.sessions["s1"] = session
        let params = try JSONDecoder().decode(
            ACPElicitationRequestParams.self,
            from: Data(#"""
            {"sessionId":"remote","mode":"form","message":"Configure", "requestedSchema":{
              "properties":{
                "name":{"type":"string","minLength":3,"pattern":"^[a-z]+$"},
                "count":{"type":"integer","minimum":1,"maximum":4},
                "tags":{"type":"array","items":{"type":"string","enum":["one","two"]},"minItems":1}
              },
              "required":["name","count","tags"]
            }}
            """#.utf8)
        )
        let pending = try #require(ACPUserInputRequest.elicitation(.init(id: .number(4), params: params)))
        session.transcript.pendingUserInputs = [pending]
        let gateway = RemoteSessionGateway(provider: provider) { _ in }

        await gateway.handle(.elicitationResponse(
            sessionId: "s1",
            requestId: pending.id.uuidString,
            action: "accept",
            content: [
                "name": .string("A"),
                "count": .integer(8),
                "tags": .strings(["unknown"]),
            ]
        ))

        #expect(provider.lastUserInputResponse == nil)
    }

    @Test func integralWireValueIsValidForNumberElicitation() async throws {
        let provider = FakeSessionsProvider()
        let session = try makeSessionWithAgentText("x")
        provider.sessions["s1"] = session
        let params = try JSONDecoder().decode(
            ACPElicitationRequestParams.self,
            from: Data(#"""
            {"sessionId":"remote","mode":"form","message":"Configure", "requestedSchema":{
              "properties":{"ratio":{"type":"number","minimum":0,"maximum":2}},
              "required":["ratio"]
            }}
            """#.utf8)
        )
        let pending = try #require(ACPUserInputRequest.elicitation(.init(id: .number(5), params: params)))
        session.transcript.pendingUserInputs = [pending]
        let gateway = RemoteSessionGateway(provider: provider) { _ in }

        await gateway.handle(.elicitationResponse(
            sessionId: "s1",
            requestId: pending.id.uuidString,
            action: "accept",
            content: ["ratio": .integer(1)]
        ))

        #expect(provider.lastUserInputResponse?.action == .submit(["ratio": .integer(1)]))
    }

    @Test func fractionalSecondsAreValidForDateTimeElicitation() async throws {
        let provider = FakeSessionsProvider()
        let session = try makeSessionWithAgentText("x")
        provider.sessions["s1"] = session
        let params = try JSONDecoder().decode(
            ACPElicitationRequestParams.self,
            from: Data(#"""
            {"sessionId":"remote","mode":"form","message":"Schedule", "requestedSchema":{
              "properties":{"startsAt":{"type":"string","format":"date-time"}},
              "required":["startsAt"]
            }}
            """#.utf8)
        )
        let pending = try #require(ACPUserInputRequest.elicitation(.init(id: .number(6), params: params)))
        session.transcript.pendingUserInputs = [pending]
        let gateway = RemoteSessionGateway(provider: provider) { _ in }

        await gateway.handle(.elicitationResponse(
            sessionId: "s1",
            requestId: pending.id.uuidString,
            action: "accept",
            content: ["startsAt": .string("2026-07-10T14:30:00.000Z")]
        ))

        #expect(provider.lastUserInputResponse?.action == .submit([
            "startsAt": .string("2026-07-10T14:30:00.000Z"),
        ]))
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
            if case .transcriptDelta(_, _, _, let upserts, _, _) = msg { return upserts }
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
        await gw.handle(.sendPrompt(sessionId: "s1", text: "hi", attachments: [], intent: "auto")) // not writer → ignored
        #expect(provider.prompts.isEmpty)
        provider.writers.insert("s1")
        await gw.handle(.sendPrompt(sessionId: "s1", text: "hi", attachments: [], intent: "auto"))
        #expect(provider.prompts.map(\.text) == ["hi"])
    }

    @Test func sendPromptTrimsAndIgnoresBlankEvenWhenWriter() async {
        let provider = FakeSessionsProvider()
        provider.writers.insert("s1")
        let gw = RemoteSessionGateway(provider: provider) { _ in }
        await gw.handle(.sendPrompt(sessionId: "s1", text: "   \n  ", attachments: [], intent: "auto")) // blank → ignored
        #expect(provider.prompts.isEmpty)
        await gw.handle(.sendPrompt(sessionId: "s1", text: "  hi  ", attachments: [], intent: "auto")) // trimmed before forwarding
        #expect(provider.prompts.map(\.text) == ["hi"])
    }

    @Test func droppedSendPromptEmitsRejection() async {
        // A non-writer sendPrompt must tell the client it was dropped so the
        // composer can restore the text instead of silently losing the message.
        let provider = FakeSessionsProvider()
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gw.handle(.sendPrompt(sessionId: "s1", text: "hi", attachments: [], intent: "auto")) // not writer
        #expect(provider.prompts.isEmpty)
        #expect(sent.contains(.promptRejected(sessionId: "s1")))
        // When we ARE the writer and the manager accepts, the prompt routes
        // and no rejection is sent.
        sent.removeAll()
        provider.writers.insert("s1")
        await gw.handle(.sendPrompt(sessionId: "s1", text: "hi", attachments: [], intent: "auto"))
        #expect(provider.prompts.map(\.text) == ["hi"])
        #expect(!sent.contains { if case .promptRejected = $0 { return true } else { return false } })
        // Writer, but the manager refuses the submit (e.g. needs auth) — the
        // client must still be told so it can restore the text.
        sent.removeAll()
        provider.sendPromptAccepts = false
        await gw.handle(.sendPrompt(sessionId: "s1", text: "later", attachments: [], intent: "auto"))
        #expect(sent.contains(.promptRejected(sessionId: "s1")))
    }

    @Test func stopWorksRegardlessOfWriterStatus() async {
        // Stop is a fast-lane emergency brake: it no longer requires the
        // writer lease, so it must succeed whether or not the caller is
        // the current writer.
        let provider = FakeSessionsProvider()
        let gw = RemoteSessionGateway(provider: provider) { _ in }
        await gw.handle(.stop(sessionId: "s1"))
        #expect(provider.stopped == ["s1"])
        provider.writers.insert("s1")
        await gw.handle(.stop(sessionId: "s1"))
        #expect(provider.stopped == ["s1", "s1"])
    }

    @Test func stopWorksWithoutWriterLeaseAndAcksImmediately() async throws {
        let provider = FakeSessionsProvider()
        provider.sessions["s1"] = try makeSessionWithAgentText("hi")
        // NOTE: provider.writers is intentionally empty — not the writer.
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gw.handle(.stop(sessionId: "s1"))
        #expect(provider.stopped == ["s1"])
        #expect(sent.first == .stopPending(sessionId: "s1"))
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
            if case .transcriptSnapshot(_, _, let canDrive, _, _, _, _, _) = msg { return canDrive }
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
        await gw.handle(.sendPrompt(sessionId: "s1", text: "x", attachments: [.init(name: nil, mimeType: "image/png", dataBase64: big)], intent: "auto"))
        #expect(provider.lastAttachments.isEmpty)
        #expect(sent.contains(.promptRejected(sessionId: "s1")))
    }

    @Test func nonImageAttachmentRejected() async {
        let provider = FakeSessionsProvider()
        provider.writers.insert("s1")
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gw.handle(.sendPrompt(sessionId: "s1", text: "x", attachments: [.init(name: "f.txt", mimeType: "text/plain", dataBase64: "AAAA")], intent: "auto"))
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

    @Test func toolCallWireOmitsInlineAssetData() throws {
        let msg = ACPMessage.toolCall(.init(
            toolCallId: "tc-image",
            title: "Image generation",
            kind: "other",
            status: "completed",
            content: "",
            preview: nil,
            rawOutput: #"{"b64_json":"raw-output-base64"}"#,
            metadata: AnyCodable([
                "terminal_output_delta": AnyCodable([
                    "terminal_id": AnyCodable("term-remote"),
                    "data": AnyCodable("large terminal output")
                ])
            ]),
            assets: [
                .image(
                    data: "base64-image-data",
                    uri: "file:///tmp/shot.png",
                    mimeType: "image/png",
                    name: "shot.png"
                ),
                .image(
                    data: nil,
                    uri: " \ndata:image/png;base64,inline-uri-data",
                    mimeType: "image/png",
                    name: "inline-uri.png"
                ),
                .resource(
                    uri: "data:application/json;base64,inline-resource-data",
                    name: "inline-resource.json",
                    mimeType: "application/json"
                )
            ]))

        let wire = RemoteSessionGateway.toWire(msg, index: 0)
        let json = try #require(wire.json)
        #expect(!json.contains("base64-image-data"))
        #expect(!json.contains("inline-uri-data"))
        #expect(!json.contains("inline-resource-data"))
        #expect(!json.contains("raw-output-base64"))
        #expect(!json.contains("large terminal output"))

        let payload = try #require(json.data(using: .utf8))
        let decoded = try JSONDecoder().decode(ACPMessage.ToolCall.self, from: payload)
        #expect(decoded.rawOutput == nil)
        #expect(decoded.metadata == nil)
        #expect(decoded.assets == [
            .image(
                data: nil,
                uri: "file:///tmp/shot.png",
                mimeType: "image/png",
                name: "shot.png"
            ),
            .image(
                data: nil,
                uri: nil,
                mimeType: "image/png",
                name: "inline-uri.png"
            ),
            .init(
                kind: .resource,
                uri: nil,
                mimeType: "application/json",
                name: "inline-resource.json"
            )
        ])
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
        await gw.handle(.sendPrompt(sessionId: "s1", text: "x", attachments: many, intent: "auto"))
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
        await gw.handle(.sendPrompt(sessionId: "s1", text: "x", attachments: [.init(name: "evil.png", mimeType: "image/png", dataBase64: "AAAAAAAAAAA=")], intent: "auto"))
        #expect(sent.contains(.promptRejected(sessionId: "s1")))
        #expect(provider.writtenAttachmentURLs.isEmpty)
    }

    @Test func validImageAttachmentSends() async {
        let provider = FakeSessionsProvider()
        provider.writers.insert("s1")
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gw.handle(.sendPrompt(sessionId: "s1", text: "look", attachments: [.init(name: "a.png", mimeType: "image/png", dataBase64: "iVBORw0KGgo=")], intent: "auto"))
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
        await gw.handle(.sendPrompt(sessionId: "s1", text: "look", attachments: [.init(name: "a.png", mimeType: "image/png", dataBase64: "iVBORw0KGgo=")], intent: "auto"))
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
        await gw.handle(.sendPrompt(sessionId: "s1", text: "look", attachments: [.init(name: "a.png", mimeType: "image/png", dataBase64: "iVBORw0KGgo=")], intent: "auto"))
        try await Task.sleep(nanoseconds: 30_000_000)   // let the async onResult land
        #expect(sent.contains(.promptRejected(sessionId: "s1")))
        #expect(!provider.writtenAttachmentURLs.isEmpty)
        for url in provider.writtenAttachmentURLs {
            #expect(FileManager.default.fileExists(atPath: url.path))   // kept
        }
        // cleanup
        for url in provider.writtenAttachmentURLs { try? FileManager.default.removeItem(at: url) }
    }

    private func makeSessionWithUserMessages(_ count: Int) throws -> ACPSession {
        let mgr = try makeManager()
        let s = mgr.createSession(agentId: "claude")
        s.transcript.messages = (0..<count).map {
            .user(id: UUID(), messageId: "u\($0)", text: "msg \($0)", attachments: [])
        }
        return s
    }

    @Test func snapshotOfLongTranscriptIsTailWindowed() async throws {
        let provider = FakeSessionsProvider()
        let s = try makeSessionWithUserMessages(200)
        provider.sessions["s1"] = s
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gw.handle(.subscribe(sessionId: "s1"))
        guard case .transcriptSnapshot(_, _, _, let msgs, let first, let total, _, let revision)? = sent.first else {
            Issue.record("expected snapshot, got \(sent)")
            return
        }
        #expect(total == 200)
        #expect(first == 200 - RemoteTranscriptSync.tailWindow)
        #expect(msgs.count == RemoteTranscriptSync.tailWindow)
        #expect(msgs.first?.stableId == "m\(first)")
        #expect(msgs.first?.index == first)
        #expect(revision == 0)
    }

    @Test func deltaCarriesOnlyDirtyMessages() async throws {
        let provider = FakeSessionsProvider()
        let s = try makeSessionWithUserMessages(50)
        provider.sessions["s1"] = s
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gw.handle(.subscribe(sessionId: "s1"))
        sent.removeAll()
        s.transcript.messages.append(.systemNotice(id: UUID(), text: "done"))
        try await Task.sleep(nanoseconds: 250_000_000)   // > coalesce window
        let delta = sent.compactMap { msg -> [RemoteWireMessage]? in
            if case .transcriptDelta(_, _, _, let u, _, _) = msg { return u }
            return nil
        }.last
        #expect(delta?.count == 1)
        #expect(delta?.first?.index == 50)
        #expect(delta?.first?.kind == "systemNotice")
    }

    @Test func structuralChangeTriggersResyncSnapshotWithBumpedEpoch() async throws {
        let provider = FakeSessionsProvider()
        let s = try makeSessionWithUserMessages(10)
        provider.sessions["s1"] = s
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gw.handle(.subscribe(sessionId: "s1"))
        guard case .transcriptSnapshot(_, _, _, _, _, _, let epoch0, _)? = sent.first else {
            Issue.record("expected snapshot")
            return
        }
        sent.removeAll()
        s.transcript.messages.removeLast()               // structural
        try await Task.sleep(nanoseconds: 250_000_000)
        let resync = sent.last { if case .transcriptSnapshot = $0 { return true }
        return false }
        guard case .transcriptSnapshot(_, _, _, let msgs, _, let total, let epoch1, _)? = resync else {
            Issue.record("expected resync snapshot, got \(sent)")
            return
        }
        #expect(epoch1 == epoch0 + 1)
        #expect(total == 9)
        #expect(msgs.count == 9)
    }

    @Test func fetchOlderReturnsClampedPage() async throws {
        let provider = FakeSessionsProvider()
        let s = try makeSessionWithUserMessages(200)
        provider.sessions["s1"] = s
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gw.handle(.subscribe(sessionId: "s1"))
        sent.removeAll()
        await gw.handle(.fetchOlder(sessionId: "s1", beforeIndex: 110, limit: 90))
        guard case .transcriptPage(_, _, let first, let msgs)? = sent.last else {
            Issue.record("expected page, got \(sent)")
            return
        }
        #expect(first == 20)
        #expect(msgs.count == 90)
        #expect(msgs.first?.index == 20)
        #expect(msgs.last?.index == 109)

        sent.removeAll()
        await gw.handle(.fetchOlder(sessionId: "s1", beforeIndex: 10, limit: 500))   // clamp both ends
        guard case .transcriptPage(_, _, let first2, let msgs2)? = sent.last else {
            Issue.record("expected page, got \(sent)")
            return
        }
        #expect(first2 == 0)
        #expect(msgs2.count == 10)
    }

    @Test func fetchOlderBeforeSubscribeIsIgnored() async throws {
        let provider = FakeSessionsProvider()
        provider.sessions["s1"] = try makeSessionWithUserMessages(5)
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gw.handle(.fetchOlder(sessionId: "s1", beforeIndex: 5, limit: 5))
        #expect(sent.isEmpty)
    }

    @Test func truncatedToolContentIsFetchedOnceAcrossSnapshotAndDeltas() async throws {
        let provider = FakeSessionsProvider()
        let fullContent = String(repeating: "abcdef0123456789", count: 400)
        var toolCall = ACPMessage.ToolCall(
            toolCallId: "old", title: "read", status: "completed",
            content: fullContent, preview: "abcdef")
        toolCall.truncateForOffWindow()
        let session = try makeSessionWithAgentText("tail")
        session.transcript.messages = [.toolCall(toolCall), .agent(id: UUID(), StreamingText("tail"))]
        provider.sessions["s1"] = session
        provider.fullToolCallContents["s1|old"] = fullContent
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gw.handle(.subscribe(sessionId: "s1"))
        #expect(provider.fullToolCallContentCallCount == 1)
        // A dirty tick on the OTHER message must not re-fetch tool content.
        session.transcript.messages.append(.systemNotice(id: UUID(), text: "x"))
        try await Task.sleep(nanoseconds: 250_000_000)
        #expect(provider.fullToolCallContentCallCount == 1)
    }

    @Test func unsubscribeReleasesChangeTracking() async throws {
        let provider = FakeSessionsProvider()
        let s = try makeSessionWithUserMessages(3)
        provider.sessions["s1"] = s
        let gw = RemoteSessionGateway(provider: provider) { _ in }
        await gw.handle(.subscribe(sessionId: "s1"))
        #expect(s.transcript.changeLog.isTracking)
        await gw.handle(.unsubscribe(sessionId: "s1"))
        #expect(!s.transcript.changeLog.isTracking)
    }

    @Test func resubscribeDoesNotLeakTrackingRetains() async throws {
        let provider = FakeSessionsProvider()
        let s = try makeSessionWithUserMessages(3)
        provider.sessions["s1"] = s
        let gw = RemoteSessionGateway(provider: provider) { _ in }
        await gw.handle(.subscribe(sessionId: "s1"))
        await gw.handle(.subscribe(sessionId: "s1"))   // client resync
        await gw.handle(.unsubscribe(sessionId: "s1"))
        #expect(!s.transcript.changeLog.isTracking)
    }

    // Regression (codex review, PR #775): a dirty delta that suspends mid-
    // serialize (awaiting truncated tool-call content) while a CONCURRENT
    // structural resync lands on the same session must not resume and send
    // its now-stale upserts stamped with the resync's new epoch/revision —
    // the client would wrongly accept them as a legitimate next delta.
    @Test func deltaDropsStaleUpsertsWhenEpochChangesDuringSerialize() async throws {
        let provider = FakeSessionsProvider()
        let fullContent = String(repeating: "abcdef0123456789", count: 400)
        var toolCall = ACPMessage.ToolCall(
            toolCallId: "old", title: "read", status: "in_progress",
            content: fullContent, preview: "abcdef")
        toolCall.truncateForOffWindow()
        let mgr = try makeManager()
        let session = mgr.createSession(agentId: "claude")
        session.transcript.messages = [.toolCall(toolCall)] + (0..<5).map {
            .user(id: UUID(), messageId: "u\($0)", text: "msg \($0)", attachments: [])
        }
        provider.sessions["s1"] = session
        provider.fullToolCallContents["s1|old"] = fullContent
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }

        await gw.handle(.subscribe(sessionId: "s1"))   // caches "old"'s content
        sent.removeAll()
        provider.fullToolCallContentCallCount = 0
        provider.pauseFullToolCallContentOnCall = 1   // suspend the delta's re-fetch below

        // Mutate the tool call in place (dirty, not structural) — invalidates
        // its cache and forces a real re-fetch in the resulting delta.
        if case .toolCall(var tc) = session.transcript.messages[0] {
            tc.status = "completed"
            session.transcript.messages[0] = .toolCall(tc)
        }

        // Wait for the coalesce timer to fire and the delta to suspend on the
        // paused fetch (call #1).
        for _ in 0..<50 where provider.fullToolCallContentCallCount == 0 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(provider.fullToolCallContentCallCount == 1)

        // While that delta is suspended, a structural change lands on the
        // SAME session and its own coalesced delta resyncs via a fresh
        // snapshot (its tool-content fetch is call #2, not paused).
        session.transcript.messages.removeLast()
        for _ in 0..<50 where !(sent.last.map { if case .transcriptSnapshot = $0 { return true }
        return false } ?? false) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard case .transcriptSnapshot(_, _, _, _, _, _, let resyncEpoch, _)? = sent.last else {
            Issue.record("expected a resync snapshot from the structural change, got \(sent)")
            return
        }

        sent.removeAll()
        // Resume the original delta's suspended fetch. With the fix, it must
        // detect the epoch moved during its await and discard rather than
        // send a stale delta stamped with the new epoch.
        provider.resumeFullToolCallContent(fullContent)
        try await Task.sleep(nanoseconds: 250_000_000)   // > coalesce window
        #expect(sent.isEmpty, "stale delta must be discarded once epoch changed during serialize, got \(sent)")
        #expect(resyncEpoch != 0)   // sanity: the resync did bump the epoch
    }

    // Regression (codex review, PR #775): an epoch-only guard misses a
    // SAME-epoch snapshot (e.g. a takeOver, or a client resubscribe with no
    // intervening structural change) landing while a dirty delta is
    // suspended mid-serialize — the snapshot still resets revision/
    // sentVersion, so the resumed delta's stale content would be accepted
    // as the next legitimate delta after it. The generation counter (bumped
    // on every snapshot regardless of epoch) must catch this too.
    @Test func deltaDropsStaleUpsertsWhenSameEpochSnapshotLandsDuringSerialize() async throws {
        let provider = FakeSessionsProvider()
        let fullContent = String(repeating: "abcdef0123456789", count: 400)
        var toolCall = ACPMessage.ToolCall(
            toolCallId: "old", title: "read", status: "in_progress",
            content: fullContent, preview: "abcdef")
        toolCall.truncateForOffWindow()
        let mgr = try makeManager()
        let session = mgr.createSession(agentId: "claude")
        session.transcript.messages = [.toolCall(toolCall)] + (0..<5).map {
            .user(id: UUID(), messageId: "u\($0)", text: "msg \($0)", attachments: [])
        }
        provider.sessions["s1"] = session
        provider.fullToolCallContents["s1|old"] = fullContent
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }

        await gw.handle(.subscribe(sessionId: "s1"))   // caches "old"'s content
        sent.removeAll()
        provider.fullToolCallContentCallCount = 0
        provider.pauseFullToolCallContentOnCall = 1   // suspend the delta's re-fetch below

        if case .toolCall(var tc) = session.transcript.messages[0] {
            tc.status = "completed"
            session.transcript.messages[0] = .toolCall(tc)
        }

        for _ in 0..<50 where provider.fullToolCallContentCallCount == 0 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(provider.fullToolCallContentCallCount == 1)

        // A SAME-epoch snapshot lands via takeOver — no structural change,
        // so the transcript's epoch never moves.
        await gw.handle(.takeOver(sessionId: "s1"))
        guard case .transcriptSnapshot(_, _, _, _, _, _, let snapshotEpoch, _)? = sent.last else {
            Issue.record("expected a snapshot from takeOver, got \(sent)")
            return
        }
        #expect(snapshotEpoch == 0)   // sanity: confirms this is the same-epoch case

        sent.removeAll()
        provider.resumeFullToolCallContent(fullContent)
        try await Task.sleep(nanoseconds: 250_000_000)   // > coalesce window
        #expect(sent.isEmpty, "stale delta must be discarded once a same-epoch snapshot landed during serialize, got \(sent)")
    }

    // Regression (codex review, PR #775): two overlapping DIRTY deltas race
    // the same way a delta and a snapshot do — a still-running (cancelled-
    // but-not-stopped) coalesce Task can suspend mid-serialize while a later
    // mutation's own coalesce Task completes and sends first. The earlier
    // delta must not resume, pass an unchanged-generation check, and roll
    // the client back with its now-stale content at a higher revision.
    @Test func deltaDropsStaleUpsertsWhenOverlappingDirtyDeltaLandsDuringSerialize() async throws {
        let provider = FakeSessionsProvider()
        let fullContent = String(repeating: "abcdef0123456789", count: 400)
        var toolCall = ACPMessage.ToolCall(
            toolCallId: "old", title: "read", status: "in_progress",
            content: fullContent, preview: "abcdef")
        toolCall.truncateForOffWindow()
        let mgr = try makeManager()
        let session = mgr.createSession(agentId: "claude")
        session.transcript.messages = [.toolCall(toolCall)] + (0..<5).map {
            .user(id: UUID(), messageId: "u\($0)", text: "msg \($0)", attachments: [])
        }
        provider.sessions["s1"] = session
        provider.fullToolCallContents["s1|old"] = fullContent
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }

        await gw.handle(.subscribe(sessionId: "s1"))   // caches "old"'s content
        sent.removeAll()
        provider.fullToolCallContentCallCount = 0
        provider.pauseFullToolCallContentOnCall = 1   // suspend the delta's re-fetch below

        // Dirty mutation #1: the tool call — invalidates its cache and
        // forces a real re-fetch that suspends.
        if case .toolCall(var tc) = session.transcript.messages[0] {
            tc.status = "completed"
            session.transcript.messages[0] = .toolCall(tc)
        }
        for _ in 0..<50 where provider.fullToolCallContentCallCount == 0 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(provider.fullToolCallContentCallCount == 1)

        // Dirty mutation #2: an appended message — a non-truncated-tool-call
        // dirty index, so its own coalesced delta completes fully (no
        // suspension) while mutation #1's delta is still stuck above.
        session.transcript.messages.append(.systemNotice(id: UUID(), text: "notice"))
        for _ in 0..<50 where sent.isEmpty {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard case .transcriptDelta(_, _, _, let firstUpserts, _, _)? = sent.last else {
            Issue.record("expected the overlapping dirty delta to land, got \(sent)")
            return
        }
        #expect(firstUpserts.contains { $0.kind == "systemNotice" })

        sent.removeAll()
        // Resume mutation #1's suspended fetch. With the fix, it must detect
        // that mutation #2's delta already claimed a newer generation and
        // discard instead of rolling the transcript back with stale content.
        provider.resumeFullToolCallContent(fullContent)
        try await Task.sleep(nanoseconds: 250_000_000)   // > coalesce window
        #expect(sent.isEmpty, "stale overlapping delta must be discarded, got \(sent)")
    }

    // Regression (codex review, PR #775): discarding a superseded dirty
    // delta must not silently lose the mutation it would have carried.
    // sentVersion used to advance BEFORE the await, so a delta that got
    // discarded still "consumed" its indices from the change log's
    // perspective — the next delta would never re-offer them, losing the
    // mutation until a full resync. sentVersion must only commit once the
    // delta is actually accepted, so a superseding delta naturally re-picks
    // up whatever the discarded one would have sent.
    @Test func overlappingDirtyDeltaStillDeliversDiscardedMutation() async throws {
        let provider = FakeSessionsProvider()
        let fullContent = String(repeating: "abcdef0123456789", count: 400)
        var toolCall = ACPMessage.ToolCall(
            toolCallId: "old", title: "read", status: "in_progress",
            content: fullContent, preview: "abcdef")
        toolCall.truncateForOffWindow()
        let mgr = try makeManager()
        let session = mgr.createSession(agentId: "claude")
        session.transcript.messages = [.toolCall(toolCall)] + (0..<5).map {
            .user(id: UUID(), messageId: "u\($0)", text: "msg \($0)", attachments: [])
        }
        provider.sessions["s1"] = session
        provider.fullToolCallContents["s1|old"] = fullContent
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }

        await gw.handle(.subscribe(sessionId: "s1"))   // caches "old"'s content
        sent.removeAll()
        provider.fullToolCallContentCallCount = 0
        provider.pauseFullToolCallContentOnCall = 1   // suspend mutation #1's re-fetch

        // Mutation #1: the tool call — invalidates its cache and suspends
        // its own delta while re-fetching.
        if case .toolCall(var tc) = session.transcript.messages[0] {
            tc.status = "completed"
            session.transcript.messages[0] = .toolCall(tc)
        }
        for _ in 0..<50 where provider.fullToolCallContentCallCount == 0 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(provider.fullToolCallContentCallCount == 1)

        // Mutation #2: an appended message. Its own coalesced delta must
        // include BOTH this new index AND mutation #1's index, because
        // sentVersion was NOT prematurely advanced by the still-suspended
        // (and about-to-be-discarded) delta from mutation #1.
        session.transcript.messages.append(.systemNotice(id: UUID(), text: "notice"))
        for _ in 0..<50 where sent.isEmpty {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard case .transcriptDelta(_, _, _, let upserts, _, _)? = sent.last else {
            Issue.record("expected the overlapping dirty delta to land, got \(sent)")
            return
        }
        #expect(upserts.contains { $0.kind == "systemNotice" })
        #expect(
            upserts.contains { $0.stableId == "m0" && ($0.json?.contains(#""status":"completed""#) ?? false) },
            "mutation #1's tool-call status change must not be lost, got \(upserts)"
        )

        sent.removeAll()
        provider.resumeFullToolCallContent(fullContent)
        try await Task.sleep(nanoseconds: 250_000_000)   // > coalesce window
        #expect(sent.isEmpty, "the superseded delta must still discard, got \(sent)")
    }

    // Regression (codex review, PR #775): sendSnapshot bumps `generation`
    // but, unlike the delta/page paths, never re-checked it after its own
    // await — so a snapshot superseded by a concurrent send (another
    // snapshot, or a dirty delta) still went out unconditionally. Because
    // the web client applies snapshots without any epoch/revision ordering
    // check (unlike deltas), this could roll the client back to stale
    // content until a later resync happened to correct it.
    @Test func sendSnapshotDropsStaleSendWhenSupersededDuringSerialize() async throws {
        let provider = FakeSessionsProvider()
        let fullContent = String(repeating: "abcdef0123456789", count: 400)
        var toolCall = ACPMessage.ToolCall(
            toolCallId: "old", title: "read", status: "completed",
            content: fullContent, preview: "abcdef")
        toolCall.truncateForOffWindow()
        let mgr = try makeManager()
        let session = mgr.createSession(agentId: "claude")
        // Small transcript: the tool call is inside the tail window, so
        // both subscribe's and takeOver's snapshots must serialize it.
        session.transcript.messages = [.toolCall(toolCall)] + (0..<5).map {
            .user(id: UUID(), messageId: "u\($0)", text: "msg \($0)", attachments: [])
        }
        provider.sessions["s1"] = session
        provider.fullToolCallContents["s1|old"] = fullContent
        provider.pauseFullToolCallContentOnCall = 1   // only subscribe's first fetch pauses
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }

        let subscribeTask = Task { @MainActor in
            await gw.handle(.subscribe(sessionId: "s1"))
        }
        for _ in 0..<50 where provider.fullToolCallContentCallCount == 0 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(provider.fullToolCallContentCallCount == 1)

        // A concurrent takeOver's own snapshot completes and sends first
        // (its own fetch is call #2, not paused).
        await gw.handle(.takeOver(sessionId: "s1"))
        let snapshotsAfterTakeOver = sent.filter { if case .transcriptSnapshot = $0 { return true }
        return false }.count
        #expect(snapshotsAfterTakeOver == 1)

        // Resume subscribe's suspended fetch. With the fix, it must detect
        // it was superseded and NOT send a second, stale snapshot.
        provider.resumeFullToolCallContent(fullContent)
        await subscribeTask.value
        try await Task.sleep(nanoseconds: 50_000_000)
        let snapshotCount = sent.filter { if case .transcriptSnapshot = $0 { return true }
        return false }.count
        #expect(snapshotCount == 1, "the superseded subscribe snapshot must be discarded, got \(sent)")
    }

    // Regression (codex review, PR #775): sendSnapshot advanced sentVersion
    // BEFORE its own await, the same premature-commit hazard as the dirty
    // delta fix above. If the snapshot is later discarded because a
    // concurrent dirty delta sent first, that delta computes its upserts
    // against the ALREADY-advanced sentVersion and never re-offers the
    // pre-snapshot dirty content — losing it entirely (neither send ever
    // delivers it) until a later full resync.
    @Test func sendSnapshotDefersSentVersionSoSupersedingDeltaStillDeliversIt() async throws {
        let provider = FakeSessionsProvider()
        let fullContent = String(repeating: "abcdef0123456789", count: 400)
        var toolCall = ACPMessage.ToolCall(
            toolCallId: "old", title: "read", status: "completed",
            content: fullContent, preview: "abcdef")
        toolCall.truncateForOffWindow()
        let mgr = try makeManager()
        let session = mgr.createSession(agentId: "claude")
        session.transcript.messages = (0..<5).map {
            .user(id: UUID(), messageId: "u\($0)", text: "msg \($0)", attachments: [])
        }
        provider.sessions["s1"] = session
        provider.fullToolCallContents["s1|old"] = fullContent
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }

        await gw.handle(.subscribe(sessionId: "s1"))   // establishes observe(); nothing to cache yet
        sent.removeAll()
        provider.fullToolCallContentCallCount = 0
        provider.pauseFullToolCallContentOnCall = 1   // suspend the re-subscribe snapshot's fetch below

        // Append the truncated tool call directly (uncached anywhere) and
        // immediately re-subscribe — its snapshot must fetch the tool call
        // for the first time and suspends.
        session.transcript.messages.append(.toolCall(toolCall))
        let resubscribeTask = Task { @MainActor in
            await gw.handle(.subscribe(sessionId: "s1"))
        }
        for _ in 0..<50 where provider.fullToolCallContentCallCount == 0 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(provider.fullToolCallContentCallCount == 1)

        // The first subscribe's still-active observer reacts to the append
        // with its own coalesced delta, which also needs the (still
        // uncached) tool call — its fetch is call #2, not paused.
        for _ in 0..<50 where sent.isEmpty {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard case .transcriptDelta(_, _, _, let upserts, _, _)? = sent.last else {
            Issue.record("expected the concurrent delta to land, got \(sent)")
            return
        }
        #expect(
            upserts.contains { $0.kind == "toolCall" },
            "the appended tool call must not be lost, got \(upserts)"
        )

        sent.removeAll()
        provider.resumeFullToolCallContent(fullContent)
        await resubscribeTask.value
        try await Task.sleep(nanoseconds: 50_000_000)
        let snapshotCount = sent.filter { if case .transcriptSnapshot = $0 { return true }
        return false }.count
        #expect(snapshotCount == 0, "the superseded re-subscribe snapshot must be discarded, got \(sent)")
    }

    // Regression (codex review, PR #775): a same-epoch snapshot reset
    // `state.revision = 0` synchronously up front, the same premature-commit
    // hazard as sentVersion but on the send side. If the snapshot is then
    // DISCARDED (superseded by a dirty delta claiming a later generation),
    // that already-happened reset still corrupts the winning delta's own
    // numbering: it computes `state.revision += 1` off the snapshot's
    // premature reset (0) instead of the client's actual last-known
    // revision, producing revision:1 when the client expects N+1 — the
    // client rejects it and resubscribes, defeating incremental delivery
    // right when it matters (an active resync race).
    @Test func sendSnapshotDefersRevisionResetSoSupersedingDeltaStaysInSync() async throws {
        let provider = FakeSessionsProvider()
        let fullContent = String(repeating: "abcdef0123456789", count: 400)
        var toolCall = ACPMessage.ToolCall(
            toolCallId: "old", title: "read", status: "completed",
            content: fullContent, preview: "abcdef")
        toolCall.truncateForOffWindow()
        let mgr = try makeManager()
        let session = mgr.createSession(agentId: "claude")
        session.transcript.messages = (0..<5).map {
            .user(id: UUID(), messageId: "u\($0)", text: "msg \($0)", attachments: [])
        }
        provider.sessions["s1"] = session
        provider.fullToolCallContents["s1|old"] = fullContent
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }

        await gw.handle(.subscribe(sessionId: "s1"))   // establishes observe(); revision committed at 0

        // Three uncontested dirty deltas first, to establish a non-zero
        // baseline revision — the bug is invisible when the baseline is
        // already 0, since a premature reset and a legitimate prior value
        // of 0 look identical.
        for i in 0..<3 {
            sent.removeAll()
            session.transcript.messages.append(.systemNotice(id: UUID(), text: "warmup \(i)"))
            for _ in 0..<50 where sent.isEmpty {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            guard case .transcriptDelta? = sent.last else {
                Issue.record("expected warmup delta \(i) to land, got \(sent)")
                return
            }
        }
        // state.revision is now legitimately 3.

        sent.removeAll()
        provider.fullToolCallContentCallCount = 0
        provider.pauseFullToolCallContentOnCall = 1   // suspend the re-subscribe snapshot's fetch below

        session.transcript.messages.append(.toolCall(toolCall))
        let resubscribeTask = Task { @MainActor in
            await gw.handle(.subscribe(sessionId: "s1"))
        }
        for _ in 0..<50 where provider.fullToolCallContentCallCount == 0 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(provider.fullToolCallContentCallCount == 1)

        // The still-active observer reacts to the append with its own
        // coalesced dirty delta, which supersedes (via generation) the
        // suspended re-subscribe snapshot.
        session.transcript.messages.append(.systemNotice(id: UUID(), text: "notice"))
        for _ in 0..<50 where sent.isEmpty {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard case .transcriptDelta(_, _, _, _, _, let winningRevision)? = sent.last else {
            Issue.record("expected the superseding delta to land, got \(sent)")
            return
        }
        #expect(
            winningRevision == 4,
            "the superseding delta must continue from the real prior revision (3), not the discarded snapshot's premature reset, got \(winningRevision)"
        )

        sent.removeAll()
        provider.resumeFullToolCallContent(fullContent)
        await resubscribeTask.value
        let snapshotCount = sent.filter { if case .transcriptSnapshot = $0 { return true }
        return false }.count
        #expect(snapshotCount == 0, "the superseded re-subscribe snapshot must still be discarded, got \(sent)")
    }

    // Regression (codex review, PR #775): fetchOlder's page serialization has
    // the same suspend-then-stamp hazard as sendDelta — a structural resync
    // landing while a truncated tool call's content is being fetched must
    // not let the FIRST attempt's page go out stamped with the post-resync
    // epoch (which the client would wrongly accept as current). It must
    // instead retry against the now-current state and deliver a correctly
    // re-stamped, fresh page — not silently drop the request (see the
    // dedicated retry test below for why silently dropping is itself a bug).
    @Test func fetchOlderRetriesAndDeliversFreshPageWhenEpochChangesDuringSerialize() async throws {
        let provider = FakeSessionsProvider()
        let fullContent = String(repeating: "abcdef0123456789", count: 400)
        var toolCall = ACPMessage.ToolCall(
            toolCallId: "old", title: "read", status: "completed",
            content: fullContent, preview: "abcdef")
        toolCall.truncateForOffWindow()
        let mgr = try makeManager()
        let session = mgr.createSession(agentId: "claude")
        // 100 messages total: the tail-window snapshot (last 90) excludes
        // index 5, so subscribing never fetches/caches its content — the
        // fetchOlder page below performs the FIRST fetch for it.
        session.transcript.messages = (0..<5).map {
            .user(id: UUID(), messageId: "u\($0)", text: "msg \($0)", attachments: [])
        } + [.toolCall(toolCall)] + (0..<94).map {
            .user(id: UUID(), messageId: "v\($0)", text: "msg \($0)", attachments: [])
        }
        provider.sessions["s1"] = session
        provider.fullToolCallContents["s1|old"] = fullContent
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }

        await gw.handle(.subscribe(sessionId: "s1"))
        guard case .transcriptSnapshot(_, _, _, _, let firstIndex, _, _, _)? = sent.first else {
            Issue.record("expected snapshot, got \(sent)")
            return
        }
        #expect(firstIndex == 10)   // sanity: index 5 is outside the tail window
        sent.removeAll()
        provider.fullToolCallContentCallCount = 0
        provider.pauseFullToolCallContentOnCall = 1   // suspend the page's fetch below

        let fetchTask = Task { @MainActor in
            await gw.handle(.fetchOlder(sessionId: "s1", beforeIndex: 10, limit: 90))
        }

        // Wait for the fetch request to suspend on the paused tool-content call.
        for _ in 0..<50 where provider.fullToolCallContentCallCount == 0 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(provider.fullToolCallContentCallCount == 1)

        // While the page is suspended, a structural change lands and its own
        // coalesced delta resyncs via a fresh snapshot.
        session.transcript.messages.removeLast()
        for _ in 0..<50 where !(sent.last.map { if case .transcriptSnapshot = $0 { return true }
        return false } ?? false) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard case .transcriptSnapshot? = sent.last else {
            Issue.record("expected a resync snapshot from the structural change, got \(sent)")
            return
        }

        sent.removeAll()
        // Resume the page's suspended fetch. With the fix, it must detect
        // the epoch moved during its await, retry against the now-current
        // state, and still deliver a fresh page rather than leaving the
        // client's request unanswered.
        provider.resumeFullToolCallContent(fullContent)
        await fetchTask.value
        guard case .transcriptPage(_, let pageEpoch, let pageFirst, let pageMessages)? = sent.last else {
            Issue.record("expected a retried page after the epoch changed during serialize, got \(sent)")
            return
        }
        #expect(pageEpoch != 0)   // reflects the post-resync epoch, not the stale captured one
        #expect(pageFirst == 0)
        #expect(pageMessages.contains { $0.stableId == "m5" })
    }

    // Regression (codex review, PR #775): unlike a dropped delta/snapshot
    // (which the client naturally recovers from via a later resync
    // snapshot), a fetchOlder page superseded by an ORDINARY same-epoch
    // delta has no client-side recovery — only a snapshot clears the
    // client's "loading earlier messages" state, and a normal delta does
    // not. Silently dropping the page in that case would leave the client
    // stuck forever. The gateway must retry and still deliver a page.
    @Test func fetchOlderRetriesAndDeliversPageInsteadOfLeavingClientStuck() async throws {
        let provider = FakeSessionsProvider()
        let fullContent = String(repeating: "abcdef0123456789", count: 400)
        var toolCall = ACPMessage.ToolCall(
            toolCallId: "old", title: "read", status: "completed",
            content: fullContent, preview: "abcdef")
        toolCall.truncateForOffWindow()
        let mgr = try makeManager()
        let session = mgr.createSession(agentId: "claude")
        // 100 messages: the tail-window snapshot (last 90) excludes index 0,
        // so subscribing never fetches/caches its content — fetchOlder below
        // performs the first, pausable fetch.
        session.transcript.messages = [.toolCall(toolCall)] + (0..<99).map {
            .user(id: UUID(), messageId: "u\($0)", text: "msg \($0)", attachments: [])
        }
        provider.sessions["s1"] = session
        provider.fullToolCallContents["s1|old"] = fullContent
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }

        await gw.handle(.subscribe(sessionId: "s1"))
        sent.removeAll()
        provider.fullToolCallContentCallCount = 0
        provider.pauseFullToolCallContentOnCall = 1   // suspend the page's first fetch attempt

        let fetchTask = Task { @MainActor in
            await gw.handle(.fetchOlder(sessionId: "s1", beforeIndex: 10, limit: 90))
        }
        for _ in 0..<50 where provider.fullToolCallContentCallCount == 0 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(provider.fullToolCallContentCallCount == 1)

        // A normal, same-epoch delta lands first (e.g. streaming continues
        // while the user is scrolled up) — this must not leave the pending
        // fetchOlder request unanswered.
        session.transcript.messages.append(.systemNotice(id: UUID(), text: "notice"))
        for _ in 0..<50 where sent.isEmpty {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard case .transcriptDelta? = sent.last else {
            Issue.record("expected the concurrent delta to land first, got \(sent)")
            return
        }

        sent.removeAll()
        provider.resumeFullToolCallContent(fullContent)
        await fetchTask.value
        guard case .transcriptPage(_, _, let pageFirst, let pageMessages)? = sent.last else {
            Issue.record("fetchOlder must still deliver a page after being superseded once, got \(sent)")
            return
        }
        #expect(pageFirst == 0)
        #expect(pageMessages.contains { $0.stableId == "m0" })
        // The retry reuses the cache the first (superseded) attempt already
        // populated — no second real fetch needed.
        #expect(provider.fullToolCallContentCallCount == 1)
    }

    @Test func queueVerbsReachTheProviderOnlyForWriters() async {
        let provider = FakeSessionsProvider()
        let id = "s1"
        var sent: [RemoteServerMessage] = []
        let gateway = RemoteSessionGateway(provider: provider) { sent.append($0) }
        let itemId = UUID()

        await gateway.handle(.queueForceSend(sessionId: id, itemId: itemId.uuidString))
        #expect(provider.queueForceSends.isEmpty)

        provider.writers.insert(id)
        await gateway.handle(.queueForceSend(sessionId: id, itemId: itemId.uuidString))
        #expect(provider.queueForceSends.map(\.itemId) == [itemId])
    }

    @Test func subscribeEmitsQueueStateEvenWhenQueueIsEmpty() async throws {
        let provider = FakeSessionsProvider()
        let id = "s1"
        provider.sessions[id] = try makeSessionWithAgentText("x")
        var sent: [RemoteServerMessage] = []
        let gateway = RemoteSessionGateway(provider: provider) { sent.append($0) }

        await gateway.handle(.subscribe(sessionId: id))

        let states = sent.compactMap { message -> [RemoteQueuedPrompt]? in
            if case .queueState(_, let items, _) = message { return items }
            return nil
        }
        #expect(states == [[]])
    }

    @Test func subscribeProjectsExistingQueue() async throws {
        let provider = FakeSessionsProvider()
        let id = "s1"
        let session = try makeSessionWithAgentText("x")
        session.queue = [QueuedPrompt(blocks: [.text("queued one")])]
        provider.sessions[id] = session
        var sent: [RemoteServerMessage] = []
        let gateway = RemoteSessionGateway(provider: provider) { sent.append($0) }

        await gateway.handle(.subscribe(sessionId: id))

        let items = sent.compactMap { message -> [RemoteQueuedPrompt]? in
            if case .queueState(_, let items, _) = message { return items }
            return nil
        }.first
        #expect(items?.count == 1)
        #expect(items?.first?.text == "queued one")
        #expect(items?.first?.status == "pending")
    }

    @Test func resubscribeStillEmitsQueueStateWhenUnchanged() async throws {
        let provider = FakeSessionsProvider()
        let id = "s1"
        provider.sessions[id] = try makeSessionWithAgentText("x")
        var sent: [RemoteServerMessage] = []
        let gateway = RemoteSessionGateway(provider: provider) { sent.append($0) }

        // First subscribe (e.g. one browser tab) populates lastQueue[id] with
        // the same (empty) snapshot a second subscribe would compute — without
        // `force: true` on the subscribe path, the second subscribe's send
        // would be swallowed by the dedupe.
        await gateway.handle(.subscribe(sessionId: id))
        await gateway.handle(.subscribe(sessionId: id))

        let states = sent.compactMap { message -> [RemoteQueuedPrompt]? in
            if case .queueState(_, let items, _) = message { return items }
            return nil
        }
        #expect(states == [[], []])
    }

    @Test func queueMutationOnLiveSessionEmitsQueueState() async throws {
        // The three existing queueState tests above only exercise the
        // force:true subscribe path. This covers the load-bearing one: the
        // emission inside the config-coalesce closure in observe(id:session:)
        // that carries a live queue mutation (a real enqueue while the
        // browser tab is already open) to the client.
        let provider = FakeSessionsProvider()
        let id = "s1"
        let session = try makeSessionWithAgentText("x")
        provider.sessions[id] = session
        var sent: [RemoteServerMessage] = []
        let gateway = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gateway.handle(.subscribe(sessionId: id))
        sent.removeAll()

        let item = QueuedPrompt(blocks: [.text("queued one")])
        session.queue = [item]                      // mutate the LIVE queue, not via subscribe
        try await Task.sleep(nanoseconds: 50_000_000)

        let items = sent.compactMap { message -> [RemoteQueuedPrompt]? in
            if case .queueState(_, let items, _) = message { return items }
            return nil
        }.last
        let queued = try #require(items, "expected a queueState after mutating session.queue")
        #expect(queued.count == 1)
        #expect(queued.first?.id == item.id.uuidString)
        #expect(queued.first?.text == "queued one")
    }

    @Test func reassigningIdenticalQueueValueDoesNotReemitQueueState() async throws {
        // The dedupe in sendQueueState must hold on the live-mutation path
        // too, not just be inert scaffolding — @Published fires
        // objectWillChange on every assignment regardless of equality, so
        // this exercises the gateway's own dedupe rather than Combine's.
        let provider = FakeSessionsProvider()
        let id = "s1"
        let session = try makeSessionWithAgentText("x")
        provider.sessions[id] = session
        var sent: [RemoteServerMessage] = []
        let gateway = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gateway.handle(.subscribe(sessionId: id))

        let item = QueuedPrompt(blocks: [.text("queued one")])
        session.queue = [item]
        try await Task.sleep(nanoseconds: 50_000_000)
        let countAfterMutation = sent.filter { if case .queueState = $0 { return true } else { return false } }.count
        #expect(countAfterMutation == 2)   // force:true baseline at subscribe + the mutation above

        session.queue = [item]             // reassign the identical value
        try await Task.sleep(nanoseconds: 50_000_000)
        let countAfterReassign = sent.filter { if case .queueState = $0 { return true } else { return false } }.count
        #expect(countAfterReassign == countAfterMutation)   // dedupe swallowed the no-op reassignment
    }

    @Test func steerUndoAvailableFlipEmitsQueueStateWithQueueUnchanged() async throws {
        // Regression guard for RemoteQueueSnapshot: steerUndoAvailable can
        // flip (a steer discards the queue, then the 5s undo window expires)
        // while `items` stays exactly as-is (already emptied by the steer
        // itself). Both transitions must independently reach the wire, or
        // the client is left showing a stale "undo available" affordance.
        // session.queue is never touched here, so a dedupe key that only
        // looked at items would swallow both sends.
        let provider = FakeSessionsProvider()
        let id = "s1"
        let session = try makeSessionWithAgentText("x")
        provider.sessions[id] = session
        var sent: [RemoteServerMessage] = []
        let gateway = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gateway.handle(.subscribe(sessionId: id))
        sent.removeAll()

        let discardedSnapshot = [QueuedPrompt(blocks: [.text("discarded by steer")])]
        session.steerUndo = .init(id: UUID(), snapshot: discardedSnapshot)
        try await Task.sleep(nanoseconds: 50_000_000)
        let afterSet = sent.compactMap { message -> Bool? in
            if case .queueState(_, _, let steerUndoAvailable) = message { return steerUndoAvailable }
            return nil
        }
        #expect(afterSet.last == true, "expected a queueState with steerUndoAvailable=true after arming the undo window")

        session.steerUndo = nil   // the window expires; session.queue is untouched throughout
        try await Task.sleep(nanoseconds: 50_000_000)
        let afterClear = sent.compactMap { message -> Bool? in
            if case .queueState(_, _, let steerUndoAvailable) = message { return steerUndoAvailable }
            return nil
        }
        #expect(afterClear.last == false, "expected a second queueState with steerUndoAvailable=false after the window closed")
        #expect(afterClear.count == afterSet.count + 1, "both the arm and the clear must independently reach the wire")
    }

    @Test func allQueueVerbsRequireWriterLease() async {
        let provider = FakeSessionsProvider()
        let id = "s1"
        let itemId = UUID()
        let gateway = RemoteSessionGateway(provider: provider) { _ in }

        await gateway.handle(.queueRemove(sessionId: id, itemId: itemId.uuidString))
        await gateway.handle(.queueRetry(sessionId: id, itemId: itemId.uuidString))
        await gateway.handle(.queueEdit(sessionId: id, itemId: itemId.uuidString))
        await gateway.handle(.queueClear(sessionId: id))
        await gateway.handle(.queueSteerUndo(sessionId: id))

        #expect(provider.queueRemoves.isEmpty)
        #expect(provider.queueRetries.isEmpty)
        #expect(provider.queueEdits.isEmpty)
        #expect(provider.queueClears.isEmpty)
        #expect(provider.queueSteerUndos.isEmpty)
    }

    @Test func queueVerbsReachProviderForWriter() async {
        let provider = FakeSessionsProvider()
        let id = "s1"
        provider.writers.insert(id)
        let itemId = UUID()
        let gateway = RemoteSessionGateway(provider: provider) { _ in }

        await gateway.handle(.queueRemove(sessionId: id, itemId: itemId.uuidString))
        await gateway.handle(.queueRetry(sessionId: id, itemId: itemId.uuidString))
        await gateway.handle(.queueClear(sessionId: id))
        await gateway.handle(.queueSteerUndo(sessionId: id))

        #expect(provider.queueRemoves.map(\.itemId) == [itemId])
        #expect(provider.queueRetries.map(\.itemId) == [itemId])
        #expect(provider.queueClears == [id])
        #expect(provider.queueSteerUndos == [id])
    }

    @Test func malformedItemIdIsIgnored() async {
        let provider = FakeSessionsProvider()
        let id = "s1"
        provider.writers.insert(id)
        let gateway = RemoteSessionGateway(provider: provider) { _ in }

        await gateway.handle(.queueRemove(sessionId: id, itemId: "not-a-uuid"))

        #expect(provider.queueRemoves.isEmpty)
    }

    @Test func queueEditRepliesWithRestoredText() async {
        let provider = FakeSessionsProvider()
        let id = "s1"
        provider.writers.insert(id)
        provider.queueEditText = "restore me"
        let itemId = UUID()
        var sent: [RemoteServerMessage] = []
        let gateway = RemoteSessionGateway(provider: provider) { sent.append($0) }

        await gateway.handle(.queueEdit(sessionId: id, itemId: itemId.uuidString))

        #expect(sent.contains(.queueEditRestored(sessionId: id, itemId: itemId.uuidString, text: "restore me")))
    }

    @Test func queueEditOnSendingItemRepliesWithNothing() async {
        let provider = FakeSessionsProvider()
        let id = "s1"
        provider.writers.insert(id)
        provider.queueEditText = nil          // takeForEditing refused
        var sent: [RemoteServerMessage] = []
        let gateway = RemoteSessionGateway(provider: provider) { sent.append($0) }

        await gateway.handle(.queueEdit(sessionId: id, itemId: UUID().uuidString))

        #expect(!sent.contains { if case .queueEditRestored = $0 { return true } else { return false } })
    }

    // Regression (codex review, PR #964): a queued item whose draft carries a
    // mention (file reference) is just as unrepresentable in the plain-text
    // web composer as one carrying an image. The web already hides Edit for
    // these, but the manager must refuse the edit too, so a client that
    // doesn't know the rule (or a hand-rolled one) can't cause the queued
    // item's file context to be silently dropped. Routed through the real
    // manager (not the plain stub) so this exercises the actual guard in
    // `ACPSessionManager.queueEdit`, not a test double's approximation of it.
    @Test func queueEditRefusesItemWithMentionAndLeavesItQueued() async throws {
        let provider = FakeSessionsProvider()
        let mgr = try makeManager()
        provider.manager = mgr
        let session = mgr.createSession(agentId: "claude")
        provider.sessions[session.id] = session
        provider.writers.insert(session.id)
        #expect(await mgr.acquireWriterLease(sessionId: session.id) == true)

        let draft = ACPComposerDraft(segments: [
            .text("see "),
            .mention(displayName: "App.swift", uri: "file:///App.swift"),
        ])
        session.enqueue(
            blocks: [.text("see "), .resourceLink(uri: "file:///App.swift", name: "App.swift")],
            draft: draft)
        let itemId = session.queue[0].id

        var sent: [RemoteServerMessage] = []
        let gateway = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gateway.handle(.queueEdit(sessionId: session.id, itemId: itemId.uuidString))

        #expect(!sent.contains { if case .queueEditRestored = $0 { return true } else { return false } })
        #expect(session.queue.map(\.id) == [itemId], "the item must remain queued, not be removed then discarded")
    }

    @Test func steerIntentRoutesToSteerPromptNotSendPrompt() async {
        let provider = FakeSessionsProvider()
        let id = "s1"
        provider.writers.insert(id)
        let gateway = RemoteSessionGateway(provider: provider) { _ in }

        await gateway.handle(.sendPrompt(sessionId: id, text: "redirect", attachments: [], intent: "steer"))

        #expect(provider.steerPrompts.map(\.text) == ["redirect"])
        #expect(provider.prompts.isEmpty)
    }

    @Test func autoIntentStillRoutesToSendPrompt() async {
        let provider = FakeSessionsProvider()
        let id = "s1"
        provider.writers.insert(id)
        let gateway = RemoteSessionGateway(provider: provider) { _ in }

        await gateway.handle(.sendPrompt(sessionId: id, text: "queue me", attachments: [], intent: "auto"))

        #expect(provider.prompts.map(\.text) == ["queue me"])
        #expect(provider.steerPrompts.isEmpty)
    }
}
