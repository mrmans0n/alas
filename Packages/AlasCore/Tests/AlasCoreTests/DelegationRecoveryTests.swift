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

    /// Wired this way on the app and on a headless host, which has no
    /// collector: a peer forgotten here will never collect what waits for it.
    @Test func forgettingAPeerDeletesWhatWaitsForItToCollect() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alas-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = ACPOrchestrationPersistence(path: root.appendingPathComponent("orchestration.sqlite").path)
        for server in ["mac-1", "mac-2"] {
            try await persistence.enqueue(.init(
                id: "to-\(server)", sourceSessionId: "child", targetSessionId: ACPPeerParent.sentinel(serverId: server),
                prompt: "done", createdAt: 1, kind: .prompt
            ))
        }
        let core = AlasCoreContext(
            projects: ProjectsManager(persistedProjects: []), runHistoryStore: nil, attentionStore: .scratch(), orchestrationPersistence: persistence
        )
        let peers = RemotePeerManager(
            store: MemoryPeerStore(peers: [RemotePeer(id: "peer-1", serverId: "mac-1", name: "Laptop", origins: [], token: "t", addedAt: .distantPast)]),
            pairing: RemotePairingService(store: MemoryDeviceStore()), localIdentity: { .init(serverId: "", name: "", origins: []) }
        )
        core.watchForRevokedPeers(of: peers)

        peers.forget(peerId: "peer-1")

        try await eventually {
            (try? await persistence.outbox(peerServerId: "mac-1", after: 0, maxBytes: 1 << 20).entries.isEmpty) == true
        }
        #expect(try await persistence.outbox(peerServerId: "mac-2", after: 0, maxBytes: 1 << 20).entries.count == 1)
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

    /// A child running on another Mac has nothing here to restart. Its parent
    /// is a real session, so the scope that looks for sentinel parents never
    /// matched it; the scope that takes everything would fail it.
    @Test(arguments: [DelegationRecoveryScope.all, .peerChildren])
    func recoverySkipsPeerRows(scope: DelegationRecoveryScope) async throws {
        let fixture = try PeerHostFixture()
        defer { fixture.tearDown() }
        for (id, phase) in [("starting", ACPDelegationPhase.starting), ("ready", .ready)] {
            try await fixture.persistence.insert(ACPDelegationRecord(
                childSessionId: id, parentSessionId: "local-parent", projectId: "p",
                parentWorktreeId: fixture.worktree.id, agentId: "gemini",
                worktreeRequest: .current(worktreeId: fixture.worktree.id), phase: phase,
                createdAt: 1, updatedAt: 1, peerServerId: "s1"
            ))
        }

        await fixture.core.recoverDelegations(scope)

        #expect(try await fixture.persistence.delegation(childSessionId: "starting")?.phase == .starting)
        #expect(try await fixture.persistence.delegation(childSessionId: "ready")?.phase == .ready)
    }

    /// Remote serves before recovery reads its rows, so a row may be a healthy
    /// child this process just created. Rows stamp whole seconds, so one from
    /// the second it started counts as its own.
    @Test(.timeLimit(.minutes(1))) func recoveryLeavesChildrenThisProcessCreated() async throws {
        let fixture = try PeerHostFixture()
        defer { fixture.tearDown() }
        fixture.core.processStartedAt = 100
        try await fixture.seedQueuedTurn(sessionIDs: ["new-ready"], otherSessionIDs: [])
        func setup(_ id: String, createdAt: Int64) -> ACPDelegationRecord {
            ACPDelegationRecord(
                childSessionId: id, parentSessionId: "parent", projectId: "p", parentWorktreeId: fixture.worktree.id,
                agentId: "gemini",
                worktreeRequest: .new(branch: id, base: "main", destinationPath: fixture.root.appendingPathComponent(id).path, optimisticId: id),
                pendingInitialPrompt: "Go", phase: .creatingWorktree, createdAt: createdAt, updatedAt: createdAt
            )
        }
        try await fixture.persistence.insert(setup("left-behind", createdAt: 99))
        for (id, createdAt) in [("same-second", Int64(100)), ("later", 200)] {
            try await fixture.persistence.insert(setup(id, createdAt: createdAt))
        }
        try await fixture.persistence.insert(ACPDelegationRecord(
            childSessionId: "new-ready", parentSessionId: "parent", projectId: "p", parentWorktreeId: fixture.worktree.id,
            childWorktreeId: fixture.worktree.id, agentId: "gemini", worktreeRequest: .existing(worktreeId: fixture.worktree.id),
            phase: .ready, createdAt: 200, updatedAt: 200
        ))

        await fixture.core.recoverDelegations()

        #expect(try await fixture.persistence.delegation(childSessionId: "left-behind")?.phase == .failed)
        #expect(try await fixture.persistence.delegation(childSessionId: "same-second")?.phase == .creatingWorktree)
        #expect(try await fixture.persistence.delegation(childSessionId: "later")?.phase == .creatingWorktree)
        #expect(fixture.core.sessionManagers.values.first?.liveSession(for: "new-ready") == nil)
    }

    /// A host stopped between committing an outcome and delivering it, or
    /// `alas-host peers remove` with no host running, leaves a root parent's
    /// wake in the inbox. Only its source row says it is the host's to deliver;
    /// `scopedRecoveryReattachesPeerChildAndLeavesLocalRows` pins the opposite.
    @Test(.timeLimit(.minutes(1))) func scopedRecoveryDeliversAPeerChildsOutcomeToItsRootParent() async throws {
        let fixture = try PeerHostFixture()
        defer { fixture.tearDown() }
        try await fixture.seedQueuedTurn(sessionIDs: [], otherSessionIDs: ["parent"])
        try await fixture.persistence.insert(fixture.childOnAPeer(phase: .failed))
        try await fixture.persistence.enqueue(.init(
            id: "outcome-on-peer-failed", sourceSessionId: "on-peer", targetSessionId: "parent", prompt: "It failed",
            createdAt: 1, kind: .prompt
        ))

        await fixture.core.recoverDelegations(.peerChildren)

        #expect(try await fixture.persistence.pendingMessages(targetSessionId: "parent").isEmpty)
        let agent = fixture.agent
        try await eventually { @MainActor in Self.prompts(agent).contains { $0.contains("It failed") } }
    }

    /// Remote can come on after launch, when nothing is there to collect from
    /// yet, and each time it does it brings a new client: the old one's
    /// channels are gone, and the signals go to the new one's slots.
    @Test(.timeLimit(.minutes(2))) func collectionFollowsPeersSetAndReplacedAfterItWasRequested() async throws {
        let fixture = try PeerHostFixture()
        defer { fixture.tearDown() }
        try await fixture.seedQueuedTurn(sessionIDs: [], otherSessionIDs: ["parent"])
        try await fixture.persistence.insert(fixture.childOnAPeer(phase: .ready))
        func outcome(_ seq: Int64) -> ACPPeerOutboxEntry {
            .init(seq: seq, messageId: "outcome-\(seq)", childSessionId: "on-peer", prompt: "done \(seq)", kind: .prompt, createdAt: seq)
        }
        let agent = fixture.agent
        func delivered(_ seq: Int64) async throws {
            try await eventually { @MainActor in Self.prompts(agent).contains { $0.contains("done \(seq)") } }
        }

        fixture.core.startCollectingPeerOutcomes()
        let first = FakePeers(entries: [outcome(1)])
        fixture.core.delegationPeers = first
        try await delivered(1)

        let second = FakePeers(entries: [outcome(1), outcome(2)])
        fixture.core.delegationPeers = second
        try await delivered(2)

        second.entries.append(outcome(3))
        second.onOutboxChanged?("s1")
        try await delivered(3)
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

    private static func prompts(_ agent: ACPMockClient) -> [String] {
        agent.sent.compactMap { $0.params as? ACPSessionPromptParams }.map { params in
            params.prompt.compactMap { block -> String? in
                guard case .text(let text) = block else { return nil }
                return text
            }.joined()
        }
    }

    /// An online Mac whose outbox holds `entries`, and which answers nothing else.
    @MainActor private final class FakePeers: ACPDelegationPeers {
        var entries: [ACPPeerOutboxEntry]
        let peers = [ACPDelegationPeerInfo(name: "Studio", serverId: "s1", state: .online, supportsDelegation: true)]
        var onOutboxChanged: (@MainActor (String) -> Void)?
        var onAvailabilityChanged: (@MainActor (String) -> Void)?

        init(entries: [ACPPeerOutboxEntry]) { self.entries = entries }

        func outbox(serverId: String, after: Int64, store: String?) async -> Result<ACPPeerOutboxPage, ACPPeerError> {
            .success(.init(entries: entries.filter { $0.seq > after }, hasMore: false))
        }
        func discover(serverId: String, repository: String?) async -> Result<ACPPeerDiscovery, ACPPeerError> { .failure(.notFound) }
        func start(serverId: String, _ start: ACPPeerChildStartRequest) async -> Result<ACPPeerStartReply, ACPPeerError> { .failure(.notFound) }
        func send(serverId: String, sessionID: String, prompt: String) async -> Result<Int64, ACPPeerError> { .failure(.notFound) }
        func read(serverId: String, sessionID: String, offset: Int?, limit: Int?, maxChars: Int?) async -> Result<Data, ACPPeerError> { .failure(.notFound) }
        func status(serverId: String, sessionIDs: [String]) async -> Result<Data, ACPPeerError> { .failure(.notFound) }
        func interrupt(serverId: String, sessionID: String) async -> Result<Bool, ACPPeerError> { .failure(.notFound) }
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

        /// A child this host delegated to a paired Mac, from root session `parent`.
        func childOnAPeer(phase: ACPDelegationPhase) -> ACPDelegationRecord {
            ACPDelegationRecord(
                childSessionId: "on-peer", parentSessionId: "parent", projectId: "p", parentWorktreeId: worktree.id,
                agentId: "gemini", worktreeRequest: .current(worktreeId: worktree.id), phase: phase,
                createdAt: 1, updatedAt: 1, peerServerId: "s1"
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
