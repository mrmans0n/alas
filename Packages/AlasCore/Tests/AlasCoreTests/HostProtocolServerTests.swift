import Foundation
import Testing
@_spi(Testing) @testable import AlasCore
@_spi(Testing) @testable import AlasHostCore

@MainActor
struct HostProtocolServerTests {
    /// A client that takes a snapshot and subscribes after its cursor hears
    /// it subscribed, then each change after the snapshot.
    @Test func subscribersHearTheirResponseThenTheChanges() async throws {
        let fixture = try Fixture()
        let client = Client()
        let connection = fixture.server.connect(caller: .localUser(uid: 501), send: client.receive)
        defer { connection.close() }

        await connection.receive(HostClientMessage(id: 1, request: .snapshot))
        guard case .response(1, .snapshot(let snapshot)) = client.messages.first else {
            Issue.record("expected a snapshot, got \(client.messages)")
            return
        }
        #expect(snapshot.worktrees.map(\.worktree) == [fixture.worktree])
        await connection.receive(HostClientMessage(id: 2, request: .subscribe(after: snapshot.cursor)))
        fixture.projects.setOperationState(for: fixture.worktree, state: .archiving(projectId: "p"))

        try await client.waitFor { $0.count == 3 }
        #expect(client.messages[1] == .response(id: 2, result: .subscribed))
        guard case .events(let events, let cursor) = client.messages[2] else {
            Issue.record("expected events, got \(client.messages[2])")
            return
        }
        #expect(events == [
            .worktreeChanged(WorktreeSnapshot(worktree: fixture.worktree, operation: .archiving, isArchived: false)),
        ])
        #expect(cursor.generation == snapshot.cursor.generation && cursor.sequence > snapshot.cursor.sequence)
    }

    /// A client that reads slowly holds its events back, where they coalesce,
    /// instead of being sent each intermediate state.
    @Test func aSlowClientGetsTheLatestState() async throws {
        let fixture = try Fixture()
        let client = Client()
        let connection = fixture.server.connect(caller: .localUser(uid: 501), send: client.receive)
        defer { connection.close() }
        await connection.receive(HostClientMessage(id: 1, request: .snapshot))
        guard case .response(1, .snapshot(let snapshot)) = client.messages.first else { return }
        await connection.receive(HostClientMessage(id: 2, request: .subscribe(after: snapshot.cursor)))

        client.holdsEvents = true
        fixture.projects.setOperationState(for: fixture.worktree, state: .archiving(projectId: "p"))
        try await client.waitFor { _ in client.heldEvents != nil }
        fixture.projects.setOperationState(for: fixture.worktree, state: .preparingDelete)
        fixture.projects.setOperationState(for: fixture.worktree, state: .deleting(projectId: "p"))
        // Let the host publish both changes while the client is still busy.
        try await client.waitFor { _ in fixture.host.worktrees.list().first?.operation == .deleting }
        await Task.yield()
        client.release()

        try await client.waitFor { $0.count == 4 }
        guard case .events(let events, _) = client.messages[3] else {
            Issue.record("expected events, got \(client.messages[3])")
            return
        }
        #expect(events == [
            .worktreeChanged(WorktreeSnapshot(worktree: fixture.worktree, operation: .deleting, isArchived: false)),
        ])
    }

    /// Requests overlap, but their messages leave in order: events never
    /// pass their subscribe response, and nothing follows an unsubscribe.
    @Test func messagesLeaveInTheOrderTheyAreQueued() async throws {
        let fixture = try Fixture()
        let client = Client()
        let connection = fixture.server.connect(caller: .localUser(uid: 501), send: client.receive)
        defer { connection.close() }
        await connection.receive(HostClientMessage(id: 1, request: .snapshot))
        guard case .response(1, .snapshot(let snapshot)) = client.messages.first else { return }

        client.heldResponseID = 2
        let subscribing = Task { await connection.receive(HostClientMessage(id: 2, request: .subscribe(after: snapshot.cursor))) }
        try await client.waitFor { _ in client.isHolding }
        let listing = Task { await connection.receive(HostClientMessage(id: 3, request: .listSessions)) }
        fixture.projects.setOperationState(for: fixture.worktree, state: .archiving(projectId: "p"))
        try await client.waitFor { _ in fixture.host.worktrees.list().first?.operation == .archiving }
        await Task.yield()
        #expect(client.messages.count == 1, "nothing passes the held subscribe response")
        client.release()
        await subscribing.value
        await listing.value
        try await client.waitFor { $0.count == 4 }
        #expect(client.messages[1] == .response(id: 2, result: .subscribed))
        #expect(client.messages[2] == .response(id: 3, result: .sessions(sessions: [])))
        guard case .events = client.messages[3] else {
            Issue.record("expected events last, got \(client.messages)")
            return
        }

        // An unsubscribe while a batch is being written comes after it, and
        // nothing comes after the unsubscribe.
        client.holdsEvents = true
        fixture.projects.setOperationState(for: fixture.worktree, state: .preparingDelete)
        try await client.waitFor { _ in client.heldEvents != nil }
        let unsubscribing = Task { await connection.receive(HostClientMessage(id: 4, request: .unsubscribe)) }
        fixture.projects.setOperationState(for: fixture.worktree, state: .deleting(projectId: "p"))
        try await client.waitFor { _ in fixture.host.worktrees.list().first?.operation == .deleting }
        await Task.yield()
        client.release()
        await unsubscribing.value
        try await client.waitFor { $0.last == .response(id: 4, result: .unsubscribed) }
        await Task.yield()
        #expect(client.messages.last == .response(id: 4, result: .unsubscribed))
    }

    @Test(arguments: [
        (HostClientMessage(version: 99, id: 1, request: .snapshot), HostError.unsupportedVersion(supported: HostProtocolVersion.current)),
        (
            HostClientMessage(id: 2, request: .archiveWorktree(
                worktree: WorktreeRef(projectID: "p", path: "/srv/missing"), lineageID: nil, branch: "missing"
            )),
            HostError.notFound(what: "worktree /srv/missing in project p")
        ),
        (
            HostClientMessage(id: 8, request: .unarchiveWorktree(worktree: WorktreeRef(projectID: "p", path: "/srv/missing"))),
            HostError.notFound(what: "worktree /srv/missing in project p")
        ),
        // A delete or archive names the checkout the client saw; one
        // replaced or switched since is not removed in its place.
        (
            HostClientMessage(id: 5, request: .archiveWorktree(
                worktree: WorktreeRef(projectID: "p", path: "/srv/feature"), lineageID: "seen", branch: "feature"
            )),
            HostError.worktreeArchive(refusal: .changed("The worktree changed since it was listed."))
        ),
        // The list can lag the disk: what is listed matches, but the path
        // holds no such checkout.
        (
            HostClientMessage(id: 7, request: .deleteWorktree(
                worktree: WorktreeRef(projectID: "p", path: "/srv/feature"),
                lineageID: "listed", branch: "feature", force: true, deleteBranchIfMerged: false
            )),
            HostError.worktreeDeletion(refusal: .changed("The checkout at this path changed."))
        ),
        (
            HostClientMessage(id: 6, request: .archiveWorktree(
                worktree: WorktreeRef(projectID: "p", path: "/srv/feature"), lineageID: "listed", branch: "feature"
            )),
            HostError.worktreeArchive(refusal: .changed("The checkout at this path changed."))
        ),
        (
            HostClientMessage(id: 3, request: .deleteWorktree(
                worktree: WorktreeRef(projectID: "p", path: "/srv/feature"),
                lineageID: "seen", branch: "feature", force: true, deleteBranchIfMerged: false
            )),
            HostError.worktreeDeletion(refusal: .changed("The worktree changed since it was listed."))
        ),
        (
            HostClientMessage(id: 4, request: .deleteWorktree(
                worktree: WorktreeRef(projectID: "p", path: "/srv/feature"),
                lineageID: "listed", branch: "old-branch", force: true, deleteBranchIfMerged: false
            )),
            HostError.worktreeDeletion(refusal: .changed("The worktree changed since it was listed."))
        ),
        (HostClientMessage(id: 9, request: .removeProject(projectID: "missing")), HostError.notFound(what: "project missing")),
    ])
    func refusedRequestsAnswerWithTheirError(_ message: HostClientMessage, _ error: HostError) async throws {
        let fixture = try Fixture()
        let client = Client()
        let connection = fixture.server.connect(caller: .localUser(uid: 501), send: client.receive)
        await connection.receive(message)
        #expect(client.messages == [.response(id: message.id, result: .failure(error: error))])
    }

    /// The refusals `host.worktrees.lifecycle.v1` added reach only a client that
    /// sent `discardUnsavedEdits`; an older one gets the message it can decode.
    @Test(arguments: [false, true])
    func newLifecycleRefusalsAreTypedOnlyForClientsThatAcknowledgeDiscards(typed: Bool) {
        let refusals: [any Error] = [
            WorktreeDeletionRefusal.unsavedEdits, WorktreeDeletionRefusal.ownedByWorkspaceCheckout("Owned."), WorktreeArchiveRefusal.unsavedEdits,
        ]
        let mapped = refusals.map { HostProtocolConnection.hostError(HostProtocolConnection.lifecycleRefusal($0, typed: typed)) }
        #expect(mapped == (typed
            ? [.worktreeDeletion(refusal: .unsavedEdits), .worktreeDeletion(refusal: .ownedByWorkspaceCheckout("Owned.")), .worktreeArchive(refusal: .unsavedEdits)]
            : refusals.map { .failed(message: $0.localizedDescription) }))
        #expect(HostProtocolConnection.hostError(HostProtocolConnection.lifecycleRefusal(WorktreeDeletionRefusal.needsForce("dirty"), typed: typed))
            == .worktreeDeletion(refusal: .needsForce("dirty")))
    }

    /// Only a listed worktree can be followed: an unknown id would keep a
    /// review refresh waking with no removal to ever end it.
    @Test func onlyListedWorktreesCanBeFollowed() async throws {
        let fixture = try Fixture()
        let client = Client()
        let connection = fixture.server.connect(caller: .localUser(uid: 501), send: client.receive)
        defer { connection.close() }
        let snapshot = try await fixture.host.snapshot()
        await connection.receive(HostClientMessage(id: 1, request: .subscribe(after: snapshot.cursor)))
        await connection.receive(HostClientMessage(id: 2, request: .followWorktree(worktreeID: "/srv/missing")))
        await connection.receive(HostClientMessage(id: 3, request: .followWorktree(worktreeID: fixture.worktree.id)))

        #expect(client.messages.contains(.response(id: 2, result: .failure(error: .notFound(what: "worktree /srv/missing")))))
        #expect(client.messages.contains(.response(id: 3, result: .done)))
    }

    /// A caller may keep only the connection, as the Remote gateway does:
    /// it still serves after the server value is gone.
    @Test func aConnectionServesAfterItsServerIsReleased() async throws {
        let fixture = try Fixture()
        let client = Client()
        let connection = HostProtocolServer(host: fixture.host).connect(caller: .localUser(uid: 501), send: client.receive)

        await connection.receive(HostClientMessage(id: 1, request: .listSessions))

        #expect(client.messages == [.response(id: 1, result: .sessions(sessions: []))])
    }

    /// Once the host stops serving, a connection opened before it answers
    /// that the host is stopping instead of serving the request.
    @Test func aClosedServerServesNoRequestOnOpenConnections() async throws {
        let fixture = try Fixture()
        let client = Client()
        let connection = fixture.server.connect(caller: .localUser(uid: 501), send: client.receive)

        fixture.server.close()
        await connection.receive(HostClientMessage(id: 1, request: .listSessions))

        #expect(client.messages == [.response(id: 1, result: .failure(error: .failed(message: "The host is stopping.")))])
    }

    /// Shutdown waits for a request still being served (here held in its
    /// script discovery, where a Git or SSH check would run) rather than
    /// exiting under it; the request then finds the host stopping.
    @Test func shutdownWaitsForARequestStillBeingServed() async throws {
        let fixture = try Fixture()
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let server = HostProtocolServer(host: fixture.host) { _, _ in
            entered.continuation.yield()
            for await _ in release.stream { break }
            return [RunScript(
                scope: .repo, fileName: "dev.sh", fileURL: URL(fileURLWithPath: "/srv/feature/dev.sh"),
                displayName: "Dev", onExit: .close, cwd: nil, isExecutable: true
            )]
        }
        let client = Client()
        let connection = server.connect(caller: .localUser(uid: 501), send: client.receive)
        let request = Task { await connection.receive(HostClientMessage(id: 1, request: .startRun(
            scriptKey: "repo:dev.sh", worktree: WorktreeRef(projectID: "p", path: fixture.worktree.path.path)
        ))) }
        for await _ in entered.stream { break }

        var shutdownFinished = false
        let shutdown = Task {
            await fixture.host.shutdown()
            shutdownFinished = true
        }
        // Shutdown is held while the request is served.
        for _ in 0..<50 { await Task.yield() }
        #expect(!shutdownFinished)
        #expect(client.messages.isEmpty)
        release.continuation.yield()
        await request.value
        await shutdown.value

        #expect(client.messages == [.response(id: 1, result: .runStart(start: .refused(
            title: "Host stopping", message: "The host is stopping and starts no new runs."
        )))])
    }

    /// Archiving stopped everything in a worktree; a run does not start
    /// there again, including one archived while its scripts were found.
    @Test(arguments: [false, true])
    func runsDoNotStartInArchivedWorktrees(archivedDuringDiscovery: Bool) async throws {
        let fixture = try Fixture()
        let projects = fixture.projects
        let worktree = fixture.worktree
        if !archivedDuringDiscovery {
            projects.setWorktreeHidden(projectId: "p", path: worktree.path, hidden: true)
        }
        let script = RunScript(
            scope: .repo, fileName: "dev.sh", fileURL: URL(fileURLWithPath: "/srv/feature/dev.sh"),
            displayName: "Dev", onExit: .close, cwd: nil, isExecutable: false
        )
        let server = HostProtocolServer(host: fixture.host) { _, _ in
            await MainActor.run { projects.setWorktreeHidden(projectId: "p", path: worktree.path, hidden: true) }
            return [script]
        }
        let client = Client()
        let connection = server.connect(caller: .localUser(uid: 501), send: client.receive)
        await connection.receive(HostClientMessage(id: 1, request: .startRun(
            scriptKey: "repo:dev.sh", worktree: WorktreeRef(projectID: "p", path: fixture.worktree.path.path)
        )))
        #expect(client.messages == [.response(id: 1, result: .runStart(start: .refused(
            title: "Worktree archived", message: "Unarchive the worktree to run scripts in it."
        )))])
    }

    /// A removed project leaves the host and the persisted list.
    @Test func removeProjectForgetsIt() async throws {
        let fixture = try await RepoFixture()
        defer { fixture.tearDown() }

        #expect(try await fixture.request(.removeProject(projectID: fixture.projectID)) == .done)

        guard case .snapshot(let snapshot) = try await fixture.request(.snapshot) else {
            Issue.record("expected a snapshot")
            return
        }
        #expect(snapshot.projects.isEmpty)
        let persisted = try #require(try PersistenceStore().readIfExists(ProjectsFile.self, from: fixture.projectsFile))
        #expect(persisted.projects.isEmpty)
    }

    /// A project with a session in one of its worktrees stays, whether its
    /// agent runs or is still starting.
    @Test(arguments: [false, true])
    func removeProjectRefusesWhileWorkIsLive(waitsForTheAgent: Bool) async throws {
        let fixture = try await RepoFixture()
        defer { fixture.tearDown() }
        let core = fixture.core
        let worktree = try #require(core.projects.worktrees(projectId: fixture.projectID).first)
        _ = try await fixture.host.sessions.create(
            .worktree(WorktreeRef(projectID: fixture.projectID, path: worktree.path.path)), agentID: "gemini", caller: .app
        )
        if waitsForTheAgent {
            try await eventually { @MainActor in core.sessionManagers.values.contains { !$0.runners.isEmpty } }
        }

        #expect(try await fixture.request(.removeProject(projectID: fixture.projectID)) == .failure(error: .projectBusy))
        #expect(core.projects.projects.map(\.id) == [fixture.projectID])
        let persisted = try #require(try PersistenceStore().readIfExists(ProjectsFile.self, from: fixture.projectsFile))
        #expect(persisted.projects.map(\.id) == [fixture.projectID])
        let manager = try #require(core.sessionManagers[.worktree(worktree.id)])
        try await eventually { @MainActor in !manager.runners.isEmpty }
    }

    /// A session archived before it ever attached no longer keeps its
    /// project from being removed.
    @Test func removeProjectAfterAnUnattachedSessionIsArchived() async throws {
        let fixture = try await RepoFixture()
        defer { fixture.tearDown() }
        fixture.core.sessionAttachScheduler = { _, _ in }
        let worktree = try #require(fixture.core.projects.worktrees(projectId: fixture.projectID).first)
        let session = try await fixture.host.sessions.create(
            .worktree(WorktreeRef(projectID: fixture.projectID, path: worktree.path.path)), agentID: "gemini", caller: .app
        )
        try await fixture.host.sessions.archive(session.id, caller: .app)

        #expect(try await fixture.request(.removeProject(projectID: fixture.projectID)) == .done)
    }

    /// A host over a real repository, persisting to a scratch directory,
    /// whose sessions talk to a scripted agent.
    @MainActor
    private struct RepoFixture {
        let root: URL
        let projectsFile: URL
        let core: AlasCoreContext
        let host: AlasHost
        let connection: HostProtocolConnection
        let client = Client()
        let projectID: String

        init() async throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("alas-remove-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let repo = root.appendingPathComponent("repo")
            try GitTemplate.repository(at: repo)
            projectsFile = root.appendingPathComponent("projects.json")
            let agent = ACPMockClient()
            agent.script(method: "initialize") { _ in Data(#"{"protocolVersion":1,"sessionCapabilities":{}}"#.utf8) }
            agent.script(method: "session/new") { _ in Data(#"{"sessionId":"agent-1"}"#.utf8) }
            let database = root.appendingPathComponent("sessions.sqlite")
            core = AlasCoreContext(
                projects: ProjectsManager(persistedProjects: []),
                projectsFile: projectsFile,
                runHistoryStore: nil,
                workspaceStore: WorkspaceStore(url: root.appendingPathComponent("workspaces.json")),
                attentionStore: .scratch(),
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
                orchestrationPersistence: ACPOrchestrationPersistence(path: root.appendingPathComponent("orchestration.sqlite").path)
            )
            host = AlasHost(core: core)
            connection = HostProtocolServer(host: host).connect(caller: .localUser(uid: 501), send: client.receive)
            projectID = try await host.projects.add(path: repo, displayName: "repo", icon: .default(), caller: .app).id
        }

        func request(_ request: HostRequest) async throws -> HostResponse {
            let id = client.messages.count + 1
            await connection.receive(HostClientMessage(id: id, request: request))
            guard case .response(id, let result) = client.messages.last else {
                throw HostError.invalidRequest(reason: "no response to \(id)")
            }
            return result
        }

        func tearDown() {
            connection.close()
            core.sessionManagers.values.forEach { $0.shutdownBackgroundTasks() }
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// Forgetting a Mac revokes the token it uses here, so only the local user
    /// may: never a paired device, which a stolen one could use to keep a peer.
    @Test(arguments: [true, false])
    func forgettingAPeerRevokesItsDeviceOnlyForTheLocalUser(isLocalUser: Bool) async throws {
        let fixture = try Fixture()
        let peer = RemotePeer(
            id: "peer-1", serverId: "mac-1", name: "Laptop", origins: ["http://laptop:1"], token: "t", addedAt: .distantPast
        )
        let device = RemoteDevice(
            id: "device-1", name: "Laptop", tokenHash: "h", createdAt: .distantPast, lastSeenAt: nil,
            kind: .alasInstance, peerServerId: "mac-1"
        )
        let peerStore = MemoryPeerStore(peers: [peer])
        let pairing = RemotePairingService(store: MemoryDeviceStore(devices: [device]))
        fixture.server.remotePeers = RemotePeerManager(
            store: peerStore, pairing: pairing, localIdentity: { .init(serverId: "", name: "", origins: []) }
        )
        let client = Client()
        let caller: HostCaller = isLocalUser ? .localUser(uid: 501) : .remotePeer(deviceID: "device-1")
        let connection = fixture.server.connect(caller: caller, send: client.receive)

        await connection.receive(HostClientMessage(id: 1, request: .forgetPeer(peerID: "peer-1")))

        if isLocalUser {
            #expect(client.messages == [.response(id: 1, result: .done)])
            #expect(peerStore.peers.isEmpty)
            #expect(pairing.devices.isEmpty)
        } else {
            guard case .response(_, .failure)? = client.messages.first else {
                Issue.record("expected a failure, got \(client.messages)")
                return
            }
            #expect(peerStore.peers == [peer])
            #expect(pairing.devices == [device])
        }
    }

    private final class MemoryPeerStore: RemotePeerStore {
        var peers: [RemotePeer]
        init(peers: [RemotePeer]) { self.peers = peers }
        func load() -> [RemotePeer] { peers }
        func save(_ peers: [RemotePeer]) { self.peers = peers }
    }

    private final class MemoryDeviceStore: RemoteDeviceStore {
        var devices: [RemoteDevice]
        init(devices: [RemoteDevice]) { self.devices = devices }
        func load() -> [RemoteDevice] { devices }
        func save(_ devices: [RemoteDevice]) { self.devices = devices }
    }

    @MainActor
    private struct Fixture {
        let projects: ProjectsManager
        let host: AlasHost
        let server: HostProtocolServer
        let worktree: Worktree

        init() throws {
            let project = ProjectConfig(id: "p", name: "p", path: "/srv/repo", color: "blue", addedAt: .distantPast)
            projects = ProjectsManager(persistedProjects: [project])
            let path = URL(fileURLWithPath: "/srv/feature")
            worktree = Worktree(
                id: Worktree.makeId(path: path), projectId: "p", name: "feature", branch: "feature",
                path: path, status: .clean, lastActivity: .distantPast, lineageID: "listed"
            )
            projects.insertOptimisticWorktree(worktree)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            host = AlasHost(core: AlasCoreContext(
                projects: projects,
                runHistoryStore: nil,
                workspaceStore: WorkspaceStore(url: directory.appendingPathComponent("workspaces.json")),
                attentionStore: .scratch()
            ))
            server = HostProtocolServer(host: host)
        }
    }

    /// What a transport would write, in order. Can hold the first event batch
    /// to play a client that reads slowly.
    @MainActor
    private final class Client {
        var messages: [HostServerMessage] = []
        var holdsEvents = false
        private(set) var heldEvents: HostServerMessage?
        /// The response to this request id waits for `release()`, while
        /// later messages go through.
        var heldResponseID: Int?
        var isHolding: Bool { gate != nil }
        private var gate: CheckedContinuation<Void, Never>?

        func receive(_ message: HostServerMessage) async {
            if holdsEvents, case .events = message {
                holdsEvents = false
                heldEvents = message
                await withCheckedContinuation { gate = $0 }
            }
            if let held = heldResponseID, case .response(held, _) = message {
                heldResponseID = nil
                await withCheckedContinuation { gate = $0 }
            }
            messages.append(message)
        }

        func release() {
            gate?.resume()
            gate = nil
        }

        func waitFor(_ condition: @escaping @MainActor @Sendable ([HostServerMessage]) -> Bool) async throws {
            try await eventually { await condition(self.messages) }
        }
    }
}
