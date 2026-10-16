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
        await #expect(throws: SessionRefusal.invalidSetting) {
            try await sessions.setConfigOption(id, configID: "no-such-option", value: .string("x"), caller: .app)
        }
        fixture.core.sessionManagers.values.first?.liveSession(for: id)?.availableModels = [ACPModelInfo(id: "fast", name: "Fast")]
        await #expect(throws: SessionRefusal.invalidSetting) {
            try await sessions.setModel(id, modelID: "unadvertised", caller: .app)
        }

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
        // Two answers race, each recording a decision for the session: only
        // the first to claim the request counts.
        let answers = [
            Task { try await sessions.answerPermission(id, requestID: pending.id, optionID: "allow", scope: .session, caller: .app) },
            Task { try await sessions.answerPermission(id, requestID: pending.id, optionID: "reject", scope: .session, caller: .app) },
        ]
        var refused = 0
        for answer in answers {
            do { try await answer.value } catch SessionRefusal.notPending { refused += 1 }
        }
        #expect(refused == 1)
        try await eventually { fixture.agent.permissionResponses[requestID] != nil }

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
        // Nobody drives an archived session again, even with a stale view of it.
        #expect(try await ACPSessionPersistence(path: fixture.sessionsDatabase.path).claimLease(
            sessionId: id, instanceId: "elsewhere", pid: Int64(getpid()),
            now: Int64(Date().timeIntervalSince1970), staleAfter: 60, leaseToken: "stale"
        ) == nil)
        await #expect(throws: SessionRefusal.notFound) { try await sessions.send(id, prompt: "again", caller: .app) }
    }

    /// An answer that reaches no agent is not reported as given: a session
    /// shown here but not connected cannot pass it on.
    @Test func answersWithNoAgentToReceiveThemAreRefused() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let manager = try fixture.core.sessionManager(for: fixture.worktree)
        let session = manager.createSession(agentId: "gemini")
        session.transcript.pendingQuestion = .init(id: .number(3), params: ACPQuestionRequestParams(
            toolCallId: "call-1", title: nil,
            questions: [ACPQuestion(id: "q", prompt: "Which?", options: [ACPQuestionOption(id: "a", label: "A")], allowMultiple: false)]
        ))

        #expect(throws: SessionRefusal.notPending) {
            try fixture.host.sessions.answerQuestion(
                session.id, requestID: .number(3), answers: [ACPQuestionAnswer(questionId: "q", selectedOptionIds: ["a"])], caller: .app
            )
        }
    }

    /// A headless host ends a Workspace checkout's sessions before the
    /// checkout is archived or removed, as the app does.
    @Test func headlessCheckoutTeardownEndsItsSessions() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let id = try await fixture.addCheckout(operation: .idle, location: .local)
        let created = try await fixture.host.sessions.create(.workspaceCheckout(id: id), agentID: "gemini", caller: .app)
        #expect(fixture.core.sessionManagers[created.owner] != nil)

        let checkout = try await WorkspaceAutomationService(store: fixture.core.workspaceStore).checkout(id: id)
        try await fixture.core.environment.stopWorkspaceCheckoutSessions(checkout, in: fixture.core)
        #expect(fixture.core.sessionManagers[created.owner] == nil)
    }

    /// A setting the session drops because another instance took it over
    /// while the lease was being confirmed is reported, not acknowledged.
    @Test func settingsLostToATakeoverAreRefused() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let sessions = fixture.host.sessions
        let id = try await sessions.create(.worktree(fixture.ref), agentID: "gemini", caller: .app).id
        try await eventually { await sessions.list().first { $0.id == id }?.isWriter == true }
        let manager = try #require(fixture.core.sessionManagers.values.first)

        // Another instance takes the lease while this one still believes it holds it.
        let store = ACPSessionPersistence(path: fixture.sessionsDatabase.path)
        try await store.releaseLease(sessionId: id, instanceId: manager.instanceId)
        _ = try await store.claimLease(
            sessionId: id, instanceId: "elsewhere", pid: Int64(getpid()),
            now: Int64(Date().timeIntervalSince1970), staleAfter: 60, leaseToken: "theirs"
        )
        #expect(manager.isWriter(for: id), "the takeover is not observed yet")

        await #expect(throws: SessionRefusal.notWriter) {
            try await sessions.setModel(id, modelID: "fast", caller: .app)
        }
    }

    /// An attachment of this instance can hold the session's lease before
    /// the manager records it; archiving fences with that lease and leaves it.
    @Test func archiveUsesALeaseThisInstanceAlreadyHolds() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let manager = try fixture.core.sessionManager(for: fixture.worktree)
        let session = manager.createSession(agentId: "gemini")
        await manager.flushAllPersistence()
        let store = ACPSessionPersistence(path: fixture.sessionsDatabase.path)
        _ = try await store.claimLease(
            sessionId: session.id, instanceId: manager.instanceId, pid: Int64(getpid()),
            now: Int64(Date().timeIntervalSince1970), staleAfter: 60, leaseToken: "attaching"
        )

        try await fixture.host.sessions.archive(session.id, caller: .app)
        #expect(!fixture.host.sessions.list().contains { $0.id == session.id })
        #expect(try await store.loadLease(sessionId: session.id)?.token == "attaching")
    }

    /// Archiving right after creating waits for the session's row, and no
    /// later snapshot of the session brings it back.
    @Test func archivingJustAfterCreatingSticks() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let id = try await fixture.host.sessions.create(.worktree(fixture.ref), agentID: "gemini", caller: .app).id
        try await fixture.host.sessions.archive(id, caller: .app)

        let manager = try #require(fixture.core.sessionManagers.values.first)
        await manager.flushAllPersistence()
        #expect(try await ACPSessionPersistence(path: fixture.sessionsDatabase.path).loadSession(id: id)?.archived == true)
        #expect(!fixture.host.sessions.list().contains { $0.id == id })
    }

    enum Unavailable: CaseIterable {
        /// An interrupted checkpoint restore is being recovered.
        case recoveringCheckpoint
        /// Something is changing the Workspace checkout.
        case busyCheckout
        /// The agent cannot run on the checkout's SSH host.
        case agentNotOnRemoteHost
        /// An archive or delete claims the worktree while creation waits.
        case worktreeClaimedMeanwhile
        /// The worktree belongs to a remote project, which a headless host
        /// cannot run agents for.
        case remoteWorktree
        /// A checkpoint recovery starts while a checkout session is created.
        case recoveryStartsMeanwhile
        /// The host's own view says the owner is being changed as creation ends.
        case ownerClaimedAsCreationEnds
    }

    /// A session is not created where it could not safely run.
    @Test(arguments: Unavailable.allCases)
    func creationIsRefusedWhereASessionCannotRun(_ reason: Unavailable) async throws {
        let environment = RefusingEnvironment()
        let fixture = try Fixture(environment: environment, projectHost: reason == .remoteWorktree ? "build" : nil)
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
        case .worktreeClaimedMeanwhile:
            let projects = fixture.core.projects
            let worktree = fixture.worktree
            environment.duringRecoveryCheck = { projects.setOperationState(for: worktree, state: .archiving(projectId: "p")) }
            target = .worktree(fixture.ref)
            refusal = .ownerUnavailable(reason: "Another operation holds the worktree.")
        case .remoteWorktree:
            target = .worktree(fixture.ref)
            refusal = .ownerUnavailable(reason: "Sessions in remote worktrees start from the app.")
        case .recoveryStartsMeanwhile:
            var checks = 0
            environment.duringRecoveryCheck = {
                checks += 1
                environment.recovering = checks > 1
            }
            target = .workspaceCheckout(id: try await fixture.addCheckout(operation: .idle, location: .local))
            refusal = .ownerUnavailable(reason: SessionsAPI.checkpointRecoveryReason)
        case .ownerClaimedAsCreationEnds:
            environment.admitsCreation = false
            target = .workspaceCheckout(id: try await fixture.addCheckout(operation: .idle, location: .local))
            refusal = .ownerUnavailable(reason: "The session's owner was closed or claimed meanwhile.")
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

        init(environment: any AlasHostEnvironment = HeadlessHostEnvironment(), projectHost: String? = nil) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("alas-sessions-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var project = ProjectConfig(id: "p", name: "p", path: root.path, color: "blue", addedAt: .distantPast)
            project.host = projectHost
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
    var admitsCreation = true
    /// Runs while creation waits on the recovery check.
    var duringRecoveryCheck: () -> Void = {}

    func checkpointRecoveryBlocksSessions(owner: SessionOwnerID, in core: AlasCoreContext) async -> Bool {
        duringRecoveryCheck()
        return recovering
    }

    func admitsAgent(_ agentID: String, remoteHost: String?) -> Bool { !localOnlyAgents || remoteHost == nil }

    func admitsSessionCreation(owner: SessionOwnerID, in core: AlasCoreContext) -> Bool { admitsCreation }
}
