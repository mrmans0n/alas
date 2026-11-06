import Foundation
import Testing
@_spi(Testing) @_spi(AppHost) @testable import AlasCore
@_spi(Testing) @_spi(AppHost) @testable import AlasHostCore

@MainActor
struct DelegationRecoveryTests {
    /// A delegation the host stopped in the middle of setting up, whose
    /// worktree never appeared, fails instead of staying in setup forever.
    @Test func setupInterruptedBeforeItsWorktreeExistedFails() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alas-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = ACPOrchestrationPersistence(path: root.appendingPathComponent("orchestration.sqlite").path)
        try await persistence.insert(ACPDelegationRecord(
            childSessionId: "child", parentSessionId: "parent", projectId: "p",
            parentWorktreeId: "parent-worktree", childWorktreeId: nil, agentId: "codex",
            worktreeRequest: .new(branch: "feature", base: "main", destinationPath: root.appendingPathComponent("feature").path, optimisticId: "feature"),
            pendingInitialPrompt: "Go", phase: .creatingWorktree, failureMessage: nil, createdAt: 1, updatedAt: 1
        ))
        let core = AlasCoreContext(
            projects: ProjectsManager(persistedProjects: []), runHistoryStore: nil, attentionStore: .scratch(), orchestrationPersistence: persistence
        )

        await core.recoverDelegations()

        let record = try #require(try await persistence.delegation(childSessionId: "child"))
        #expect(record.phase == .failed)
        #expect(record.failureMessage == "Alas stopped before delegated session setup completed.")
    }

    /// A child a paired Mac started, caught by a restart before its session
    /// existed, restarts like a local one. What the peer allowed is not
    /// stored, so it cannot auto-run on this Mac's default, and it joins no
    /// local hierarchy.
    @Test(.timeLimit(.minutes(1))) func recoveryReattachesPeerChild() async throws {
        let fixture = try PeerHostFixture()
        defer { fixture.tearDown() }
        try await fixture.persistence.insert(fixture.peerRecord(phase: .starting, pendingInitialPrompt: "Go"))

        await fixture.core.loadDelegatedSessionParents()
        await fixture.core.recoverDelegations()

        let record = try #require(try await fixture.persistence.delegation(childSessionId: "child"))
        #expect(record.phase == .ready)
        let manager = try #require(fixture.core.sessionManagers.values.first)
        #expect(manager.liveSession(for: "child")?.autoRunEnabled == false)
        let agent = fixture.agent
        try await eventually { @MainActor in agent.sent.contains { $0.params is ACPSessionPromptParams } }
        #expect(fixture.core.delegatedSessionParents["child"] == nil)
        #expect(await fixture.core.delegatedParentSessionID(for: "child") == "peer:s1")
    }

    /// A finished peer child nobody recovers or reopens still names its Mac
    /// after the one backfill the host runs at boot.
    @Test(.timeLimit(.minutes(1))) func bootBackfillNamesFinishedPeerChildren() async throws {
        let fixture = try PeerHostFixture()
        defer { fixture.tearDown() }
        try await fixture.persistence.insert(fixture.peerRecord(phase: .ready, pendingInitialPrompt: nil))
        let devices = FileDeviceStore(url: fixture.root.appendingPathComponent("devices.json"))
        devices.save([RemoteDevice(
            id: "d1", name: "Studio", tokenHash: "h", createdAt: .distantPast, lastSeenAt: nil,
            kind: .alasInstance, peerServerId: "s1"
        )])
        let pairing = RemotePairingService(store: devices)
        fixture.core.delegationPairing = { pairing }
        #expect(fixture.core.delegatedFromName(of: "child") == nil)

        await fixture.core.loadDelegatedSessionParents()

        #expect(fixture.core.delegatedFromName(of: "child") == "Studio")
    }

    /// A headless host, which may share its profile with the app, re-attaches
    /// a peer child that had a turn in flight and touches nothing else: a
    /// local child it does not list would otherwise fail, and a local
    /// session's messages would be delivered.
    @Test(.timeLimit(.minutes(1))) func scopedRecoveryReattachesPeerChildAndLeavesLocalRows() async throws {
        let fixture = try PeerHostFixture()
        defer { fixture.tearDown() }
        try await fixture.seedQueuedTurn(sessionIDs: ["child", "local-ready"], otherSessionIDs: ["local-parent"])
        let persistence = fixture.persistence
        try await persistence.insert(fixture.peerRecord(phase: .ready, pendingInitialPrompt: nil))
        try await persistence.insert(fixture.localRecord(id: "local-starting", phase: .starting))
        try await persistence.insert(fixture.localRecord(id: "local-ready", phase: .ready))
        try await persistence.enqueue(.init(
            id: "for-local", sourceSessionId: "someone", targetSessionId: "local-parent", prompt: "Hello",
            createdAt: 1, kind: .notice
        ))

        await fixture.core.recoverDelegations(.peerChildren)

        let manager = try #require(fixture.core.sessionManagers.values.first)
        #expect(manager.isWriter(for: "child"))
        #expect(manager.liveSession(for: "child")?.agentState == .ready)
        let agent = fixture.agent
        try await eventually { @MainActor in agent.sent.contains { $0.params is ACPSessionPromptParams } }
        #expect(try await persistence.delegation(childSessionId: "child")?.phase == .ready)
        #expect(try await persistence.delegation(childSessionId: "local-starting")?.phase == .starting)
        #expect(try await persistence.delegation(childSessionId: "local-ready")?.phase == .ready)
        #expect(try await persistence.pendingMessages(targetSessionId: "local-parent").map(\.id) == ["for-local"])
        #expect(manager.liveSession(for: "local-ready") == nil)
    }

    /// Wired as headless boot wires it, a child blocked with no app around
    /// reaches the peer.
    @Test(.timeLimit(.minutes(1))) func blockedChildOfAHeadlessBuiltManagerReachesTheOutbox() async throws {
        let fixture = try PeerHostFixture()
        defer { fixture.tearDown() }
        let persistence = fixture.persistence
        try await persistence.insert(fixture.peerRecord(phase: .starting, pendingInitialPrompt: "Go"))
        await fixture.core.recoverDelegations(.peerChildren)

        fixture.agent.emitPermission(id: .number(7), params: ACPPermissionRequestParams(
            sessionId: "agent-1",
            toolCall: ACPPermissionToolCall(
                toolCallId: "call-1", title: "Run", kind: nil, status: nil,
                content: nil, locations: nil, rawInput: nil, rawOutput: nil
            ),
            options: [ACPPermissionOption(optionId: "allow", name: "Allow", kind: "allow_once")]
        ))

        try await eventually {
            (try? await persistence.outbox(peerServerId: "s1", after: 0, maxBytes: 1 << 20).entries.isEmpty) == false
        }
        let entries = try await persistence.outbox(peerServerId: "s1", after: 0, maxBytes: 1 << 20).entries
        #expect(entries.map(\.kind) == [.notice])
        #expect(entries.first?.prompt.contains("waiting for a human decision") == true)
    }

    /// A host whose managers come from `sessionManagerFactory`, as headless
    /// boot's do, with auto-run on by default and a listed worktree.
    @MainActor private struct PeerHostFixture {
        let root: URL
        let agent = ACPMockClient()
        let persistence: ACPOrchestrationPersistence
        let worktree: Worktree
        let core: AlasCoreContext
        var sessionsDB: URL { root.appendingPathComponent("sessions.sqlite") }

        init() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("alas-recovery-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            self.root = root
            let path = root.appendingPathComponent("feature")
            let worktree = Worktree(
                id: Worktree.makeId(path: path), projectId: "p", name: "feature", branch: "feature",
                path: path, status: .clean, lastActivity: .distantPast
            )
            self.worktree = worktree
            let projects = ProjectsManager(persistedProjects: [
                ProjectConfig(id: "p", name: "p", path: root.path, color: "blue", addedAt: .distantPast)
            ])
            projects.insertOptimisticWorktree(worktree)
            let agent = agent
            agent.script(method: "initialize") { _ in Data(#"{"protocolVersion":1,"sessionCapabilities":{}}"#.utf8) }
            agent.script(method: "session/new") { _ in Data(#"{"sessionId":"agent-1"}"#.utf8) }
            agent.script(method: "session/prompt") { _ in Data(#"{"stopReason":"end_turn"}"#.utf8) }
            let persistence = ACPOrchestrationPersistence(path: root.appendingPathComponent("orchestration.sqlite").path)
            self.persistence = persistence
            var configuration = AppConfig.defaults
            configuration.harness.acpAutoRunByDefault = true
            let database = root.appendingPathComponent("sessions.sqlite")
            weak var builtCore: AlasCoreContext?
            core = AlasCoreContext(
                projects: projects, runHistoryStore: nil, attentionStore: .scratch(),
                makeSessionManager: AlasCoreContext.sessionManagerFactory(
                    config: { configuration },
                    onChildBlocked: { blocker in
                        Task { @MainActor in await builtCore?.orchestration.childBlocked(blocker) }
                    },
                    sessionsDB: { _ in database },
                    setupEvaluator: { _ in .ready },
                    connectionFactory: { _, _, _ in ACPConnection(client: agent) }
                ),
                environment: HeadlessHostEnvironment(configuration: configuration),
                orchestrationPersistence: persistence
            )
            builtCore = core
            core.delegatedSessionsDB = { _ in database }
        }

        func peerRecord(phase: ACPDelegationPhase, pendingInitialPrompt: String?) -> ACPDelegationRecord {
            ACPDelegationRecord(
                childSessionId: "child", parentSessionId: ACPPeerParent.sentinel(serverId: "s1"), projectId: "p",
                parentWorktreeId: worktree.id, childWorktreeId: worktree.id, agentId: "gemini",
                worktreeRequest: .existing(worktreeId: worktree.id),
                pendingInitialPrompt: pendingInitialPrompt, phase: phase, failureMessage: nil, createdAt: 1, updatedAt: 1
            )
        }

        /// A local child in a worktree this host does not list.
        func localRecord(id: String, phase: ACPDelegationPhase) -> ACPDelegationRecord {
            ACPDelegationRecord(
                childSessionId: id, parentSessionId: "local-parent", projectId: "elsewhere",
                parentWorktreeId: "unlisted", childWorktreeId: "unlisted", agentId: "gemini",
                worktreeRequest: .existing(worktreeId: "unlisted"),
                pendingInitialPrompt: "Go", phase: phase, failureMessage: nil, createdAt: 1, updatedAt: 1
            )
        }

        /// What a stopped host left behind: stored sessions, the first ones
        /// with a queued prompt whose turn the parent is waiting on.
        func seedQueuedTurn(sessionIDs: [String], otherSessionIDs: [String]) async throws {
            let manager = ACPSessionManager(
                worktreeId: worktree.id, worktreePath: worktree.path.path, owner: .worktree(worktree.id),
                persistence: ACPSessionPersistence(path: sessionsDB.path),
                setupEvaluator: { _ in .missing(reason: "Not started") }
            )
            defer { manager.shutdownBackgroundTasks() }
            for id in otherSessionIDs { _ = manager.createSession(id: id, agentId: "gemini") }
            for id in sessionIDs {
                _ = manager.createSession(id: id, agentId: "gemini")
                let source = ACPDelegatedPromptSource(sessionId: "parent", messageId: "initial-\(id)")
                #expect(await manager.enqueueDelegatedPrompt(text: "Go", source: source, into: id))
            }
            await manager.flushPersistence()
        }

        func tearDown() {
            core.sessionManagers.values.forEach { $0.shutdownBackgroundTasks() }
            try? FileManager.default.removeItem(at: root)
        }
    }
}
