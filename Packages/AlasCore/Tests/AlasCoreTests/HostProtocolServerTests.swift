import Foundation
import Testing
@_spi(Testing) @testable import AlasCore
@_spi(Testing) @_spi(AppHost) @testable import AlasHostCore

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
        let notes = worktree.path.appendingPathComponent("notes.txt")
        try "hi\n".write(to: notes, atomically: true, encoding: .utf8)
        let ref = WorktreeRef(projectID: fixture.projectID, path: worktree.path.path)

        guard case .worktreeRead(.fileContents(worktree.id, "notes.txt", "hi\n", false, let version?)) =
            try await fixture.request(.readWorktree(worktree: ref, read: .file(path: "notes.txt")))
        else {
            Issue.record("expected the file's contents with its version")
            return
        }
        #expect(version.contentHash == WorktreeFileVersion.contentHash(of: Data("hi\n".utf8)))
        let modified = try FileManager.default.attributesOfItem(atPath: notes.path)[.modificationDate] as? Date
        #expect(version.modified == modified)
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

    /// A preview reads a file's raw bytes, from the working tree or a stored
    /// side, under the text read's path rules and refused over the cap.
    @Test func aMacReadsAWorktreeFilesBytes() async throws {
        let fixture = try await RepoFixture()
        defer { fixture.tearDown() }
        let (repo, ref) = try await fixture.mainWorktree()
        let worktree = try #require(fixture.core.projects.worktrees(projectId: fixture.projectID).first)
        let id = worktree.id
        func git(_ arguments: String...) async throws -> String {
            let result = try await Process.git(arguments, cwd: repo)
            #expect(result.exitCode == 0, "\(arguments): \(result.stderr)")
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func read(_ path: String, at revision: HostFileRevision? = nil) async throws -> RemoteServerMessage? {
            guard case .worktreeRead(let reply) = try await fixture.request(
                .readWorktree(worktree: ref, read: .fileBytes(path: path, revision: revision)))
            else { return nil }
            return reply
        }
        func bytes(_ data: Data, _ path: String = "icon.png") -> RemoteServerMessage {
            .fileBytes(sessionId: id, path: path, data: data, byteSize: data.count)
        }
        func refused(_ path: String, _ reason: RemoteFileAccessReason) -> RemoteServerMessage {
            .fileUnavailable(sessionId: id, path: path, reason: reason, byteSize: nil, message: nil)
        }
        let before = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF, 0x01])
        let committed = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF, 0x02, 0x0A])
        let working = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFE])
        let icon = repo.appendingPathComponent("icon.png")
        try before.write(to: icon)
        _ = try await git("add", "icon.png")
        _ = try await git("commit", "-q", "-m", "Add icon")
        try committed.write(to: icon)
        _ = try await git("commit", "-q", "-am", "Change icon")
        let sha = try await git("rev-parse", "HEAD")
        try working.write(to: icon)
        try Data([1]).write(to: repo.appendingPathComponent("new.bin"))

        #expect(try await read("icon.png") == bytes(working))
        #expect(try await read("icon.png", at: .index) == bytes(committed))
        #expect(try await read("icon.png", at: .head) == bytes(committed))
        #expect(try await read("icon.png", at: .base(comparisonMode: nil)) == bytes(committed))
        #expect(try await read("icon.png", at: .commit(sha: sha)) == bytes(committed))
        #expect(try await read("icon.png", at: .parent(sha: sha)) == bytes(before))
        #expect(try await read("new.bin", at: .base(comparisonMode: nil)) == refused("new.bin", .notFound))

        // Over the cap, refused with its size before it is read.
        for revision in [nil, HostFileRevision.commit(sha: sha)] {
            #expect(await fixture.core.remoteFileBytes(in: .found(worktree), path: "icon.png", revision: revision, maxBytes: 4)
                == .failure(reason: .tooLarge, byteSize: revision == nil ? working.count : committed.count, message: nil))
        }

        // The text read's path rules.
        try FileManager.default.createSymbolicLink(at: repo.appendingPathComponent("link.png"), withDestinationURL: icon)
        try Data("*.log\n".utf8).write(to: repo.appendingPathComponent(".gitignore"))
        try Data([1]).write(to: repo.appendingPathComponent("debug.log"))
        #expect(try await read("link.png") == refused("link.png", .notFound))
        #expect(try await read("debug.log") == refused("debug.log", .pathRejected))
        #expect(try await read(".git/config") == refused(".git/config", .pathRejected))
        #expect(try await read(".git/config", at: .index) == refused(".git/config", .pathRejected))

        // Only verified commit SHAs name a revision.
        let tree = try await git("rev-parse", "HEAD^{tree}")
        for name in ["HEAD~1", tree, String(repeating: "0", count: 40)] {
            #expect(try await read("icon.png", at: .commit(sha: name)) == refused("icon.png", .pathRejected))
        }
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
        case branchChanged, checkedOutSinceListed, staleDiscard, staleConflict, conflictedDirectory, nothingStaged, tooManyPaths,
            pendingCheckpoint, appHost, hidden, archivedWhileQueued
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
        let (repo, ref) = refusal == .conflictedDirectory ? try await fixture.stopPullOnConflicts() : try await fixture.mainWorktree()
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
        case .staleConflict:
            // Not unmerged: taking a side would overwrite the host's edit.
            try "edited\n".write(to: repo.appendingPathComponent(".alas/scripts/hello.sh"), atomically: true, encoding: .utf8)
            change = .useTheirs(path: ".alas/scripts/hello.sh")
            expected = .failed(message: "The conflict on .alas/scripts/hello.sh changed; refresh and try again.")
        case .conflictedDirectory:
            // A folder holding a conflict is not one: its merged files keep their edits.
            let other = repo.appendingPathComponent(".alas/scripts/other.sh")
            try "staged\n".write(to: other, atomically: true, encoding: .utf8)
            #expect(try await Process.git(["add", ".alas/scripts/other.sh"], cwd: repo).exitCode == 0)
            try "edited\n".write(to: other, atomically: true, encoding: .utf8)
            change = .useTheirs(path: ".alas/scripts")
            expected = .failed(message: "The conflict on .alas/scripts changed; refresh and try again.")
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
            #expect(try await fixture.request(.listStashes(worktree: ref))
                == .failure(error: .invalidRequest(reason: "This host does not serve this git action.")))
            #expect(try await fixture.request(.followFile(worktree: ref, path: "notes.txt"))
                == .failure(error: .invalidRequest(reason: "This host does not serve file editing.")))
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
        if refusal == .staleConflict {
            #expect(try String(contentsOf: repo.appendingPathComponent(".alas/scripts/hello.sh"), encoding: .utf8) == "edited\n")
        }
        if refusal == .conflictedDirectory {
            #expect(try String(contentsOf: repo.appendingPathComponent(".alas/scripts/other.sh"), encoding: .utf8) == "edited\n")
        }
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

    /// The Mac learns why a pull stopped, and the host is left mid-rebase:
    /// relisted, the worktree is detached, and a commit or push on it is
    /// refused until the rebase is finished. Aborted, it is listed on its
    /// branch again, so the Mac's next change passes.
    @Test func pullStoppedOnConflictsLeavesTheRebaseInPlace() async throws {
        let fixture = try await RepoFixture()
        defer { fixture.tearDown() }
        let (repo, ref) = try await fixture.stopPullOnConflicts()
        #expect(FileManager.default.fileExists(atPath: repo.appendingPathComponent(".git/rebase-merge").path))

        try await fixture.host.worktrees.refresh(projectID: fixture.projectID, caller: .app)
        let branch = try #require(fixture.core.projects.worktrees(projectId: fixture.projectID).first).branch
        #expect(branch == "(detached)")
        for change in [HostWorktreeChange.commit(subject: "Mid-rebase", body: "", amend: true), .push(forceWithLease: true)] {
            #expect(try await fixture.request(.mutateWorktree(worktree: ref, branch: branch, change: change)) == .failure(error: .failed(
                message: "A rebase, merge, cherry-pick or revert is in progress; finish or abort it first."
            )))
        }

        #expect(try await fixture.request(.mutateWorktree(worktree: ref, branch: branch, change: .abortOperation(kind: .rebase))) == .done)
        #expect(fixture.core.projects.worktrees(projectId: fixture.projectID).first?.branch == "main")
        try "new\n".write(to: repo.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        #expect(try await fixture.request(.mutateWorktree(worktree: ref, branch: "main", change: .stage(paths: ["new.txt"]))) == .done)
    }

    /// Mid-rebase the worktree is still listed on its branch while git is
    /// detached: the Mac resolves and continues, or aborts, from there.
    @Test(arguments: [true, false])
    func aRebaseStoppedOnConflictsIsLeftFromTheMac(continues: Bool) async throws {
        let fixture = try await RepoFixture()
        defer { fixture.tearDown() }
        let (repo, ref) = try await fixture.stopPullOnConflicts()
        let ours = try await Process.git(["rev-parse", "ORIG_HEAD"], cwd: repo).stdout
        func mutate(_ change: HostWorktreeChange) async throws -> HostResponse {
            try await fixture.request(.mutateWorktree(worktree: ref, branch: "main", change: change))
        }

        if continues {
            #expect(try await mutate(.useTheirs(path: ".alas/scripts/hello.sh")) == .done)
            #expect(try await mutate(.continueOperation(kind: .rebase)) == .done)
            #expect(try await Process.git(["rev-parse", "--abbrev-ref", "HEAD"], cwd: repo).stdout == "main\n")
            // A rebase's "theirs" is the commit being replayed.
            #expect(try String(contentsOf: repo.appendingPathComponent(".alas/scripts/hello.sh"), encoding: .utf8) == "ours\n")
        } else {
            #expect(try await mutate(.abortOperation(kind: .rebase)) == .done)
            #expect(try await Process.git(["rev-parse", "HEAD"], cwd: repo).stdout == ours)
        }
        #expect(!FileManager.default.fileExists(atPath: repo.appendingPathComponent(".git/rebase-merge").path))
        guard case .worktreeRead(.changeList(_, _, _, _, _, _, _, _, _, _, let operation)) =
            try await fixture.request(.readWorktree(worktree: ref, read: .changes(comparisonMode: nil)))
        else {
            Issue.record("expected the changes")
            return
        }
        #expect(operation == nil)
    }

    /// As locally, a conflicting cherry-pick stays in place: the Mac sees it
    /// in the changes and can leave it.
    @Test func aConflictingCherryPickLeavesAnOperationTheMacCanSeeAndLeave() async throws {
        let fixture = try await RepoFixture()
        defer { fixture.tearDown() }
        let (repo, ref) = try await fixture.mainWorktree()
        let script = repo.appendingPathComponent(".alas/scripts/hello.sh")
        for (branch, contents) in [("other", "theirs\n"), ("main", "ours\n")] {
            let checkout = branch == "other" ? ["checkout", "-q", "-b", "other"] : ["checkout", "-q", "main"]
            #expect(try await Process.git(checkout, cwd: repo).exitCode == 0)
            try contents.write(to: script, atomically: true, encoding: .utf8)
            let commit = ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-q", "-am", contents]
            #expect(try await Process.git(commit, cwd: repo).exitCode == 0)
        }
        func sha(_ ref: String) async throws -> String {
            try await Process.git(["rev-parse", ref], cwd: repo).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let (theirs, head) = try (await sha("other"), await sha("HEAD"))
        func mutate(_ change: HostWorktreeChange) async throws -> HostResponse {
            try await fixture.request(.mutateWorktree(worktree: ref, branch: "main", change: change))
        }
        func changes() async throws -> (MergeOperation?, [RemoteChangedFile]) {
            guard case .worktreeRead(.changeList(_, _, _, let files, let staged, let unstaged, _, _, _, _, let operation)) =
                try await fixture.request(.readWorktree(worktree: ref, read: .changes(comparisonMode: nil)))
            else { throw HostError.failed(message: "expected the changes") }
            return (operation, files + staged + unstaged)
        }

        #expect(try await mutate(.cherryPick(sha: theirs)) == .done)
        let (operation, files) = try await changes()
        #expect(operation == .cherryPick(sha: theirs, summary: "theirs"))
        #expect(files.contains { $0.conflict != nil })

        #expect(try await mutate(.abortOperation(kind: .cherryPick)) == .done)
        #expect(try await changes().0 == nil)
        #expect(try await sha("HEAD") == head)
        #expect(try await Process.git(["status", "--porcelain"], cwd: repo).stdout == "")
    }

    /// A Mac merges or rebases onto another listed branch only, never over
    /// changes git would lose or into an operation already in progress.
    @Test func aMacMergesAndRebasesAListedWorktree() async throws {
        let fixture = try await RepoFixture()
        defer { fixture.tearDown() }
        let (repo, ref) = try await fixture.mainWorktree()
        let script = repo.appendingPathComponent(".alas/scripts/hello.sh")
        func git(_ arguments: String...) async throws {
            #expect(try await Process.git(arguments, cwd: repo).exitCode == 0)
        }
        func commit(_ contents: String) async throws {
            try contents.write(to: script, atomically: true, encoding: .utf8)
            try await git("commit", "-q", "-am", contents)
        }
        func sha(_ ref: String) async throws -> String {
            try await Process.git(["rev-parse", ref], cwd: repo).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func mutate(_ change: HostWorktreeChange, on branch: String = "feature") async throws -> HostResponse {
            try await fixture.request(.mutateWorktree(worktree: ref, branch: branch, change: change))
        }
        try await git("branch", "-q", "feature")
        try await commit("main\n")
        let main = try await sha("main")
        try await git("checkout", "-q", "feature")
        try await fixture.host.worktrees.refresh(projectID: fixture.projectID, caller: .app)

        #expect(try await mutate(.merge(branch: "feature"))
            == .failure(error: .failed(message: "A worktree can't merge or rebase onto its own branch.")))
        for (change, name) in [(HostWorktreeChange.rebase(onto: "--abort"), "--abort"), (.merge(branch: "nope"), "nope")] {
            #expect(try await mutate(change) == .failure(error: .failed(message: "\(name) isn't a branch of this repository.")))
        }

        try "dirty\n".write(to: script, atomically: true, encoding: .utf8)
        let head = try await sha("HEAD")
        guard case .failure(.failed(let message)) = try await mutate(.merge(branch: "main")) else {
            Issue.record("a merge over a dirty file must be refused")
            return
        }
        #expect(!message.isEmpty)
        #expect(try await sha("HEAD") == head)

        try await git("checkout", "-q", "--", ".alas/scripts/hello.sh")
        try await commit("feature\n")
        #expect(try await mutate(.rebase(onto: "main")) == .done)
        guard case .rebase? = try await GitService().mergeState(worktreePath: repo) else {
            Issue.record("expected a rebase in progress")
            return
        }
        // Mid-rebase the host lists the worktree detached.
        try await fixture.host.worktrees.refresh(projectID: fixture.projectID, caller: .app)
        #expect(try await mutate(.merge(branch: "main"), on: "(detached)") == .failure(error: .failed(
            message: "A rebase, merge, cherry-pick or revert is in progress; finish or abort it first."
        )))

        #expect(try await mutate(.abortOperation(kind: .rebase), on: "(detached)") == .done)
        try await git("reset", "-q", "--hard", "HEAD~1")
        #expect(try await mutate(.merge(branch: "main")) == .done)
        #expect(try await Process.git(["merge-base", "--is-ancestor", main, "HEAD"], cwd: repo).exitCode == 0)
    }

    /// Only an object ID crosses to git, and only one of this repository's commits.
    @Test(arguments: [
        ("HEAD", HostError.invalidRequest(reason: "A commit is named by its SHA.")),
        ("--abort", .invalidRequest(reason: "A commit is named by its SHA.")),
        (String(repeating: "a", count: 40), .notFound(what: "commit \(String(repeating: "a", count: 40))")),
    ])
    func cherryPickAndRevertTakeOnlyThisRepositorysCommits(_ sha: String, _ error: HostError) async throws {
        let fixture = try await RepoFixture()
        defer { fixture.tearDown() }
        let (repo, ref) = try await fixture.mainWorktree()
        let head = try await Process.git(["rev-parse", "HEAD"], cwd: repo).stdout

        for change in [HostWorktreeChange.cherryPick(sha: sha), .revert(sha: sha)] {
            #expect(try await fixture.request(.mutateWorktree(worktree: ref, branch: "main", change: change)) == .failure(error: error))
        }
        #expect(try await Process.git(["rev-parse", "HEAD"], cwd: repo).stdout == head)
        #expect(try await GitService().mergeState(worktreePath: repo) == nil)
    }

    enum DuringRebase: CaseIterable { case stage, commit, wrongKind, outsidePath }

    /// Only a way out of the rebase passes for the branch git left: anything
    /// else is refused as before, and the rebase stays.
    @Test(arguments: DuringRebase.allCases)
    func onlyTheWayOutPassesTheGateDuringARebase(_ change: DuringRebase) async throws {
        let fixture = try await RepoFixture()
        defer { fixture.tearDown() }
        let (repo, ref) = try await fixture.stopPullOnConflicts()
        let (sent, expected): (HostWorktreeChange, HostError) = switch change {
        case .stage: (.stage(paths: ["x"]), .failed(message: "The worktree changed since it was listed."))
        case .commit: (.commit(subject: "x", body: "", amend: true), .failed(message: "The worktree changed since it was listed."))
        case .wrongKind: (.continueOperation(kind: .cherryPick), .failed(message: "The operation on the host changed; refresh and try again."))
        case .outsidePath: (.useOurs(path: "../x"), .invalidRequest(reason: "The path ../x is outside the worktree."))
        }

        #expect(try await fixture.request(.mutateWorktree(worktree: ref, branch: "main", change: sent)) == .failure(error: expected))
        #expect(FileManager.default.fileExists(atPath: repo.appendingPathComponent(".git/rebase-merge").path))
    }

    /// A Mac saves against the version it read: its bytes land as sent, with
    /// the file's mode, and a new file or folder only where nothing is.
    @Test func aMacSavesAHostFileAgainstTheVersionItRead() async throws {
        let fixture = try await RepoFixture()
        defer { fixture.tearDown() }
        let (repo, ref) = try await fixture.mainWorktree()
        let scripts = repo.appendingPathComponent(".alas/scripts")
        let hello = scripts.appendingPathComponent("hello.sh")
        try Data("old\r\n".utf8).write(to: hello)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hello.path)
        let path = ".alas/scripts/hello.sh"
        func write(_ path: String, _ text: String, expected: WorktreeFileVersion?) async throws -> HostResponse {
            try await fixture.request(.writeFile(worktree: ref, path: path, text: text, expected: expected))
        }
        func mode(_ url: URL) throws -> Int? { try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int }

        guard case .fileWritten(let written) = try await write(path, "new\r\n", expected: try await fixture.fileVersion(path, in: ref)) else {
            Issue.record("expected the save to land")
            return
        }
        #expect(written.contentHash == WorktreeFileVersion.contentHash(of: Data("new\r\n".utf8)))
        #expect(try Data(contentsOf: hello) == Data("new\r\n".utf8))
        #expect(try mode(hello) == 0o755)
        #expect(try FileManager.default.contentsOfDirectory(atPath: scripts.path).allSatisfy { !$0.hasPrefix(".hello.sh.alas-") })
        guard case .fileWritten = try await write(path, "newer\n", expected: written) else {
            Issue.record("expected a save against the version written to land")
            return
        }

        let created = repo.appendingPathComponent("new.txt")
        guard case .fileWritten = try await write("new.txt", "", expected: nil) else {
            Issue.record("expected the file created")
            return
        }
        #expect(try Data(contentsOf: created).isEmpty)
        #expect(try mode(created) == 0o644)
        guard case .failure(.fileChanged(let existing?)) = try await write("new.txt", "", expected: nil) else {
            Issue.record("expected a second create refused")
            return
        }
        #expect(existing.contentHash == WorktreeFileVersion.contentHash(of: Data()))
        // A file that appears after the probe is not replaced by a create either.
        await #expect(throws: POSIXError(.EEXIST)) {
            let (folder, name) = try AlasCoreContext.writableFolder("new.txt", in: repo)
            return try await RemoteWorktreeFileAccess.replaceAtomically(name, in: folder, with: Data("x".utf8), creating: true)
        }
        #expect(try Data(contentsOf: created).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: repo.path).allSatisfy { !$0.hasPrefix(".new.txt.alas-") })

        #expect(try await fixture.request(.createFolder(worktree: ref, path: "docs")) == .done)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: repo.appendingPathComponent("docs").path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(try await fixture.request(.createFolder(worktree: ref, path: "docs"))
            == .failure(error: .failed(message: "docs already exists on the host.")))
        #expect(try await fixture.request(.createFolder(worktree: ref, path: "new.txt"))
            == .failure(error: .failed(message: "new.txt already exists on the host.")))
        #expect(try await write("gone/x.txt", "", expected: nil)
            == .failure(error: .failed(message: "The folder holding gone/x.txt is no longer on the host.")))
    }

    enum OutsideChange: CaseIterable { case edited, deleted, touched }

    /// The bytes decide a conflict: a save over a file edited or deleted since
    /// it was read is refused and leaves it be; one only touched lands.
    @Test(arguments: OutsideChange.allCases)
    func aSaveIsCheckedAgainstTheFilesContentNotItsTimestamp(_ change: OutsideChange) async throws {
        let fixture = try await RepoFixture()
        defer { fixture.tearDown() }
        let (repo, ref) = try await fixture.mainWorktree()
        let notes = repo.appendingPathComponent("notes.txt")
        try Data("a\n".utf8).write(to: notes)
        let read = try await fixture.fileVersion("notes.txt", in: ref)
        switch change {
        case .edited: try Data("theirs\n".utf8).write(to: notes)
        case .deleted: try FileManager.default.removeItem(at: notes)
        case .touched:
            try FileManager.default.setAttributes([.modificationDate: read.modified.addingTimeInterval(60)], ofItemAtPath: notes.path)
        }

        let response = try await fixture.request(.writeFile(worktree: ref, path: "notes.txt", text: "mine\n", expected: read))
        let onDisk = (try? Data(contentsOf: notes)).map { String(decoding: $0, as: UTF8.self) }
        switch change {
        case .edited:
            guard case .failure(.fileChanged(let current?)) = response else {
                Issue.record("expected the save refused, got \(response)")
                return
            }
            #expect(current.contentHash == WorktreeFileVersion.contentHash(of: Data("theirs\n".utf8)))
            #expect(onDisk == "theirs\n")
        case .deleted:
            #expect(response == .failure(error: .fileChanged(current: nil)))
            #expect(onDisk == nil)
        case .touched:
            guard case .fileWritten = response else {
                Issue.record("expected the save to land, got \(response)")
                return
            }
            #expect(onDisk == "mine\n")
        }
    }

    enum UnwritablePath: CaseIterable {
        case parentDirectory, absolute, nul, dotGit, dotGitCase, symlinkFinal, symlinkParentOutside, symlinkParentInside, directory, ignored,
            colonPrefixed, nestedWorktree, parentSwappedAfterTheCheck
    }

    /// Paths come from the client: a save lands only on a regular file inside
    /// the worktree, reached through no symlink, never in `.git` or on a file
    /// git ignores, and touches nothing it refuses.
    @Test(arguments: UnwritablePath.allCases)
    func fileWritesStayOnRegularFilesInsideTheWorktree(_ shape: UnwritablePath) async throws {
        let fixture = try await RepoFixture()
        defer { fixture.tearDown() }
        let (repo, ref) = try await fixture.mainWorktree()
        let outside = fixture.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let inside = outside.appendingPathComponent("inside.txt")
        try Data("keep\n".utf8).write(to: inside)
        let config = repo.appendingPathComponent(".git/config")
        let hello = repo.appendingPathComponent(".alas/scripts/hello.sh")
        let (configBytes, helloBytes) = (try Data(contentsOf: config), try Data(contentsOf: hello))
        let path: String
        switch shape {
        case .parentDirectory: path = "../outside/inside.txt"
        case .absolute: path = inside.path
        case .nul: path = "notes\0.txt"
        case .dotGit: path = ".git/config"
        case .dotGitCase: path = ".GIT/config"
        case .symlinkFinal:
            path = "alias.txt"
            try FileManager.default.createSymbolicLink(at: repo.appendingPathComponent(path), withDestinationURL: inside)
        case .symlinkParentOutside:
            path = "out/inside.txt"
            try FileManager.default.createSymbolicLink(at: repo.appendingPathComponent("out"), withDestinationURL: outside)
        case .symlinkParentInside:
            path = "scripts/hello.sh"
            try FileManager.default.createSymbolicLink(
                at: repo.appendingPathComponent("scripts"), withDestinationURL: repo.appendingPathComponent(".alas/scripts")
            )
        case .directory: path = ".alas"
        case .ignored:
            path = "debug.log"
            try Data("*.log\n".utf8).write(to: repo.appendingPathComponent(".gitignore"))
            try Data("a\n".utf8).write(to: repo.appendingPathComponent(path))
        case .colonPrefixed:
            // Pathspec magic would check `x.env` at the top instead.
            path = ":/x.env"
            try FileManager.default.createDirectory(at: repo.appendingPathComponent(":"), withIntermediateDirectories: true)
            try Data(":/\n".utf8).write(to: repo.appendingPathComponent(".gitignore"))
            try Data("a\n".utf8).write(to: repo.appendingPathComponent(path))
        case .nestedWorktree:
            // Its own gate guards it, not this one's.
            path = "nested/wt/a.txt"
            #expect(try await Process.git(["worktree", "add", "-q", "-b", "nested", "nested/wt"], cwd: repo).exitCode == 0)
        case .parentSwappedAfterTheCheck:
            path = "dir/new.txt"
            let dir = repo.appendingPathComponent("dir")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            fixture.core.beforeFileChange = {
                try? FileManager.default.removeItem(at: dir)
                try FileManager.default.createSymbolicLink(at: dir, withDestinationURL: outside)
            }
        }

        let response = try await fixture.request(.writeFile(worktree: ref, path: path, text: "x", expected: nil))
        #expect(response == .failure(error: .invalidRequest(reason: "The host does not edit \(path).")))
        #expect(try Data(contentsOf: inside) == Data("keep\n".utf8))
        #expect(try Data(contentsOf: config) == configBytes)
        #expect(try Data(contentsOf: hello) == helloBytes)
        if shape == .ignored || shape == .colonPrefixed {
            #expect(try Data(contentsOf: repo.appendingPathComponent(path)) == Data("a\n".utf8))
        }
        if shape == .nestedWorktree {
            #expect(!FileManager.default.fileExists(atPath: repo.appendingPathComponent(path).path))
        }
        if shape == .parentSwappedAfterTheCheck {
            // Real again for the check, swapped again before the folder is made.
            let dir = repo.appendingPathComponent("dir")
            try FileManager.default.removeItem(at: dir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            #expect(try await fixture.request(.createFolder(worktree: ref, path: "dir/made"))
                == .failure(error: .invalidRequest(reason: "The host does not edit dir/made.")))
            #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path) == ["inside.txt"])
        }
        // A read never hands out a version a save would refuse.
        if shape == .nestedWorktree { try Data("a\n".utf8).write(to: repo.appendingPathComponent(path)) }
        let read = try await fixture.request(.readWorktree(worktree: ref, read: .file(path: path)))
        switch shape {
        case .nestedWorktree:
            guard case .worktreeRead(.fileContents(_, _, _, _, .none)) = read else {
                Issue.record("expected the content without a version, got \(read)")
                return
            }
        case .ignored:
            guard case .worktreeRead(.fileUnavailable(_, _, .pathRejected, _, _)) = read else {
                Issue.record("expected the read refused, got \(read)")
                return
            }
        default:
            if case .worktreeRead(.fileContents(_, _, _, _, .some)) = read { Issue.record("expected no version, got \(read)") }
        }
    }

    /// A folder has no ignore rules, and its tree lists every file: what a
    /// Mac can read there it can save, unless reached through a symlink. In a git project the same file is
    /// refused (`fileWritesStayOnRegularFilesInsideTheWorktree`).
    @Test func ignoredFilesAreEditedInFolderProjects() async throws {
        let fixture = try await RepoFixture()
        defer { fixture.tearDown() }
        let root = fixture.root.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = try await fixture.host.projects.add(path: root, displayName: "plain", icon: .default(), kind: .folder, caller: .app).id
        let worktree = try #require(fixture.core.projects.worktrees(projectId: id).first)
        let ref = WorktreeRef(projectID: id, path: worktree.path.path)
        try Data("*.log\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        let log = root.appendingPathComponent("debug.log")
        try Data("a\n".utf8).write(to: log)

        let version = try await fixture.fileVersion("debug.log", in: ref)
        guard case .fileWritten = try await fixture.request(.writeFile(worktree: ref, path: "debug.log", text: "b\n", expected: version)) else {
            Issue.record("expected the ignored file saved in a folder")
            return
        }
        #expect(try Data(contentsOf: log) == Data("b\n".utf8))

        // Read through a symlinked folder, but not saved there, so it carries no version.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("real"), withIntermediateDirectories: true)
        try Data("a\n".utf8).write(to: root.appendingPathComponent("real/a.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias"), withDestinationURL: root.appendingPathComponent("real"))
        let read = try await fixture.request(.readWorktree(worktree: ref, read: .file(path: "alias/a.txt")))
        guard case .worktreeRead(.fileContents(_, _, "a\n", _, .none)) = read else {
            Issue.record("expected the content without a version, got \(read)")
            return
        }
    }

    enum WriteGate: CaseIterable { case restoreHold, pendingRecovery, overCap, appHost }

    /// A save waits for nothing: refused while a restore holds the worktree or
    /// waits to finish, past the read cap, and on a host that edits no files.
    @Test(arguments: WriteGate.allCases)
    func fileWritesAreRefusedWhileTheWorktreeIsHeld(_ gate: WriteGate) async throws {
        let environment: RecordingRunEnvironment? = switch gate {
        case .pendingRecovery: RecordingRunEnvironment(servesWorktreeGit: true, blocksForCheckpoint: true)
        case .appHost: RecordingRunEnvironment()
        case .restoreHold, .overCap: nil
        }
        let fixture = try await RepoFixture(environment: environment)
        defer { fixture.tearDown() }
        let (repo, ref) = try await fixture.mainWorktree()
        let notes = repo.appendingPathComponent("notes.txt")
        try Data("a\n".utf8).write(to: notes)
        let read = try await fixture.fileVersion("notes.txt", in: ref)
        var text = "b\n"
        let expected: HostError
        switch gate {
        case .restoreHold:
            let id = try #require(fixture.core.projects.worktrees(projectId: fixture.projectID).first).id
            fixture.core.checkpointRestoreHolds[UUID()] = [SessionOwnerID.worktree(id).storageKey]
            expected = .failed(message: "A checkpoint restore is running on the host; save again once it finishes.")
        case .pendingRecovery:
            expected = .failed(message: "A checkpoint restore is pending on the host; finish it there first.")
        case .overCap:
            text = String(repeating: "a", count: RemoteWorktreeFileAccess.maxFileBytes + 1)
            expected = .invalidRequest(reason: "The host edits files up to 512 KB.")
        case .appHost:
            expected = .invalidRequest(reason: "This host does not serve file editing.")
        }

        #expect(try await fixture.request(.writeFile(worktree: ref, path: "notes.txt", text: text, expected: read)) == .failure(error: expected))
        #expect(try Data(contentsOf: notes) == Data("a\n".utf8))
    }

    /// A save needs no branch: mid-rebase, with git detached and the listing
    /// still on the branch, a conflicted file is resolved by hand.
    @Test func aFileIsSavedMidRebaseWhileTheListingLags() async throws {
        let fixture = try await RepoFixture()
        defer { fixture.tearDown() }
        let (repo, ref) = try await fixture.stopPullOnConflicts()
        let path = ".alas/scripts/hello.sh"
        let read = try await fixture.fileVersion(path, in: ref)

        guard case .fileWritten = try await fixture.request(.writeFile(worktree: ref, path: path, text: "resolved\n", expected: read)) else {
            Issue.record("expected the save to land")
            return
        }
        #expect(try Data(contentsOf: repo.appendingPathComponent(path)) == Data("resolved\n".utf8))
        #expect(FileManager.default.fileExists(atPath: repo.appendingPathComponent(".git/rebase-merge").path))
    }

    /// A Mac hears when a file it follows changes, however it is saved, and
    /// only while it follows it; a Mac that does not follow it hears nothing.
    @Test func aFollowedFileChangeReachesOnlyTheMacsFollowingIt() async throws {
        let fixture = try await RepoFixture()
        defer { fixture.tearDown() }
        let (repo, ref) = try await fixture.mainWorktree()
        let worktree = try #require(fixture.core.projects.worktrees(projectId: fixture.projectID).first)
        let notes = repo.appendingPathComponent("notes.txt")
        try "a\n".write(to: notes, atomically: true, encoding: .utf8)
        let a = try await fixture.fileFollower()
        let b = try await fixture.fileFollower()
        defer {
            a.connection.close()
            b.connection.close()
        }
        #expect(await a.request(.followFile(worktree: ref, path: "../notes.txt"))
            == .failure(error: .invalidRequest(reason: "The host does not edit ../notes.txt.")))
        #expect(await a.request(.followFile(worktree: ref, path: "notes.txt")) == .done)
        let hashes = ["b\n", "c\n"].map { WorktreeFileVersion.contentHash(of: Data($0.utf8)) }

        try "b\n".write(to: notes, atomically: true, encoding: .utf8)
        try await a.client.waitFor(within: .seconds(60)) { Self.notesVersions($0).last??.contentHash == hashes[0] }
        // A rename save swaps the file for a new one, which is watched too.
        try "c\n".write(to: notes, atomically: true, encoding: .utf8)
        try await a.client.waitFor(within: .seconds(60)) { Self.notesVersions($0).last??.contentHash == hashes[1] }
        try FileManager.default.removeItem(at: notes)
        try await a.client.waitFor(within: .seconds(60)) { Self.notesVersions($0).last == .some(nil) }

        #expect(await a.request(.unfollowFile(worktree: ref, path: "notes.txt")) == .done)
        try "d\n".write(to: notes, atomically: true, encoding: .utf8)
        // A later event both Macs get proves each had its chance.
        fixture.core.projects.setOperationState(for: worktree, state: .archiving(projectId: fixture.projectID))
        for mac in [a, b] {
            try await mac.client.waitFor { Self.events($0).contains { if case .worktreeChanged = $0 { true } else { false } } }
        }
        #expect(Self.notesVersions(a.client.messages).map { $0?.contentHash } == hashes + [nil])
        #expect(Self.notesVersions(b.client.messages).isEmpty)
        let batch = try #require(a.client.messages.first { !Self.notesVersions([$0]).isEmpty })
        #expect(try JSONDecoder().decode(HostServerMessage.self, from: JSONEncoder().encode(batch)) == batch)
    }

    /// One Mac going away leaves the file watched for the others, through
    /// its folder being removed and made again; the last one to let go ends
    /// the watch.
    @Test func aFileStaysWatchedWhileAnyMacFollowsIt() async throws {
        let fixture = try await RepoFixture()
        defer { fixture.tearDown() }
        let (repo, ref) = try await fixture.mainWorktree()
        let docs = repo.appendingPathComponent("docs")
        let notes = docs.appendingPathComponent("notes.txt")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try "a\n".write(to: notes, atomically: true, encoding: .utf8)
        let a = try await fixture.fileFollower()
        let b = try await fixture.fileFollower()
        defer { b.connection.close() }
        for mac in [a, b] {
            #expect(await mac.request(.followFile(worktree: ref, path: "docs/notes.txt")) == .done)
        }
        a.connection.close()

        let hashes = ["b\n", "c\n"].map { WorktreeFileVersion.contentHash(of: Data($0.utf8)) }
        try "b\n".write(to: notes, atomically: true, encoding: .utf8)
        try await b.client.waitFor(within: .seconds(60)) { Self.notesVersions($0, "docs/notes.txt").last??.contentHash == hashes[0] }
        // As a branch switch does.
        try FileManager.default.removeItem(at: docs)
        try await b.client.waitFor(within: .seconds(60)) { Self.notesVersions($0, "docs/notes.txt").last == .some(nil) }
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try "c\n".write(to: notes, atomically: true, encoding: .utf8)
        try await b.client.waitFor(within: .seconds(60)) { Self.notesVersions($0, "docs/notes.txt").last??.contentHash == hashes[1] }
        #expect(await b.request(.unfollowFile(worktree: ref, path: "docs/notes.txt")) == .done)
        #expect(fixture.host.eventSource?.fileWatcher.watches.isEmpty == true)
    }

    private static func events(_ messages: [HostServerMessage]) -> [HostEvent] {
        messages.flatMap { message -> [HostEvent] in
            guard case .events(let batch, _) = message else { return [] }
            return batch
        }
    }

    /// The versions `fileChanged` sent for `path`, in order.
    private static func notesVersions(_ messages: [HostServerMessage], _ path: String = "notes.txt") -> [WorktreeFileVersion?] {
        var versions: [WorktreeFileVersion?] = []
        for case .fileChanged(_, path, let version) in events(messages) {
            versions.append(version)
        }
        return versions
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

    @Test func aMacStashesAndPopsAHostWorktreesChanges() async throws {
        let fixture = try await RepoFixture()
        defer { fixture.tearDown() }
        let (repo, ref) = try await fixture.mainWorktree()
        try "new\n".write(to: repo.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)

        #expect(try await fixture.request(.mutateWorktree(
            worktree: ref, branch: "main", change: .stash(message: "wip", includeUntracked: true)
        )) == .done)
        let status = try await Process.git(["status", "--porcelain"], cwd: repo).stdout
        #expect(status == "")
        guard case .stashes(let stashes) = try await fixture.request(.listStashes(worktree: ref)) else {
            Issue.record("expected stashes")
            return
        }
        #expect(stashes.map(\.subject) == ["On main: wip"])
        let stash = HostStashRef(try #require(stashes.first))
        guard case .stashFiles(let files) = try await fixture.request(.stashFiles(worktree: ref, stash: stash)) else {
            Issue.record("expected stash files")
            return
        }
        #expect(files.map(\.path) == ["new.txt"])
        #expect(files.first?.isUntracked == true)
        guard case .diff(let diff) = try await fixture.request(.stashDiff(worktree: ref, stash: stash, path: "new.txt")) else {
            Issue.record("expected a diff")
            return
        }
        #expect(diff.hunks.count == 1)
        // The host reads it bounded: past the cap, git's output is cut and reported.
        let listed = try #require(await GitService().stashes(worktreePath: repo).first)
        let file = try #require(await GitService().stashFiles(worktreePath: repo, stash: listed).first)
        #expect(try await GitService().stashDiff(worktreePath: repo, stash: listed, file: file, maxOutputBytes: 8).truncated)

        let popped = try await fixture.request(.mutateWorktree(worktree: ref, branch: "main", change: .popStash(stash)))
        #expect(popped == .done)
        #expect(FileManager.default.fileExists(atPath: repo.appendingPathComponent("new.txt").path))
        #expect(try await fixture.request(.listStashes(worktree: ref)) == .stashes(stashes: []))
    }

    enum StaleStash: CaseIterable { case otherSHA, unlistedRef, optionRef, missingFile }

    /// The Mac names a stash by ref and SHA; the host acts only on the one
    /// `git stash list` still holds, and never hands git a ref it did not list.
    @Test(arguments: StaleStash.allCases)
    func stashActionsActOnlyOnTheStashTheMacSaw(_ stale: StaleStash) async throws {
        let fixture = try await RepoFixture()
        defer { fixture.tearDown() }
        let (repo, ref) = try await fixture.mainWorktree()
        try "new\n".write(to: repo.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        #expect(try await Process.git(["stash", "push", "-q", "--include-untracked"], cwd: repo).exitCode == 0)
        let list = try await Process.git(["stash", "list", "--format=%gd %H"], cwd: repo).stdout
        let listed = list.split(separator: " ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let stash = HostStashRef(ref: listed[0], sha: listed[1])

        switch stale {
        case .missingFile:
            #expect(try await fixture.request(.stashDiff(worktree: ref, stash: stash, path: "nope.txt"))
                == .failure(error: .invalidRequest(reason: "The stash has no file nope.txt.")))
        case .otherSHA, .unlistedRef, .optionRef:
            let head = try await Process.git(["rev-parse", "HEAD"], cwd: repo).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let seen = switch stale {
            case .otherSHA: HostStashRef(ref: stash.ref, sha: head)
            case .unlistedRef: HostStashRef(ref: "stash@{3}", sha: stash.sha)
            default: HostStashRef(ref: "--index", sha: stash.sha)
            }
            let changed = HostResponse.failure(error: .failed(message: "This stash changed since it was listed. Refresh and try again."))
            for change in [HostWorktreeChange.dropStash(seen), .applyStash(seen), .popStash(seen)] {
                #expect(try await fixture.request(.mutateWorktree(worktree: ref, branch: "main", change: change)) == changed)
            }
            #expect(try await fixture.request(.stashFiles(worktree: ref, stash: seen)) == changed)
        }
        #expect(try await Process.git(["stash", "list", "--format=%gd %H"], cwd: repo).stdout == list)
    }

    /// As locally, a conflicting pop keeps the stash and leaves the conflict
    /// in the worktree to resolve.
    @Test func aConflictingStashPopKeepsTheStashAndShowsTheConflict() async throws {
        let fixture = try await RepoFixture()
        defer { fixture.tearDown() }
        let (repo, ref) = try await fixture.mainWorktree()
        let script = repo.appendingPathComponent(".alas/scripts/hello.sh")
        try "stashed\n".write(to: script, atomically: true, encoding: .utf8)
        #expect(try await Process.git(["stash", "push", "-q"], cwd: repo).exitCode == 0)
        try "committed\n".write(to: script, atomically: true, encoding: .utf8)
        #expect(try await Process.git(["commit", "-q", "-am", "Conflict"], cwd: repo).exitCode == 0)
        guard case .stashes(let stashes) = try await fixture.request(.listStashes(worktree: ref)) else {
            Issue.record("expected stashes")
            return
        }
        let stash = HostStashRef(try #require(stashes.first))

        guard case .failure(.failed(let message)) = try await fixture.request(
            .mutateWorktree(worktree: ref, branch: "main", change: .popStash(stash))
        ) else {
            Issue.record("expected the pop to fail")
            return
        }
        #expect(message.contains("CONFLICT"))
        guard case .stashes(let after) = try await fixture.request(.listStashes(worktree: ref)) else {
            Issue.record("expected stashes")
            return
        }
        #expect(after.map(HostStashRef.init) == [stash])
        guard case .worktreeRead(.changeList(_, _, _, let files, let staged, let unstaged, _, _, _, _, _)) =
            try await fixture.request(.readWorktree(worktree: ref, read: .changes(comparisonMode: nil)))
        else {
            Issue.record("expected the changes")
            return
        }
        #expect((files + staged + unstaged).contains { $0.path == ".alas/scripts/hello.sh" && $0.conflict != nil })

        // No operation is in progress, yet the conflict is the Mac's to resolve.
        #expect(try await fixture.request(.mutateWorktree(
            worktree: ref, branch: "main", change: .useTheirs(path: ".alas/scripts/hello.sh")
        )) == .done)
        #expect(try String(contentsOf: script, encoding: .utf8) == "stashed\n")
        #expect(try await Process.git(["diff", "--name-only", "--diff-filter=U"], cwd: repo).stdout == "")
    }

    @Test func aMacCreatesInspectsAndDeletesAHostCheckpoint() async throws {
        let fixture = try await RepoFixture()
        defer { fixture.tearDown() }
        let (repo, ref) = try await fixture.mainWorktree()
        let file = repo.appendingPathComponent("a.txt")
        try "one\n".write(to: file, atomically: true, encoding: .utf8)

        let manifest = try await fixture.checkpoint("  Before  ", in: ref)
        #expect(manifest.label == "Before")
        guard case .checkpoints(let catalog) = try await fixture.request(.listCheckpoints(worktree: ref)) else {
            Issue.record("expected checkpoints")
            return
        }
        #expect(catalog.summaries.map(\.label) == ["Before"])
        try "two\n".write(to: file, atomically: true, encoding: .utf8)
        guard case .diff(let diff) = try await fixture.request(.checkpointDiff(worktree: ref, id: manifest.id, path: "a.txt")) else {
            Issue.record("expected a diff")
            return
        }
        #expect(diff.hunks.count == 1)

        #expect(try await fixture.request(.mutateWorktree(
            worktree: ref, branch: "main", change: .deleteCheckpoint(id: manifest.id)
        )) == .done)
        guard case .checkpoints(let after) = try await fixture.request(.listCheckpoints(worktree: ref)) else {
            Issue.record("expected checkpoints")
            return
        }
        #expect(after.summaries.isEmpty)
        #expect(try await fixture.request(.mutateWorktree(worktree: ref, branch: "main", change: .createCheckpoint(label: " ")))
            == .failure(error: .invalidRequest(reason: "A checkpoint needs a name.")))
    }

    @Test func aCheckpointRestoreWaitsForTheWorktreesSessions() async throws {
        let fixture = try await RepoFixture()
        defer { fixture.tearDown() }
        let (repo, ref) = try await fixture.mainWorktree()
        let file = repo.appendingPathComponent("a.txt")
        try "one\n".write(to: file, atomically: true, encoding: .utf8)
        let manifest = try await fixture.checkpoint("Before", in: ref)
        try "two\n".write(to: file, atomically: true, encoding: .utf8)
        let worktree = try #require(fixture.core.projects.worktrees(projectId: fixture.projectID).first)
        let session = try await fixture.host.sessions.create(.worktree(ref), agentID: "gemini", caller: .app)
        let core = fixture.core
        try await eventually { @MainActor in core.sessionManagers[.worktree(worktree.id)]?.runners.isEmpty == false }

        let busy = try await fixture.restorePreview(manifest.id, in: ref)
        #expect(busy.blocker == .activeSession)
        #expect(try await fixture.request(.mutateWorktree(worktree: ref, branch: "main", change: .restoreCheckpoint(
            id: manifest.id, groupIDs: busy.selectedGroupIDs, fingerprint: busy.currentFingerprint
        ))) == .failure(error: .failed(message: "Stop active terminal and agent sessions before restoring.")))
        #expect(try String(contentsOf: file, encoding: .utf8) == "two\n")

        try await fixture.host.sessions.archive(session.id, caller: .app)
        try await eventually { @MainActor in core.sessionManagers[.worktree(worktree.id)]?.runners.isEmpty != false }
        let preview = try await fixture.restorePreview(manifest.id, in: ref)
        #expect(preview.blocker == nil)
        #expect(try await fixture.request(.mutateWorktree(worktree: ref, branch: "main", change: .restoreCheckpoint(
            id: manifest.id, groupIDs: preview.selectedGroupIDs, fingerprint: "stale"
        ))) == .failure(error: .failed(message: "Refresh the restore preview before trying again.")))
        #expect(try await fixture.request(.mutateWorktree(worktree: ref, branch: "main", change: .restoreCheckpoint(
            id: manifest.id, groupIDs: preview.selectedGroupIDs, fingerprint: preview.currentFingerprint
        ))) == .done)
        #expect(try String(contentsOf: file, encoding: .utf8) == "one\n")
        guard case .checkpoints(let catalog) = try await fixture.request(.listCheckpoints(worktree: ref)) else {
            Issue.record("expected checkpoints")
            return
        }
        #expect(catalog.summaries.contains { $0.kind == .recovery && $0.label == "Before checkpoint restore" })
    }

    /// A restore keeps new sessions out of its worktree from the moment it
    /// counts the writers until it ends, so none starts after the count.
    @Test func aRestoreHoldsNewSessionsOffItsWorktreeUntilItEnds() async throws {
        let pause = CheckpointGitPause()
        let fixture = try await RepoFixture(checkpointGit: PausingCheckpointGit(pause: pause))
        defer { fixture.tearDown() }
        let (repo, ref) = try await fixture.mainWorktree()
        try "one\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let manifest = try await fixture.checkpoint("Before", in: ref)
        try "two\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let preview = try await fixture.restorePreview(manifest.id, in: ref)

        pause.armed = true
        let restore = Task { @MainActor in
            try await fixture.request(.mutateWorktree(worktree: ref, branch: "main", change: .restoreCheckpoint(
                id: manifest.id, groupIDs: preview.selectedGroupIDs, fingerprint: preview.currentFingerprint
            )))
        }
        try await eventually { await pause.isHolding }
        await #expect(throws: SessionRefusal.ownerUnavailable(reason: SessionsAPI.checkpointRestoreReason)) {
            try await fixture.host.sessions.create(.worktree(ref), agentID: "gemini", caller: .app)
        }

        pause.release()
        #expect(try await restore.value == .done)
        _ = try await fixture.host.sessions.create(.worktree(ref), agentID: "gemini", caller: .app)
    }

    enum RestoreWriter: CaseIterable {
        case worktreeSession, memberCheckoutSession, otherCheckoutSession, checkoutSessionWithUnreadableState, run, console
    }

    /// A restore counts the writers of the worktree and of each Workspace
    /// checkout that has it as a member, as the app does; another checkout's
    /// session does not hold it back, and unreadable Workspace state counts them all.
    @Test(arguments: RestoreWriter.allCases)
    func checkpointRestoreCountsTheWorktreesWriters(_ writer: RestoreWriter) {
        let worktree = Worktree(
            id: "wt", projectId: "p", name: "wt", branch: "b",
            path: URL(fileURLWithPath: "/srv/repo/wt"), status: .clean, lastActivity: .distantPast
        )
        func checkout(memberPath: String) -> WorkspaceCheckout {
            WorkspaceCheckout(
                workspaceID: UUID(), fallbackWorkspaceName: "w", executionLocation: .local, branch: "b", rootPath: "/srv/w",
                members: [WorkspaceCheckoutMember(
                    workspaceMemberID: UUID(), projectID: "p", fallbackProjectName: "repo",
                    fallbackRepositoryRoot: "/srv/repo", worktreePath: memberPath
                )]
            )
        }
        let member = checkout(memberPath: "/srv/repo/wt")
        let other = checkout(memberPath: "/srv/repo/other")
        let memberOwner = SessionOwnerID.workspaceCheckout(member.id, .local)
        let otherOwner = SessionOwnerID.workspaceCheckout(other.id, .local)
        let sessions: [SessionOwnerID: Int] = switch writer {
        case .worktreeSession: [.worktree("wt"): 1, .worktree("elsewhere"): 1]
        case .memberCheckoutSession, .checkoutSessionWithUnreadableState: [memberOwner: 2]
        case .otherCheckoutSession: [otherOwner: 1]
        case .run, .console: [:]
        }
        let counts = AlasCoreContext.checkpointWriterCounts(
            for: worktree, checkouts: writer == .checkoutSessionWithUnreadableState ? nil : [member, other],
            sessions: sessions, runOwnerKeys: writer == .run ? ["wt", "elsewhere"] : ["elsewhere"],
            hasConsoles: { writer == .console && $0.contains("wt") }
        )
        let expected: (sessions: Int, terminals: Int) = switch writer {
        case .worktreeSession: (1, 0)
        case .memberCheckoutSession, .checkoutSessionWithUnreadableState: (2, 0)
        case .otherCheckoutSession: (0, 0)
        case .run, .console: (0, 1)
        }
        #expect(counts == expected)
    }

    /// As the app does, the host checkpoints a worktree before each prompt and
    /// the user row carries its id; a failed capture still sends the prompt.
    @Test(arguments: [false, true])
    func aHostPromptTakesAnAutomaticCheckpointFirst(captureFails: Bool) async throws {
        let fixture = try await RepoFixture()
        defer { fixture.tearDown() }
        let (repo, ref) = try await fixture.mainWorktree()
        try "one\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let worktree = try #require(fixture.core.projects.worktrees(projectId: fixture.projectID).first)
        let sessions = fixture.host.sessions
        let session = try await sessions.create(.worktree(ref), agentID: "gemini", caller: .app)
        let id = session.id
        try await eventually { await sessions.list().first { $0.id == id }?.isWriter == true }
        if captureFails {
            // A file where the checkpoint store's directory belongs, once the session is past the recovery gate.
            try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("checkpoints"))
            try Data().write(to: fixture.root.appendingPathComponent("checkpoints"))
        }
        try await sessions.send(id, prompt: "fix it", caller: .app)

        let agent = fixture.agent
        // The prompt waits for the capture: two full snapshots, about two dozen git processes in turn,
        // which take well over the default 10 s on a loaded 3-vCPU runner.
        try await eventually(within: .seconds(60)) { agent.sent.contains { $0.method == "session/prompt" } }
        let manager = try #require(fixture.core.sessionManagers[.worktree(worktree.id)])
        let user = try #require(manager.liveSession(for: id)?.transcript.messages.first {
            if case .user = $0 { return true }
            return false
        })
        guard case .user(_, _, _, let attachments, _, _) = user else {
            Issue.record("expected a user row")
            return
        }
        let carried = attachments.compactMap(\.checkpointID)
        #expect(RemoteSessionGateway.toWire(user, index: 0).checkpointId == carried.first?.uuidString)
        if captureFails {
            #expect(carried.isEmpty)
            return
        }
        let target = try #require(fixture.core.checkpointTarget(for: worktree))
        let automatic = try await fixture.core.checkpoints.summaries(target: target).summaries.filter { $0.kind == .automatic }
        #expect(automatic.map(\.label) == ["Before: fix it"])
        #expect(carried == automatic.map(\.id))
    }

    /// A Mac names only checkpoints of the worktree it asks about, and paths inside it.
    @Test func checkpointRequestsNameOnlyThisWorktreesCheckpoints() async throws {
        let fixture = try await RepoFixture()
        defer { fixture.tearDown() }
        let (repo, ref) = try await fixture.mainWorktree()
        try "one\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let mine = try await fixture.checkpoint("Mine", in: ref)
        let otherRepo = fixture.root.appendingPathComponent("other")
        try await GitTemplate.repository(at: otherRepo)
        try "one\n".write(to: otherRepo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let otherID = try await fixture.host.projects.add(path: otherRepo, displayName: "other", icon: .default(), caller: .app).id
        let otherWorktree = try #require(fixture.core.projects.worktrees(projectId: otherID).first)
        let otherRef = WorktreeRef(projectID: otherID, path: otherWorktree.path.path)
        let other = try await fixture.checkpoint("Other", in: otherRef)

        let unknown = HostResponse.failure(error: .notFound(what: "checkpoint \(other.id)"))
        #expect(try await fixture.request(.checkpointManifest(worktree: ref, id: other.id)) == unknown)
        #expect(try await fixture.request(.checkpointDiff(worktree: ref, id: other.id, path: "a.txt")) == unknown)
        #expect(try await fixture.request(.mutateWorktree(worktree: ref, branch: "main", change: .deleteCheckpoint(id: other.id)))
            == unknown)
        guard case .checkpoints(let catalog) = try await fixture.request(.listCheckpoints(worktree: otherRef)) else {
            Issue.record("expected checkpoints")
            return
        }
        #expect(catalog.summaries.map(\.id) == [other.id])
        #expect(try await fixture.request(.checkpointDiff(worktree: ref, id: mine.id, path: "../x"))
            == .failure(error: .invalidRequest(reason: "The path ../x is outside the worktree.")))
    }

    @Test func aMacRewordsAHostCommit() async throws {
        let fixture = try await RepoFixture(aheadOfOrigin: true)
        defer { fixture.tearDown() }
        let (repo, ref) = try await fixture.mainWorktree()
        let shas = fixture.aheadSHAs

        guard case .commitDetails(let details) = try await fixture.request(.commitDetails(worktree: ref, sha: shas[1])) else {
            Issue.record("expected the commit's details")
            return
        }
        #expect(details.info.rawSubject == "entry 2")
        guard case .commitEdited(let result) = try await fixture.request(.mutateWorktree(
            worktree: ref, branch: "main", change: .editCommit(sha: shas[1], edit: .message(subject: "Reworded", body: ""), comparisonMode: nil)
        )) else {
            Issue.record("expected the commit edited")
            return
        }
        #expect(result.currentSha != shas[1])
        #expect(try await Process.git(["log", "--format=%s", "origin/main..HEAD"], cwd: repo).stdout == "entry 3\nReworded\nentry 1\n")
    }

    /// The host drops the file, or the hunk at the index the Mac saw, and
    /// replays the commit above it.
    @Test(arguments: [true, false])
    func aMacDropsAFileOrAHunkFromAHostCommit(_ dropsHunk: Bool) async throws {
        let fixture = try await RepoFixture(aheadOfOrigin: true)
        defer { fixture.tearDown() }
        let (repo, ref) = try await fixture.mainWorktree()
        let notes = repo.appendingPathComponent("notes.txt")
        let lines = (1...20).map { "line \($0)" }
        for (contents, subject) in [
            (lines, "Add notes"), (["first"] + lines.dropFirst().dropLast() + ["last"], "Edit notes"),
        ] {
            try (contents.joined(separator: "\n") + "\n").write(to: notes, atomically: true, encoding: .utf8)
            // Dropping notes.txt must leave the edit something to commit.
            try subject.write(to: repo.appendingPathComponent("other.txt"), atomically: true, encoding: .utf8)
            #expect(try await Process.git(["add", "notes.txt", "other.txt"], cwd: repo).exitCode == 0)
            #expect(try await Process.git(["commit", "-q", "-m", subject], cwd: repo).exitCode == 0)
        }
        let target = try await Process.git(["rev-parse", "HEAD"], cwd: repo).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(try await Process.git(["commit", "-q", "--allow-empty", "-m", "Above"], cwd: repo).exitCode == 0)
        let hunks = try await GitService().diff(worktreePath: repo, sha: target, file: "notes.txt").hunks
        try #require(hunks.count == 2)
        let edit: HostCommitEdit = dropsHunk ? .dropHunk(path: "notes.txt", index: 1, header: hunks[1].header) : .dropFile(path: "notes.txt")

        guard case .commitEdited = try await fixture.request(.mutateWorktree(
            worktree: ref, branch: "main", change: .editCommit(sha: target, edit: edit, comparisonMode: nil)
        )) else {
            Issue.record("expected the commit edited")
            return
        }
        let kept = dropsHunk ? ["first"] + lines.dropFirst() : lines
        #expect(try String(contentsOf: notes, encoding: .utf8) == kept.joined(separator: "\n") + "\n")
        #expect(try await Process.git(["log", "--format=%s", "-2"], cwd: repo).stdout == "Above\nEdit notes\n")
    }

    /// The host stages, unstages or discards only the hunk the Mac was shown,
    /// rebuilt from its own diff of that side.
    @Test func aMacStagesUnstagesAndDiscardsAHunk() async throws {
        let fixture = try await RepoFixture()
        defer { fixture.tearDown() }
        let (repo, ref) = try await fixture.mainWorktree()
        let notes = repo.appendingPathComponent("notes.txt")
        let lines = (1...20).map { "line \($0)" }
        try (lines.joined(separator: "\n") + "\n").write(to: notes, atomically: true, encoding: .utf8)
        try "gone\n".write(to: repo.appendingPathComponent("gone.txt"), atomically: true, encoding: .utf8)
        #expect(try await Process.git(["add", "notes.txt", "gone.txt"], cwd: repo).exitCode == 0)
        #expect(try await Process.git(["commit", "-q", "-m", "Add notes"], cwd: repo).exitCode == 0)
        try FileManager.default.removeItem(at: repo.appendingPathComponent("gone.txt"))
        // One line over the cap: the Mac is sent it clamped.
        let longLine = String(repeating: "x", count: RemoteWorktreeFileAccess.maxDiffLineBytes + 1)
        try (longLine + "\n").write(to: repo.appendingPathComponent("long.txt"), atomically: true, encoding: .utf8)
        let edited = ["first"] + lines.dropFirst().dropLast() + ["last"]
        try (edited.joined(separator: "\n") + "\n").write(to: notes, atomically: true, encoding: .utf8)
        let script = repo.appendingPathComponent("new.sh")
        try "#!/bin/sh\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        func shown(_ path: String, _ stage: ChangeStage) async throws -> [RemoteDiffHunk] {
            guard case .worktreeRead(.fileDiffResult(_, _, _, let hunks, _, _)) = try await fixture.request(
                .readWorktree(worktree: ref, read: .fileDiff(path: path, stage: stage.rawValue, comparisonMode: nil))
            ) else { throw HostError.failed(message: "expected \(path)'s diff") }
            return hunks
        }
        func act(
            _ action: HostHunkAction, _ path: String, _ stage: ChangeStage, _ index: Int,
            header: String? = nil, linesHash: String? = nil
        ) async throws -> HostResponse {
            let hunks = try await shown(path, stage)
            let hunk = hunks[min(index, hunks.count - 1)]
            return try await fixture.request(.mutateWorktree(worktree: ref, branch: "main", change: .hunk(
                path: path, stage: stage, index: index, header: header ?? hunk.header,
                linesHash: linesHash ?? hunk.linesHash, action: action
            )))
        }
        let unstaged = try await shown("notes.txt", .unstaged)
        try #require(unstaged.count == 2)
        let stale = HostResponse.failure(error: .failed(message: "The file changed since it was shown. Refresh and try again."))

        #expect(try await act(.stage, "notes.txt", .unstaged, 1, linesHash: unstaged[0].linesHash) == stale)
        #expect(try await act(.stage, "notes.txt", .unstaged, 1, header: unstaged[0].header) == stale)
        #expect(try await act(.discard, "notes.txt", .unstaged, 2) == stale)
        guard case .failure(.invalidRequest) = try await act(.unstage, "notes.txt", .unstaged, 0) else {
            Issue.record("expected unstage of an unstaged hunk refused")
            return
        }
        #expect(try await shown("notes.txt", .unstaged) == unstaged)
        #expect(try await act(.discard, "new.sh", .unstaged, 0)
            == .failure(error: .failed(message: "Discard new.sh as a whole file instead.")))
        // The Mac is shown no diff of a missing file; the host refuses one named anyway.
        let gone = try #require(await GitService().diff(worktreePath: repo, file: "gone.txt").hunks.first)
        #expect(try await fixture.request(.mutateWorktree(worktree: ref, branch: "main", change: .hunk(
            path: "gone.txt", stage: .unstaged, index: 0, header: gone.header, linesHash: RemoteDiffHunk(gone).linesHash,
            action: .discard
        ))) == .failure(error: .failed(message: "Discard gone.txt as a whole file instead.")))
        #expect(try await act(.stage, "long.txt", .unstaged, 0)
            == .failure(error: .failed(message: "This hunk is too large to change from here.")))

        #expect(try await act(.stage, "new.sh", .unstaged, 0) == .done)
        #expect(try await Process.git(["ls-files", "-s", "new.sh"], cwd: repo).stdout.hasPrefix("100755 "))
        #expect(try await act(.stage, "notes.txt", .unstaged, 1) == .done)
        #expect(try await shown("notes.txt", .unstaged) == [unstaged[0]])
        #expect(try await shown("notes.txt", .staged).map(\.linesHash) == [unstaged[1].linesHash])
        #expect(try await act(.unstage, "notes.txt", .staged, 0) == .done)
        #expect(try await shown("notes.txt", .unstaged) == unstaged)
        #expect(try await act(.discard, "notes.txt", .unstaged, 0) == .done)
        #expect(try String(contentsOf: notes, encoding: .utf8) == (lines.dropLast() + ["last"]).joined(separator: "\n") + "\n")
    }

    enum StaleEdit: CaseIterable { case notASHA, belowTheFold, otherHunk, unseenHunk, outsidePath, dirtyTree, renamedFile }

    /// The host edits only a commit above its own fold, named by SHA, and
    /// drops only a hunk its own parse of that commit still has and the Mac was sent whole.
    @Test(arguments: StaleEdit.allCases)
    func commitEditsTakeOnlyWhatTheMacSaw(_ stale: StaleEdit) async throws {
        let fixture = try await RepoFixture(aheadOfOrigin: true)
        defer { fixture.tearDown() }
        let (repo, ref) = try await fixture.mainWorktree()
        let script = ".alas/scripts/hello.sh"
        if stale == .otherHunk {
            try "#!/bin/sh\necho hello from run\necho more\n".write(to: repo.appendingPathComponent(script), atomically: true, encoding: .utf8)
            #expect(try await Process.git(["commit", "-q", "-am", "entry 4"], cwd: repo).exitCode == 0)
        }
        // A first hunk over the diff cap: the Mac never saw the hunk after it.
        var unseenHeader = ""
        if stale == .unseenHunk {
            let cap = RemoteWorktreeFileAccess.maxDiffLines
            let lines = (1...cap + 20).map { "line \($0)" }
            for (index, contents) in [lines, lines.prefix(cap).map { $0 + " edited" } + lines.dropFirst(cap).dropLast() + ["last"]].enumerated() {
                try (contents.joined(separator: "\n") + "\n").write(to: repo.appendingPathComponent("big.txt"), atomically: true, encoding: .utf8)
                #expect(try await Process.git(["add", "big.txt"], cwd: repo).exitCode == 0)
                #expect(try await Process.git(["commit", "-q", "-m", "entry \(index + 4)"], cwd: repo).exitCode == 0)
            }
            let hunks = try await GitService().diff(worktreePath: repo, sha: "HEAD", file: "big.txt").hunks
            try #require(hunks.count == 2)
            unseenHeader = hunks[1].header
        }
        if stale == .renamedFile {
            #expect(try await Process.git(["mv", script, "renamed.sh"], cwd: repo).exitCode == 0)
            #expect(try await Process.git(["commit", "-q", "-m", "entry 4"], cwd: repo).exitCode == 0)
        }
        if stale == .dirtyTree {
            try "new\n".write(to: repo.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        }
        let head = try await Process.git(["rev-parse", "HEAD"], cwd: repo).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = try await Process.git(["rev-parse", "origin/main"], cwd: repo).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let shas = fixture.aheadSHAs
        let notAboveFold = try #require(CommitEditError.targetNotAboveFold.errorDescription)
        let dirty = try #require(CommitEditError.dirtyWorktree.errorDescription)
        let unsupported = try #require(CommitEditError.unsupportedAction.errorDescription)
        let (sha, edit, expected): (String, HostCommitEdit, HostError) = switch stale {
        case .notASHA: ("HEAD~1", .message(subject: "x", body: ""), .invalidRequest(reason: "A commit is named by its SHA."))
        case .belowTheFold: (base, .message(subject: "x", body: ""), .failed(message: notAboveFold))
        case .otherHunk:
            (head, .dropHunk(path: script, index: 0, header: "@@ -9 +9 @@"),
             .failed(message: "This commit changed since it was shown. Refresh and try again."))
        case .unseenHunk:
            (head, .dropHunk(path: "big.txt", index: 1, header: unseenHeader),
             .failed(message: "This commit changed since it was shown. Refresh and try again."))
        case .outsidePath: (shas[1], .dropFile(path: "../x"), .invalidRequest(reason: "The path ../x is outside the worktree."))
        case .dirtyTree: (shas[1], .message(subject: "Reworded", body: ""), .failed(message: dirty))
        // As locally, a rename is not dropped: it would delete the file.
        case .renamedFile: (head, .dropFile(path: "renamed.sh"), .failed(message: unsupported))
        }

        #expect(try await fixture.request(.mutateWorktree(
            worktree: ref, branch: "main", change: .editCommit(sha: sha, edit: edit, comparisonMode: nil)
        )) == .failure(error: expected))
        #expect(try await Process.git(["rev-parse", "HEAD"], cwd: repo).stdout.trimmingCharacters(in: .whitespacesAndNewlines) == head)
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

    /// Saves draft `id` on line `line` of a.txt in review `session`.
    private static func saveDraft(_ id: String, line: Int, in session: ReviewDraftSessionID, to fixture: RepoFixture) throws {
        try fixture.core.reviewDrafts.save(ReviewDraftComment(
            id: id, sessionID: session, fileID: DiffReviewFileID(namespace: "github-pr", path: "a.txt"), path: "a.txt",
            side: .new, startLine: line, bodyMarkdown: "Why \(id)?", state: .active, createdAt: .distantPast, updatedAt: .distantPast
        ))
    }

    /// A worktree's commit review, with draft "theirs" on it.
    private static func commitReviewWithADraft(_ fixture: RepoFixture, worktree: Worktree) async throws -> ReviewDraftSessionID {
        guard case .success(let commit) = await fixture.host.reviews.open("HEAD", in: worktree, caller: .app) else {
            throw HostError.failed(message: "expected the commit review")
        }
        try saveDraft("theirs", line: 1, in: commit.record.target.draftSessionID, to: fixture)
        return commit.record.target.draftSessionID
    }

    /// A Mac publishes only its review's own drafts, at the head it showed,
    /// and each draft keeps what became of it.
    @Test func publishPostsTheSessionsDraftsAtTheHeadTheMacShowed() async throws {
        let fixture = try await RepoFixture()
        defer { fixture.tearDown() }
        let (_, ref) = try await fixture.mainWorktree()
        let worktree = try #require(fixture.core.projects.worktrees(projectId: fixture.projectID).first)
        let provider = FakeReviewProvider(kind: .github)
        let rawSession = try await fixture.openPullRequestReview(provider)
        let session = try #require(ReviewDraftSessionID(rawValue: rawSession))
        try Self.saveDraft("a", line: 1, in: session, to: fixture)
        try Self.saveDraft("b", line: 2, in: session, to: fixture)
        let commit = try await Self.commitReviewWithADraft(fixture, worktree: worktree)
        let theirs = try fixture.core.reviewDrafts.load(sessionID: commit)
        let result = ProviderReviewPublishResult(
            published: [ProviderReviewPublishedComment(localDraftID: "a", providerThreadID: "t1", providerCommentID: "c1", providerURL: nil)],
            failed: [ProviderReviewFailedComment(localDraftID: "b", message: "outdated")],
            refreshedRequest: ShepherdFixtures.request(), warnings: ["GitHub dropped the approval."]
        )
        provider.publishResult = result
        let subscription = fixture.host.subscribe()

        #expect(try await fixture.request(.publishReview(
            worktree: ref, sessionID: rawSession,
            publish: HostReviewPublish(decision: .comment, body: "", draftIDs: nil, headSHA: "aaaaaaa")
        )) == .reviewPublished(result: result))
        #expect(provider.publishes.count == 1)
        #expect(provider.publishes.first?.reviewRequest.headSHA == "aaaaaaa")
        #expect(provider.publishes.first?.comments.map(\.localDraftID) == ["a", "b"])
        let stored = try fixture.core.reviewDrafts.load(sessionID: session)
        #expect(stored.first { $0.id == "a" }?.providerPublish?.threadID == "t1")
        let b = try #require(stored.first { $0.id == "b" })
        #expect(b.providerError?.message == "outdated")
        #expect(b.state == .active)
        #expect(try fixture.core.reviewDrafts.load(sessionID: commit) == theirs)
        #expect(await fixture.events(of: subscription).contains(.reviewsChanged(worktreeID: worktree.id)))
    }

    /// A publish with nothing of its own review to post never reaches the provider.
    @Test(arguments: [
        (["theirs"], "aaaaaaa", "The selected draft is no longer publishable."),
        (nil, "aaaaaaa", "There are no publishable draft comments for a comment review."),
        (nil, "HEAD; rm", "The head commit must be a commit SHA."),
    ] as [([String]?, String, String)])
    func publishRefusalsReachNoProvider(draftIDs: [String]?, headSHA: String, reason: String) async throws {
        let fixture = try await RepoFixture()
        defer { fixture.tearDown() }
        let (_, ref) = try await fixture.mainWorktree()
        let worktree = try #require(fixture.core.projects.worktrees(projectId: fixture.projectID).first)
        let provider = FakeReviewProvider(kind: .github)
        let rawSession = try await fixture.openPullRequestReview(provider)
        _ = try await Self.commitReviewWithADraft(fixture, worktree: worktree)

        #expect(try await fixture.request(.publishReview(
            worktree: ref, sessionID: rawSession,
            publish: HostReviewPublish(decision: .comment, body: "", draftIDs: draftIDs, headSHA: headSHA)
        )) == .failure(error: .invalidRequest(reason: reason)))
        #expect(provider.publishes.isEmpty)
    }

    /// A second publish of a review is refused while the first runs, so no
    /// draft posts twice.
    @Test func aReviewPublishesOnceWhileAPublishIsInFlight() async throws {
        let fixture = try await RepoFixture()
        defer { fixture.tearDown() }
        _ = try await fixture.mainWorktree()
        let worktree = try #require(fixture.core.projects.worktrees(projectId: fixture.projectID).first)
        let provider = FakeReviewProvider(kind: .github)
        provider.holdsPublish = true
        let rawSession = try await fixture.openPullRequestReview(provider)
        try Self.saveDraft("a", line: 1, in: try #require(ReviewDraftSessionID(rawValue: rawSession)), to: fixture)
        func publish(_ draftIDs: [String]?) async throws -> ProviderReviewPublishResult {
            try await fixture.host.reviews.publish(
                HostReviewPublish(decision: .comment, body: "", draftIDs: draftIDs, headSHA: "aaaaaaa"),
                sessionID: rawSession, in: worktree, caller: .app
            )
        }

        let first = Task { try await publish(nil) }
        try await eventually { await MainActor.run { provider.releasePublish != nil } }
        await #expect(throws: HostError.invalidRequest(reason: "This review is already being published.")) {
            try await publish(["a"])
        }
        // An edit would be marked published with the body the provider never got.
        for mutation in [HostReviewMutation.edit(commentID: "a", body: "later"), .delete(commentID: "a")] {
            await #expect(throws: HostError.invalidRequest(reason: "This review is being published. Try again when it finishes.")) {
                try await fixture.host.reviews.mutate(mutation, sessionID: rawSession, in: worktree, caller: .app)
            }
        }
        provider.releasePublish?.resume()
        #expect(try await first.value.published.map(\.localDraftID) == ["a"])
        await #expect(throws: HostError.invalidRequest(reason: "The selected draft is no longer publishable.")) {
            try await publish(["a"])
        }
        #expect(provider.publishes.count == 1)
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
        let agent = ACPMockClient()
        let projectID: String
        /// With `aheadOfOrigin`, `main`'s three commits `origin/main` lacks, bottom-up.
        let aheadSHAs: [String]

        init(
            environment: (any AlasHostEnvironment)? = nil, aheadOfOrigin: Bool = false,
            checkpointGit: any CheckpointGitRunning = WorktreeStateSnapshotter.live.git
        ) async throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("alas-remove-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let repo = root.appendingPathComponent("repo")
            if aheadOfOrigin {
                aheadSHAs = try await GitTemplate.repositoryAheadOfOrigin(at: repo)
            } else {
                try await GitTemplate.repository(at: repo)
                aheadSHAs = []
            }
            projectsFile = root.appendingPathComponent("projects.json")
            let agent = self.agent
            agent.script(method: "initialize") { _ in Data(#"{"protocolVersion":1,"sessionCapabilities":{}}"#.utf8) }
            agent.script(method: "session/new") { _ in Data(#"{"sessionId":"agent-1"}"#.utf8) }
            agent.script(method: "session/prompt") { _ in Data("null".utf8) }
            let database = root.appendingPathComponent("sessions.sqlite")
            // The checkpoint store refuses a root reached through a symlink, as `/var` is.
            let realRoot = try #require(realpath(root.path, nil))
            defer { free(realRoot) }
            let checkpointsRoot = URL(fileURLWithPath: String(cString: realRoot)).appendingPathComponent("checkpoints")
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
                reviewSessions: ReviewSessionStore(url: root.appendingPathComponent("review-sessions.json")),
                checkpoints: WorktreeCheckpointService(store: .init(root: checkpointsRoot), snapshotter: .init(git: checkpointGit))
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

        /// The main checkout stopped mid-rebase by a pull whose upstream
        /// changed hello.sh to "theirs" against a local "ours". The worktree
        /// stays listed on `main`; nothing relists it.
        func stopPullOnConflicts() async throws -> (URL, WorktreeRef) {
            let (repo, ref) = try await mainWorktree()
            let origin = root.appendingPathComponent("origin")
            try await GitTemplate.repository(at: origin)
            for (directory, contents) in [(origin, "theirs\n"), (repo, "ours\n")] {
                try contents.write(to: directory.appendingPathComponent(".alas/scripts/hello.sh"), atomically: true, encoding: .utf8)
                let commit = ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-q", "-am", contents]
                #expect(try await Process.git(commit, cwd: directory).exitCode == 0)
            }
            for arguments in [["remote", "add", "origin", origin.path], ["fetch", "-q", "origin"], ["branch", "-q", "--set-upstream-to=origin/main"]] {
                #expect(try await Process.git(arguments, cwd: repo).exitCode == 0)
            }
            #expect(try await request(.mutateWorktree(worktree: ref, branch: "main", change: .pull))
                == .failure(error: .failed(message: "Pull stopped on conflicts; resolve them, then continue.")))
            return (repo, ref)
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

        /// The version a Mac reads `path` at.
        func fileVersion(_ path: String, in ref: WorktreeRef) async throws -> WorktreeFileVersion {
            let response = try await request(.readWorktree(worktree: ref, read: .file(path: path)))
            guard case .worktreeRead(.fileContents(_, _, _, _, let version?)) = response else {
                throw HostError.failed(message: "\(response)")
            }
            return version
        }

        func request(_ request: HostRequest) async throws -> HostResponse {
            let id = client.messages.count + 1
            await connection.receive(HostClientMessage(id: id, request: request))
            guard case .response(id, let result) = client.messages.last else {
                throw HostError.invalidRequest(reason: "no response to \(id)")
            }
            return result
        }

        /// A manual checkpoint of the listed worktree at `ref`, taken as a Mac takes it.
        func checkpoint(_ label: String, in ref: WorktreeRef) async throws -> WorktreeCheckpointManifest {
            let branch = try #require(core.projects.worktrees(projectId: ref.projectID).first { $0.path.path == ref.path }).branch
            let response = try await request(.mutateWorktree(worktree: ref, branch: branch, change: .createCheckpoint(label: label)))
            guard case .checkpointManifest(let manifest) = response else { throw HostError.failed(message: "\(response)") }
            return manifest
        }

        func restorePreview(_ id: CheckpointID, in ref: WorktreeRef) async throws -> CheckpointRestorePreview {
            let response = try await request(.checkpointRestorePreview(worktree: ref, id: id, groupIDs: nil))
            guard case .checkpointRestorePreview(let preview) = response else { throw HostError.failed(message: "\(response)") }
            return preview
        }

        /// Another Mac on this host, subscribed to `fileChanged`.
        func fileFollower() async throws -> Mac {
            let client = Client()
            let mac = Mac(connection: HostProtocolServer(host: host).connect(caller: .localUser(uid: 501), send: client.receive), client: client)
            #expect(await mac.request(.subscribeAccepting(after: try await host.snapshot().cursor, events: ["fileChanged"])) == .subscribed)
            return mac
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
    /// `login`. Its mutating methods run on the main actor, where the tests read them.
    final class FakeReviewProvider: CodeHostProvider, @unchecked Sendable {
        let kind: CodeHostKind
        var headSHA = "bbb"
        var threads: [ReviewThread] = []
        var diff = ""
        var login: String? = "octocat"
        /// Thrown by `reviewRequest`.
        var readError: (any Error)?
        var threadMutations: [ProviderThreadMutation] = []
        /// What `publishReview` answers; nil publishes every comment.
        var publishResult: ProviderReviewPublishResult?
        /// The next `publishReview` waits for `releasePublish` to be resumed.
        var holdsPublish = false
        var releasePublish: CheckedContinuation<Void, Never>?
        var publishes: [ProviderReviewPublishRequest] = []

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
        @MainActor func mutateReviewThread(_ mutation: ProviderThreadMutation) async throws -> ProviderThreadMutationResult {
            threadMutations.append(mutation)
            return ProviderThreadMutationResult(refreshedRequest: mutation.reviewRequest, providerURL: nil)
        }
        @MainActor func publishReview(_ request: ProviderReviewPublishRequest) async throws -> ProviderReviewPublishResult {
            publishes.append(request)
            if holdsPublish {
                holdsPublish = false
                await withCheckedContinuation { releasePublish = $0 }
            }
            return publishResult ?? ProviderReviewPublishResult(
                published: request.comments.map {
                    ProviderReviewPublishedComment(localDraftID: $0.localDraftID, providerThreadID: nil, providerCommentID: nil, providerURL: nil)
                },
                failed: [], refreshedRequest: request.reviewRequest, warnings: []
            )
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

    @MainActor
    private struct Mac {
        let connection: HostProtocolConnection
        let client: Client

        func request(_ request: HostRequest) async -> HostResponse? {
            let id = client.messages.count + 1
            await connection.receive(HostClientMessage(id: id, request: request))
            for case .response(id, let result) in client.messages {
                return result
            }
            return nil
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

        func waitFor(
            within timeout: Duration = .seconds(10), _ condition: @escaping @MainActor @Sendable ([HostServerMessage]) -> Bool
        ) async throws {
            try await eventually(within: timeout) { await condition(self.messages) }
        }
    }
}

/// Once armed, holds the next checkpoint git call until `release()`.
@MainActor private final class CheckpointGitPause {
    var armed = false
    var isHolding: Bool { gate != nil }
    private var gate: CheckedContinuation<Void, Never>?

    func pass() async {
        guard armed else { return }
        armed = false
        await withCheckedContinuation { gate = $0 }
    }

    func release() {
        gate?.resume()
        gate = nil
    }
}

/// Real git, held by `pause` before a call.
private struct PausingCheckpointGit: CheckpointGitRunning {
    let pause: CheckpointGitPause
    let git = WorktreeStateSnapshotter.live.git

    func run(_ args: [String], cwd: URL, environment: [String: String]) async throws -> ProcessResult {
        await pause.pass()
        return try await git.run(args, cwd: cwd, environment: environment)
    }

    func runData(_ args: [String], cwd: URL, environment: [String: String]) async throws -> ProcessResultData {
        await pause.pass()
        return try await git.runData(args, cwd: cwd, environment: environment)
    }

    func blobSizes(oids: [String], cwd: URL) async throws -> [String: Int64] { try await git.blobSizes(oids: oids, cwd: cwd) }
    func blobContents(oids: [String], cwd: URL) async throws -> [String: Data] { try await git.blobContents(oids: oids, cwd: cwd) }
    func blobReferences(oids: [String], cwd: URL) async throws -> [String: CheckpointBlobReference] {
        try await git.blobReferences(oids: oids, cwd: cwd)
    }
    func writeBlobs(relativePaths: [String], cwd: URL) async throws -> [String] {
        try await git.writeBlobs(relativePaths: relativePaths, cwd: cwd)
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
    func checkpointRecoveryBlocksRemoval(_ worktree: Worktree, in core: AlasCoreContext) async -> Bool { blocksForCheckpoint }
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
