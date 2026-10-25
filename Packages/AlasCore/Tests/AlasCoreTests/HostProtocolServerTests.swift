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

    /// Only a client that accepts `reviewStatus` hears it, intact over the
    /// wire, and once: reading the same status again publishes nothing.
    @Test func aReviewStatusReachesOnlyClientsThatAcceptIt() async throws {
        let fixture = try Fixture()
        let core = fixture.host.core
        let status = ShepherdFixtures.snapshot(ShepherdFixtures.request())
        let worktree = fixture.worktree
        core.reviewStatusRefresh = { _ in core.reviewLoop(for: worktree, baseBranch: "main").setSnapshotForTests(status) }
        let plain = Client()
        let accepting = Client()
        let plainConnection = fixture.server.connect(caller: .localUser(uid: 501), send: plain.receive)
        let acceptingConnection = fixture.server.connect(caller: .localUser(uid: 501), send: accepting.receive)
        defer {
            plainConnection.close()
            acceptingConnection.close()
        }
        let cursor = try await fixture.host.snapshot().cursor
        await plainConnection.receive(HostClientMessage(id: 1, request: .subscribe(after: cursor)))
        await acceptingConnection.receive(HostClientMessage(id: 1, request: .subscribeAccepting(after: cursor, events: ["reviewStatus"])))
        let ref = WorktreeRef(projectID: "p", path: worktree.path.path)

        await acceptingConnection.receive(HostClientMessage(id: 2, request: .reviewStatus(worktree: ref)))
        #expect(accepting.messages.contains(.response(id: 2, result: .reviewStatus(snapshot: status))))
        func events(_ messages: [HostServerMessage]) -> [HostEvent] {
            messages.flatMap { message -> [HostEvent] in
                guard case .events(let batch, _) = message else { return [] }
                return batch
            }
        }
        try await accepting.waitFor { !events($0).isEmpty }
        let batch = try #require(accepting.messages.first { !events([$0]).isEmpty })
        #expect(events([batch]) == [.reviewStatus(worktreeID: worktree.id, snapshot: status)])
        #expect(try JSONDecoder().decode(HostServerMessage.self, from: JSONEncoder().encode(batch)) == batch)

        await acceptingConnection.receive(HostClientMessage(id: 3, request: .reviewStatus(worktree: ref)))
        fixture.projects.setOperationState(for: worktree, state: .archiving(projectId: "p"))
        let archiving = HostEvent.worktreeChanged(WorktreeSnapshot(worktree: worktree, operation: .archiving, isArchived: false))
        try await accepting.waitFor { events($0).contains(archiving) }
        try await plain.waitFor { events($0).contains(archiving) }
        #expect(events(accepting.messages).filter { $0 != archiving }.count == 1)
        #expect(events(plain.messages) == [archiving])
    }

    /// Only a client that accepts `reviewsChanged` hears that a worktree's
    /// reviews changed.
    @Test func aReviewChangeReachesOnlyClientsThatAcceptIt() async throws {
        let fixture = try Fixture()
        let worktree = fixture.worktree
        let plain = Client()
        let accepting = Client()
        let plainConnection = fixture.server.connect(caller: .localUser(uid: 501), send: plain.receive)
        let acceptingConnection = fixture.server.connect(caller: .localUser(uid: 501), send: accepting.receive)
        defer {
            plainConnection.close()
            acceptingConnection.close()
        }
        let cursor = try await fixture.host.snapshot().cursor
        await plainConnection.receive(HostClientMessage(id: 1, request: .subscribe(after: cursor)))
        await acceptingConnection.receive(HostClientMessage(id: 1, request: .subscribeAccepting(after: cursor, events: ["reviewsChanged"])))
        func events(_ messages: [HostServerMessage]) -> [HostEvent] {
            messages.flatMap { message -> [HostEvent] in
                guard case .events(let batch, _) = message else { return [] }
                return batch
            }
        }

        _ = fixture.host.reviews.finish(origin: worktree, sessionID: nil, verdict: .approve, summary: "ok", projectWorktrees: [worktree])
        let changed = HostEvent.reviewsChanged(worktreeID: worktree.id)
        try await accepting.waitFor { events($0).contains(changed) }
        // A later event both clients get proves the plain one had its chance.
        fixture.projects.setOperationState(for: worktree, state: .archiving(projectId: "p"))
        try await plain.waitFor { events($0).contains { if case .worktreeChanged = $0 { true } else { false } } }
        #expect(!events(plain.messages).contains(changed))
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

    /// A range is read as a commit is, its replies named by the range. Refs
    /// must be SHAs, as stored review targets pin them, or a root's parent.
    @Test(arguments: [false, true])
    func rangeReadsAnswerAsCommitRepliesNamedByTheirRange(threeDot: Bool) async throws {
        let fixture = try await RepoFixture()
        defer { fixture.tearDown() }
        let (repo, ref) = try await fixture.mainWorktree()
        func headSHA() async throws -> String {
            try await Process.git(["rev-parse", "HEAD"], cwd: repo).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let base = try await headSHA()
        try "a\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        #expect(try await Process.git(["add", "a.txt"], cwd: repo).exitCode == 0)
        #expect(try await Process.git(["commit", "-q", "-m", "Add a"], cwd: repo).exitCode == 0)
        let head = try await headSHA()
        let id = try #require(fixture.core.projects.worktrees(projectId: fixture.projectID).first).id
        func read(_ read: HostWorktreeRead) async throws -> HostResponse {
            try await fixture.request(.readWorktree(worktree: ref, read: read))
        }

        for base in [base, "\(head)^"] {
            let spec = HostWorktreeRead.rangeSpec(base: base, head: head, threeDot: threeDot)
            guard case .worktreeRead(.commitFiles(id, spec, let files, false)) =
                try await read(.rangeFiles(base: base, head: head, threeDot: threeDot))
            else {
                Issue.record("expected the range's files")
                return
            }
            #expect(files.map(\.path) == ["a.txt"])
            guard case .worktreeRead(.commitDiffResult(id, spec, "a.txt", let hunks, false, _)) =
                try await read(.rangeDiff(base: base, head: head, threeDot: threeDot, path: "a.txt", originalPath: nil))
            else {
                Issue.record("expected the range's diff")
                return
            }
            #expect(!hunks.isEmpty)
        }
        if !threeDot {
            // A review from a root commit stores the empty tree as its base.
            let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
            guard case .worktreeRead(.commitFiles(id, _, let files, _)) =
                try await read(.rangeFiles(base: emptyTree, head: head, threeDot: false))
            else {
                Issue.record("expected the files from the empty tree")
                return
            }
            #expect(files.map(\.path).contains("a.txt"))
        }
        #expect(try await read(.rangeFiles(base: "main", head: head, threeDot: threeDot)) == .worktreeRead(reply: .commitFilesFailed(
            sessionId: id, sha: HostWorktreeRead.rangeSpec(base: "main", head: head, threeDot: threeDot),
            reason: .pathRejected, message: nil)))
        let tree = try await Process.git(["rev-parse", "HEAD^{tree}"], cwd: repo).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard case .worktreeRead(.commitDiffFailed(id, _, "a.txt", .gitFailed, _)) =
            try await read(.rangeDiff(base: base, head: tree, threeDot: threeDot, path: "a.txt", originalPath: nil))
        else {
            Issue.record("expected a tree refused as a range end")
            return
        }
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

    enum Refusal: CaseIterable {
        case branchChanged, checkedOutSinceListed, staleDiscard, nothingStaged, tooManyPaths, pendingCheckpoint, appHost, hidden,
            archivedWhileQueued
    }

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
        case .checkedOutSinceListed:
            // Nothing relists the worktree here: git alone knows it moved.
            #expect(try await Process.git(["checkout", "-q", "-b", "other"], cwd: repo).exitCode == 0)
            expected = .failed(message: "The worktree changed since it was listed.")
        case .tooManyPaths:
            change = .stage(paths: (0...10_000).map { "file\($0)" })
            expected = .invalidRequest(reason: "One request can name at most 10000 paths.")
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
        case .archivedWhileQueued:
            // Past the endpoint's check, then archived while waiting on the gate.
            let listed = try #require(fixture.core.projects.worktrees(projectId: fixture.projectID).first)
            fixture.core.projects.setWorktreeHidden(projectId: fixture.projectID, path: repo, hidden: true)
            await #expect(throws: HostError.notFound(what: "worktree \(ref.path) in project \(fixture.projectID)")) {
                try await fixture.host.worktrees.mutate(listed, branch: branch, change: change, caller: .app)
            }
            return
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

        #expect(try await fixture.request(.mutateWorktree(worktree: ref, branch: "main", change: .stage(paths: [path])))
            == .failure(error: .failed(message: "fatal: pathspec '\(path)' did not match any files")))
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
        try await GitTemplate.repository(at: real)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        let projectID = try await fixture.host.projects.add(path: alias, displayName: "alias", icon: .default(), caller: .app).id
        let worktree = try #require(fixture.core.projects.worktrees(projectId: projectID).first)
        #expect(try await Process.git(["rm", "-r", "-q", ".alas"], cwd: real).exitCode == 0)
        let ref = WorktreeRef(projectID: projectID, path: worktree.path.path)

        #expect(try await fixture.request(.mutateWorktree(worktree: ref, branch: "main", change: change)) == .done)
        #expect(try await Process.git(["status", "--porcelain"], cwd: real).stdout == porcelain)
    }

    /// The Mac learns why a pull stopped, and the host is left mid-rebase to
    /// resolve there: relisted, the worktree is detached, and a commit or push
    /// on it is refused until the rebase is finished.
    @Test func pullStoppedOnConflictsSaysToResolveOnTheHost() async throws {
        let fixture = try await RepoFixture()
        defer { fixture.tearDown() }
        let (repo, ref) = try await fixture.mainWorktree()
        let origin = fixture.root.appendingPathComponent("origin")
        try await GitTemplate.repository(at: origin)
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

        try await fixture.host.worktrees.refresh(projectID: fixture.projectID, caller: .app)
        let branch = try #require(fixture.core.projects.worktrees(projectId: fixture.projectID).first).branch
        #expect(branch == "(detached)")
        for change in [HostWorktreeChange.commit(subject: "Mid-rebase", body: "", amend: true), .push(forceWithLease: true)] {
            #expect(try await fixture.request(.mutateWorktree(worktree: ref, branch: branch, change: change)) == .failure(error: .failed(
                message: "A rebase, merge, cherry-pick or revert is in progress on the host; finish it there first."
            )))
        }
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

    /// Paired Macs of other versions decode this, so its shape must not drift.
    @Test func repoHookConsentKeepsItsWireShape() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        func json(_ consent: RepoHookConsent) throws -> String {
            try String(decoding: encoder.encode(consent), as: UTF8.self)
        }
        #expect(try json(.approve(hash: "h")) == #"{"approve":{"hash":"h"}}"#)
        #expect(try json(.ask) == #"{"ask":{}}"#)
    }

    /// A peer is never the person at this Mac: its creation must not reach the
    /// app's approval sheet, even when the host has one. A peer that can't
    /// ask its own user hears the hook was skipped, unless the project
    /// doesn't use the repository's hook at all.
    @Test(arguments: [(nil, .useGlobal, true), (.skip, .useGlobal, false), (nil, .disabled, false)]
        as [(RepoHookConsent?, ProjectStartupScriptMode, Bool)])
    func aPeerThatCantAskSkipsTheHookWithoutAskingTheHost(
        consent: RepoHookConsent?, mode: ProjectStartupScriptMode, notices: Bool
    ) async throws {
        let environment = AskingEnvironment()
        let fixture = try await RepoFixture(environment: environment)
        defer { fixture.tearDown() }
        _ = try await fixture.commitHook(.worktreeCreate, "touch hook-ran\n")
        var scripts = ProjectStartupScripts.defaults
        scripts.worktreeCreateMode = mode
        fixture.core.projects.updateProject(id: fixture.projectID, update: ProjectUpdate(name: "repo", icon: .default(), startupScripts: scripts))
        let subscription = fixture.host.subscribe()

        let result = await fixture.createForPeer(consent)

        guard case .success = result else {
            Issue.record("\(result)")
            return
        }
        let created = try #require(fixture.core.projects.worktrees(projectId: fixture.projectID).first { $0.branch == "feature" })
        #expect(environment.asks == 0)
        #expect(!FileManager.default.fileExists(atPath: created.path.appendingPathComponent("hook-ran").path))
        let worktreeNotices = await fixture.worktreeNotices(of: subscription)
        #expect(worktreeNotices.map { [$0.worktreeID, $0.title, $0.body] }
            == (notices ? [[created.id, "Setup hook not run", "It needs approval in Alas."]] : []))
    }

    @Test func aPeerThatMayAskIsSentTheHookAndNothingIsCreated() async throws {
        let fixture = try await RepoFixture(environment: AskingEnvironment())
        defer { fixture.tearDown() }
        let hash = try await fixture.commitHook(.worktreeCreate, "touch hook-ran\n")

        #expect(await fixture.createForPeer(.ask)
            == .needsRepoHookApproval(PeerRepoHook(event: .worktreeCreate, text: "touch hook-ran\n", hash: hash)))
        #expect(!fixture.core.projects.worktrees(projectId: fixture.projectID).contains { $0.branch == "feature" })
    }

    /// Only the script now on disk can be approved; a stale hash is asked again.
    @Test(arguments: [true, false])
    func approvingRunsTheHookOnlyForTheScriptOnDisk(hashMatches: Bool) async throws {
        let fixture = try await RepoFixture(environment: AskingEnvironment())
        defer { fixture.tearDown() }
        let hash = try await fixture.commitHook(.worktreeCreate, "touch hook-ran\n")

        let result = await fixture.createForPeer(.approve(hash: hashMatches ? hash : "stale"))

        #expect(fixture.core.projects.isRepoHookApproved(projectId: fixture.projectID, hash: hash) == hashMatches)
        if hashMatches {
            guard case .success = result else {
                Issue.record("\(result)")
                return
            }
            let created = try #require(fixture.core.projects.worktrees(projectId: fixture.projectID).first { $0.branch == "feature" })
            #expect(FileManager.default.fileExists(atPath: created.path.appendingPathComponent("hook-ran").path))
            #expect(try String(contentsOf: fixture.projectsFile, encoding: .utf8).contains(hash))
        } else {
            guard case .needsRepoHookApproval(let hook) = result else {
                Issue.record("\(result)")
                return
            }
            #expect(hook.hash == hash)
        }
    }

    /// A requested branch that only exists as a remote-tracking name is not
    /// what the worktree checks out: it is created from base, so the peer
    /// is shown base's hook.
    @Test func aRemoteTrackingBranchNameIsShownTheBasesHook() async throws {
        let fixture = try await RepoFixture(environment: AskingEnvironment())
        defer { fixture.tearDown() }
        let hash = try await fixture.commitHook(.worktreeCreate, "touch main-ran\n")
        let (repo, _) = try await fixture.mainWorktree()
        _ = try await fixture.commitHook(.worktreeCreate, "touch topic-ran\n")
        _ = try await Process.git(["update-ref", "refs/remotes/origin/topic", "HEAD"], cwd: repo)
        _ = try await Process.git(["reset", "-q", "--hard", "HEAD~1"], cwd: repo)

        #expect(await fixture.createForPeer(.ask, branch: "origin/topic")
            == .needsRepoHookApproval(PeerRepoHook(event: .worktreeCreate, text: "touch main-ran\n", hash: hash)))
    }

    /// With fetch-before-create, the hook is read after the base is fetched:
    /// the peer approves the script the checkout will get.
    @Test func aFetchedBaseIsShownItsFetchedHook() async throws {
        let environment = AskingEnvironment()
        environment.config.worktrees.fetchRemoteBeforeCreate = true
        let fixture = try await RepoFixture(environment: environment)
        defer { fixture.tearDown() }
        let (repo, _) = try await fixture.mainWorktree()
        let origin = fixture.root.appendingPathComponent("origin")
        try await GitTemplate.repository(at: origin)
        _ = try await Process.git(["remote", "add", "origin", origin.path], cwd: repo)
        _ = try await Process.git(["fetch", "-q", "origin", "main"], cwd: repo)
        let hook = origin.appendingPathComponent(RepoHookEvent.worktreeCreate.relativePath)
        try FileManager.default.createDirectory(at: hook.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("touch fetched-ran\n".utf8).write(to: hook)
        _ = try await Process.git(["add", "-A"], cwd: origin)
        _ = try await Process.git(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-q", "-m", "Add hook"], cwd: origin)

        #expect(await fixture.createForPeer(.ask, base: "origin/main") == .needsRepoHookApproval(PeerRepoHook(
            event: .worktreeCreate, text: "touch fetched-ran\n",
            hash: RepoHookTrust.hash(event: .worktreeCreate, bytes: Data("touch fetched-ran\n".utf8))
        )))
    }

    /// An approval covers the script the peer was shown: if the worktree's
    /// script differs by the time it would run, it does not run.
    @Test func anApprovedHookThatChangedBeforeItRunsIsNotRun() async throws {
        let environment = AskingEnvironment()
        environment.scriptOnDisk = "touch other-ran\n"
        let fixture = try await RepoFixture(environment: environment)
        defer { fixture.tearDown() }
        let hash = try await fixture.commitHook(.worktreeCreate, "touch hook-ran\n")

        let result = await fixture.createForPeer(.approve(hash: hash))

        guard case .success = result else {
            Issue.record("\(result)")
            return
        }
        let created = try #require(fixture.core.projects.worktrees(projectId: fixture.projectID).first { $0.branch == "feature" })
        #expect(environment.asks == 0)
        for file in ["hook-ran", "other-ran"] {
            #expect(!FileManager.default.fileExists(atPath: created.path.appendingPathComponent(file).path))
        }
    }

    @Test func reviewRequestsAreServedOnlyByAHeadlessHost() async throws {
        let fixture = try await RepoFixture(environment: RecordingRunEnvironment())
        defer { fixture.tearDown() }
        let (_, ref) = try await fixture.mainWorktree()

        #expect(try await fixture.request(.listReviews(worktree: ref))
            == .failure(error: .invalidRequest(reason: "This host does not serve reviews.")))
        #expect(try await fixture.request(.readProviderReview(worktree: ref, sessionID: "x", withDiff: false))
            == .failure(error: .invalidRequest(reason: "This host does not serve pull request reviews.")))
    }

    /// A Mac opens a worktree's pull request review, reusing the open one,
    /// and reads it from the provider as the host's user.
    @Test func aMacOpensAndReadsAPullRequestReview() async throws {
        let fixture = try await RepoFixture()
        defer { fixture.tearDown() }
        let (_, ref) = try await fixture.mainWorktree()
        let worktree = try #require(fixture.core.projects.worktrees(projectId: fixture.projectID).first)
        let provider = FakeReviewProvider(kind: .github)
        provider.threads = [ReviewThread(
            id: "t1", path: "a.txt", line: 1, startLine: nil, originalLine: nil, diffHunk: nil, isResolved: false,
            isOutdated: false, isFileLevel: false, comments: [], viewerCanResolve: true, viewerCanReply: true, url: nil
        )]
        provider.diff = "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-a\n+b\n"
        let sessionID = try await fixture.openPullRequestReview(provider)

        for _ in 0..<2 {
            guard case .review(let review) = try await fixture.request(.openProviderReview(worktree: ref, number: 7)) else {
                Issue.record("expected the review")
                return
            }
            #expect(review.summary.sessionID == sessionID)
            #expect(review.summary.record.target.kind == .reviewRequest)
        }
        #expect(try fixture.core.reviewSessions.list(worktreeID: worktree.id).count == 1)

        for withDiff in [true, false] {
            guard case .providerReview(let review) = try await fixture.request(
                .readProviderReview(worktree: ref, sessionID: sessionID, withDiff: withDiff)
            ) else {
                Issue.record("expected the provider review")
                return
            }
            #expect(review.request.number == 7)
            #expect(review.request.threads.map(\.id) == ["t1"])
            #expect(review.account == "octocat")
            #expect(review.diff == (withDiff ? provider.diff : nil))
            #expect(!review.diffTruncated)
        }

        fixture.host.reviews.openLocalChanges(in: worktree)
        let localChanges = ReviewDraftSessionID.localChanges(worktreeID: worktree.id, worktreePath: worktree.path, scope: .all)
        #expect(try await fixture.request(.readProviderReview(worktree: ref, sessionID: localChanges.rawValue, withDiff: false))
            == .failure(error: .invalidRequest(reason: "This review has no pull or merge request.")))
        provider.readError = CodeHostProviderError.unauthenticated("github.com")
        #expect(try await fixture.request(.readProviderReview(worktree: ref, sessionID: sessionID, withDiff: false))
            == .failure(error: .failed(message: "Authentication is required for github.com.")))
    }

    /// A Mac acts only on the threads of the review's own pull request, and
    /// the host tells subscribers the reviews changed.
    @Test func threadActionsActOnlyOnTheirPullRequestsThreads() async throws {
        let fixture = try await RepoFixture()
        defer { fixture.tearDown() }
        let (repo, ref) = try await fixture.mainWorktree()
        let worktree = try #require(fixture.core.projects.worktrees(projectId: fixture.projectID).first)
        let provider = FakeReviewProvider(kind: .github)
        provider.threads = [ReviewThread(
            id: "t1", path: "a.txt", line: 1, startLine: nil, originalLine: nil, diffHunk: nil, isResolved: false,
            isOutdated: false, isFileLevel: false, comments: [], viewerCanResolve: true, viewerCanReply: true, url: nil
        )]
        let sessionID = try await fixture.openPullRequestReview(provider)
        let subscription = fixture.host.subscribe()

        guard case .reviewThreadMutated = try await fixture.request(
            .mutateReviewThread(worktree: ref, sessionID: sessionID, threadID: "t1", kind: .resolve, body: nil)
        ) else {
            Issue.record("expected the mutated thread")
            return
        }
        #expect(provider.threadMutations.map { [$0.thread.providerThreadID, $0.kind.rawValue, $0.cwd.path] }
            == [["t1", "resolve", worktree.path.path]])
        #expect(await fixture.events(of: subscription).contains(.reviewsChanged(worktreeID: worktree.id)))

        #expect(try await fixture.request(.mutateReviewThread(
            worktree: ref, sessionID: sessionID, threadID: "t9", kind: .reply, body: "Hi"
        )) == .failure(error: .notFound(what: "review thread t9")))
        guard case .success(let commit) = await fixture.host.reviews.open("HEAD", in: worktree, caller: .app) else {
            Issue.record("expected the commit review")
            return
        }
        #expect(try await fixture.request(.mutateReviewThread(
            worktree: ref, sessionID: commit.record.target.draftSessionID.rawValue, threadID: "t1", kind: .resolve, body: nil
        )) == .failure(error: .invalidRequest(reason: "This review has no pull or merge request.")))
        let foreign = ReviewDraftSessionID.localChanges(worktreeID: "other", worktreePath: repo, scope: .all).rawValue
        #expect(try await fixture.request(.mutateReviewThread(
            worktree: ref, sessionID: foreign, threadID: "t1", kind: .resolve, body: nil
        )) == .failure(error: .notFound(what: "review \(foreign)")))
        #expect(provider.threadMutations.count == 1)
    }

    /// Comments on a renamed file of a pull or merge request keep the path it
    /// had before where the provider publishes against it, and a Mac files
    /// them on the review's own files.
    @Test(arguments: [CodeHostKind.github, .gitlab])
    func commentsOnAPullRequestReviewKeepTheirOriginalPath(_ kind: CodeHostKind) async throws {
        let fixture = try await RepoFixture()
        defer { fixture.tearDown() }
        let (repo, ref) = try await fixture.mainWorktree()
        let worktree = try #require(fixture.core.projects.worktrees(projectId: fixture.projectID).first)
        try "b\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let provider = FakeReviewProvider(kind: kind)
        provider.diff = "diff --git a/old.txt b/a.txt\nsimilarity index 50%\nrename from old.txt\nrename to a.txt\n"
            + "--- a/old.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-a\n+b\n"
        let rawSession = try await fixture.openPullRequestReview(provider)
        let session = try #require(ReviewDraftSessionID(rawValue: rawSession))

        _ = await fixture.host.reviews.addComment(
            origin: worktree, path: "a.txt", startLine: 1, endLine: nil, side: nil, body: "Why?",
            sessionID: rawSession, projectWorktrees: [worktree]
        )
        #expect(try fixture.core.reviewDrafts.load(sessionID: session).map(\.originalPath)
            == [kind == .gitlab ? "old.txt" : nil])

        let namespace = kind == .github ? "github-pr" : "gitlab-mr"
        func add(_ namespace: String) async throws -> HostResponse {
            try await fixture.request(.mutateReview(worktree: ref, sessionID: rawSession, mutation: .add(
                fileID: DiffReviewFileID(namespace: namespace, path: "a.txt"), path: "a.txt", originalPath: "old.txt",
                anchor: .line(side: .new, startLine: 1, endLine: nil, selectedText: nil), body: "From the Mac"
            )))
        }
        #expect(try await add(namespace) == .done)
        #expect(try await add("commit") == .failure(error: .invalidRequest(reason: "this review has no commit files")))
        let mac = try fixture.core.reviewDrafts.load(sessionID: session).filter { $0.bodyMarkdown == "From the Mac" }
        #expect(mac.map(\.fileID.namespace) == [namespace])
        #expect(mac.map(\.effectiveAuthor) == [.user])
    }

    /// Local changes are listed, never saved, once an agent comments on them;
    /// finishing them saves the one record the list then shows instead.
    @Test func theListSynthesizesLocalChangesOnceItHasComments() async throws {
        let fixture = try await RepoFixture()
        defer { fixture.tearDown() }
        let (repo, ref) = try await fixture.mainWorktree()
        let worktree = try #require(fixture.core.projects.worktrees(projectId: fixture.projectID).first)
        try "changed\n".write(to: repo.appendingPathComponent(".alas/scripts/hello.sh"), atomically: true, encoding: .utf8)
        func reviews() async throws -> [HostReviewSummary] {
            guard case .reviews(let reviews) = try await fixture.request(.listReviews(worktree: ref)) else {
                Issue.record("expected reviews")
                return []
            }
            return reviews
        }

        #expect(try await reviews() == [])
        _ = await fixture.host.reviews.addComment(
            origin: worktree, path: ".alas/scripts/hello.sh", startLine: 1, endLine: nil, side: nil, body: "Why?",
            sessionID: nil, projectWorktrees: [worktree]
        )
        let listed = try await reviews()
        #expect(listed.map(\.record.target.kind) == [.localChanges])
        #expect(listed.first?.openCommentCount == 1)
        #expect(listed.first?.sessionID
            == ReviewDraftSessionID.localChanges(worktreeID: worktree.id, worktreePath: worktree.path, scope: .all).rawValue)
        #expect(try fixture.core.reviewSessions.list(worktreeID: worktree.id) == [])

        _ = fixture.host.reviews.finish(origin: worktree, sessionID: nil, verdict: .approve, summary: "ok", projectWorktrees: [worktree])
        #expect(try await reviews().map(\.record.verdict?.verdict) == [.approve])
        guard case .success = await fixture.host.reviews.open("HEAD", in: worktree, caller: .app) else {
            Issue.record("expected the commit review opened")
            return
        }
        #expect(try await reviews().map(\.record.target.kind) == [.commit, .localChanges])
    }

    enum ReplyPath: CaseIterable {
        case reply, resolveWithReply, bareResolve
    }

    /// An agent's answer to a review comment notices the Mac with its
    /// review; resolving without a word does not.
    @Test(arguments: ReplyPath.allCases)
    func agentRepliesNoticeTheMacWithTheirReview(_ path: ReplyPath) async throws {
        let fixture = try await RepoFixture()
        defer { fixture.tearDown() }
        let (repo, _) = try await fixture.mainWorktree()
        let worktree = try #require(fixture.core.projects.worktrees(projectId: fixture.projectID).first)
        try "changed\n".write(to: repo.appendingPathComponent(".alas/scripts/hello.sh"), atomically: true, encoding: .utf8)
        _ = await fixture.host.reviews.addComment(
            origin: worktree, path: ".alas/scripts/hello.sh", startLine: 1, endLine: nil, side: nil, body: "Why?",
            sessionID: nil, projectWorktrees: [worktree]
        )
        let comment = try #require(try fixture.core.reviewDrafts.loadAll().first)
        let subscription = fixture.host.subscribe()

        switch path {
        case .reply:
            _ = fixture.host.reviews.reply(origin: worktree, commentID: comment.id, body: "Because.", projectWorktrees: [worktree])
        case .resolveWithReply:
            _ = fixture.host.reviews.resolve(
                origin: worktree, commentID: comment.id, reply: "Because.", reopen: false, projectWorktrees: [worktree]
            )
        case .bareResolve:
            _ = fixture.host.reviews.resolve(origin: worktree, commentID: comment.id, reply: nil, reopen: false, projectWorktrees: [worktree])
        }

        let notices = await fixture.worktreeNotices(of: subscription)
        #expect(notices.map { [$0.worktreeID, $0.title, $0.body, $0.reviewSessionID] } == (path == .bareResolve ? [] : [
            [worktree.id, "Agent replied to review feedback", "Because.", comment.sessionID.rawValue],
        ]))
    }

    /// Only opening a review that wasn't open notices the Mac.
    @Test func anAgentOpeningAReviewNoticesTheMac() async throws {
        let fixture = try await RepoFixture()
        defer { fixture.tearDown() }
        _ = try await fixture.mainWorktree()
        let worktree = try #require(fixture.core.projects.worktrees(projectId: fixture.projectID).first)
        let subscription = fixture.host.subscribe()

        var opened: OpenedReview?
        for _ in 0..<2 {
            guard case .success(let review) = await fixture.host.reviews.open("HEAD", in: worktree, caller: .app) else {
                Issue.record("expected the commit review opened")
                return
            }
            opened = review
            fixture.host.reviews.openLocalChanges(in: worktree)
        }

        let commit = try #require(opened)
        let localChanges = ReviewDraftSessionID.localChanges(worktreeID: worktree.id, worktreePath: worktree.path, scope: .all)
        let notices = await fixture.worktreeNotices(of: subscription)
        #expect(notices.map { [$0.worktreeID, $0.title, $0.body, $0.reviewSessionID] } == [
            [worktree.id, "Agent opened a review", commit.label, commit.record.target.draftSessionID.rawValue],
            [worktree.id, "Agent opened a review", "local changes", localChanges.rawValue],
        ])
    }

    /// A comment whose file no longer differs still belongs to its review.
    @Test func aReviewReadsEveryCommentOfItsSession() async throws {
        let fixture = try await RepoFixture()
        defer { fixture.tearDown() }
        let (repo, ref) = try await fixture.mainWorktree()
        let worktree = try #require(fixture.core.projects.worktrees(projectId: fixture.projectID).first)
        try "changed\n".write(to: repo.appendingPathComponent(".alas/scripts/hello.sh"), atomically: true, encoding: .utf8)
        _ = await fixture.host.reviews.addComment(
            origin: worktree, path: ".alas/scripts/hello.sh", startLine: 1, endLine: nil, side: nil, body: "Why?",
            sessionID: nil, projectWorktrees: [worktree]
        )
        #expect(try await Process.git(["checkout", "--", ".alas/scripts/hello.sh"], cwd: repo).exitCode == 0)
        let sessionID = ReviewDraftSessionID.localChanges(worktreeID: worktree.id, worktreePath: worktree.path, scope: .all).rawValue

        guard case .review(let review) = try await fixture.request(.readReview(worktree: ref, sessionID: sessionID)) else {
            Issue.record("expected the review")
            return
        }
        #expect(review.comments.map(\.bodyMarkdown) == ["Why?"])
        #expect(review.summary.openCommentCount == 1)
        let foreign = ReviewDraftSessionID.localChanges(worktreeID: "other", worktreePath: repo, scope: .all).rawValue
        for unknown in ["nope", foreign] {
            #expect(try await fixture.request(.readReview(worktree: ref, sessionID: unknown))
                == .failure(error: .notFound(what: "review \(unknown)")))
        }
    }

    /// A Mac may start the local-changes review before it is listed: it
    /// reads with no comments, and reading saves nothing.
    @Test func theUnlistedLocalChangesReviewReadsEmpty() async throws {
        let fixture = try await RepoFixture()
        defer { fixture.tearDown() }
        let (_, ref) = try await fixture.mainWorktree()
        let worktree = try #require(fixture.core.projects.worktrees(projectId: fixture.projectID).first)
        let sessionID = ReviewDraftSessionID.localChanges(worktreeID: worktree.id, worktreePath: worktree.path, scope: .all).rawValue

        guard case .review(let review) = try await fixture.request(.readReview(worktree: ref, sessionID: sessionID)) else {
            Issue.record("expected the review")
            return
        }
        #expect(review.summary.sessionID == sessionID)
        #expect(review.comments.isEmpty)
        #expect(try fixture.core.reviewSessions.list(worktreeID: worktree.id).isEmpty)
        #expect(try fixture.host.reviews.list(in: worktree).isEmpty)
    }

    /// With a path both staged and unstaged, an agent's comment goes to the
    /// unstaged side; a Mac's stays on the side it was filed on, and only on
    /// a side its review has: not a commit's, nor a stage the file lacks.
    @Test(arguments: [
        (false, "staged", true, true), (false, "unstaged", true, true), (false, "commit", true, false),
        (true, "unstaged", true, false), (false, "staged", false, false),
    ])
    func aMacCommentKeepsTheStageItWasFiledOn(commitReview: Bool, namespace: String, alsoStaged: Bool, accepted: Bool) async throws {
        let fixture = try await RepoFixture()
        defer { fixture.tearDown() }
        let (repo, ref) = try await fixture.mainWorktree()
        let worktree = try #require(fixture.core.projects.worktrees(projectId: fixture.projectID).first)
        let file = repo.appendingPathComponent("a.txt")
        if alsoStaged {
            try "one\n".write(to: file, atomically: true, encoding: .utf8)
            _ = try await Process.git(["add", "a.txt"], cwd: repo)
        }
        try "two\n".write(to: file, atomically: true, encoding: .utf8)
        var session = ReviewDraftSessionID.localChanges(worktreeID: worktree.id, worktreePath: worktree.path, scope: .all)
        if commitReview {
            guard case .success(let opened) = await fixture.host.reviews.open("HEAD", in: worktree, caller: .app) else {
                Issue.record("expected the commit review opened")
                return
            }
            session = opened.record.target.draftSessionID
        }

        let response = try await fixture.request(.mutateReview(worktree: ref, sessionID: session.rawValue, mutation: .add(
            fileID: DiffReviewFileID(namespace: namespace, path: "a.txt"), path: "a.txt", originalPath: nil,
            anchor: .line(side: .new, startLine: 1, endLine: nil, selectedText: nil), body: "Why?"
        )))

        let stored = try fixture.core.reviewDrafts.load(sessionID: session)
        if accepted {
            #expect(response == .done)
            #expect(stored.map(\.fileID) == [DiffReviewFileID(namespace: namespace, path: "a.txt")])
            #expect(stored.map(\.effectiveAuthor) == [.user])
        } else {
            guard case .failure(.invalidRequest) = response else {
                Issue.record("expected a refusal, got \(response)")
                return
            }
            #expect(stored.isEmpty)
        }
    }

    /// A Mac names the review it acts in; a comment of another review, or of
    /// another worktree's, is not found, and only line and file comments of
    /// bounded size are filed.
    @Test func macMutationsStayInsideTheirReview() async throws {
        let fixture = try await RepoFixture()
        defer { fixture.tearDown() }
        let (repo, ref) = try await fixture.mainWorktree()
        let worktree = try #require(fixture.core.projects.worktrees(projectId: fixture.projectID).first)
        try "changed\n".write(to: repo.appendingPathComponent(".alas/scripts/hello.sh"), atomically: true, encoding: .utf8)
        let local = ReviewDraftSessionID.localChanges(worktreeID: worktree.id, worktreePath: worktree.path, scope: .all)
        func add(_ anchor: ReviewDraftCommentAnchor, body: String = "Why?") async throws -> HostResponse {
            try await fixture.request(.mutateReview(worktree: ref, sessionID: local.rawValue, mutation: .add(
                fileID: DiffReviewFileID(namespace: "unstaged", path: ".alas/scripts/hello.sh"),
                path: ".alas/scripts/hello.sh", originalPath: nil, anchor: anchor, body: body
            )))
        }
        #expect(try await add(.file) == .done)
        let comment = try #require(try fixture.core.reviewDrafts.load(sessionID: local).first)
        guard case .success(let opened) = await fixture.host.reviews.open("HEAD", in: worktree, caller: .app) else {
            Issue.record("expected the commit review opened")
            return
        }
        let foreign = ReviewDraftSessionID.localChanges(worktreeID: "other", worktreePath: repo, scope: .all)
        var theirs = comment
        theirs.id = "theirs"
        theirs.sessionID = foreign
        try fixture.core.reviewDrafts.save(theirs)

        for (sessionID, commentID, missing) in [
            (opened.record.target.draftSessionID.rawValue, comment.id, "review comment \(comment.id)"),
            (local.rawValue, "nope", "review comment nope"),
            (local.rawValue, "theirs", "review comment theirs"),
            (foreign.rawValue, "theirs", "review \(foreign.rawValue)"),
        ] {
            #expect(try await fixture.request(.mutateReview(
                worktree: ref, sessionID: sessionID, mutation: .edit(commentID: commentID, body: "Edited")
            )) == .failure(error: .notFound(what: missing)))
        }
        #expect(try await add(.image(side: .new, normalizedX: 0, normalizedY: 0))
            == .failure(error: .invalidRequest(reason: "Only file and line comments can be added from a paired Mac.")))
        guard case .failure(.invalidRequest) = try await add(.file, body: String(repeating: "x", count: 1 << 20)) else {
            Issue.record("expected an oversized comment refused")
            return
        }
        #expect(try fixture.core.reviewDrafts.load(sessionID: local).map(\.bodyMarkdown) == ["Why?"])
        #expect(try fixture.core.reviewDrafts.find(commentID: "theirs")?.bodyMarkdown == "Why?")
    }

    @Test func macMutationsActAsTheUser() async throws {
        let fixture = try await RepoFixture()
        defer { fixture.tearDown() }
        let (repo, ref) = try await fixture.mainWorktree()
        let worktree = try #require(fixture.core.projects.worktrees(projectId: fixture.projectID).first)
        try "changed\n".write(to: repo.appendingPathComponent(".alas/scripts/hello.sh"), atomically: true, encoding: .utf8)
        let session = ReviewDraftSessionID.localChanges(worktreeID: worktree.id, worktreePath: worktree.path, scope: .all)
        func mutate(_ mutation: HostReviewMutation) async throws -> HostResponse {
            try await fixture.request(.mutateReview(worktree: ref, sessionID: session.rawValue, mutation: mutation))
        }
        for line in [1, 2] {
            #expect(try await mutate(.add(
                fileID: DiffReviewFileID(namespace: "unstaged", path: ".alas/scripts/hello.sh"),
                path: ".alas/scripts/hello.sh", originalPath: nil,
                anchor: .line(side: .new, startLine: line, endLine: nil, selectedText: nil), body: "Line \(line)"
            )) == .done)
        }
        let ids = try fixture.core.reviewDrafts.load(sessionID: session).sorted { $0.startLine < $1.startLine }.map(\.id)
        func comment(_ id: String) throws -> ReviewDraftComment? { try fixture.core.reviewDrafts.find(commentID: id) }

        #expect(try await mutate(.edit(commentID: ids[0], body: "Edited")) == .done)
        #expect(try comment(ids[0])?.bodyMarkdown == "Edited")
        #expect(try await mutate(.resolve(commentID: ids[0])) == .done)
        #expect(try comment(ids[0])?.state == .resolved)
        #expect(try comment(ids[0])?.resolvedBy == .user)
        guard case .failure(.invalidRequest) = try await mutate(.edit(commentID: ids[0], body: "Again")) else {
            Issue.record("expected editing a resolved comment refused")
            return
        }
        #expect(try await mutate(.dismiss(commentID: ids[1])) == .done)
        #expect(try comment(ids[1])?.state == .dismissed)
        #expect(try await mutate(.delete(commentID: ids[1])) == .done)
        guard case .review(let review) = try await fixture.request(.readReview(worktree: ref, sessionID: session.rawValue)) else {
            Issue.record("expected the review")
            return
        }
        #expect(review.comments.map(\.id) == [ids[0]])
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
            try await GitTemplate.repository(at: repo)
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
                orchestrationPersistence: ACPOrchestrationPersistence(path: root.appendingPathComponent("orchestration.sqlite").path),
                reviewDrafts: ReviewDraftCommentStore(url: root.appendingPathComponent("review-drafts.json")),
                reviewSessions: ReviewSessionStore(url: root.appendingPathComponent("review-sessions.json"))
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

        /// Commits `.alas/hooks/<event>.sh` to the main checkout; returns its trust hash.
        func commitHook(_ event: RepoHookEvent, _ script: String) async throws -> String {
            let (repo, _) = try await mainWorktree()
            let file = repo.appendingPathComponent(event.relativePath)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(script.utf8).write(to: file)
            _ = try await Process.git(["add", event.relativePath], cwd: repo)
            _ = try await Process.git(["commit", "-q", "-m", "Add hook"], cwd: repo)
            return RepoHookTrust.hash(event: event, bytes: Data(script.utf8))
        }

        /// Creates `feature` from `main` for a paired Mac, inside the fixture
        /// rather than under the real home, with a stub session.
        func createForPeer(
            _ consent: RepoHookConsent?, base: String = "main", branch: String = "feature"
        ) async -> RemoteCreateWorktreeSessionResult {
            core.worktreeDestinationPreparer = { [root] _, destination in
                root.appendingPathComponent(destination.lastPathComponent)
            }
            host.remoteSessionCreator = { _ in .success(RemoteSessionSummary(id: "s", title: "", agentId: "a", status: "idle", canDrive: true)) }
            return await host.remoteCreateWorktreeSession(
                RemoteWorktreeSessionCreation(projectID: projectID, base: base, branch: branch, agentID: "a", repoHook: consent),
                caller: .remotePeer(deviceID: "d"))
        }

        /// The events `subscription` has received so far.
        func events(of subscription: HostSubscription) async -> [HostEvent] {
            let marker = HostEvent.worktreeNotice(HostWorktreeNotice(id: UUID(), worktreeID: "", title: nil, body: ""))
            host.noteAttention([marker])
            var events: [HostEvent] = []
            while let batch = await subscription.next() {
                events += batch
                if events.contains(marker) { break }
            }
            return events.filter { $0 != marker }
        }

        /// The worktree notices `subscription` has received so far.
        func worktreeNotices(of subscription: HostSubscription) async -> [HostWorktreeNotice] {
            await events(of: subscription).compactMap { if case .worktreeNotice(let notice) = $0 { notice } else { nil } }
        }

        /// Adds an `origin` of `provider`'s kind, installs `provider` for it,
        /// and opens PR/MR 7 as an agent would; returns the session id.
        func openPullRequestReview(_ provider: FakeReviewProvider) async throws -> String {
            let (repo, _) = try await mainWorktree()
            let host = provider.kind == .github ? "github.com" : "gitlab.com"
            _ = try await Process.git(["remote", "add", "origin", "https://\(host)/acme/app.git"], cwd: repo)
            core.codeHostProviders = CodeHostProviderRegistry(providers: [provider.kind: provider])
            let worktree = try #require(core.projects.worktrees(projectId: projectID).first)
            switch await self.host.reviews.open("7", in: worktree, caller: .app) {
            case .success(let opened): return opened.record.target.draftSessionID.rawValue
            case .failure(let failure): throw HostError.failed(message: failure.message)
            }
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
                environment: environment ?? HeadlessHostEnvironment(),
                reviewDrafts: ReviewDraftCommentStore(url: directory.appendingPathComponent("review-drafts.json")),
                reviewSessions: ReviewSessionStore(url: directory.appendingPathComponent("review-sessions.json"))
            ))
            server = HostProtocolServer(host: host)
        }
    }

    /// A code host serving PR/MR `number` with `threads` and `diff`, as
    /// `login`. Used from the main actor only.
    final class FakeReviewProvider: CodeHostProvider, @unchecked Sendable {
        let kind: CodeHostKind
        var headSHA = "bbb"
        var threads: [ReviewThread] = []
        var diff = ""
        var login: String? = "octocat"
        /// Thrown by `reviewRequest`.
        var readError: (any Error)?
        var threadMutations: [ProviderThreadMutation] = []

        init(kind: CodeHostKind) { self.kind = kind }

        var capabilities: CodeHostProviderCapabilities { .githubCLI }
        func reviewRequest(remote: CodeHostRemote, number: Int, cwd: URL) async throws -> ReviewRequest {
            if let readError { throw readError }
            return ReviewRequest(
                remote: remote, number: number, title: "Fix", url: remote.reviewRequestURL(number: number), state: .open,
                isDraft: false, headRefName: "feature", baseRefName: "main", headSHA: headSHA, reviewDecision: .unknown,
                mergeState: .unknown, checks: [], threads: threads
            )
        }
        func reviewDiff(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> String { diff }
        func mutateReviewThread(_ mutation: ProviderThreadMutation) async throws -> ProviderThreadMutationResult {
            threadMutations.append(mutation)
            return ProviderThreadMutationResult(refreshedRequest: mutation.reviewRequest, providerURL: nil)
        }
        func viewerLogin(remote: CodeHostRemote, cwd: URL) async -> String? { login }
        func isAvailable(cwd: URL) async -> Bool { true }
        func isAuthenticated(remote: CodeHostRemote, cwd: URL) async -> Bool { true }
        func currentReviewRequest(
            remote: CodeHostRemote, branch: String, headOwner: String?, baseBranch: String, cwd: URL
        ) async throws -> ReviewRequest? {
            nil
        }
        func createReviewRequest(
            remote: CodeHostRemote, branch: String, headOwner: String?, baseBranch: String,
            title: String, body: String, isDraft: Bool, cwd: URL
        ) async throws -> URL {
            throw CodeHostProviderError.unsupportedProvider(kind)
        }
        func checks(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> [ReviewCheck] { [] }
        func rerunFailedChecks(
            remote: CodeHostRemote, branch: String, headSHA: String, request: ReviewRequest?, cwd: URL
        ) async throws {}
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

/// A host with an approval sheet that approves whatever it is asked.
@MainActor private final class AskingEnvironment: AlasHostEnvironment {
    var asks = 0
    /// What a new worktree's hook reads as, when not its committed script.
    var scriptOnDisk: String?
    var config = AppConfig.defaults
    func configuration() -> AppConfig { config }
    var repoHookLoader: RepoHookLoader {
        guard let scriptOnDisk else { return RepoHookLoader() }
        return RepoHookLoader { _, _, _ in .data(Data(scriptOnDisk.utf8)) }
    }
    var repoHookPrompter: RepoHookPrompter {
        RepoHookPrompter(
            decide: { [self] _, _, _ in
                asks += 1
                return .approve
            },
            decideFailure: { [self] _, _ in
                asks += 1
                return .skip
            }
        )
    }
    func admitsAgent(_ agentID: String, remoteHost: String?) -> Bool { true }
}
