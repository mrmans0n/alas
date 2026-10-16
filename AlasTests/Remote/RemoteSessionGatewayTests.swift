import Testing
import Foundation
@testable import Alas
@_spi(Testing) @_spi(AppHost) import AlasCore

@MainActor
final class FakeSessionsProvider: RemoteSessionsProvider, RemoteSessionPresenter, RemoteWorktreeInspecting {
    var summaries: [RemoteSessionSummary] = []
    var worktrees: [RemoteWorktreeOption] = []
    var projects: [RemoteProjectOption] = []
    var branchResults: [String: RemoteBranchListResult] = [:]
    var agents: [RemoteAgentOption] = []
    var createResults: [String: RemoteCreateSessionResult] = [:]
    var createWorktreeSessionResult: RemoteCreateWorktreeSessionResult = .failure(
        stage: .worktree,
        message: "Could not create worktree.",
        worktreeId: nil
    )
    var renamed: [(id: String, title: String)] = []
    var tabActions: [String] = []
    var tabActionResult: RemoteSessionTabActionResult = .success
    var changeListResult: RemoteChangeListResult = .failure(reason: .sessionUnknown, message: nil)
    var fileDiffResult: RemoteFileDiffResult = .failure(reason: .sessionUnknown, message: nil)
    var fileTreeResult: RemoteFileTreeResult = .failure(reason: .sessionUnknown, message: nil)
    var fileContentsResult: RemoteFileContentsResult = .failure(reason: .sessionUnknown, byteSize: nil, message: nil)
    var changeListRequests: [(
        sessionId: String,
        comparisonMode: AppConfig.Changes.ChangesComparisonMode?
    )] = []
    var fileDiffRequests: [(
        sessionId: String,
        path: String,
        stage: String?,
        comparisonMode: AppConfig.Changes.ChangesComparisonMode?
    )] = []
    var fileTreeRequests: [(
        sessionId: String,
        path: String?,
        comparisonMode: AppConfig.Changes.ChangesComparisonMode?
    )] = []
    var fileContentsRequests: [(sessionId: String, path: String)] = []
    var eventHost: AlasHost?
    var fullToolCallContents: [String: String] = [:]
    var fullToolCallContentCallCount = 0
    var sessionSummariesCallCount = 0
    var remoteWorktreesCallCount = 0
    var remoteProjectsCallCount = 0
    var remoteProjectsCompletionCount = 0
    var remoteBranchesCallCount = 0
    var remoteBranchesCompletionCount = 0
    var remoteBranchRequests: [String] = []
    var remoteAgentsCallCount = 0
    var createRequests: [(worktreeId: String, agentId: String)] = []
    var createWorktreeSessionRequests: [(projectId: String, base: String, branch: String, agentId: String, caller: HostCaller)] = []
    var pauseSessionSummaries = false
    var pauseRemoteWorktrees = false
    var pauseRemoteProjects = false
    var pauseRemoteBranches = false
    var pauseFileDiff = false
    /// 1-indexed call number of `fullToolCallContent` to suspend on (nil = never pause).
    /// Lets a test freeze exactly one in-flight fetch while later calls proceed normally.
    var pauseFullToolCallContentOnCall: Int?
    private var sessionSummariesContinuation: CheckedContinuation<[RemoteSessionSummary], Never>?
    private var remoteWorktreesContinuation: CheckedContinuation<[RemoteWorktreeOption], Never>?
    private var remoteProjectsContinuation: CheckedContinuation<[RemoteProjectOption], Never>?
    private var remoteBranchesContinuation: CheckedContinuation<RemoteBranchListResult, Never>?
    private var remoteProjectsCallWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var remoteProjectsCompletionWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var remoteBranchesCallWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var remoteBranchesCompletionWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var fileDiffContinuation: CheckedContinuation<RemoteFileDiffResult, Never>?
    private var fileDiffCallWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
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
        resumeWaiters(&remoteProjectsCallWaiters, through: remoteProjectsCallCount)
        let result: [RemoteProjectOption]
        if pauseRemoteProjects {
            result = await withCheckedContinuation { continuation in
                remoteProjectsContinuation = continuation
            }
        } else {
            result = projects
        }
        remoteProjectsCompletionCount += 1
        resumeWaiters(&remoteProjectsCompletionWaiters, through: remoteProjectsCompletionCount)
        return result
    }
    func remoteBranches(projectId: String) async -> RemoteBranchListResult {
        remoteBranchesCallCount += 1
        remoteBranchRequests.append(projectId)
        resumeWaiters(&remoteBranchesCallWaiters, through: remoteBranchesCallCount)
        let result: RemoteBranchListResult
        if pauseRemoteBranches {
            result = await withCheckedContinuation { continuation in
                remoteBranchesContinuation = continuation
            }
        } else {
            result = branchResults[projectId] ?? .failure("Could not load branches.")
        }
        remoteBranchesCompletionCount += 1
        resumeWaiters(&remoteBranchesCompletionWaiters, through: remoteBranchesCompletionCount)
        return result
    }
    func remoteAgents() -> [RemoteAgentOption] {
        remoteAgentsCallCount += 1
        return agents
    }
    func createRemoteSession(worktreeId: String, agentId: String, modelId: String?, effortId: String?) async -> RemoteCreateSessionResult {
        createRequests.append((worktreeId, agentId))
        return createResults["\(worktreeId)|\(agentId)"] ?? .failure("Could not create session.")
    }
    func createRemoteWorktreeSession(
        projectId: String,
        base: String,
        branch: String,
        agentId: String,
        modelId: String?,
        effortId: String?,
        caller: HostCaller
    ) async -> RemoteCreateWorktreeSessionResult {
        createWorktreeSessionRequests.append((projectId, base, branch, agentId, caller))
        return createWorktreeSessionResult
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
    func waitForRemoteProjectsCall(_ count: Int) async {
        guard remoteProjectsCallCount < count else { return }
        await withCheckedContinuation { continuation in
            remoteProjectsCallWaiters.append((count, continuation))
        }
    }
    func waitForRemoteProjectsCompletion(_ count: Int) async {
        guard remoteProjectsCompletionCount < count else { return }
        await withCheckedContinuation { continuation in
            remoteProjectsCompletionWaiters.append((count, continuation))
        }
    }
    func waitForRemoteBranchesCall(_ count: Int) async {
        guard remoteBranchesCallCount < count else { return }
        await withCheckedContinuation { continuation in
            remoteBranchesCallWaiters.append((count, continuation))
        }
    }
    func waitForRemoteBranchesCompletion(_ count: Int) async {
        guard remoteBranchesCompletionCount < count else { return }
        await withCheckedContinuation { continuation in
            remoteBranchesCompletionWaiters.append((count, continuation))
        }
    }
    func resumeFileDiff() {
        fileDiffContinuation?.resume(returning: fileDiffResult)
        fileDiffContinuation = nil
    }
    func waitForFileDiffCall(_ count: Int) async {
        guard fileDiffRequests.count < count else { return }
        await withCheckedContinuation { continuation in
            fileDiffCallWaiters.append((count, continuation))
        }
    }
    private func resumeWaiters(
        _ waiters: inout [(count: Int, continuation: CheckedContinuation<Void, Never>)],
        through count: Int
    ) {
        let ready = waiters.filter { $0.count <= count }
        waiters.removeAll { $0.count <= count }
        ready.forEach { $0.continuation.resume() }
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

    func openSessionTab(for id: String) async -> RemoteSessionTabActionResult {
        tabActions.append("open \(id)")
        return tabActionResult
    }
    func closeSessionTab(for id: String) async -> RemoteSessionTabActionResult {
        tabActions.append("close \(id)")
        return tabActionResult
    }
    func sessionRenamed(_ id: String, title: String) {
        renamed.append((id, title))
    }
    var created: [(id: String, worktreeID: String)] = []
    func sessionCreated(_ id: String, worktreeID: String) {
        created.append((id, worktreeID))
    }
    /// The lists and creations this fake serves, as a gateway asks for them.
    var hostCalls: RemoteGatewayHostCalls {
        RemoteGatewayHostCalls(
            worktrees: { await self.remoteWorktrees() },
            projects: { await self.remoteProjects() },
            branches: { await self.remoteBranches(projectId: $0) },
            agents: { self.remoteAgents() },
            createSession: { request, _ in
                await self.createRemoteSession(
                    worktreeId: request.worktreeID, agentId: request.agentID, modelId: request.modelID, effortId: request.effortID)
            },
            createWorktreeSession: { request, caller in
                await self.createRemoteWorktreeSession(
                    projectId: request.projectID, base: request.base, branch: request.branch, agentId: request.agentID,
                    modelId: request.modelID, effortId: request.effortID, caller: caller)
            },
            inspection: self,
            mentionCandidates: { sessionID, query, _ in
                (await self.remoteMentionCandidates(sessionId: sessionID, query: query), [])
            },
            mentionAttachments: { await self.remoteMentionAttachments($0, sessionId: $1) },
            fullToolCallContent: { await self.fullToolCallContent(sessionId: $0, toolCallId: $1) }
        )
    }

    var mentionCandidates: [RemoteMention] = []
    func remoteMentionCandidates(sessionId: String, query: String) async -> [RemoteMention] { mentionCandidates }

    /// What `remoteMentionAttachments` answers for a non-empty list.
    var mentionAttachments: [ACPMessage.Attachment]? = []
    func remoteMentionAttachments(_ mentions: [RemoteMention], sessionId: String) async -> [ACPMessage.Attachment]? {
        mentions.isEmpty ? [] : mentionAttachments
    }

    func remoteChangeList(
        sessionId: String,
        comparisonMode: AppConfig.Changes.ChangesComparisonMode?
    ) async -> RemoteChangeListResult {
        changeListRequests.append((sessionId, comparisonMode))
        return changeListResult
    }

    func remoteFileDiff(
        sessionId: String,
        path: String,
        stage: String?,
        comparisonMode: AppConfig.Changes.ChangesComparisonMode?
    ) async -> RemoteFileDiffResult {
        fileDiffRequests.append((sessionId, path, stage, comparisonMode))
        resumeWaiters(&fileDiffCallWaiters, through: fileDiffRequests.count)
        if pauseFileDiff {
            return await withCheckedContinuation { continuation in
                fileDiffContinuation = continuation
            }
        }
        return fileDiffResult
    }

    func remoteFileTree(
        sessionId: String,
        path: String?,
        comparisonMode: AppConfig.Changes.ChangesComparisonMode?
    ) async -> RemoteFileTreeResult {
        fileTreeRequests.append((sessionId, path, comparisonMode))
        return fileTreeResult
    }

    func remoteCommitFiles(sessionId: String, sha: String) async -> RemoteCommitFilesResult {
        .failure(reason: .unknown, message: "Commit inspection is unavailable.")
    }
    func remoteCommitDiff(sessionId: String, sha: String, path: String) async -> RemoteFileDiffResult {
        .failure(reason: .unknown, message: "Commit inspection is unavailable.")
    }
    func remoteFileContents(sessionId: String, path: String) async -> RemoteFileContentsResult {
        fileContentsRequests.append((sessionId, path))
        return fileContentsResult
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

extension ACPCursorCreatePlanParams {
    static func stub() -> ACPCursorCreatePlanParams {
        ACPCursorCreatePlanParams(
            toolCallId: "tc-plan",
            name: "Implementation plan",
            overview: "Review before coding.",
            plan: "Build the small remote approval path.",
            todos: [
                ACPCursorTodo(id: "todo-1", content: "Add wire message", status: "pending")
            ],
            isProject: false,
            phases: [
                ACPCursorPlanPhase(
                    name: "Remote",
                    todos: [ACPCursorTodo(id: "todo-2", content: "Render the sheet", status: "pending")]
                )
            ]
        )
    }
}
#endif

#if DEBUG
extension ACPPermissionRequestParams {
    /// Test factory: one tool call named "Bash" with an allow_once +
    /// reject_once option, matching the real ACPPermissionToolCall /
    /// ACPPermissionOption initializers.
    static func stub(
        sessionId: String = "remote", toolTitle: String = "Bash",
        toolCallContent: [ACPToolCallContent]? = nil,
        metadata: AnyCodable? = nil, toolCallMetadata: AnyCodable? = nil,
        allowOptionMetadata: AnyCodable? = nil, toolName: String? = nil
    ) -> ACPPermissionRequestParams {
        ACPPermissionRequestParams(
            sessionId: sessionId,
            toolCall: ACPPermissionToolCall(
                toolCallId: "tc-stub",
                title: toolTitle,
                kind: "execute",
                status: nil,
                content: toolCallContent,
                locations: nil,
                rawInput: nil,
                rawOutput: nil,
                name: toolName,
                metadata: toolCallMetadata),
            options: [
                ACPPermissionOption(optionId: "allow_once", name: "Allow once", kind: "allow_once", metadata: allowOptionMetadata),
                ACPPermissionOption(optionId: "reject_once", name: "Reject once", kind: "reject_once"),
            ],
            metadata: metadata)
    }
}
#endif

struct InvalidQuestionAnswerCase: Sendable, CustomTestStringConvertible {
    let label: String
    /// Id of the question currently pending; the answer always targets id 0.
    let pendingRequestId: Int
    let selectedOptionIds: [String]

    var testDescription: String { label }
}

private let invalidQuestionAnswerCases: [InvalidQuestionAnswerCase] = [
    InvalidQuestionAnswerCase(label: "stale request id", pendingRequestId: 5, selectedOptionIds: ["o1"]),
    InvalidQuestionAnswerCase(label: "empty selection", pendingRequestId: 0, selectedOptionIds: []),
    InvalidQuestionAnswerCase(label: "only unknown option ids", pendingRequestId: 0, selectedOptionIds: ["bogus"]),
]

struct ElicitationValidationCase: Sendable, CustomTestStringConvertible {
    let label: String
    let requestJSON: String
    let content: [String: ACPElicitationValue]
    let accepted: Bool

    var testDescription: String { label }
}

private let elicitationValidationCases: [ElicitationValidationCase] = [
    ElicitationValidationCase(
        label: "values violating minLength/pattern, maximum, and enum items are rejected",
        requestJSON: #"""
        {"sessionId":"remote","mode":"form","message":"Configure", "requestedSchema":{
          "properties":{
            "name":{"type":"string","minLength":3,"pattern":"^[a-z]+$"},
            "count":{"type":"integer","minimum":1,"maximum":4},
            "tags":{"type":"array","items":{"type":"string","enum":["one","two"]},"minItems":1}
          },
          "required":["name","count","tags"]
        }}
        """#,
        content: [
            "name": .string("A"),
            "count": .integer(8),
            "tags": .strings(["unknown"]),
        ],
        accepted: false
    ),
    ElicitationValidationCase(
        label: "integral wire value is valid for a number field",
        requestJSON: #"""
        {"sessionId":"remote","mode":"form","message":"Configure", "requestedSchema":{
          "properties":{"ratio":{"type":"number","minimum":0,"maximum":2}},
          "required":["ratio"]
        }}
        """#,
        content: ["ratio": .integer(1)],
        accepted: true
    ),
    ElicitationValidationCase(
        label: "fractional seconds are valid for a date-time field",
        requestJSON: #"""
        {"sessionId":"remote","mode":"form","message":"Schedule", "requestedSchema":{
          "properties":{"startsAt":{"type":"string","format":"date-time"}},
          "required":["startsAt"]
        }}
        """#,
        content: ["startsAt": .string("2026-07-10T14:30:00.000Z")],
        accepted: true
    ),
]

enum InvalidAttachmentBatch: String, CaseIterable, Sendable {
    /// ~10.5MB decoded, over the batch byte cap.
    case oversize
    /// One more than the per-prompt count cap (parity with the native composer).
    case tooMany
    /// Claims image/png but the bytes are not a real image; the byte sniff
    /// must reject it rather than trusting the MIME.
    case imageMimeWithNonImageBytes

    @MainActor
    var attachments: [RemoteAttachment] {
        switch self {
        case .oversize:
            [RemoteAttachment(name: nil, mimeType: "image/png", dataBase64: String(repeating: "A", count: 14_000_000))]
        case .tooMany:
            (0..<(RemoteSessionGateway.maxAttachmentCount + 1)).map { _ in
                RemoteAttachment(name: "a.png", mimeType: "image/png", dataBase64: "iVBORw0KGgo=")
            }
        case .imageMimeWithNonImageBytes:
            [RemoteAttachment(name: "evil.png", mimeType: "image/png", dataBase64: "AAAAAAAAAAA=")]
        }
    }
}

@MainActor
struct RemoteSessionGatewayTests {
    /// A host for the tests whose sessions it serves; one per test.
    let hosted: GatewayHostFixture

    init() throws {
        hosted = try GatewayHostFixture()
    }

    /// A client drives a session through the host: prompts are trimmed and
    /// blank ones refused, a session this Mac does not drive refuses them,
    /// and rename, auto-run, takeover and stop reach it.
    @Test func aClientDrivesASessionThroughTheHost() async throws {
        let fixture = try GatewayHostFixture()
        defer { fixture.tearDown() }
        let id = try await fixture.drivenSession()
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: fixture.provider) { sent.append($0) }
        gw.presenter = fixture.provider
        defer { gw.close() }

        await gw.handle(.sendPrompt(sessionId: "elsewhere", text: "hi", attachments: [], intent: "auto"))
        #expect(sent == [.promptRejected(sessionId: "elsewhere")])
        await gw.handle(.sendPrompt(sessionId: id, text: "   \n  ", attachments: [], intent: "auto"))
        #expect(sent.last == .promptRejected(sessionId: id))
        sent.removeAll()
        await gw.handle(.sendPrompt(sessionId: id, text: "  hi  ", attachments: [], intent: "auto"))
        try await fixture.until { fixture.prompts.last?.hasSuffix("hi") == true }
        await gw.handle(.sendPrompt(sessionId: id, text: "redirect", attachments: [], intent: "steer"))
        try await fixture.until { fixture.prompts.last?.hasSuffix("redirect") == true }
        #expect(fixture.prompts.count == 2)
        #expect(!sent.contains(.promptRejected(sessionId: id)))

        await gw.handle(.renameSession(sessionId: id, title: "  Renamed  "))
        #expect(sent.contains(.sessionRenamed(sessionId: id, title: "Renamed")))
        #expect(fixture.provider.renamed.map(\.title) == ["Renamed"])
        #expect(fixture.host.sessions.list().first { $0.id == id }?.title == "Renamed")
        await gw.handle(.renameSession(sessionId: "missing", title: "Name"))
        #expect(sent.contains(.error(message: "Could not rename session.", sessionId: "missing")))

        await gw.handle(.setAutoRun(sessionId: id, enabled: true))
        #expect(fixture.manager?.liveSession(for: id)?.autoRunEnabled == true)

        // Takeover pushes a snapshot to a client following the session, so it
        // learns it can drive.
        await gw.handle(.subscribe(sessionId: id))
        try await fixture.until { sent.contains { if case .transcriptSnapshot = $0 { true } else { false } } }
        sent.removeAll()
        await gw.handle(.takeOver(sessionId: id))
        try await fixture.until { sent.contains { if case .transcriptSnapshot(id, _, true, _, _, _, _, _, _) = $0 { true } else { false } } }

        // Stop is acknowledged before the agent is told.
        sent.removeAll()
        await gw.handle(.stop(sessionId: id))
        #expect(sent.first == .stopPending(sessionId: id))
    }

    /// Editing a queued prompt hands its text back to the client, unless
    /// the item carries a mention the plain-text composer cannot hold: then
    /// it stays queued.
    @Test func queueEditRestoresPlainTextAndKeepsMentionsQueued() async throws {
        let fixture = try GatewayHostFixture()
        defer { fixture.tearDown() }
        let id = try await fixture.drivenSession()
        let session = try #require(fixture.manager?.liveSession(for: id))
        session.enqueue(blocks: [.text("plain")], draft: ACPComposerDraft(segments: [.text("plain")]))
        session.enqueue(
            blocks: [.text("see "), .resourceLink(uri: "file:///App.swift", name: "App.swift")],
            draft: ACPComposerDraft(segments: [.text("see "), .mention(displayName: "App.swift", uri: "file:///App.swift")])
        )
        let plain = session.queue[0].id
        let mentioning = session.queue[1].id
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: fixture.provider) { sent.append($0) }
        defer { gw.close() }

        await gw.handle(.queueEdit(sessionId: id, itemId: plain.uuidString))
        #expect(sent.contains(.queueEditRestored(sessionId: id, itemId: plain.uuidString, text: "plain")))
        sent.removeAll()
        await gw.handle(.queueEdit(sessionId: id, itemId: mentioning.uuidString))
        #expect(!sent.contains { if case .queueEditRestored = $0 { true } else { false } })
        #expect(session.queue.map(\.id) == [mentioning])
    }

    /// Image files written for a prompt are deleted when the prompt is
    /// refused before the session records it, and kept when delivery fails
    /// later, because the recorded message refers to them.
    @Test(arguments: [true, false])
    func refusedPromptsLeaveNoImageFiles(refusedAtOnce: Bool) async throws {
        let fixture = try GatewayHostFixture()
        defer { fixture.tearDown() }
        let id = try await fixture.drivenSession()
        if refusedAtOnce {
            try await fixture.loseLease(id)
        } else {
            fixture.agent.script(method: "session/prompt") { _ in throw ACPClientError.notRunning }
        }
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: fixture.provider) { sent.append($0) }
        defer { gw.close() }
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

        await gw.handle(.sendPrompt(sessionId: id, text: "look", attachments: [
            RemoteAttachment(name: "a.png", mimeType: "image/png", dataBase64: png),
        ], intent: "auto"))
        try await fixture.until { sent.contains(.promptRejected(sessionId: id)) }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Paths.acpAttachmentsDir(forWorktreeId: fixture.worktree.id).path)) ?? []
        #expect(files.isEmpty == refusedAtOnce)
    }

    /// Mentions resolve before any image is written, and go after the images.
    @Test func promptMentionsResolveBeforeImagesAreWritten() async throws {
        let fixture = try GatewayHostFixture()
        defer { fixture.tearDown() }
        let id = try await fixture.drivenSession()
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: fixture.provider) { sent.append($0) }
        defer { gw.close() }
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
        let image = RemoteAttachment(name: "a.png", mimeType: "image/png", dataBase64: png)
        let mention = RemoteMention(kind: RemoteMention.file, value: "App.swift", name: "App.swift")
        let attachments = Paths.acpAttachmentsDir(forWorktreeId: fixture.worktree.id).path
        let fake = fixture.provider
        gw.hostCalls.mentionAttachments = { await fake.remoteMentionAttachments($0, sessionId: $1) }

        fixture.provider.mentionAttachments = nil
        await gw.handle(.sendPrompt(sessionId: id, text: "@App.swift", attachments: [image], intent: "auto", mentions: [mention]))
        #expect(sent.contains(.promptRejected(sessionId: id)))
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: attachments)) ?? []).isEmpty)

        let linked = ACPMessage.Attachment(uri: "file:///w/App.swift", name: "App.swift", mimeType: nil)
        fixture.provider.mentionAttachments = [linked]
        await gw.handle(.sendPrompt(sessionId: id, text: "@App.swift", attachments: [image], intent: "auto", mentions: [mention]))
        let session = try #require(fixture.manager?.liveSession(for: id))
        try await fixture.until {
            session.transcript.messages.contains { if case .user = $0 { true } else { false } }
        }
        guard case .user(_, _, _, let recorded, _, _)? = session.transcript.messages.last(where: { if case .user = $0 { true } else { false } }) else {
            Issue.record("expected the user message")
            return
        }
        #expect(recorded.map(\.mimeType) == ["image/png", nil])
        #expect(recorded.last == linked)
    }

    /// The host's manager for the fixture's worktree.
    private func makeManager() throws -> ACPSessionManager {
        try hosted.core.sessionManager(for: hosted.worktree)
    }

    private func makeSessionWithAgentText(_ text: String, id: String = "s1") throws -> ACPSession {
        try hosted.session(id, messages: [.agent(id: UUID(), StreamingText(text))])
    }

    private func makeLog() throws -> ACPPermissionDecisionLog {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-gw-log-\(UUID()).sqlite")
        return ACPPermissionDecisionLog(store: try ACPSessionStore(path: url.path))
    }

    @Test func consoleAttachIsRefusedWithoutAnAuthenticatedPeerLink() async {
        // Browsers get no console link, so the host is never consulted.
        let provider = FakeSessionsProvider()
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gw.handle(.console(.attach(consoleId: "c", attachmentId: "a", scrollbackRows: 0)))
        #expect(sent == [.console(.detached(attachmentId: "a", reason: .unauthorized))])
    }

    @Test func listProjectsDropsSupersededPausedResponse() async {
        let provider = FakeSessionsProvider()
        let oldProjects = [RemoteProjectOption(id: "project-old", name: "Old")]
        let newProjects = [RemoteProjectOption(id: "project-new", name: "New")]
        provider.projects = oldProjects
        provider.pauseRemoteProjects = true
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        gw.hostCalls = provider.hostCalls

        await gw.handle(.listProjects)
        await provider.waitForRemoteProjectsCall(1)

        provider.pauseRemoteProjects = false
        provider.projects = newProjects
        await gw.handle(.listProjects)
        await provider.waitForRemoteProjectsCompletion(1)

        provider.projects = oldProjects
        provider.resumeRemoteProjects()
        await provider.waitForRemoteProjectsCompletion(2)

        #expect(provider.remoteProjectsCallCount == 2)
        #expect(sent == [.projectList(projects: newProjects)])
    }

    @Test func listBranchesDropsSupersededPausedResponse() async {
        let provider = FakeSessionsProvider()
        provider.branchResults["project-old"] = .success(
            branches: ["main", "feature/old"],
            preferredBase: "main"
        )
        provider.branchResults["project-new"] = .failure("Could not load branches.")
        provider.pauseRemoteBranches = true
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        gw.hostCalls = provider.hostCalls

        await gw.handle(.listBranches(projectId: "project-old"))
        await provider.waitForRemoteBranchesCall(1)

        provider.pauseRemoteBranches = false
        await gw.handle(.listBranches(projectId: "project-new"))
        await provider.waitForRemoteBranchesCompletion(1)

        provider.resumeRemoteBranches(projectId: "project-old")
        await provider.waitForRemoteBranchesCompletion(2)

        #expect(provider.remoteBranchRequests == ["project-old", "project-new"])
        #expect(sent == [
            .branchListFailed(projectId: "project-new", message: "Could not load branches.")
        ])
    }

    @Test func closeCancelsPendingProjectListRefresh() async {
        let provider = FakeSessionsProvider()
        provider.projects = [RemoteProjectOption(id: "project-1", name: "Alas")]
        provider.pauseRemoteProjects = true
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        gw.hostCalls = provider.hostCalls

        await gw.handle(.listProjects)
        await provider.waitForRemoteProjectsCall(1)
        gw.close()
        provider.resumeRemoteProjects()
        await provider.waitForRemoteProjectsCompletion(1)

        #expect(provider.remoteProjectsCallCount == 1)
        #expect(sent.isEmpty)
    }

    @Test func closeCancelsPendingBranchListRefresh() async {
        let provider = FakeSessionsProvider()
        provider.branchResults["project-1"] = .success(branches: ["main"], preferredBase: "main")
        provider.pauseRemoteBranches = true
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        gw.hostCalls = provider.hostCalls

        await gw.handle(.listBranches(projectId: "project-1"))
        await provider.waitForRemoteBranchesCall(1)
        gw.close()
        provider.resumeRemoteBranches(projectId: "project-1")
        await provider.waitForRemoteBranchesCompletion(1)

        #expect(provider.remoteBranchesCallCount == 1)
        #expect(sent.isEmpty)
    }

    /// A host change pushes the lists it makes stale, unasked: sessions
    /// always, worktrees and projects once the client has asked for them.
    @Test func hostChangesPushTheListsTheClientFollows() async throws {
        let project = ProjectConfig(id: "p", name: "p", path: "/srv/repo", color: "blue", addedAt: .distantPast)
        let projects = ProjectsManager(persistedProjects: [project])
        let provider = FakeSessionsProvider()
        provider.eventHost = AlasHost(core: AlasCoreContext(projects: projects, runHistoryStore: nil))
        let gw = RemoteSessionGateway(provider: provider) { _ in }
        gw.hostCalls = provider.hostCalls
        defer { gw.close() }
        await gw.handle(.listWorktrees)
        await gw.handle(.listProjects)
        #expect(provider.sessionSummariesCallCount == 0)

        let path = URL(fileURLWithPath: "/srv/new")
        projects.insertOptimisticWorktree(Worktree(
            id: Worktree.makeId(path: path), projectId: "p", name: "new", branch: "new",
            path: path, status: .clean, lastActivity: .distantPast
        ))
        let deadline = ContinuousClock.now + .seconds(5)
        while provider.sessionSummariesCallCount == 0 || provider.remoteWorktreesCallCount < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(provider.sessionSummariesCallCount == 1)
        #expect(provider.remoteWorktreesCallCount == 2)
        #expect(provider.remoteProjectsCallCount == 1)

        // A project's own change refreshes the project list too.
        projects.updateProject(id: "p", update: ProjectUpdate(name: "renamed", icon: .default()))
        while provider.remoteProjectsCallCount < 2, ContinuousClock.now < deadline + .seconds(5) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(provider.remoteProjectsCallCount == 2)
    }

    /// A connection serves host protocol messages for the caller its
    /// transport authenticated, and refuses them without one.
    @Test(arguments: [true, false])
    func hostMessagesAreServedOnlyForAnAuthenticatedCaller(authenticated: Bool) async throws {
        let projects = ProjectsManager(persistedProjects: [])
        let provider = FakeSessionsProvider()
        provider.eventHost = AlasHost(core: AlasCoreContext(projects: projects, runHistoryStore: nil))
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(
            provider: provider, caller: authenticated ? .remotePeer(deviceID: "phone") : nil
        ) { sent.append($0) }
        defer { gw.close() }

        await gw.handle(.host(HostClientMessage(id: 7, request: .listSessions)))
        let deadline = ContinuousClock.now + .seconds(5)
        while sent.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(sent == [.host(.response(id: 7, result: authenticated
            ? .sessions(sessions: [])
            : .failure(error: .invalidRequest(reason: "This connection does not serve the host protocol."))
        ))])
    }

    @Test func createWorktreeSessionEmitsCreatedSessionAndRefreshesLists() async {
        let provider = FakeSessionsProvider()
        let summary = RemoteSessionSummary(
            id: "session-1",
            title: "Feature remote",
            agentId: "claude",
            status: "idle",
            canDrive: true
        )
        provider.createWorktreeSessionResult = .success(summary)
        provider.summaries = [summary]
        provider.worktrees = [
            RemoteWorktreeOption(
                id: "worktree-1",
                projectName: "Alas",
                worktreeName: "Feature remote",
                branch: "feature/remote",
                path: "/tmp/alas-feature-remote",
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
        let gw = RemoteSessionGateway(provider: provider, caller: .remotePeer(deviceID: "phone")) { sent.append($0) }
        gw.hostCalls = provider.hostCalls

        await gw.handle(.createWorktreeSession(
            projectId: "project-1",
            base: "main",
            branch: "feature/remote",
            agentId: "claude"
        ))
        for _ in 0..<10 {
            if provider.sessionSummariesCallCount == 1, provider.remoteWorktreesCallCount == 1 { break }
            await Task.yield()
        }

        #expect(provider.createWorktreeSessionRequests.count == 1)
        #expect(provider.createWorktreeSessionRequests.first?.projectId == "project-1")
        #expect(provider.createWorktreeSessionRequests.first?.base == "main")
        #expect(provider.createWorktreeSessionRequests.first?.branch == "feature/remote")
        #expect(provider.createWorktreeSessionRequests.first?.agentId == "claude")
        #expect(provider.createWorktreeSessionRequests.first?.caller == .remotePeer(deviceID: "phone"))
        #expect(sent.first == .worktreeSessionCreated(session: summary))
        #expect(sent.contains(.sessionList(sessions: [summary])))
        #expect(sent.contains(.worktreeList(worktrees: provider.worktrees)))
        #expect(!sent.contains(.sessionCreated(session: summary)))
    }

    @Test func createWorktreeSessionEmitsWorktreeFailureWithoutRefreshingLists() async {
        let provider = FakeSessionsProvider()
        provider.createWorktreeSessionResult = .failure(
            stage: .worktree,
            message: "Could not create worktree.",
            worktreeId: nil
        )
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        gw.hostCalls = provider.hostCalls

        await gw.handle(.createWorktreeSession(
            projectId: "project-1",
            base: "main",
            branch: "feature/remote",
            agentId: "claude"
        ))

        #expect(sent == [
            .worktreeSessionCreationFailed(
                stage: .worktree,
                message: "Could not create worktree.",
                worktreeId: nil
            )
        ])
        #expect(provider.sessionSummariesCallCount == 0)
        #expect(provider.remoteWorktreesCallCount == 0)
    }

    @Test func createWorktreeSessionEmitsSessionFailureAndRefreshesWorktrees() async {
        let provider = FakeSessionsProvider()
        provider.createWorktreeSessionResult = .failure(
            stage: .session,
            message: "Worktree created, but the session could not be created.",
            worktreeId: "worktree-1"
        )
        provider.worktrees = [
            RemoteWorktreeOption(
                id: "worktree-1",
                projectName: "Alas",
                worktreeName: "Feature remote",
                branch: "feature/remote",
                path: "/tmp/alas-feature-remote",
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
        gw.hostCalls = provider.hostCalls

        await gw.handle(.createWorktreeSession(
            projectId: "project-1",
            base: "main",
            branch: "feature/remote",
            agentId: "claude"
        ))
        for _ in 0..<10 where provider.remoteWorktreesCallCount == 0 {
            await Task.yield()
        }

        #expect(sent.first == .worktreeSessionCreationFailed(
            stage: .session,
            message: "Worktree created, but the session could not be created.",
            worktreeId: "worktree-1"
        ))
        #expect(sent.contains(.worktreeList(worktrees: provider.worktrees)))
        #expect(provider.sessionSummariesCallCount == 0)
    }

    @Test func createSessionEmitsCreatedSession() async {
        let provider = FakeSessionsProvider()
        let summary = RemoteSessionSummary(id: "s1", title: "New session", agentId: "claude", status: "idle", canDrive: true)
        provider.summaries = [summary]
        provider.createResults["wt1|claude"] = .success(summary)
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        gw.hostCalls = provider.hostCalls

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

    @Test func listSessionsDoesNotBlockFollowingSubscribe() async throws {
        let provider = hosted.provider
        provider.summaries = [RemoteSessionSummary(id: "s1", title: "T", agentId: "claude", status: "idle", canDrive: false)]
        provider.pauseSessionSummaries = true
        _ = try makeSessionWithAgentText("hello")
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
        try await hosted.until { sent.contains { if case .transcriptSnapshot = $0 { true } else { false } } }
        #expect(sent.contains { message in
            if case .transcriptSnapshot(let id, _, _, _, _, _, _, _, _) = message {
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
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        gw.hostCalls = provider.hostCalls

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
        #expect(sent == [.stopPending(sessionId: "s1")])

        provider.resumeRemoteWorktrees()
        await listTask.value
        for _ in 0..<10 {
            if sent.last == .worktreeList(worktrees: provider.worktrees) { break }
            await Task.yield()
        }
        #expect(sent.last == .worktreeList(worktrees: provider.worktrees))
    }

    @Test("remote projection hides background rows across snapshots and deltas", arguments: [false, true])
    func backgroundRowVisibility(showInTranscript: Bool) {
        var task = ACPBackgroundTask(ownerSessionId: "s1", asyncTaskId: "job", name: "Monitor")
        task.showInTranscript = showInTranscript
        let row = RemoteSessionGateway.toWire(.toolCall(task.transcriptRow), index: 10)
        if !showInTranscript { #expect(row.json == nil && row.text == nil) }
        var mirror = NativePeerTranscript(sessionId: "s1")
        mirror.apply(.transcriptSnapshot(sessionId: "s1", streamingState: "idle", canDrive: true,
            messages: [row], firstIndex: 10, totalCount: 11, epoch: 1, revision: 0))
        #expect(mirror.messages.count == (showInTranscript ? 1 : 0))
        #expect(mirror.olderPageBeforeIndex == 10)
        task.showInTranscript.toggle()
        mirror.apply(.transcriptDelta(sessionId: "s1", streamingState: "idle", canDrive: true,
            upserts: [RemoteSessionGateway.toWire(.toolCall(task.transcriptRow), index: 10)], epoch: 1, revision: 1))
        #expect(mirror.messages.count == (showInTranscript ? 0 : 1))
        #expect(mirror.totalCount == 11)
        task.showInTranscript = false
        mirror.apply(.transcriptPage(sessionId: "s1", epoch: 1, firstIndex: 0,
            messages: [RemoteSessionGateway.toWire(.toolCall(task.transcriptRow), index: 0)]))
        #expect(mirror.olderPageBeforeIndex == nil)
        #expect(mirror.messages.count == (showInTranscript ? 0 : 1))
    }

    @Test("latest background snapshots suppress older positional rows across tail, backfill and deltas", .timeLimit(.minutes(1)), arguments: [("snapshot", false), ("snapshot", true), ("page", false), ("page", true), ("delta", false), ("delta", true)])
    func latestBackgroundSnapshotsSuppressOlderRows(path: String, latestVisible: Bool) async throws {
        let provider = hosted.provider
        let session = try makeSessionWithAgentText("unused")
        var task = ACPBackgroundTask(ownerSessionId: "s1", asyncTaskId: "job", name: "Older")
        session.transcript.messages = [.toolCall(task.transcriptRow)]
        if path == "page" {
            for index in 0...RemoteTranscriptSync.tailWindow {
                session.transcript.appendMessage(.agent(id: UUID(), StreamingText("Filler \(index)")))
            }
        }
        task.name = "Latest"
        task.showInTranscript = latestVisible
        let latest = ACPMessage.toolCall(task.transcriptRow)
        if path != "delta" { session.transcript.appendMessage(latest) }
        var sent: [RemoteServerMessage] = []
        var nextDelta: CheckedContinuation<RemoteServerMessage, Never>?
        let gw = RemoteSessionGateway(provider: provider) { frame in
            sent.append(frame)
            if case .transcriptDelta = frame, let waiter = nextDelta {
                nextDelta = nil
                waiter.resume(returning: frame)
            }
        }
        await gw.handle(.subscribe(sessionId: "s1"))
        try await hosted.until { sent.contains { if case .transcriptSnapshot = $0 { true } else { false } } }
        var mirror = NativePeerTranscript(sessionId: "s1")
        mirror.apply(try #require(sent.first))
        if path != "delta" {
            #expect(mirror.messages.filter { $0.kind == "toolCall" }.map(\.index)
                == (latestVisible ? [session.transcript.messages.count - 1] : []))
        }
        let frame: RemoteServerMessage
        if path == "delta" {
            frame = await withCheckedContinuation { nextDelta = $0
                session.transcript.appendMessage(latest) }
        } else {
            await gw.handle(.fetchOlder(sessionId: "s1", beforeIndex: session.transcript.messages.count - 1, limit: 200))
            frame = try #require(sent.last)
        }
        let rows: [RemoteWireMessage]
        switch frame {
        case .transcriptDelta(_, _, _, let upserts, _, _, _): rows = upserts
        case .transcriptPage(_, _, let first, let page):
            #expect(first == 0)
            rows = page
        default: Issue.record("Expected a delta or page")
            return
        }
        let older = try #require(rows.first(where: { $0.index == 0 }))
        #expect(older.stableId == "m0")
        #expect(older.isHidden == true && older.json == nil && older.text == nil)
        mirror.apply(frame)
        let visibleTasks = mirror.messages.filter { $0.kind == "toolCall" }
        #expect(visibleTasks.map(\.index) == (latestVisible ? [session.transcript.messages.count - 1] : []))
        #expect(mirror.olderPageBeforeIndex == nil)
    }

    @Test("remote snapshots and state-only deltas advertise cancellable background work while idle", .timeLimit(.minutes(1)), arguments: [false, true])
    func idleBackgroundStopSnapshot(supported: Bool) async throws {
        let provider = hosted.provider
        let session = try makeSessionWithUserMessages(0)
        session.agentState = .ready
        session.backgroundTaskStopSupported = supported
        session.applyBackgroundTask(.init(sessionUpdate: "async_task_spawned", asyncTaskId: "job", canStop: true), ownerSessionId: "s1")
        var sent: [RemoteServerMessage] = []
        var nextDelta: CheckedContinuation<RemoteServerMessage, Never>?
        let gateway = RemoteSessionGateway(provider: provider) {
            sent.append($0)
            if case .transcriptDelta = $0, let continuation = nextDelta {
                nextDelta = nil
                continuation.resume(returning: $0)
            }
        }
        defer { gateway.close() }
        await gateway.handle(.subscribe(sessionId: "s1"))
        try await hosted.until { sent.contains { if case .transcriptSnapshot = $0 { true } else { false } } }
        let data = try JSONEncoder().encode(try #require(sent.first))
        let fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(fields["streamingState"] as? String == "idle")
        #expect(fields["hasCancellableBackgroundWork"] as? Bool == supported)
        var mirror = NativePeerTranscript(sessionId: "peer:s1")
        mirror.apply(try #require(sent.first).replacingSessionId("peer:s1"))
        #expect(mirror.hasCancellableBackgroundWork == supported)
        let delta = await withCheckedContinuation { continuation in
            nextDelta = continuation
            session.backgroundTaskStopSupported = !supported
        }
        mirror.apply(delta.replacingSessionId("peer:s1"))
        #expect(mirror.hasCancellableBackgroundWork == !supported)
        #expect(mirror.streamingState == "idle")
    }

    @Test func snapshotRestoresFullTruncatedToolCallContent() async throws {
        let provider = hosted.provider
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
        provider.fullToolCallContents["s1|old"] = fullContent
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        gw.hostCalls.fullToolCallContent = { await provider.fullToolCallContent(sessionId: $0, toolCallId: $1) }

        await gw.handle(.subscribe(sessionId: "s1"))
        try await hosted.until { sent.contains { if case .transcriptSnapshot = $0 { true } else { false } } }

        guard case .transcriptSnapshot(_, _, _, let msgs, _, _, _, _, _)? = sent.first,
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

    /// A permission reaches the phone under the agent's own request id, is
    /// answered by it alone, and is dismissed once answered, here or on the Mac.
    @Test func permissionsAreAnsweredByTheAgentsRequestId() async throws {
        let id = try await hosted.drivenSession()
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: hosted.provider) { sent.append($0) }
        defer { gw.close() }
        await gw.handle(.subscribe(sessionId: id))
        try await hosted.until { sent.contains { if case .transcriptSnapshot = $0 { true } else { false } } }

        hosted.agent.emitPermission(id: .number(7), params: .stub())
        try await hosted.until { sent.contains { if case .permissionRequest(_, let payload) = $0 { payload.requestId == 7 } else { false } } }
        // A reply under another id answers nothing.
        await gw.handle(.permissionDecision(sessionId: id, requestId: 0, optionId: "allow_once", persistScope: nil))
        #expect(hosted.agent.permissionResponses[.number(7)] == nil)
        await gw.handle(.permissionDecision(sessionId: id, requestId: 7, optionId: "allow_once", persistScope: nil))
        try await hosted.until { hosted.agent.permissionResponses[.number(7)]?.outcome == .selected(optionId: "allow_once") }
        try await hosted.until { sent.contains(.permissionResolved(sessionId: id, requestId: 7)) }

        // One answered on the Mac is dismissed on the phone too.
        hosted.agent.emitPermission(id: .number(8), params: .stub())
        try await hosted.until { sent.contains { if case .permissionRequest(_, let payload) = $0 { payload.requestId == 8 } else { false } } }
        try await hosted.host.sessions.answerPermission(id, requestID: .number(8), optionID: "allow_once", caller: .app)
        try await hosted.until { sent.contains(.permissionResolved(sessionId: id, requestId: 8)) }
    }

    /// Following again dismisses what the client was shown before the new
    /// follow surfaces what is still pending, so a request resolved while
    /// the old follow was replaced cannot stay on screen.
    @Test func followingAgainDismissesSurfacedRequestsBeforeResurfacingThem() async throws {
        let id = try await hosted.drivenSession()
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: hosted.provider) { sent.append($0) }
        defer { gw.close() }
        await gw.handle(.subscribe(sessionId: id))
        hosted.agent.emitPermission(id: .number(7), params: .stub())
        try await hosted.until { sent.contains { if case .permissionRequest(_, let payload) = $0 { payload.requestId == 7 } else { false } } }
        sent.removeAll()

        await gw.handle(.subscribe(sessionId: id))
        try await hosted.until { sent.contains { if case .permissionRequest = $0 { true } else { false } } }

        let dismissed = try #require(sent.firstIndex(of: .permissionResolved(sessionId: id, requestId: 7)))
        let resurfaced = try #require(sent.firstIndex { if case .permissionRequest = $0 { true } else { false } })
        #expect(dismissed < resurfaced)
    }

    @Test func permissionRequestForwardsDecodedPresentationToTheRemoteClient() async throws {
        let id = try await hosted.drivenSession()
        let params = ACPPermissionRequestParams.stub(
            toolCallContent: [.content(.text("swift build"))],
            metadata: AnyCodable([
                "permission": AnyCodable([
                    "version": AnyCodable(1),
                    "title": AnyCodable("Run command?"),
                    "description": AnyCodable("Reason: needs shell access"),
                    "defaultToNo": AnyCodable(true),
                ] as [String: AnyCodable]),
            ] as [String: AnyCodable]),
            toolCallMetadata: AnyCodable([
                "claudeCode": AnyCodable([
                    "mcpServer": AnyCodable(["name": AnyCodable("github")] as [String: AnyCodable]),
                ] as [String: AnyCodable]),
            ] as [String: AnyCodable]),
            allowOptionMetadata: AnyCodable([
                "permission": AnyCodable([
                    "version": AnyCodable(1),
                    "description": AnyCodable("Run this command one time"),
                ] as [String: AnyCodable]),
            ] as [String: AnyCodable])
        )
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: hosted.provider) { sent.append($0) }
        defer { gw.close() }
        await gw.handle(.subscribe(sessionId: id))
        try await hosted.until { sent.contains { if case .transcriptSnapshot = $0 { true } else { false } } }
        hosted.agent.emitPermission(id: .number(7), params: params)
        try await hosted.until { sent.contains { if case .permissionRequest = $0 { true } else { false } } }

        guard case .permissionRequest(_, let payload) = try #require(sent.first(where: {
            if case .permissionRequest = $0 { return true }
            return false
        })) else {
            Issue.record("expected a permissionRequest message")
            return
        }
        #expect(payload.title == "Run command?")
        #expect(payload.reason == "Reason: needs shell access")
        #expect(payload.defaultToNo == true)
        #expect(payload.mcpServerName == "github")
        #expect(payload.commandSummary == "swift build")
        #expect(payload.options.first { $0.optionId == "allow_once" }?.description == "Run this command one time")
        #expect(payload.options.first { $0.optionId == "reject_once" }?.description == nil)
    }

    @Test func subscribeEmitsQuestionRequest() async throws {
        let provider = hosted.provider
        let s = try makeSessionWithAgentText("x")
        s.transcript.pendingQuestion = .init(id: .number(0), params: .stub())
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gw.handle(.subscribe(sessionId: "s1"))
        try await hosted.until { sent.contains { if case .transcriptSnapshot = $0 { true } else { false } } }
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

    @Test func questionAnswerReachesTheAgent() async throws {
        let id = try await hosted.drivenSession()
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: hosted.provider) { sent.append($0) }
        defer { gw.close() }
        await gw.handle(.subscribe(sessionId: id))
        try await hosted.until { sent.contains { if case .transcriptSnapshot = $0 { true } else { false } } }
        hosted.agent.emitQuestion(id: .number(3), params: .stub())
        try await hosted.until { sent.contains { if case .questionRequest(_, let payload) = $0 { payload.requestId == 3 } else { false } } }
        await gw.handle(.questionAnswer(
            sessionId: id, requestId: 3, answers: [RemoteQuestionAnswer(questionId: "q1", selectedOptionIds: ["o1"])]))
        try await hosted.until {
            hosted.agent.questionResponses[.number(3)] == .init(outcome: .answered(answers: [
                ACPQuestionAnswer(questionId: "q1", selectedOptionIds: ["o1"]),
            ]))
        }
        try await hosted.until { sent.contains(.questionResolved(sessionId: id, requestId: 3)) }
    }

    @Test func subscribeEmitsPlanRequest() async throws {
        let provider = hosted.provider
        let session = try makeSessionWithAgentText("x")
        session.transcript.pendingPlan = .init(id: .string("plan-1"), params: .stub())
        var sent: [RemoteServerMessage] = []
        let gateway = RemoteSessionGateway(provider: provider) { sent.append($0) }

        await gateway.handle(.subscribe(sessionId: "s1"))
        try await hosted.until { sent.contains { if case .transcriptSnapshot = $0 { true } else { false } } }

        let payload = try #require(sent.compactMap { message -> RemotePlanPayload? in
            if case .planRequest(_, let payload) = message { return payload }
            return nil
        }.first)
        #expect(payload.requestId == .string("plan-1"))
        #expect(payload.toolCallId == "tc-plan")
        #expect(payload.name == "Implementation plan")
        #expect(payload.todos == [
            RemotePlanTodo(id: "todo-1", content: "Add wire message", status: "pending")
        ])
        #expect(payload.phases == [
            RemotePlanPhase(
                name: "Remote",
                todos: [RemotePlanTodo(id: "todo-2", content: "Render the sheet", status: "pending")]
            )
        ])
    }

    @Test func planResponseReachesTheAgent() async throws {
        let id = try await hosted.drivenSession()
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: hosted.provider) { sent.append($0) }
        defer { gw.close() }
        await gw.handle(.subscribe(sessionId: id))
        try await hosted.until { sent.contains { if case .transcriptSnapshot = $0 { true } else { false } } }
        hosted.agent.emitPlan(id: .string("plan-1"), params: .stub())
        try await hosted.until { sent.contains { if case .planRequest = $0 { true } else { false } } }
        await gw.handle(.planResponse(sessionId: id, requestId: .string("plan-1"), action: "accept", reason: nil))
        try await hosted.until {
            hosted.agent.planResponses[.string("plan-1")] == .init(outcome: .accepted(planUri: "alas://plans/tc-plan"))
        }
        try await hosted.until { sent.contains(.planResolved(sessionId: id, requestId: .string("plan-1"))) }
    }

    @Test func stalePlanResponseIsNoOp() async throws {
        let id = try await hosted.drivenSession()
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: hosted.provider) { sent.append($0) }
        defer { gw.close() }
        await gw.handle(.subscribe(sessionId: id))
        try await hosted.until { sent.contains { if case .transcriptSnapshot = $0 { true } else { false } } }
        hosted.agent.emitPlan(id: .string("plan-2"), params: .stub())
        try await hosted.until { sent.contains { if case .planRequest = $0 { true } else { false } } }
        await gw.handle(.planResponse(sessionId: id, requestId: .string("plan-1"), action: "accept", reason: nil))
        #expect(hosted.agent.planResponses.isEmpty)
    }

    @Test(arguments: invalidQuestionAnswerCases)
    func invalidQuestionAnswerIsNoOp(_ testCase: InvalidQuestionAnswerCase) async throws {
        let id = try await hosted.drivenSession()
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: hosted.provider) { sent.append($0) }
        defer { gw.close() }
        await gw.handle(.subscribe(sessionId: id))
        try await hosted.until { sent.contains { if case .transcriptSnapshot = $0 { true } else { false } } }
        let requestID = JSONRPCID.number(testCase.pendingRequestId)
        hosted.agent.emitQuestion(id: requestID, params: .stub())
        try await hosted.until { sent.contains { if case .questionRequest = $0 { true } else { false } } }
        // Must not resume the agent with a stale or vacuous answer.
        await gw.handle(.questionAnswer(
            sessionId: id,
            requestId: 0,
            answers: [RemoteQuestionAnswer(questionId: "q1", selectedOptionIds: testCase.selectedOptionIds)]))
        #expect(hosted.agent.questionResponses[requestID] == nil)
        #expect(!sent.contains { if case .questionResolved = $0 { true } else { false } })
    }

    @Test func subscribeEmitsStandardElicitationAndAcceptRoutesByOpaqueToken() async throws {
        let id = try await hosted.drivenSession()
        let session = try #require(hosted.manager?.liveSession(for: id))
        let params = try JSONDecoder().decode(
            ACPElicitationRequestParams.self,
            from: Data(#"""
            {"sessionId":"agent-1","mode":"form","message":"Pick", "requestedSchema":{
              "properties":{
                "strategy":{"type":"string","enum":["safe","fast"]},
                "token":{"type":"string","_meta":{"codex":{"isSecret":true}}}
              },
              "required":["strategy"]
            }}
            """#.utf8)
        )
        var sent: [RemoteServerMessage] = []
        let gateway = RemoteSessionGateway(provider: hosted.provider) { sent.append($0) }
        defer { gateway.close() }
        await gateway.handle(.subscribe(sessionId: id))
        try await hosted.until { sent.contains { if case .transcriptSnapshot = $0 { true } else { false } } }
        hosted.agent.emitElicitation(id: .number(4), params: params)
        try await hosted.until { sent.contains { if case .elicitationRequest = $0 { true } else { false } } }
        let pending = try #require(session.transcript.pendingUserInputs.first)
        let payload = try #require(sent.compactMap { message -> RemoteElicitationPayload? in
            if case .elicitationRequest(_, let payload) = message { return payload }
            return nil
        }.first)
        #expect(payload.requestId == pending.id.uuidString)
        #expect(payload.fields.first { $0.key == "strategy" }?.options.map(\.value) == ["safe", "fast"])
        #expect(payload.fields.first { $0.key == "token" }?.isSecret == true)

        session.transcript.messages.append(.agent(id: UUID(), StreamingText("still waiting")))
        try await Task.sleep(nanoseconds: 250_000_000)
        #expect(sent.filter {
            if case .elicitationRequest = $0 { return true }
            return false
        }.count == 1)

        await gateway.handle(.elicitationResponse(
            sessionId: id,
            requestId: payload.requestId,
            action: "accept",
            content: ["strategy": .string("safe")]
        ))
        try await hosted.until {
            if case .success(let response)? = hosted.agent.elicitationResponses[.number(4)] {
                response == .accept(["strategy": .string("safe")])
            } else { false }
        }
    }

    @Test func remoteInputSurfaceDoesNotSkipPastSharedQueueHead() async throws {
        let provider = hosted.provider
        let session = try makeSessionWithAgentText("x")
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
        try await hosted.until { sent.contains { if case .transcriptSnapshot = $0 { true } else { false } } }

        #expect(sent.contains {
            if case .questionRequest = $0 { return true }
            return false
        })
        #expect(!sent.contains {
            if case .elicitationRequest = $0 { return true }
            return false
        })
    }

    @Test(arguments: elicitationValidationCases)
    func elicitationAcceptIsValidatedAgainstTheRequestedSchema(_ testCase: ElicitationValidationCase) async throws {
        let id = try await hosted.drivenSession()
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: hosted.provider) { sent.append($0) }
        defer { gw.close() }
        await gw.handle(.subscribe(sessionId: id))
        try await hosted.until { sent.contains { if case .transcriptSnapshot = $0 { true } else { false } } }
        // Addressed to the scripted agent's own session.
        let json = testCase.requestJSON.replacingOccurrences(of: #""sessionId":"remote""#, with: #""sessionId":"agent-1""#)
        let params = try JSONDecoder().decode(ACPElicitationRequestParams.self, from: Data(json.utf8))
        hosted.agent.emitElicitation(id: .number(4), params: params)
        let payload = try await hosted.firstElicitation(in: { sent })
        await gw.handle(.elicitationResponse(sessionId: id, requestId: payload.requestId, action: "accept", content: testCase.content))
        if testCase.accepted {
            try await hosted.until {
                if case .success(let response)? = hosted.agent.elicitationResponses[.number(4)] {
                    response == .accept(testCase.content)
                } else { false }
            }
        } else {
            #expect(hosted.agent.elicitationResponses[.number(4)] == nil)
        }
    }

    @Test func closeStopsFurtherDeltas() async throws {
        let provider = hosted.provider
        let s = try makeSessionWithAgentText("hello")
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gw.handle(.subscribe(sessionId: "s1"))
        try await hosted.until { sent.contains { if case .transcriptSnapshot = $0 { true } else { false } } }
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

    @Test func overlongMentionQueriesGetNoRows() async {
        let provider = FakeSessionsProvider()
        provider.mentionCandidates = [RemoteMention(kind: RemoteMention.file, value: "a", name: "a")]
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        gw.hostCalls = provider.hostCalls
        let long = String(repeating: "a", count: RemoteSessionGateway.maxMentionQueryLength + 1)
        await gw.handle(.searchMentions(sessionId: "s1", query: long))
        await gw.handle(.searchMentions(sessionId: "s1", query: "a"))
        #expect(sent == [.mentionCandidates(sessionId: "s1", query: long, candidates: []),
                         .mentionCandidates(sessionId: "s1", query: "a", candidates: provider.mentionCandidates)])
    }

    /// A setting the host refuses changes nothing, so no new config arrives;
    /// the gateway re-sends the last one, so the viewer reverts.
    @Test(arguments: [true, false])
    func refusedConfigVerbResendsAuthoritativeConfig(isWriter: Bool) async throws {
        let session = try makeSessionWithAgentText("x")
        session.availableModels = [.init(id: "sonnet", name: "Sonnet", description: nil)]
        let manager = try makeManager()
        if isWriter {
            if !manager.isWriter(for: "s1") { #expect(await manager.acquireWriterLease(sessionId: "s1")) }
        } else {
            await manager.releaseWriterLease(sessionId: "s1")
        }
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: hosted.provider) { sent.append($0) }
        defer { gw.close() }
        await gw.handle(.subscribe(sessionId: "s1"))
        try await hosted.until { sent.contains { if case .sessionConfig = $0 { true } else { false } } }
        let config = try #require(sent.compactMap { if case .sessionConfig(let config) = $0 { config } else { nil } }.last)
        sent.removeAll()
        // Not an advertised model, so refused whether or not this Mac drives the session.
        await gw.handle(.setModel(sessionId: "s1", modelId: "opus"))
        #expect(sent == [.sessionConfig(config)])
    }

    @Test func sessionTabActionsRefreshTheListOnSuccessAndReportFailure() async {
        let provider = FakeSessionsProvider()
        provider.summaries = [RemoteSessionSummary(id: "s1", title: "S", agentId: "claude", status: "idle", canDrive: false)]
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        gw.presenter = provider

        await gw.handle(.openSessionTab(sessionId: "s1"))
        await Task.yield()
        #expect(sent == [.sessionTabActionSucceeded(sessionId: "s1"), .sessionList(sessions: provider.summaries)])

        sent.removeAll()
        provider.tabActionResult = .failure("This session is archived.")
        await gw.handle(.closeSessionTab(sessionId: "s1"))
        await Task.yield()
        #expect(sent == [.sessionTabActionFailed(sessionId: "s1", message: "This session is archived.")])
        #expect(provider.tabActions == ["open s1", "close s1"])
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

    @Test func sessionConfigChangeEmitsUpdate() async throws {
        let provider = hosted.provider
        let s = try makeSessionWithAgentText("hi")
        s.availableModels = [.init(id: "opus", name: "Opus", description: nil)]
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gw.handle(.subscribe(sessionId: "s1"))
        try await hosted.until { sent.contains { if case .transcriptSnapshot = $0 { true } else { false } } }
        sent.removeAll()
        s.currentModel = "opus"                    // mutate config
        try await hosted.until { sent.contains { if case .sessionConfig(let config) = $0 { config.currentModel == "opus" } else { false } } }
    }

    @Test func imageOnlyUserMessageRendersPlaceholder() {
        // An image-only prompt (empty text) must not serialize to a blank bubble.
        let msg = ACPMessage.user(id: UUID(), text: "",
            attachments: [.init(uri: "file:///tmp/shot.png", name: "shot.png", mimeType: "image/png")])
        let wire = RemoteSessionGateway.toWire(msg, index: 0)
        #expect(wire.kind == "user")
        #expect(wire.text == "🖼 shot.png")
    }

    @Test func mentionAttachmentsRenderAsResourcesNotImages() {
        let msg = ACPMessage.user(id: UUID(), text: "see @App.swift", attachments: [
            .init(uri: "file:///w/App.swift", name: "App.swift", mimeType: nil),
            .init(uri: "file:///tmp/shot.png", name: "shot.png", mimeType: "image/png"),
        ])
        #expect(RemoteSessionGateway.toWire(msg, index: 0).text == "see @App.swift\n\n🖼 shot.png\n\n📎 App.swift")
    }

    @Test func checkpointAttachmentDoesNotRenderAsRemotePlaceholder() {
        let msg = ACPMessage.user(id: UUID(), text: "hello", attachments: [.checkpointReference(id: UUID())])
        let wire = RemoteSessionGateway.toWire(msg, index: 0)

        #expect(wire.kind == "user")
        #expect(wire.text == "hello")
    }

    private func makeVisual(answer: ACPVisualAid.Answer? = nil, allowMultiple: Bool = false) -> ACPVisualAid {
        ACPVisualAid(
            id: UUID(uuidString: "6F0C2D4E-8B1A-4C3D-9E5F-1A2B3C4D5E6F")!,
            title: "Layouts", html: "<h2>Pick</h2>",
            question: .init(prompt: "Which?", options: [.init(id: "a", label: "One"), .init(id: "b", label: "Two")], allowMultiple: allowMultiple),
            answer: answer, createdAt: Date(timeIntervalSince1970: 0))
    }

    @Test func visualAidRowIsVisibleWithTitleAndStructuredJSON() throws {
        let visual = makeVisual()
        let wire = RemoteSessionGateway.toWire(.visualAid(visual), index: 3)
        #expect(wire.kind == "visualAid")
        #expect(wire.text == "Layouts")
        #expect(wire.isHidden != true)
        #expect(wire.stableId == "m3")
        let dto = try JSONDecoder().decode(RemoteVisualAid.self, from: Data(try #require(wire.json).utf8))
        #expect(dto.id == visual.id.uuidString)
        #expect(dto.html == "<h2>Pick</h2>")
        #expect(dto.question?.options.map(\.id) == ["a", "b"])
        #expect(dto.answer == nil)
    }

    @Test func visualAidAnswerDTOOmitsTheTimestamp() throws {
        let answered = RemoteVisualAid(makeVisual(answer: .answered(selectedOptionIds: ["b"], note: "ok", at: Date(timeIntervalSince1970: 9))))
        #expect(answered.answer == .init(kind: "answered", selectedOptionIds: ["b"], note: "ok"))
        let dismissed = RemoteVisualAid(makeVisual(answer: .dismissed(at: Date())))
        #expect(dismissed.answer == .init(kind: "dismissed", selectedOptionIds: nil, note: nil))
    }

    @Test(arguments: ["mcp__alas__visual_show", "visual_show"], ["Show visual", "<h2>secret</h2>"])
    func visualShowToolCallIsScrubbedOnTheWire(name: String, title: String) throws {
        let call = ACPMessage.ToolCall(
            toolCallId: "t1", title: title, status: "completed",
            content: "<h2>secret</h2>", preview: "<h2>secret</h2>", rawInput: #"{"html":"<h2>secret</h2>"}"#,
            locations: ["<h2>secret</h2>"], name: name)
        let wire = RemoteSessionGateway.toWire(.toolCall(call), index: 0)
        let json = try #require(wire.json)
        #expect(!json.contains("secret"))
        #expect(!json.contains("Show visual"))
        let decoded = try JSONDecoder().decode(ACPMessage.ToolCall.self, from: Data(json.utf8))
        #expect(decoded.title == "Visual aid")
        #expect(decoded.status == "completed")
        #expect(decoded.name == name)
    }

    @Test func visualShowPermissionRequestHidesTheVisualFromThePhone() async throws {
        let id = try await hosted.drivenSession()
        let meta = AnyCodable([
            "permission": AnyCodable([
                "version": AnyCodable(1),
                "title": AnyCodable("<h2>secret</h2>"),
                "description": AnyCodable("<h2>secret</h2>"),
                "defaultToNo": AnyCodable(true),
            ] as [String: AnyCodable]),
        ] as [String: AnyCodable])
        let params = ACPPermissionRequestParams.stub(
            toolTitle: "<h2>secret</h2>",
            toolCallContent: [.content(.text("<h2>secret</h2>"))],
            metadata: meta, allowOptionMetadata: meta, toolName: "mcp__alas__visual_show")
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: hosted.provider) { sent.append($0) }
        defer { gw.close() }
        await gw.handle(.subscribe(sessionId: id))
        try await hosted.until { sent.contains { if case .transcriptSnapshot = $0 { true } else { false } } }
        hosted.agent.emitPermission(id: .number(7), params: params)
        try await hosted.until { sent.contains { if case .permissionRequest = $0 { true } else { false } } }

        guard case .permissionRequest(_, let payload) = try #require(sent.first(where: {
            if case .permissionRequest = $0 { return true }
            return false
        })) else {
            Issue.record("expected a permissionRequest message")
            return
        }
        #expect(payload.toolName == "Visual aid")
        #expect(payload.defaultToNo, "the adapter's default-to-deny survives the redaction")
        let json = try String(decoding: JSONEncoder().encode(payload), as: UTF8.self)
        #expect(!json.contains("secret"))
    }

    @Test func ordinaryToolCallKeepsItsContent() throws {
        let call = ACPMessage.ToolCall(toolCallId: "t1", title: "Run", status: "completed", content: "output", name: "Bash")
        let wire = RemoteSessionGateway.toWire(.toolCall(call), index: 0)
        #expect(try #require(wire.json).contains("output"))
    }

    @Test func truncatedVisualShowCallIsNotRehydratedFromStorage() async throws {
        let provider = hosted.provider
        let html = String(repeating: "<p>secret</p>", count: 600)
        var toolCall = ACPMessage.ToolCall(
            toolCallId: "old", title: "Show visual", status: "completed",
            content: html, preview: "<p>secret</p>", name: "mcp__alas__visual_show")
        toolCall.truncateForOffWindow()
        let session = try makeSessionWithAgentText("tail")
        session.transcript.messages = [.toolCall(toolCall)]
        provider.fullToolCallContents["s1|old"] = html
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        gw.hostCalls.fullToolCallContent = { await provider.fullToolCallContent(sessionId: $0, toolCallId: $1) }

        await gw.handle(.subscribe(sessionId: "s1"))
        try await hosted.until { sent.contains { if case .transcriptSnapshot = $0 { true } else { false } } }

        guard case .transcriptSnapshot(_, _, _, let msgs, _, _, _, _, _)? = sent.first,
              let json = msgs.first(where: { $0.kind == "toolCall" })?.json
        else {
            Issue.record("expected tool-call snapshot, got \(sent)")
            return
        }
        #expect(!json.contains("secret"))
        #expect(provider.fullToolCallContentCallCount == 0)
    }

    /// Chunks that grow an existing row do not republish the transcript, so
    /// peers must hear about them through `streamingTicks` or their copy
    /// freezes mid-answer.
    @Test func streamedChunksIntoAnExistingRowReachThePeer() async throws {
        let provider = hosted.provider
        let s = try makeSessionWithAgentText("Hello")
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gw.handle(.subscribe(sessionId: "s1"))
        try await hosted.until { sent.contains { if case .transcriptSnapshot = $0 { true } else { false } } }
        guard case .agent(_, _, let buffer) = s.transcript.messages[0] else {
            Issue.record("expected an agent row")
            return
        }

        buffer.append(" streamed world")
        s.transcript.noteStreamingChange(at: 0)

        try await eventually("a delta carrying the streamed text") {
            sent.contains { frame in
                guard case .transcriptDelta(_, _, _, let upserts, _, _, _) = frame else { return false }
                return String(describing: upserts).contains("streamed world")
            }
        }
    }

    @Test func answeringAVisualUpdatesTheSameRowThroughADelta() async throws {
        let provider = hosted.provider
        let s = try makeSessionWithAgentText("hi")
        let visual = makeVisual()
        s.transcript.appendMessage(.visualAid(visual))
        var sent: [RemoteServerMessage] = []
        var nextDelta: CheckedContinuation<RemoteServerMessage, Never>?
        let gw = RemoteSessionGateway(provider: provider) { frame in
            sent.append(frame)
            if case .transcriptDelta = frame, let waiter = nextDelta {
                nextDelta = nil
                waiter.resume(returning: frame)
            }
        }
        await gw.handle(.subscribe(sessionId: "s1"))
        try await hosted.until { sent.contains { if case .transcriptSnapshot = $0 { true } else { false } } }
        let snapshot = sent.compactMap { msg -> [RemoteWireMessage]? in
            if case .transcriptSnapshot(_, _, _, let m, _, _, _, _, _) = msg { return m }
            return nil
        }.first
        #expect(snapshot?.last?.kind == "visualAid")
        let index = try #require(snapshot?.last?.index)

        var answered = visual
        answered.answer = .dismissed(at: Date())
        let frame = await withCheckedContinuation { nextDelta = $0
            s.transcript.replaceMessage(at: index, with: .visualAid(answered)) }
        guard case .transcriptDelta(_, _, _, let upserts, _, _, _) = frame else {
            Issue.record("expected delta")
            return
        }
        #expect(upserts.count == 1)
        #expect(upserts[0].index == index)
        #expect(upserts[0].kind == "visualAid")
        let dto = try JSONDecoder().decode(RemoteVisualAid.self, from: Data(try #require(upserts[0].json).utf8))
        #expect(dto.answer?.kind == "dismissed")
    }

    @Test func oversizedVisualBecomesTheTooLargeNoticeAtItsPosition() throws {
        var visual = makeVisual()
        visual = ACPVisualAid(id: visual.id, title: visual.title, html: String(repeating: "x", count: 5 * 1024 * 1024),
                              question: nil, answer: nil, createdAt: Date())
        let wire = RemoteSessionGateway.toWire(.visualAid(visual), index: 7)
        let bounded = wire.boundedForTransport(maximumBytes: RemoteTranscriptSync.maxMessageBytes).message
        #expect(bounded.kind == "systemNotice")
        #expect(bounded.index == 7)
        #expect(bounded.stableId == "m7")
    }

    private func makeVisualSession(allowMultiple: Bool) throws -> (ACPSession, ACPVisualAid) {
        let session = try makeSessionWithAgentText("hi")
        let visual = makeVisual(allowMultiple: allowMultiple)
        session.transcript.appendMessage(.visualAid(visual))
        return (session, visual)
    }

    private func visualRejection(_ sent: [RemoteServerMessage]) -> String? {
        for case .visualAidRejected(_, _, let reason, _) in sent { return reason }
        return nil
    }

    private func visualRejectionRequestId(_ sent: [RemoteServerMessage]) -> String? {
        for case .visualAidRejected(_, _, _, let requestId) in sent { return requestId }
        return nil
    }

    @Test func visualAnswersKeepQuestionOrderAndTrimTheNote() throws {
        let question = try #require(makeVisual(allowMultiple: true).question)
        #expect(RemoteSessionGateway.visualAidAnswer(
            to: question, action: "answer", selectedOptionIds: ["b", "a"], note: "  keep it  ", at: .distantPast
        ) == .answered(selectedOptionIds: ["a", "b"], note: "keep it", at: .distantPast))
        #expect(RemoteSessionGateway.visualAidAnswer(
            to: question, action: "dismiss", selectedOptionIds: [], note: nil, at: .distantPast
        ) == .dismissed(at: .distantPast))
    }

    @Test(arguments: [
        ("notWriter", false, false, "answer", ["a"], Optional<String>.none),
        ("invalid", true, false, "answer", [String](), nil),
        ("invalid", true, true, "answer", [String](), nil),
        ("invalid", true, false, "answer", ["zzz"], nil),
        ("invalid", true, false, "answer", ["a", "a"], nil),
        ("invalid", true, false, "answer", ["a", "b"], nil),
        ("invalid", true, false, "answer", ["a"], String(repeating: "x", count: 2001)),
        ("invalid", true, false, "wave", ["a"], nil),
        ("invalid", true, true, "answer", ["a", "b", "c", "d", "e", "f", "g", "h", "i"], nil),
        ("invalid", true, false, "answer", [String(repeating: "a", count: 300)], nil),
        ("invalid", true, false, "answer", ["a"], String(repeating: "x", count: 100_000)),
    ])
    func invalidVisualResponsesAreRejectedWithoutCallingTheManager(
        reason: String, isWriter: Bool, allowMultiple: Bool, action: String, ids: [String], note: String?
    ) async throws {
        let provider = hosted.provider
        let (s, visual) = try makeVisualSession(allowMultiple: allowMultiple)
        if isWriter { #expect(try await makeManager().acquireWriterLease(sessionId: "s1")) }
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gw.handle(.visualAidResponse(sessionId: "s1", visualId: visual.id.uuidString, action: action,
                                           selectedOptionIds: ids, note: note, requestId: "req-1"))
        #expect(visualRejection(sent) == reason)
        #expect(visualRejectionRequestId(sent) == "req-1")
    }

    @Test(arguments: [(64, true), (65, false), (1_000_000, false)])
    func visualRejectionEchoesOnlyBoundedRequestIds(length: Int, echoed: Bool) async throws {
        let provider = hosted.provider
        let (s, visual) = try makeVisualSession(allowMultiple: false)
        #expect(try await makeManager().acquireWriterLease(sessionId: "s1"))
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        let id = String(repeating: "r", count: length)
        await gw.handle(.visualAidResponse(sessionId: "s1", visualId: visual.id.uuidString, action: "wave",
                                           selectedOptionIds: ["a"], note: nil, requestId: id))
        #expect(visualRejection(sent) == "invalid")
        #expect(visualRejectionRequestId(sent) == (echoed ? id : nil))
    }

    @Test func visualRejectionWithoutRequestIdCarriesNone() async throws {
        let provider = hosted.provider
        let (s, visual) = try makeVisualSession(allowMultiple: false)
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gw.handle(.visualAidResponse(sessionId: "s1", visualId: visual.id.uuidString, action: "answer",
                                           selectedOptionIds: ["a"], note: nil))
        #expect(visualRejection(sent) == "notWriter")
        #expect(visualRejectionRequestId(sent) == nil)
    }

    @Test(arguments: [
        (["a", "b", "c", "d", "e", "f", "g", "h"], Optional<String>.none, false),
        (["a", "b", "c", "d", "e", "f", "g", "h", "i"], nil, true),
        ([String(repeating: "a", count: 64)], nil, false),
        ([String(repeating: "a", count: 256)], nil, false),
        ([String(repeating: "a", count: 257)], nil, true),
        (["a"], String(repeating: "x", count: 256 * 1024), false),
        (["a"], String(repeating: "x", count: 256 * 1024 + 1), true),
    ])
    func visualResponseBoundsRejectOversizedInputBeforeAnyWork(ids: [String], note: String?, exceeds: Bool) {
        #expect(RemoteVisualAidLimits.exceedsBounds(ids: ids, note: note) == exceeds)
    }

    @Test(arguments: [(2000, true), (2001, false)])
    func aNoteIsLimitedByGraphemesNotBytes(count: Int, accepted: Bool) throws {
        let question = try #require(makeVisual().question)
        let note = String(repeating: "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}", count: count)
        #expect((RemoteSessionGateway.visualAidAnswer(to: question, action: "answer", selectedOptionIds: ["a"], note: note) != nil) == accepted)
    }

    /// The same vectors run in scripts/tests/remote-web-visual-aid/test-visual-aid.js against `trimNote`: the phone
    /// must count and send exactly what this side trims (CharacterSet.whitespacesAndNewlines).
    @Test(arguments: [
        (0x85, true), (0x200B, true), (0xA0, true), (0x2028, true), (0x3000, true), (0x1680, true),
        (0x202F, true), (0xFEFF, false),
    ] as [(UInt32, Bool)])
    func noteEdgesTrimLikeThePhone(scalar: UInt32, trimmed: Bool) throws {
        let question = try #require(makeVisual().question)
        let edge = String(Unicode.Scalar(scalar)!)
        let body = String(repeating: "x", count: 2000)
        for (note, expectedNote) in [(edge + body, trimmed ? body : nil), (edge + body + edge, trimmed ? body : nil), (edge, trimmed ? "" : edge)] {
            let answer = RemoteSessionGateway.visualAidAnswer(to: question, action: "answer", selectedOptionIds: ["a"], note: note)
            // Kept edge characters push the 2000-character body over the limit; the edge-only note stays valid.
            let accepted = trimmed || note == edge
            #expect((answer != nil) == accepted, "U+\(String(scalar, radix: 16)) \(note.count)")
            if accepted, case .answered(_, let stored, _) = answer {
                #expect(stored == (expectedNote?.isEmpty == true ? nil : expectedNote))
            }
        }
    }

    @Test func unknownAndAlreadyAnsweredVisualsAreRejected() async throws {
        let provider = hosted.provider
        let (s, visual) = try makeVisualSession(allowMultiple: false)
        #expect(try await makeManager().acquireWriterLease(sessionId: "s1"))
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gw.handle(.visualAidResponse(sessionId: "s1", visualId: UUID().uuidString, action: "dismiss", selectedOptionIds: [], note: nil))
        #expect(visualRejection(sent) == "notFound")
        sent.removeAll()
        var answered = visual
        answered.answer = .dismissed(at: Date())
        s.transcript.replaceMessage(at: s.transcript.messages.count - 1, with: .visualAid(answered))
        await gw.handle(.visualAidResponse(sessionId: "s1", visualId: visual.id.uuidString, action: "dismiss", selectedOptionIds: [], note: nil))
        #expect(visualRejection(sent) == "alreadyAnswered")
    }

    /// A valid answer the host cannot deliver, here for want of a host, is
    /// reported as failed.
    @Test func aManagerFailureIsReportedAsFailed() async throws {
        let provider = hosted.provider
        let (s, visual) = try makeVisualSession(allowMultiple: false)
        #expect(try await makeManager().acquireWriterLease(sessionId: "s1"))
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gw.handle(.visualAidResponse(sessionId: "s1", visualId: visual.id.uuidString, action: "answer",
                                           selectedOptionIds: ["a"], note: nil))
        #expect(visualRejection(sent) == "failed")
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

    @Test(arguments: InvalidAttachmentBatch.allCases)
    func invalidAttachmentBatchIsRejectedBeforeAnyWrite(_ batch: InvalidAttachmentBatch) async throws {
        let fixture = try GatewayHostFixture()
        defer { fixture.tearDown() }
        let id = try await fixture.drivenSession()
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: fixture.provider) { sent.append($0) }
        defer { gw.close() }
        await gw.handle(.sendPrompt(sessionId: id, text: "x", attachments: batch.attachments, intent: "auto"))
        #expect(sent.contains(.promptRejected(sessionId: id)))
        #expect(fixture.prompts.isEmpty)
        let written = (try? FileManager.default.contentsOfDirectory(atPath: Paths.acpAttachmentsDir(forWorktreeId: fixture.worktree.id).path)) ?? []
        #expect(written.isEmpty)   // rejected before any write
    }

    private func makeSessionWithUserMessages(_ count: Int, id: String = "s1") throws -> ACPSession {
        try hosted.session(id, messages: (0..<count).map {
            .user(id: UUID(), messageId: "u\($0)", text: "msg \($0)", attachments: [])
        })
    }

    private func largeFileEdits() -> [ACPMessage] {
        // Repeated full before/after copies reproduce the peer session that
        // failed despite having fewer than the 90-row snapshot limit.
        let text = String(repeating: "let value = \"source/path\"\n", count: 30_000)
        return (0..<7).map { index in
            .fileEdit(id: UUID(), .init(
                path: "Source.swift", added: 1, removed: 1,
                oldText: text, newText: text + "// edit \(index)\n"))
        }
    }

    private func expectFileEditContents(
        _ rows: ArraySlice<RemoteWireMessage>, originals: [ACPMessage], firstIndex: Int
    ) throws {
        #expect(rows.map(\.index) == Array(firstIndex..<(firstIndex + originals.count)))
        for (row, original) in zip(rows, originals) {
            guard case .fileEdit(_, let expected) = original else {
                Issue.record("Expected file-edit fixture")
                return
            }
            #expect(row.kind == "fileEdit")
            let json = try #require(row.json)
            let edit = try JSONDecoder().decode(ACPMessage.FileEdit.self, from: Data(json.utf8))
            #expect(edit == expected)
        }
    }

    @Test func fileEditSnapshotCarriesCompactSummary() async throws {
        let provider = hosted.provider
        let session = try makeSessionWithUserMessages(0)
        session.transcript.messages = [
            .fileEdit(id: UUID(), .init(
                path: "Sources/Large.swift", added: 12, removed: 3,
                oldText: String(repeating: "old\n", count: 100_000),
                newText: String(repeating: "new\n", count: 100_000)))
        ]
        var sent: [RemoteServerMessage] = []
        let gateway = RemoteSessionGateway(provider: provider) { sent.append($0) }
        defer { gateway.close() }

        await gateway.handle(.subscribe(sessionId: "s1"))
        try await hosted.until { sent.contains { if case .transcriptSnapshot = $0 { true } else { false } } }

        guard case .transcriptSnapshot(_, _, _, let rows, _, _, _, _, _) = try #require(sent.first) else {
            Issue.record("Expected initial snapshot")
            return
        }
        let row = try #require(rows.first)
        #expect(row.text == "Sources/Large.swift  +12 -3")
        #expect(row.json != nil, "Native peers still need the full file edit payload")
    }

    @Test func byteBoundedHistoryRetainsLargeEditsAcrossPages() async throws {
        let provider = hosted.provider
        let session = try makeSessionWithUserMessages(0)
        let originals = largeFileEdits()
        session.transcript.messages = originals
        var sent: [RemoteServerMessage] = []
        let gateway = RemoteSessionGateway(provider: provider) { sent.append($0) }
        defer { gateway.close() }
        await gateway.handle(.subscribe(sessionId: "s1"))
        try await hosted.until { sent.contains { if case .transcriptSnapshot = $0 { true } else { false } } }
        let snapshot = try #require(sent.first)
        guard case .transcriptSnapshot(_, _, _, _, let first, let total, _, _, _) = snapshot else {
            Issue.record("Expected initial snapshot")
            return
        }
        #expect(try JSONEncoder().encode(snapshot).count <= 8 * 1024 * 1024)
        #expect(first > 0, "Large rows must reduce the initial window")
        #expect(total == originals.count)
        var mirror = NativePeerTranscript(sessionId: "s1")
        mirror.apply(snapshot)
        while let before = mirror.olderPageBeforeIndex {
            sent.removeAll()
            await gateway.handle(.fetchOlder(sessionId: "s1", beforeIndex: before, limit: 200))
            let page = try #require(sent.first)
            #expect(try JSONEncoder().encode(page).count <= 8 * 1024 * 1024)
            mirror.apply(page)
            try #require(mirror.firstIndex < before, "Every page must advance without gaps")
        }
        try expectFileEditContents(mirror.messages[...], originals: originals, firstIndex: 0)
        #expect(session.transcript.messages == originals)
    }

    @Test func oversizedRowDoesNotPreventPagingPastIt() async throws {
        let provider = hosted.provider
        let session = try makeSessionWithUserMessages(90)
        let original = ACPMessage.fileEdit(id: UUID(), .init(
            path: "Large.swift", added: 1, removed: 0,
            newText: String(repeating: "x", count: 5 * 1024 * 1024)))
        session.transcript.messages.insert(original, at: 0)
        var sent: [RemoteServerMessage] = []
        let gateway = RemoteSessionGateway(provider: provider) { sent.append($0) }
        defer { gateway.close() }
        await gateway.handle(.subscribe(sessionId: "s1"))
        try await hosted.until { sent.contains { if case .transcriptSnapshot = $0 { true } else { false } } }
        sent.removeAll()
        await gateway.handle(.fetchOlder(sessionId: "s1", beforeIndex: 1, limit: 90))
        let frame = try #require(sent.first)
        guard case .transcriptPage(_, _, let first, let rows) = frame else {
            Issue.record("Expected older page")
            return
        }
        #expect(first == 0)
        #expect(rows.count == 1)
        #expect(rows.first?.index == 0)
        #expect(rows.first?.kind == "systemNotice")
        #expect(try JSONEncoder().encode(frame).count <= 8 * 1024 * 1024)
        #expect(session.transcript.messages[0] == original)
    }

    @Test(.timeLimit(.minutes(1)))
    func largeLiveUpdatesArriveInBoundedOrderedBatches() async throws {
        let provider = hosted.provider
        let session = try makeSessionWithUserMessages(1)
        let (stream, continuation) = AsyncStream<RemoteServerMessage>.makeStream()
        let gateway = RemoteSessionGateway(provider: provider) { continuation.yield($0) }
        defer {
            gateway.close()
            continuation.finish()
        }
        await gateway.handle(.subscribe(sessionId: "s1"))
        var mirror = NativePeerTranscript(sessionId: "s1")
        // The snapshot comes from the follow; the edits go out as deltas after it.
        for await frame in stream {
            if case .transcriptSnapshot = frame {
                mirror.apply(frame)
                break
            }
        }
        let edits = largeFileEdits()
        session.transcript.messages.append(contentsOf: edits)
        var revisions: [Int] = []
        for await frame in stream {
            switch frame {
            case .transcriptSnapshot:
                mirror.apply(frame)
            case .transcriptDelta(_, _, _, let rows, _, let revision, _):
                #expect(try JSONEncoder().encode(frame).count <= 8 * 1024 * 1024)
                let needsResubscribe = mirror.apply(frame)
                #expect(!needsResubscribe, "Splitting must not trigger a resubscription")
                revisions.append(revision)
                if rows.last?.index == edits.count {
                    continuation.finish()
                }
            default:
                break
            }
        }
        #expect(revisions.count > 1)
        #expect(revisions == Array(1..<(revisions.count + 1)))
        #expect(mirror.messages.first?.text == "msg 0")
        try expectFileEditContents(mirror.messages.dropFirst(), originals: edits, firstIndex: 1)
    }

    @Test func snapshotOfLongTranscriptIsTailWindowed() async throws {
        let provider = hosted.provider
        let s = try makeSessionWithUserMessages(200)
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gw.handle(.subscribe(sessionId: "s1"))
        try await hosted.until { sent.contains { if case .transcriptSnapshot = $0 { true } else { false } } }
        guard case .transcriptSnapshot(_, _, _, let msgs, let first, let total, _, let revision, _)? = sent.first else {
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
        let provider = hosted.provider
        let s = try makeSessionWithUserMessages(50)
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gw.handle(.subscribe(sessionId: "s1"))
        try await hosted.until { sent.contains { if case .transcriptSnapshot = $0 { true } else { false } } }
        sent.removeAll()
        s.transcript.messages.append(.systemNotice(id: UUID(), text: "done"))
        try await Task.sleep(nanoseconds: 250_000_000)   // > coalesce window
        let delta = sent.compactMap { msg -> [RemoteWireMessage]? in
            if case .transcriptDelta(_, _, _, let u, _, _, _) = msg { return u }
            return nil
        }.last
        #expect(delta?.count == 1)
        #expect(delta?.first?.index == 50)
        #expect(delta?.first?.kind == "systemNotice")
    }

    @Test func structuralChangeTriggersResyncSnapshotWithBumpedEpoch() async throws {
        let provider = hosted.provider
        let s = try makeSessionWithUserMessages(10)
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gw.handle(.subscribe(sessionId: "s1"))
        try await hosted.until { sent.contains { if case .transcriptSnapshot = $0 { true } else { false } } }
        guard case .transcriptSnapshot(_, _, _, _, _, _, let epoch0, _, _)? = sent.first else {
            Issue.record("expected snapshot")
            return
        }
        sent.removeAll()
        s.transcript.messages.removeLast()               // structural
        try await Task.sleep(nanoseconds: 250_000_000)
        let resync = sent.last { if case .transcriptSnapshot = $0 { return true }
        return false }
        guard case .transcriptSnapshot(_, _, _, let msgs, _, let total, let epoch1, _, _)? = resync else {
            Issue.record("expected resync snapshot, got \(sent)")
            return
        }
        #expect(epoch1 == epoch0 + 1)
        #expect(total == 9)
        #expect(msgs.count == 9)
    }

    @Test func fetchOlderReturnsClampedPage() async throws {
        let provider = hosted.provider
        let s = try makeSessionWithUserMessages(200)
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gw.handle(.subscribe(sessionId: "s1"))
        try await hosted.until { sent.contains { if case .transcriptSnapshot = $0 { true } else { false } } }
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
        let provider = hosted.provider
        _ = try makeSessionWithUserMessages(5)
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gw.handle(.fetchOlder(sessionId: "s1", beforeIndex: 5, limit: 5))
        #expect(sent.isEmpty)
    }

    @Test func truncatedToolContentIsFetchedOnceAcrossSnapshotAndDeltas() async throws {
        let provider = hosted.provider
        let fullContent = String(repeating: "abcdef0123456789", count: 400)
        var toolCall = ACPMessage.ToolCall(
            toolCallId: "old", title: "read", status: "completed",
            content: fullContent, preview: "abcdef")
        toolCall.truncateForOffWindow()
        let session = try makeSessionWithAgentText("tail")
        session.transcript.messages = [.toolCall(toolCall), .agent(id: UUID(), StreamingText("tail"))]
        provider.fullToolCallContents["s1|old"] = fullContent
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        gw.hostCalls.fullToolCallContent = { await provider.fullToolCallContent(sessionId: $0, toolCallId: $1) }
        await gw.handle(.subscribe(sessionId: "s1"))
        try await hosted.until { sent.contains { if case .transcriptSnapshot = $0 { true } else { false } } }
        #expect(provider.fullToolCallContentCallCount == 1)
        // A dirty tick on the OTHER message must not re-fetch tool content.
        session.transcript.messages.append(.systemNotice(id: UUID(), text: "x"))
        try await Task.sleep(nanoseconds: 250_000_000)
        #expect(provider.fullToolCallContentCallCount == 1)
    }

    @Test func resubscribeDoesNotLeakTrackingRetains() async throws {
        let provider = hosted.provider
        let s = try makeSessionWithUserMessages(3)
        let gw = RemoteSessionGateway(provider: provider) { _ in }
        await gw.handle(.subscribe(sessionId: "s1"))
        await gw.handle(.subscribe(sessionId: "s1"))   // client resync
        await gw.handle(.unsubscribe(sessionId: "s1"))
        #expect(!s.transcript.changeLog.isTracking)
    }

    // Regression (codex review, PR #775): an epoch-only guard misses a
    // SAME-epoch snapshot (e.g. a takeOver, or a client resubscribe with no
    // intervening structural change) landing while a dirty delta is
    // suspended mid-serialize — the snapshot still resets revision/
    // sentVersion, so the resumed delta's stale content would be accepted
    // as the next legitimate delta after it. The generation counter (bumped
    // on every snapshot regardless of epoch) must catch this too.
    @Test func deltaDropsStaleUpsertsWhenSameEpochSnapshotLandsDuringSerialize() async throws {
        let provider = hosted.provider
        let fullContent = String(repeating: "abcdef0123456789", count: 400)
        var toolCall = ACPMessage.ToolCall(
            toolCallId: "old", title: "read", status: "in_progress",
            content: fullContent, preview: "abcdef")
        toolCall.truncateForOffWindow()
        let mgr = try makeManager()
        let session = mgr.createSession(id: "s1", agentId: "claude")
        session.transcript.messages = [.toolCall(toolCall)] + (0..<5).map {
            .user(id: UUID(), messageId: "u\($0)", text: "msg \($0)", attachments: [])
        }
        provider.fullToolCallContents["s1|old"] = fullContent
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        gw.hostCalls.fullToolCallContent = { await provider.fullToolCallContent(sessionId: $0, toolCallId: $1) }
        gw.hostCalls = provider.hostCalls

        await gw.handle(.subscribe(sessionId: "s1"))
        try await hosted.until { sent.contains { if case .transcriptSnapshot = $0 { true } else { false } } }   // caches "old"'s content
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
        // Following again resets; the paused delta belongs to the state it
        // replaced, so it must not go out once its fetch resumes.
        await gw.handle(.takeOver(sessionId: "s1"))
        provider.resumeFullToolCallContent(fullContent)
        try await hosted.until { sent.contains { if case .transcriptSnapshot = $0 { true } else { false } } }
        let snapshotAt = try #require(sent.firstIndex { if case .transcriptSnapshot = $0 { true } else { false } })
        #expect(!sent[..<snapshotAt].contains { if case .transcriptDelta(_, _, _, let rows, _, _, _) = $0 { !rows.isEmpty } else { false } },
                "stale delta must be discarded once a same-epoch snapshot replaced its state, got \(sent)")
    }

    /// The follow is read one batch at a time, so a delta waiting on a tool
    /// call's full content holds back the changes made meanwhile, which
    /// follow it in order, each delta with the next revision.
    @Test func changesWaitingBehindASlowContentFetchFollowInOrder() async throws {
        let provider = hosted.provider
        let fullContent = String(repeating: "abcdef0123456789", count: 400)
        var toolCall = ACPMessage.ToolCall(
            toolCallId: "old", title: "read", status: "in_progress", content: fullContent, preview: "abcdef")
        toolCall.truncateForOffWindow()
        let session = try hosted.session(messages: [.toolCall(toolCall), .user(id: UUID(), messageId: "u0", text: "msg 0", attachments: [])])
        provider.fullToolCallContents["s1|old"] = fullContent
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        gw.hostCalls = provider.hostCalls
        defer { gw.close() }
        await gw.handle(.subscribe(sessionId: "s1"))
        try await hosted.until { sent.contains { if case .transcriptSnapshot = $0 { true } else { false } } }
        sent.removeAll()
        provider.fullToolCallContentCallCount = 0
        provider.pauseFullToolCallContentOnCall = 1

        // The tool call's own delta re-fetches its content, and waits.
        if case .toolCall(var call) = session.transcript.messages[0] {
            call.status = "completed"
            session.transcript.messages[0] = .toolCall(call)
        }
        try await hosted.until { provider.fullToolCallContentCallCount == 1 }
        session.transcript.messages.append(.systemNotice(id: UUID(), text: "meanwhile"))
        provider.resumeFullToolCallContent(fullContent)

        try await hosted.until { sent.contains { if case .transcriptDelta(_, _, _, let rows, _, _, _) = $0 { rows.contains { $0.kind == "systemNotice" } } else { false } } }
        let deltas = sent.compactMap { if case .transcriptDelta(_, _, _, let rows, _, let revision, _) = $0 { (rows, revision) } else { nil } }
        #expect(deltas.map(\.1) == Array(1...deltas.count))
        #expect(deltas.first?.0.first?.index == 0, "the tool call goes out first")
        #expect(deltas.last?.0.contains { $0.kind == "systemNotice" } == true)
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
        let provider = hosted.provider
        let fullContent = String(repeating: "abcdef0123456789", count: 400)
        var toolCall = ACPMessage.ToolCall(
            toolCallId: "old", title: "read", status: "completed",
            content: fullContent, preview: "abcdef")
        toolCall.truncateForOffWindow()
        let mgr = try makeManager()
        let session = mgr.createSession(id: "s1", agentId: "claude")
        // 100 messages total: the tail-window snapshot (last 90) excludes
        // index 5, so subscribing never fetches/caches its content — the
        // fetchOlder page below performs the FIRST fetch for it.
        session.transcript.messages = (0..<5).map {
            .user(id: UUID(), messageId: "u\($0)", text: "msg \($0)", attachments: [])
        } + [.toolCall(toolCall)] + (0..<94).map {
            .user(id: UUID(), messageId: "v\($0)", text: "msg \($0)", attachments: [])
        }
        provider.fullToolCallContents["s1|old"] = fullContent
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        gw.hostCalls.fullToolCallContent = { await provider.fullToolCallContent(sessionId: $0, toolCallId: $1) }
        gw.hostCalls = provider.hostCalls

        await gw.handle(.subscribe(sessionId: "s1"))
        try await hosted.until { sent.contains { if case .transcriptSnapshot = $0 { true } else { false } } }
        guard case .transcriptSnapshot(_, _, _, _, let firstIndex, _, _, _, _)? = sent.first else {
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
        let provider = hosted.provider
        let fullContent = String(repeating: "abcdef0123456789", count: 400)
        var toolCall = ACPMessage.ToolCall(
            toolCallId: "old", title: "read", status: "completed",
            content: fullContent, preview: "abcdef")
        toolCall.truncateForOffWindow()
        let mgr = try makeManager()
        let session = mgr.createSession(id: "s1", agentId: "claude")
        // 100 messages: the tail-window snapshot (last 90) excludes index 0,
        // so subscribing never fetches/caches its content — fetchOlder below
        // performs the first, pausable fetch.
        session.transcript.messages = [.toolCall(toolCall)] + (0..<99).map {
            .user(id: UUID(), messageId: "u\($0)", text: "msg \($0)", attachments: [])
        }
        provider.fullToolCallContents["s1|old"] = fullContent
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        gw.hostCalls.fullToolCallContent = { await provider.fullToolCallContent(sessionId: $0, toolCallId: $1) }
        gw.hostCalls = provider.hostCalls

        await gw.handle(.subscribe(sessionId: "s1"))
        try await hosted.until { sent.contains { if case .transcriptSnapshot = $0 { true } else { false } } }
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

    /// A resubscribe while an older page waits on a tool call's content
    /// replaces the state the page was read for, so the page is read again
    /// from the current one rather than sent stale after its snapshot.
    @Test func fetchOlderRereadsThePageAfterAResubscribeReplacesItsState() async throws {
        let provider = hosted.provider
        let fullContent = String(repeating: "abcdef0123456789", count: 400)
        var toolCall = ACPMessage.ToolCall(
            toolCallId: "old", title: "read", status: "completed", content: fullContent, preview: "abcdef")
        toolCall.truncateForOffWindow()
        // Index 0 and 1 sit before the 90-row snapshot window.
        let session = try hosted.session(messages: [.toolCall(toolCall)] + (0..<99).map {
            .user(id: UUID(), messageId: "u\($0)", text: "msg \($0)", attachments: [])
        })
        provider.fullToolCallContents["s1|old"] = fullContent
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        gw.hostCalls = provider.hostCalls
        defer { gw.close() }
        await gw.handle(.subscribe(sessionId: "s1"))
        try await hosted.until { sent.contains { if case .transcriptSnapshot = $0 { true } else { false } } }
        provider.fullToolCallContentCallCount = 0
        provider.pauseFullToolCallContentOnCall = 1

        let fetch = Task { @MainActor in await gw.handle(.fetchOlder(sessionId: "s1", beforeIndex: 10, limit: 90)) }
        try await hosted.until { provider.fullToolCallContentCallCount == 1 }
        sent.removeAll()
        await gw.handle(.subscribe(sessionId: "s1"))
        try await hosted.until { sent.contains { if case .transcriptSnapshot = $0 { true } else { false } } }
        session.transcript.messages[1] = .user(id: UUID(), messageId: "u0", text: "edited", attachments: [])
        try await hosted.until { sent.contains { if case .transcriptDelta(_, _, _, let rows, _, _, _) = $0 { rows.contains { $0.index == 1 } } else { false } } }
        provider.resumeFullToolCallContent(fullContent)
        await fetch.value

        guard case .transcriptPage(_, _, _, let rows)? = sent.last else {
            Issue.record("expected the page last, got \(sent)")
            return
        }
        let edited = try #require(rows.first { $0.index == 1 })
        #expect(edited.text == "edited")
    }

    @Test func resubscribeStillEmitsQueueStateWhenUnchanged() async throws {
        let provider = hosted.provider
        let id = "s1"
        _ = try makeSessionWithAgentText("x")
        var sent: [RemoteServerMessage] = []
        let gateway = RemoteSessionGateway(provider: provider) { sent.append($0) }

        // First subscribe (e.g. one browser tab) populates lastQueue[id] with
        // the same (empty) snapshot a second subscribe would compute — without
        // `force: true` on the subscribe path, the second subscribe's send
        // would be swallowed by the dedupe.
        await gateway.handle(.subscribe(sessionId: id))
        try await hosted.until { sent.contains { if case .transcriptSnapshot = $0 { true } else { false } } }
        await gateway.handle(.subscribe(sessionId: id))
        try await hosted.until { sent.filter { if case .queueState = $0 { true } else { false } }.count == 2 }

        let states = sent.compactMap { message -> [RemoteQueuedPrompt]? in
            if case .queueState(_, let items) = message { return items }
            return nil
        }
        #expect(states == [[], []])
    }

    @Test func queueMutationOnLiveSessionEmitsQueueState() async throws {
        // The resubscribe queueState test above only exercises the
        // force:true subscribe path. This covers the load-bearing one: the
        // emission inside the config-coalesce closure in observe(id:session:)
        // that carries a live queue mutation (a real enqueue while the
        // browser tab is already open) to the client.
        let provider = hosted.provider
        let id = "s1"
        let session = try makeSessionWithAgentText("x")
        var sent: [RemoteServerMessage] = []
        let gateway = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gateway.handle(.subscribe(sessionId: id))
        try await hosted.until { sent.contains { if case .transcriptSnapshot = $0 { true } else { false } } }
        sent.removeAll()

        let item = QueuedPrompt(blocks: [.text("queued one")])
        session.queue = [item]                      // mutate the LIVE queue, not via subscribe
        try await hosted.until { sent.contains { if case .queueState = $0 { true } else { false } } }

        let items = sent.compactMap { message -> [RemoteQueuedPrompt]? in
            if case .queueState(_, let items) = message { return items }
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
        let provider = hosted.provider
        let id = "s1"
        let session = try makeSessionWithAgentText("x")
        var sent: [RemoteServerMessage] = []
        let gateway = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gateway.handle(.subscribe(sessionId: id))
        try await hosted.until { sent.contains { if case .transcriptSnapshot = $0 { true } else { false } } }

        let item = QueuedPrompt(blocks: [.text("queued one")])
        session.queue = [item]
        try await hosted.until { sent.filter { if case .queueState = $0 { true } else { false } }.count == 2 }
        let countAfterMutation = sent.filter { if case .queueState = $0 { return true } else { return false } }.count
        #expect(countAfterMutation == 2)   // force:true baseline at subscribe + the mutation above

        session.queue = [item]             // reassign the identical value
        // Anything the reassignment sent comes before this message's delta.
        session.transcript.messages.append(.systemNotice(id: UUID(), text: "marker"))
        try await hosted.until { sent.contains { if case .transcriptDelta(_, _, _, let upserts, _, _, _) = $0 { !upserts.isEmpty } else { false } } }
        let countAfterReassign = sent.filter { if case .queueState = $0 { return true } else { return false } }.count
        #expect(countAfterReassign == countAfterMutation)   // dedupe swallowed the no-op reassignment
    }

    @Test func listChangesSendsChangeListFromTheProvider() async {
        let provider = FakeSessionsProvider()
        let file = RemoteChangedFile(
            path: "a.txt", status: "M", add: 2, del: 1, conflict: nil, renameFrom: nil)
        provider.changeListResult = .success(
            comparisonRef: "origin/main", metricsAvailable: true, files: [file], staged: [file], unstaged: [],
            commits: [], truncated: false)
        var sent: [RemoteServerMessage] = []
        let gateway = RemoteSessionGateway(provider: provider) { sent.append($0) }
        gateway.hostCalls = provider.hostCalls

        await gateway.handle(.listChanges(sessionId: "s1", comparisonMode: .branchUpstream))

        #expect(provider.changeListRequests.map(\.sessionId) == ["s1"])
        #expect(provider.changeListRequests.map(\.comparisonMode) == [.branchUpstream])
        #expect(sent == [.changeList(
            sessionId: "s1", comparisonRef: "origin/main", metricsAvailable: true,
            files: [file], staged: [file], unstaged: [], commits: [], truncated: false)])
    }

    @Test func fileDiffSendsHunksAndFailures() async {
        let provider = FakeSessionsProvider()
        let hunk = RemoteDiffHunk(
            header: "@@ -1 +1,2 @@", oldStart: 1, newStart: 1,
            lines: [RemoteDiffLine(kind: "add", text: "new", oldNumber: nil, newNumber: 2)])
        provider.fileDiffResult = .success(hunks: [hunk], truncated: true)
        var sent: [RemoteServerMessage] = []
        let gateway = RemoteSessionGateway(provider: provider) { sent.append($0) }
        gateway.hostCalls = provider.hostCalls

        await gateway.handle(.fileDiff(
            sessionId: "s1",
            path: "a.txt",
            stage: "staged",
            comparisonMode: .manual
        ))
        #expect(provider.fileDiffRequests.map(\.path) == ["a.txt"])
        #expect(provider.fileDiffRequests.map(\.stage) == ["staged"])
        #expect(provider.fileDiffRequests.map(\.comparisonMode) == [.manual])
        #expect(sent == [.fileDiffResult(
            sessionId: "s1", path: "a.txt", stage: "staged", hunks: [hunk], truncated: true)])

        provider.fileDiffResult = .failure(reason: .pathRejected, message: nil)
        sent.removeAll()
        await gateway.handle(.fileDiff(sessionId: "s1", path: "../etc/passwd", stage: "unstaged"))
        #expect(sent == [.fileDiffFailed(
            sessionId: "s1", path: "../etc/passwd", stage: "unstaged", reason: .pathRejected, message: nil)])
    }

    @Test func listFilesAndReadFileSendTreeAndContents() async {
        let provider = FakeSessionsProvider()
        let node = RemoteFileNode(
            name: "src", path: "src", kind: "dir", badge: nil,
            childrenState: "notLoaded", isSubmodule: false)
        provider.fileTreeResult = .success(nodes: [node], truncated: false)
        provider.fileContentsResult = .success(text: "# Alas\n", truncated: false)
        var sent: [RemoteServerMessage] = []
        let gateway = RemoteSessionGateway(provider: provider) { sent.append($0) }
        gateway.hostCalls = provider.hostCalls

        await gateway.handle(.listFiles(
            sessionId: "s1",
            path: nil,
            comparisonMode: .branchUpstream
        ))
        await gateway.handle(.readFile(sessionId: "s1", path: "README.md"))
        #expect(provider.fileTreeRequests.map(\.comparisonMode) == [.branchUpstream])

        #expect(sent == [
            .fileTree(sessionId: "s1", path: nil, nodes: [node], truncated: false),
            .fileContents(sessionId: "s1", path: "README.md", text: "# Alas\n", truncated: false)
        ])
    }

    @Test func duplicateInFlightRequestsForTheSamePathAreDropped() async {
        let provider = FakeSessionsProvider()
        provider.fileDiffResult = .success(hunks: [], truncated: false)
        provider.pauseFileDiff = true
        var sent: [RemoteServerMessage] = []
        let gateway = RemoteSessionGateway(provider: provider) { sent.append($0) }
        gateway.hostCalls = provider.hostCalls

        async let first: Void = gateway.handle(.fileDiff(sessionId: "s1", path: "a.txt", stage: nil))
        await provider.waitForFileDiffCall(1)   // first call has entered the provider and is now suspended — the gateway's dedup key is held

        await gateway.handle(.fileDiff(sessionId: "s1", path: "a.txt", stage: nil))   // must be dropped: the key is still held by the suspended first call
        #expect(provider.fileDiffRequests.count == 1)   // second call never reached the provider
        #expect(sent.isEmpty)   // dropped call sends nothing

        provider.resumeFileDiff()
        await first
        #expect(provider.fileDiffRequests.count == 1)   // still just the one real call
        #expect(sent == [.fileDiffResult(sessionId: "s1", path: "a.txt", hunks: [], truncated: false)])
    }

    @Test func sessionListMergesLocalAndPeerRows() async {
        let provider = FakeSessionsProvider()
        provider.summaries = [RemoteSessionSummary(id: "local", title: "L", agentId: "claude", status: "idle", canDrive: true)]
        let links = FederatedSessionsProviderTests.FakeLinks()
        let federation = FederatedSessionsProvider(links: links)
        var out: [RemoteServerMessage] = []
        let gateway = RemoteSessionGateway(provider: provider, federation: federation) { out.append($0) }
        links.goOnline("srv-b", name: "Mac B")
        links.receive(.sessionList(sessions: [
            RemoteSessionSummary(id: "s1", title: "B1", agentId: "claude", status: "idle", canDrive: false)
        ]), from: "srv-b")
        // The cache update itself asks the gateway to refresh; the explicit
        // request supersedes that refresh (same generation counter) and its
        // list is what lands.
        await gateway.handle(.listSessions)
        await Task.yield()
        guard case .sessionList(let rows) = out.last else {
            Issue.record("expected sessionList, got \(String(describing: out.last))")
            return
        }
        #expect(rows.map(\.id) == ["local", "srv-b:s1"])
        #expect(rows.last?.serverId == "srv-b")
        #expect(links.sent(to: "srv-b").filter { $0 == .listSessions }.count >= 1)
        gateway.close()
    }

    @Test func closingTheGatewayUnsubscribesUpstream() async {
        let provider = FakeSessionsProvider()
        let links = FederatedSessionsProviderTests.FakeLinks()
        let federation = FederatedSessionsProvider(links: links)
        let gateway = RemoteSessionGateway(provider: provider, federation: federation) { _ in }
        links.goOnline("srv-b", name: "Mac B")
        await gateway.handle(.subscribe(sessionId: "srv-b:s1"))
        gateway.close()
        #expect(links.sent(to: "srv-b").contains(.unsubscribe(sessionId: "s1")))
    }

    @Test func aGatewayWithoutFederationTreatsPrefixedIdsAsLocal() async {
        let provider = FakeSessionsProvider()
        var out: [RemoteServerMessage] = []
        let gateway = RemoteSessionGateway(provider: provider) { out.append($0) }
        await gateway.handle(.subscribe(sessionId: "srv-b:s1"))
        #expect(out == [.sessionClosed(sessionId: "srv-b:s1")])
    }
}
