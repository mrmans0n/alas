import Foundation
import Testing
@_spi(Testing) @testable import AlasCore

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
    ])
    func refusedRequestsAnswerWithTheirError(_ message: HostClientMessage, _ error: HostError) async throws {
        let fixture = try Fixture()
        let client = Client()
        let connection = fixture.server.connect(caller: .localUser(uid: 501), send: client.receive)
        await connection.receive(message)
        #expect(client.messages == [.response(id: message.id, result: .failure(error: error))])
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
                workspaceStore: WorkspaceStore(url: directory.appendingPathComponent("workspaces.json"))
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
