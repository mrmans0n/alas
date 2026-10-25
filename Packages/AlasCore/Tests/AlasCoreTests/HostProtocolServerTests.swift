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
            return [Self.devScript()]
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

    /// Archiving stopped everything in a worktree; a run does not start or
    /// restart there again, including one archived while its scripts were found.
    @Test(arguments: [false, true], [false, true])
    func runsDoNotStartInArchivedWorktrees(archivedDuringDiscovery: Bool, restart: Bool) async throws {
        let fixture = try Fixture()
        let projects = fixture.projects
        let worktree = fixture.worktree
        if !archivedDuringDiscovery {
            projects.setWorktreeHidden(projectId: "p", path: worktree.path, hidden: true)
        }
        let server = HostProtocolServer(host: fixture.host) { _, _ in
            await MainActor.run { projects.setWorktreeHidden(projectId: "p", path: worktree.path, hidden: true) }
            return [Self.devScript()]
        }
        let client = Client()
        let connection = server.connect(caller: .localUser(uid: 501), send: client.receive)
        let ref = WorktreeRef(projectID: "p", path: fixture.worktree.path.path)
        await connection.receive(HostClientMessage(
            id: 1, request: restart ? .restartRun(scriptKey: "repo:dev.sh", worktree: ref) : .startRun(scriptKey: "repo:dev.sh", worktree: ref)
        ))
        #expect(client.messages == [.response(id: 1, result: .runStart(start: .refused(
            title: "Worktree archived", message: "Unarchive the worktree to run scripts in it."
        )))])
    }

    /// The listing is the server's discovery with each script's run location;
    /// an archived worktree is refused as an unknown one is.
    @Test func runScriptsAreListedForListedWorktreesOnly() async throws {
        let fixture = try Fixture()
        let server = HostProtocolServer(host: fixture.host) { _, _ in [Self.devScript(cwd: "web")] }
        let client = Client()
        let connection = server.connect(caller: .remotePeer(deviceID: "d"), send: client.receive)
        let ref = WorktreeRef(projectID: "p", path: fixture.worktree.path.path)
        await connection.receive(HostClientMessage(id: 1, request: .listRunScripts(worktree: ref)))
        fixture.projects.setWorktreeHidden(projectId: "p", path: fixture.worktree.path, hidden: true)
        await connection.receive(HostClientMessage(id: 2, request: .listRunScripts(worktree: ref)))
        #expect(client.messages == [
            .response(id: 1, result: .runScripts(scripts: [HostRunScript(
                scope: .repo, fileName: "dev.sh", name: "Dev", cwd: "web",
                target: RunExecutionTarget(host: nil, workingDirectory: "/srv/feature/web")
            )])),
            .response(id: 2, result: .failure(error: .notFound(what: "worktree /srv/feature in project p"))),
        ])
    }

    /// A run asked for over the host protocol is shown as the script says, or
    /// for a restart as its open console is. It becomes the active tab only to
    /// replace the active console, so the host's screen stays where it was.
    /// Only a local caller is asked about an unapproved repository hook.
    @Test(arguments: [
        (restart: false, console: RunScriptConsole.hidden, openConsoleIsHidden: Bool?.some(false), active: false, hidden: true, activates: false),
        (restart: false, console: .shown, openConsoleIsHidden: nil, active: false, hidden: false, activates: false),
        (restart: true, console: .shown, openConsoleIsHidden: true, active: false, hidden: true, activates: false),
        (restart: true, console: .hidden, openConsoleIsHidden: nil, active: false, hidden: true, activates: false),
        (restart: true, console: .shown, openConsoleIsHidden: false, active: true, hidden: false, activates: true),
    ], [HostCaller.remotePeer(deviceID: "d"), .localUser(uid: 501)])
    func hostProtocolRunsFollowTheConsoleSettingAndActivateOnlyInPlaceOfTheActiveConsole(
        _ run: (restart: Bool, console: RunScriptConsole, openConsoleIsHidden: Bool?, active: Bool, hidden: Bool, activates: Bool),
        caller: HostCaller
    ) async throws {
        let (restart, console, openConsoleIsHidden, active, hidden, activates) = run
        let environment = RecordingRunEnvironment()
        environment.openConsoleIsHidden = openConsoleIsHidden
        environment.launcher.hostsActiveConsole = active
        let fixture = try Fixture(environment: environment)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("alas-run-\(UUID().uuidString).sh")
        try "#!/bin/sh\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let server = HostProtocolServer(host: fixture.host) { _, _ in [Self.devScript(console: console, fileURL: file)] }
        let connection = server.connect(caller: caller, send: Client().receive)
        let ref = WorktreeRef(projectID: "p", path: fixture.worktree.path.path)
        await connection.receive(HostClientMessage(id: 1, request: restart
            ? .restartRun(scriptKey: "repo:dev.sh", worktree: ref) : .startRun(scriptKey: "repo:dev.sh", worktree: ref)))
        await fixture.host.core.waitForStartingRunsForTesting()
        #expect(environment.launcher.requests.map(\.isHidden) == [hidden])
        #expect(environment.launcher.requests.map(\.activatesConsole) == [activates])
        #expect(environment.launcher.requests.map(\.promptsForRepoHooks) == [caller == .localUser(uid: 501)])
    }

    nonisolated static func devScript(
        cwd: String? = nil, console: RunScriptConsole = .shown, fileURL: URL = URL(fileURLWithPath: "/srv/feature/dev.sh")
    ) -> RunScript {
        RunScript(
            scope: .repo, fileName: "dev.sh", fileURL: fileURL,
            displayName: "Dev", onExit: .close, cwd: cwd, isExecutable: true, console: console
        )
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

    /// A worktree is read as a session in it would be, keyed by the worktree.
    @Test func worktreeReadsAnswerWithTheSessionReplyKeyedByTheWorktree() async throws {
        let fixture = try await RepoFixture()
        defer { fixture.tearDown() }
        let worktree = try #require(fixture.core.projects.worktrees(projectId: fixture.projectID).first)
        try "hi\n".write(to: worktree.path.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let ref = WorktreeRef(projectID: fixture.projectID, path: worktree.path.path)

        #expect(try await fixture.request(.readWorktree(worktree: ref, read: .file(path: "notes.txt")))
            == .worktreeRead(reply: .fileContents(sessionId: worktree.id, path: "notes.txt", text: "hi\n", truncated: false)))
        guard case .worktreeRead(.fileTree(worktree.id, nil, let nodes, _)) =
            try await fixture.request(.readWorktree(worktree: ref, read: .files(path: nil, comparisonMode: nil)))
        else {
            Issue.record("expected a file tree")
            return
        }
        #expect(nodes.contains { $0.path == "notes.txt" })
        guard case .worktreeRead(.fileUnavailable(worktree.id, "../outside", .pathRejected, _, _)) =
            try await fixture.request(.readWorktree(worktree: ref, read: .file(path: "../outside")))
        else {
            Issue.record("expected the escape refused")
            return
        }
        #expect(try await fixture.request(.readWorktree(worktree: WorktreeRef(projectID: fixture.projectID, path: "/srv/missing"), read: .file(path: "a")))
            == .failure(error: .notFound(what: "worktree /srv/missing in project \(fixture.projectID)")))
        // An archived worktree is not listed, so it is not read either.
        fixture.core.projects.setWorktreeHidden(projectId: fixture.projectID, path: worktree.path, hidden: true)
        #expect(try await fixture.request(.readWorktree(worktree: ref, read: .file(path: "notes.txt")))
            == .failure(error: .notFound(what: "worktree \(ref.path) in project \(fixture.projectID)")))
    }

    /// A linked worktree's branch is renamed and listed under its new name;
    /// the main checkout's is refused, as the local menu never offers it, and
    /// so is a rename of a branch the worktree is no longer listed on.
    @Test func renameBranchRenamesALinkedWorktreeOnly() async throws {
        let fixture = try await RepoFixture()
        defer { fixture.tearDown() }
        let main = try #require(fixture.core.projects.worktrees(projectId: fixture.projectID).first)
        let linked = fixture.root.appendingPathComponent("feature")
        #expect(try await Process.git(["worktree", "add", "-q", "-b", "feature", linked.path], cwd: main.path).exitCode == 0)
        try await fixture.host.worktrees.refresh(projectID: fixture.projectID, caller: .app)
        let linkedRef = WorktreeRef(projectID: fixture.projectID, path: linked.path)

        #expect(try await fixture.request(.renameBranch(worktree: linkedRef, from: "feature", to: "renamed")) == .done)
        #expect(fixture.core.projects.worktrees(projectId: fixture.projectID)
            .first { $0.path.standardizedFileURL.path == linked.standardizedFileURL.path }?.branch == "renamed")
        #expect(try await fixture.request(.renameBranch(worktree: linkedRef, from: "feature", to: "again"))
            == .failure(error: .failed(message: "The worktree changed since it was listed.")))
        #expect(try await fixture.request(.renameBranch(
            worktree: WorktreeRef(projectID: fixture.projectID, path: main.path.path), from: main.branch, to: "nope"
        )) == .failure(error: .failed(message: "This worktree's branch cannot be renamed.")))
    }

    /// A staged rename is unstaged and discarded as both paths, as locally.
    @Test(arguments: [
        (HostWorktreeChange.unstage(paths: ["renamed.sh"]), " D .alas/scripts/hello.sh\n?? renamed.sh\n"),
        (HostWorktreeChange.discard(paths: ["renamed.sh"]), ""),
    ])
    func renamesAreUnstagedAndDiscardedAsBothPaths(change: HostWorktreeChange, porcelain: String) async throws {
        let fixture = try await RepoFixture()
        defer { fixture.tearDown() }
        let (repo, ref) = try await fixture.mainWorktree()
        #expect(try await Process.git(["mv", ".alas/scripts/hello.sh", "renamed.sh"], cwd: repo).exitCode == 0)

        #expect(try await fixture.request(.mutateWorktree(worktree: ref, branch: "main", change: change)) == .done)
        #expect(try await Process.git(["status", "--porcelain"], cwd: repo).stdout == porcelain)
    }

    @Test func commitThenAmendRewordsTheNewCommit() async throws {
        let fixture = try await RepoFixture()
        defer { fixture.tearDown() }
        let (repo, ref) = try await fixture.mainWorktree()
        try "new\n".write(to: repo.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        func mutate(_ change: HostWorktreeChange) async throws -> HostResponse {
            try await fixture.request(.mutateWorktree(worktree: ref, branch: "main", change: change))
        }
        func head(_ format: String) async throws -> String {
            try await Process.git(["log", "-1", "--format=\(format)"], cwd: repo).stdout
        }

        #expect(try await mutate(.stage(paths: ["new.txt"])) == .done)
        #expect(try await mutate(.commit(subject: "Add new", body: "", amend: false)) == .done)
        #expect(try await head("%s") == "Add new\n")
        #expect(try await mutate(.commit(subject: "Reword", body: "Why", amend: true)) == .done)
        #expect(try await head("%s") == "Reword\n")
        #expect(try await head("%b") == "Why\n\n")
        #expect(try await Process.git(["rev-list", "--count", "HEAD"], cwd: repo).stdout == "2\n")
    }

    enum Refusal: CaseIterable { case branchChanged, staleDiscard, nothingStaged, pendingCheckpoint, appHost, hidden }

    @Test(arguments: Refusal.allCases)
    func gitActionsAreRefused(_ refusal: Refusal) async throws {
        let environment: RecordingRunEnvironment? = switch refusal {
        case .pendingCheckpoint: RecordingRunEnvironment(servesWorktreeGit: true, blocksForCheckpoint: true)
        case .appHost: RecordingRunEnvironment()
        default: nil
        }
        let fixture = try await RepoFixture(environment: environment)
        defer { fixture.tearDown() }
        let (repo, ref) = try await fixture.mainWorktree()
        var branch = "main"
        var change = HostWorktreeChange.stage(paths: ["x"])
        let expected: HostError
        switch refusal {
        case .branchChanged:
            branch = "other"
            expected = .failed(message: "The worktree changed since it was listed.")
        case .staleDiscard:
            change = .discard(paths: ["missing.txt"])
            expected = .failed(message: "These changes are no longer in the worktree.")
        case .nothingStaged:
            change = .commit(subject: "Empty", body: "", amend: false)
            expected = .failed(message: "Nothing is staged to commit.")
        case .pendingCheckpoint:
            expected = .failed(message: "A checkpoint restore is pending on the host; finish it there first.")
        case .appHost:
            expected = .invalidRequest(reason: "This host does not serve git actions.")
            guard case .capabilities(let capabilities) = try await fixture.request(.capabilities) else {
                Issue.record("expected capabilities")
                return
            }
            #expect(!capabilities.contains(HostProtocolCapability.worktreesGitV1))
        case .hidden:
            fixture.core.projects.setWorktreeHidden(projectId: fixture.projectID, path: repo, hidden: true)
            expected = .notFound(what: "worktree \(ref.path) in project \(fixture.projectID)")
        }

        #expect(try await fixture.request(.mutateWorktree(worktree: ref, branch: branch, change: change)) == .failure(error: expected))
    }

    /// Paths come from the client: the host acts only inside the worktree,
    /// never through `..`, an absolute path, or a symlink out of it, and
    /// never on an empty path or one git would cut at a NUL.
    @Test(arguments: [
        ("../outside/inside.txt", "The path ../outside/inside.txt is outside the worktree."),
        ("/etc/hosts", "The path /etc/hosts is outside the worktree."),
        ("link/inside.txt", "The path link/inside.txt is outside the worktree."),
        ("", "A path is empty or holds a NUL character."),
        ("inside\0.txt", "A path is empty or holds a NUL character."),
    ])
    func gitActionsRefusePathsOutsideTheWorktree(_ path: String, reason: String) async throws {
        let fixture = try await RepoFixture()
        defer { fixture.tearDown() }
        let (repo, ref) = try await fixture.mainWorktree()
        let outside = fixture.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "keep\n".write(to: outside.appendingPathComponent("inside.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: repo.appendingPathComponent("link"), withDestinationURL: outside)

        #expect(try await fixture.request(.mutateWorktree(worktree: ref, branch: "main", change: .discard(paths: [path])))
            == .failure(error: .invalidRequest(reason: reason)))
        #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("inside.txt").path))
    }

    /// A client path is one path: a glob or pathspec magic matches nothing else.
    @Test(arguments: ["*.txt", ":(glob)*.txt"])
    func gitActionsTakePathsLiterally(_ path: String) async throws {
        let fixture = try await RepoFixture()
        defer { fixture.tearDown() }
        let (repo, ref) = try await fixture.mainWorktree()
        try "new\n".write(to: repo.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)

        #expect(try await fixture.request(.mutateWorktree(worktree: ref, branch: "main", change: .stage(paths: [path]))) != .done)
        #expect(try await Process.git(["diff", "--cached", "--name-only"], cwd: repo).stdout == "")
    }

    /// A file in a folder that is gone is still inside a worktree reached
    /// through a symlinked path.
    @Test(arguments: [
        (HostWorktreeChange.unstage(paths: [".alas/scripts/hello.sh"]), " D .alas/scripts/hello.sh\n"),
        (HostWorktreeChange.discard(paths: [".alas/scripts/hello.sh"]), ""),
    ])
    func deletedFoldersOfASymlinkedWorktreeAreInside(change: HostWorktreeChange, porcelain: String) async throws {
        let fixture = try await RepoFixture()
        defer { fixture.tearDown() }
        let real = fixture.root.appendingPathComponent("real")
        let alias = fixture.root.appendingPathComponent("alias")
        try GitTemplate.repository(at: real)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        let projectID = try await fixture.host.projects.add(path: alias, displayName: "alias", icon: .default(), caller: .app).id
        let worktree = try #require(fixture.core.projects.worktrees(projectId: projectID).first)
        #expect(try await Process.git(["rm", "-r", "-q", ".alas"], cwd: real).exitCode == 0)
        let ref = WorktreeRef(projectID: projectID, path: worktree.path.path)

        #expect(try await fixture.request(.mutateWorktree(worktree: ref, branch: "main", change: change)) == .done)
        #expect(try await Process.git(["status", "--porcelain"], cwd: real).stdout == porcelain)
    }

    /// The Mac learns why a pull stopped, and the host is left mid-rebase to resolve there.
    @Test func pullStoppedOnConflictsSaysToResolveOnTheHost() async throws {
        let fixture = try await RepoFixture()
        defer { fixture.tearDown() }
        let (repo, ref) = try await fixture.mainWorktree()
        let origin = fixture.root.appendingPathComponent("origin")
        try GitTemplate.repository(at: origin)
        for (directory, contents) in [(origin, "theirs\n"), (repo, "ours\n")] {
            try contents.write(to: directory.appendingPathComponent(".alas/scripts/hello.sh"), atomically: true, encoding: .utf8)
            let commit = ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-q", "-am", contents]
            #expect(try await Process.git(commit, cwd: directory).exitCode == 0)
        }
        for arguments in [["remote", "add", "origin", origin.path], ["fetch", "-q", "origin"], ["branch", "-q", "--set-upstream-to=origin/main"]] {
            #expect(try await Process.git(arguments, cwd: repo).exitCode == 0)
        }

        #expect(try await fixture.request(.mutateWorktree(worktree: ref, branch: "main", change: .pull))
            == .failure(error: .failed(message: "Pull stopped on conflicts; resolve them on the host.")))
        #expect(FileManager.default.fileExists(atPath: repo.appendingPathComponent(".git/rebase-merge").path))
    }

    /// A branch with no upstream is pushed as the review pill pushes it,
    /// setting the upstream it then tracks.
    @Test func pushPublishesTheBranchAndTracksIt() async throws {
        let fixture = try await RepoFixture()
        defer { fixture.tearDown() }
        let (repo, ref) = try await fixture.mainWorktree()
        let origin = fixture.root.appendingPathComponent("origin.git")
        #expect(try await Process.git(["init", "-q", "--bare", origin.path]).exitCode == 0)
        #expect(try await Process.git(["remote", "add", "origin", origin.path], cwd: repo).exitCode == 0)

        #expect(try await fixture.request(.mutateWorktree(worktree: ref, branch: "main", change: .push(forceWithLease: false))) == .done)
        #expect(try await Process.git(["rev-parse", "main"], cwd: origin).stdout
            == Process.git(["rev-parse", "HEAD"], cwd: repo).stdout)
        #expect(try await Process.git(["rev-parse", "--abbrev-ref", "@{u}"], cwd: repo).stdout == "origin/main\n")
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

        init(environment: (any AlasHostEnvironment)? = nil) async throws {
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
                environment: environment ?? HeadlessHostEnvironment(),
                orchestrationPersistence: ACPOrchestrationPersistence(path: root.appendingPathComponent("orchestration.sqlite").path)
            )
            host = AlasHost(core: core)
            connection = HostProtocolServer(host: host).connect(caller: .localUser(uid: 501), send: client.receive)
            projectID = try await host.projects.add(path: repo, displayName: "repo", icon: .default(), caller: .app).id
        }

        /// The project's main checkout, on `main`, with a committer set.
        func mainWorktree() async throws -> (URL, WorktreeRef) {
            let worktree = try #require(core.projects.worktrees(projectId: projectID).first)
            for (key, value) in [("user.name", "Test"), ("user.email", "test@example.com")] {
                _ = try await Process.git(["config", key, value], cwd: worktree.path)
            }
            return (worktree.path, WorktreeRef(projectID: projectID, path: worktree.path.path))
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

        init(environment: (any AlasHostEnvironment)? = nil) throws {
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
                attentionStore: .scratch(),
                environment: environment ?? HeadlessHostEnvironment()
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

@MainActor private final class RecordingRunEnvironment: AlasHostEnvironment {
    final class Launcher: RunLauncher {
        var requests: [RunLaunchRequest] = []
        var hostsActiveConsole = false
        func hostsRun(scriptKey: String, worktreeID: String) -> Bool { hostsActiveConsole }
        func runHostIsActive(scriptKey: String, worktreeID: String) -> Bool { hostsActiveConsole }
        func endRunHost(scriptKey: String, worktreeID: String) { hostsActiveConsole = false }
        func launch(_ request: RunLaunchRequest, in core: AlasCoreContext) async throws -> RunLaunch {
            requests.append(request)
            return .unobservable
        }
    }

    let launcher = Launcher()
    var openConsoleIsHidden: Bool?
    var servesWorktreeGit = false
    var blocksForCheckpoint = false
    var runLauncher: any RunLauncher { launcher }
    init(servesWorktreeGit: Bool = false, blocksForCheckpoint: Bool = false) {
        self.servesWorktreeGit = servesWorktreeGit
        self.blocksForCheckpoint = blocksForCheckpoint
    }
    func runConsoleIsHidden(scriptKey: String, worktreeID: String) -> Bool? { openConsoleIsHidden }
    func checkpointRecoveryBlocksRemoval(_ worktree: Worktree) async -> Bool { blocksForCheckpoint }
}
