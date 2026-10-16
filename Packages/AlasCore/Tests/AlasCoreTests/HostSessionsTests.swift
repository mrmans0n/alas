import Foundation
import Testing
@_spi(Testing) @testable import AlasCore

@MainActor
struct HostSessionsTests {
    /// The host's session verbs drive an agent end to end: a session is
    /// created and connected, takes a prompt, has its permission request
    /// answered once, and is stopped, renamed and archived.
    @Test func sessionVerbsDriveAnAgent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alas-sessions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = ProjectConfig(id: "p", name: "p", path: root.path, color: "blue", addedAt: .distantPast)
        let projects = ProjectsManager(persistedProjects: [project])
        let path = root.appendingPathComponent("feature")
        let worktree = Worktree(
            id: Worktree.makeId(path: path), projectId: "p", name: "feature", branch: "feature",
            path: path, status: .clean, lastActivity: .distantPast
        )
        projects.insertOptimisticWorktree(worktree)
        let agent = ACPMockClient()
        agent.script(method: "initialize") { _ in Data(#"{"protocolVersion":1,"sessionCapabilities":{}}"#.utf8) }
        agent.script(method: "session/new") { _ in Data(#"{"sessionId":"agent-1"}"#.utf8) }
        agent.script(method: "session/prompt") { _ in Data("null".utf8) }
        let core = AlasCoreContext(
            projects: projects,
            runHistoryStore: nil,
            workspaceStore: WorkspaceStore(url: root.appendingPathComponent("workspaces.json")),
            makeSessionManager: { owner, worktree in
                ACPSessionManager(
                    worktreeId: worktree.id,
                    worktreePath: worktree.path.path,
                    owner: owner,
                    persistence: ACPSessionPersistence(path: root.appendingPathComponent("sessions.sqlite").path),
                    setupEvaluator: { _ in .ready },
                    connectionFactory: { _, _, _ in ACPConnection(client: agent) }
                )
            }
        )
        let sessions = AlasHost(core: core).sessions
        defer { core.sessionManagers.values.forEach { $0.shutdownBackgroundTasks() } }

        await #expect(throws: SessionRefusal.agentUnavailable) {
            try await sessions.create(.worktree(WorktreeRef(projectID: "p", path: path.path)), agentID: "nobody", caller: .app)
        }
        let created = try await sessions.create(.worktree(WorktreeRef(projectID: "p", path: path.path)), agentID: "gemini", caller: .app)
        #expect(created.owner == .worktree(worktree.id))
        let id = created.id
        try await eventually { await sessions.list().first { $0.id == id }?.isWriter == true }

        try await sessions.send(id, prompt: "hello", caller: .app)
        try await eventually { agent.sent.contains { $0.method == "session/prompt" } }

        let requestID = JSONRPCID.number(7)
        agent.emitPermission(id: requestID, params: ACPPermissionRequestParams(
            sessionId: "agent-1",
            toolCall: ACPPermissionToolCall(
                toolCallId: "call-1", title: "Run", kind: nil, status: nil,
                content: nil, locations: nil, rawInput: nil, rawOutput: nil
            ),
            options: [
                ACPPermissionOption(optionId: "allow", name: "Allow", kind: "allow_once"),
                ACPPermissionOption(optionId: "reject", name: "Reject", kind: "reject_once"),
            ]
        ))
        try await eventually { await core.sessionManagers.values.first?.liveSession(for: id)?.transcript.pendingPermission != nil }
        // Clients answer the request by the id the session shows for it.
        let pending = try #require(core.sessionManagers.values.first?.liveSession(for: id)?.transcript.pendingPermission)
        await #expect(throws: SessionRefusal.invalidAnswer) {
            try await sessions.answerPermission(id, requestID: pending.id, optionID: "maybe", caller: .app)
        }
        try await sessions.answerPermission(id, requestID: pending.id, optionID: "allow", caller: .app)
        try await eventually { agent.permissionResponses[requestID] != nil }
        await #expect(throws: SessionRefusal.notPending) {
            try await sessions.answerPermission(id, requestID: pending.id, optionID: "allow", caller: .app)
        }

        try await sessions.stop(id, caller: .app)
        try sessions.rename(id, title: "Renamed", caller: .app)
        #expect(sessions.list().first { $0.id == id }?.title == "Renamed")
        try await sessions.archive(id, caller: .app)
        #expect(!sessions.list().contains { $0.id == id })
        await #expect(throws: SessionRefusal.notFound) { try await sessions.send(id, prompt: "again", caller: .app) }
    }
}
