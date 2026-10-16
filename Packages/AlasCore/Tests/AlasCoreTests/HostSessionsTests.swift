import Foundation
import Testing
@_spi(Testing) @testable import AlasCore

@MainActor
struct HostSessionsTests {
    /// The host's session verbs drive an agent end to end: a session is
    /// created and connected, takes a prompt, has its permission request
    /// answered once, and is stopped, renamed and archived.
    @Test func sessionVerbsDriveAnAgent() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let sessions = fixture.host.sessions

        await #expect(throws: SessionRefusal.agentUnavailable) {
            try await sessions.create(.worktree(fixture.ref), agentID: "nobody", caller: .app)
        }
        let created = try await sessions.create(.worktree(fixture.ref), agentID: "gemini", caller: .app)
        #expect(created.owner == .worktree(fixture.worktree.id))
        let id = created.id
        try await eventually { await sessions.list().first { $0.id == id }?.isWriter == true }

        try await sessions.send(id, prompt: "hello", caller: .app)
        try await eventually { fixture.agent.sent.contains { $0.method == "session/prompt" } }

        let requestID = JSONRPCID.number(7)
        fixture.agent.emitPermission(id: requestID, params: ACPPermissionRequestParams(
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
        let manager = try #require(fixture.core.sessionManagers.values.first)
        try await eventually { await manager.liveSession(for: id)?.transcript.pendingPermission != nil }
        // Clients answer the request by the id the session shows for it.
        let pending = try #require(manager.liveSession(for: id)?.transcript.pendingPermission)
        await #expect(throws: SessionRefusal.invalidAnswer) {
            try await sessions.answerPermission(id, requestID: pending.id, optionID: "maybe", caller: .app)
        }
        try await sessions.answerPermission(id, requestID: pending.id, optionID: "allow", caller: .app)
        try await eventually { fixture.agent.permissionResponses[requestID] != nil }
        await #expect(throws: SessionRefusal.notPending) {
            try await sessions.answerPermission(id, requestID: pending.id, optionID: "allow", caller: .app)
        }

        // Another instance on the same store cannot archive what this one drives.
        let elsewhere = ACPSessionManager(
            worktreeId: fixture.worktree.id,
            worktreePath: fixture.worktree.path.path,
            owner: .worktree(fixture.worktree.id),
            persistence: ACPSessionPersistence(path: fixture.sessionsDatabase.path),
            instanceId: "elsewhere"
        )
        #expect(try await !elsewhere.archiveUnlessDrivenElsewhere(id: id))

        try await sessions.stop(id, caller: .app)
        try sessions.rename(id, title: "Renamed", caller: .app)
        #expect(sessions.list().first { $0.id == id }?.title == "Renamed")
        try await sessions.archive(id, caller: .app)
        #expect(!sessions.list().contains { $0.id == id })
        await #expect(throws: SessionRefusal.notFound) { try await sessions.send(id, prompt: "again", caller: .app) }
    }

    enum Unavailable: CaseIterable {
        /// An interrupted checkpoint restore is being recovered.
        case recoveringCheckpoint
        /// Something is changing the Workspace checkout.
        case busyCheckout
        /// The agent cannot run on the checkout's SSH host.
        case agentNotOnRemoteHost
    }

    /// A session is not created where it could not safely run.
    @Test(arguments: Unavailable.allCases)
    func creationIsRefusedWhereASessionCannotRun(_ reason: Unavailable) async throws {
        let environment = RefusingEnvironment()
        let fixture = try Fixture(environment: environment)
        defer { fixture.tearDown() }
        let target: SessionTarget
        let refusal: SessionRefusal
        switch reason {
        case .recoveringCheckpoint:
            environment.recovering = true
            target = .worktree(fixture.ref)
            refusal = .ownerUnavailable(reason: SessionsAPI.checkpointRecoveryReason)
        case .busyCheckout:
            target = .workspaceCheckout(id: try await fixture.addCheckout(operation: .archiving, location: .local))
            refusal = .ownerUnavailable(reason: "The Workspace checkout is busy.")
        case .agentNotOnRemoteHost:
            environment.localOnlyAgents = true
            target = .workspaceCheckout(id: try await fixture.addCheckout(operation: .idle, location: .ssh("build")))
            refusal = .agentUnavailable
        }

        await #expect(throws: refusal) {
            try await fixture.host.sessions.create(target, agentID: "gemini", caller: .app)
        }
        #expect(fixture.host.sessions.list().isEmpty)
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let core: AlasCoreContext
        let host: AlasHost
        let agent = ACPMockClient()
        let worktree: Worktree
        var ref: WorktreeRef { WorktreeRef(projectID: "p", path: worktree.path.path) }
        var sessionsDatabase: URL { root.appendingPathComponent("sessions.sqlite") }

        init(environment: any AlasHostEnvironment = HeadlessHostEnvironment()) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("alas-sessions-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let project = ProjectConfig(id: "p", name: "p", path: root.path, color: "blue", addedAt: .distantPast)
            let projects = ProjectsManager(persistedProjects: [project])
            let path = root.appendingPathComponent("feature")
            worktree = Worktree(
                id: Worktree.makeId(path: path), projectId: "p", name: "feature", branch: "feature",
                path: path, status: .clean, lastActivity: .distantPast
            )
            projects.insertOptimisticWorktree(worktree)
            agent.script(method: "initialize") { _ in Data(#"{"protocolVersion":1,"sessionCapabilities":{}}"#.utf8) }
            agent.script(method: "session/new") { _ in Data(#"{"sessionId":"agent-1"}"#.utf8) }
            agent.script(method: "session/prompt") { _ in Data("null".utf8) }
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
                },
                environment: environment
            )
            host = AlasHost(core: core)
        }

        func addCheckout(operation: WorkspaceCheckoutOperation, location: ExecutionLocation) async throws -> UUID {
            let checkout = WorkspaceCheckout(
                workspaceID: nil, fallbackWorkspaceName: "w", executionLocation: location,
                branch: "b", rootPath: root.path, operation: operation, members: []
            )
            try await core.workspaceStore.mutate { $0.checkouts.append(checkout) }
            return checkout.id
        }

        func tearDown() {
            core.sessionManagers.values.forEach { $0.shutdownBackgroundTasks() }
            try? FileManager.default.removeItem(at: root)
        }
    }
}

/// A host that can refuse what the tests ask it to.
@MainActor
private final class RefusingEnvironment: AlasHostEnvironment {
    var recovering = false
    var localOnlyAgents = false

    func checkpointRecoveryBlocksSessions(owner: SessionOwnerID, in core: AlasCoreContext) async -> Bool { recovering }

    func admitsAgent(_ agentID: String, remoteHost: String?) -> Bool { !localOnlyAgents || remoteHost == nil }
}
