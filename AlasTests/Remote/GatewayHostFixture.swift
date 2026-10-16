import Foundation
import Testing
@testable import Alas
@_spi(Testing) import AlasCore

/// A host built from `AlasCoreContext` with one worktree and a scripted
/// agent, with the fake app around it.
@MainActor
final class GatewayHostFixture {
    let root: URL
    let agent = ACPMockClient()
    let core: AlasCoreContext
    let host: AlasHost
    let worktree: Worktree
    let provider = FakeRemoteApp()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("alas-gateway-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let projects = ProjectsManager(persistedProjects: [
            ProjectConfig(id: "p", name: "p", path: root.path, color: "blue", addedAt: .distantPast),
        ])
        let path = root.appendingPathComponent("feature")
        worktree = Worktree(
            id: Worktree.makeId(path: path), projectId: "p", name: "feature", branch: "feature",
            path: path, status: .clean, lastActivity: .distantPast
        )
        projects.insertOptimisticWorktree(worktree)
        agent.script(method: "initialize") { _ in Data(#"{"protocolVersion":1,"sessionCapabilities":{}}"#.utf8) }
        agent.script(method: "session/new") { _ in Data(#"{"sessionId":"agent-1"}"#.utf8) }
        agent.script(method: "session/prompt") { _ in Data(#"{"stopReason":"end_turn"}"#.utf8) }
        let agent = agent
        let database = root.appendingPathComponent("sessions.sqlite")
        core = AlasCoreContext(
            projects: projects,
            runHistoryStore: nil,
            workspaceStore: WorkspaceStore(url: root.appendingPathComponent("workspaces.json")),
            makeSessionManager: { owner, worktree in
                ACPSessionManager(
                    worktreeId: worktree.id,
                    worktreePath: worktree.path.path,
                    owner: owner,
                    persistence: ACPSessionPersistence(path: database.path),
                    setupEvaluator: { _ in .ready },
                    connectionFactory: { _, _, _ in ACPConnection(client: agent) }
                )
            }
        )
        host = AlasHost(core: core)
        provider.host = host
    }

    var manager: ACPSessionManager? { core.sessionManagers.values.first }

    /// A loaded session `id` with no agent, holding `messages`.
    func session(_ id: String = "s1", messages: [ACPMessage] = []) throws -> ACPSession {
        let session = try core.sessionManager(for: worktree).createSession(id: id, agentId: "claude")
        session.transcript.messages = messages
        return session
    }

    /// A session this instance drives, connected to the agent.
    func drivenSession() async throws -> String {
        let ref = WorktreeRef(projectID: "p", path: worktree.path.path)
        let id = try await host.sessions.create(.worktree(ref), agentID: "gemini", caller: .app).id
        try await until { self.host.sessions.isWriter(id) && self.manager?.liveSession(for: id)?.agentState == .ready }
        return id
    }

    /// Another instance takes the session's lease while this one still
    /// believes it holds it, so the manager refuses at its next check.
    func loseLease(_ id: String) async throws {
        let manager = try #require(manager)
        let store = ACPSessionPersistence(path: root.appendingPathComponent("sessions.sqlite").path)
        try await store.releaseLease(sessionId: id, instanceId: manager.instanceId)
        _ = try await store.claimLease(
            sessionId: id, instanceId: "elsewhere", pid: Int64(getpid()),
            now: Int64(Date().timeIntervalSince1970), staleAfter: 60, leaseToken: "theirs"
        )
    }

    /// The text of each prompt the agent was sent, in order.
    var prompts: [String] {
        agent.sent.compactMap { request -> String? in
            guard request.method == "session/prompt", let params = request.params as? ACPSessionPromptParams else { return nil }
            return params.prompt.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(separator: "\n")
        }
    }

    /// The first form request a client was sent, once one is.
    func firstElicitation(in sent: @MainActor () -> [RemoteServerMessage]) async throws -> RemoteElicitationPayload {
        try await until { sent().contains { if case .elicitationRequest = $0 { true } else { false } } }
        return try #require(sent().compactMap { if case .elicitationRequest(_, let payload) = $0 { payload } else { nil } }.first)
    }

    func until(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("condition not met within 10 seconds")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    isolated deinit {
        tearDown()
    }

    func tearDown() {
        core.sessionManagers.values.forEach { $0.shutdownBackgroundTasks() }
        try? FileManager.default.removeItem(at: Paths.acpAttachmentsDir(forWorktreeId: worktree.id))
        // The session store stays open until its managers go, so its folder,
        // under the system's temporary directory, is left to the system.
    }
}
