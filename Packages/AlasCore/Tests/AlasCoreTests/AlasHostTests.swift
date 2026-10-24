import Foundation
import Testing
@_spi(Testing) @testable import AlasCore
@_spi(Testing) @testable import AlasHostCore

@MainActor
struct AlasHostTests {
    /// A worktree's snapshot carries the operation holding it and whether it
    /// is archived; archived worktrees are listed only when asked for.
    @Test func worktreeSnapshotsCarryTheirOperationAndArchivedState() {
        let project = ProjectConfig(id: "p", name: "p", path: "/srv/repo", color: "blue", addedAt: .distantPast)
        let projects = ProjectsManager(persistedProjects: [project])
        func worktree(_ name: String) -> Worktree {
            let path = URL(fileURLWithPath: "/srv/\(name)")
            return Worktree(
                id: Worktree.makeId(path: path), projectId: "p", name: name, branch: name,
                path: path, status: .clean, lastActivity: .distantPast
            )
        }
        let busy = worktree("busy")
        let archived = worktree("archived")
        projects.insertOptimisticWorktree(busy)
        projects.insertOptimisticWorktree(archived)
        projects.setOperationState(for: busy, state: .deleting(projectId: "p"))
        projects.setWorktreeHidden(projectId: "p", path: archived.path, hidden: true)
        let host = AlasHost(core: AlasCoreContext(projects: projects, runHistoryStore: nil, attentionStore: .scratch()))

        #expect(host.worktrees.list() == [
            WorktreeSnapshot(worktree: busy, operation: .deleting, isArchived: false),
        ])
        #expect(Set(host.worktrees.list(includingArchived: true).map(\.worktree.id)) == [busy.id, archived.id])
        #expect(host.worktrees.list(includingArchived: true).first { $0.worktree.id == archived.id }?.isArchived == true)
    }

    enum VerbCheck: CaseIterable {
        case createWithInvalidBranch
        /// The remote path it is created at is taken, though the one asked
        /// for is free.
        case createAtATakenRemoteDestination
        case deleteWorkspaceOwned
        case deleteWithUnsavedEdits
        case forceDeleteWithUnsavedEdits
        case archiveWithUnsavedEdits
    }

    /// The create, delete and archive verbs check what every caller would, whatever
    /// the transport: nothing is listed or claimed for a refused request.
    @Test(arguments: VerbCheck.allCases)
    func worktreeVerbsRefuseWhatTheirChecksRefuse(_ check: VerbCheck) async throws {
        var project = ProjectConfig(id: "p", name: "p", path: "/srv/repo", color: "blue", addedAt: .distantPast)
        if check == .createAtATakenRemoteDestination { project.host = "alas-test.invalid" }
        let projects = ProjectsManager(persistedProjects: [project])
        let path = URL(fileURLWithPath: "/srv/feature")
        let worktree = Worktree(
            id: Worktree.makeId(path: path), projectId: "p", name: "feature", branch: "feature",
            path: path, status: .clean, lastActivity: .distantPast, lineageID: "listed"
        )
        projects.insertOptimisticWorktree(worktree)
        let environment = CheckingEnvironment()
        let core = AlasCoreContext(projects: projects, runHistoryStore: nil, attentionStore: .scratch(), environment: environment)
        let host = AlasHost(core: core)
        switch check {
        case .createAtATakenRemoteDestination:
            core.worktreeDestinationPreparer = { _, destination in
                URL(fileURLWithPath: destination.path.replacingOccurrences(of: "/Users/local", with: "/home/remote"))
            }
            core.remoteCommandRunner = { _, _, command in
                ProcessResult(exitCode: command.contains("/home/remote/new") ? 0 : 1, stdout: "", stderr: "")
            }
            await #expect(throws: WorktreeCheckRefusal.destinationTaken) {
                try await host.worktrees.create(
                    WorktreeCreateRequest(projectID: "p", base: "main", branch: "new", destination: URL(fileURLWithPath: "/Users/local/new")),
                    caller: .localUser(uid: 501)
                )
            }
        case .createWithInvalidBranch:
            await #expect(throws: WorktreeCheckRefusal.self) {
                try await host.worktrees.create(
                    WorktreeCreateRequest(projectID: "p", base: "main", branch: "bad..name", destination: URL(fileURLWithPath: "/srv/new")),
                    caller: .localUser(uid: 501)
                )
            }
        case .deleteWorkspaceOwned:
            environment.workspaceRefusal = "A Workspace checkout manages this worktree."
            await #expect(throws: WorktreeDeletionRefusal.ownedByWorkspaceCheckout("A Workspace checkout manages this worktree.")) {
                try await host.worktrees.delete(worktree, caller: .localUser(uid: 501))
            }
        case .deleteWithUnsavedEdits, .forceDeleteWithUnsavedEdits:
            environment.unsavedEdits = true
            // Force means only "despite git changes": it discards no edits.
            await #expect(throws: WorktreeDeletionRefusal.unsavedEdits) {
                try await host.worktrees.delete(worktree, force: check == .forceDeleteWithUnsavedEdits, caller: .localUser(uid: 501))
            }
        case .archiveWithUnsavedEdits:
            environment.unsavedEdits = true
            await #expect(throws: WorktreeArchiveRefusal.unsavedEdits) {
                try await host.worktrees.archive(worktree, caller: .localUser(uid: 501))
            }
            #expect(!projects.isWorktreeHidden(projectId: "p", path: worktree.path))
        }
        #expect(projects.worktrees(projectId: "p") == [worktree])
        #expect(projects.operationState(for: worktree) == nil)
    }

    /// A worktree's review loop keeps a base picked in its pane while the
    /// configured base stays, and takes a new configured base when settings
    /// change it, so background refreshes do not query the old one.
    @Test func reviewLoopFollowsTheConfiguredBaseBranch() {
        let core = AlasCoreContext(projects: ProjectsManager(persistedProjects: []), runHistoryStore: nil, attentionStore: .scratch())
        let worktree = Worktree(
            id: "w", projectId: "p", name: "feature", branch: "feature",
            path: URL(fileURLWithPath: "/srv/feature"), status: .clean, lastActivity: .distantPast
        )
        core.reviewLoop(for: worktree, baseBranch: "main").updateBaseBranch("release")

        #expect(core.reviewLoop(for: worktree, baseBranch: "main").currentBaseBranch == "release")
        #expect(core.reviewLoop(for: worktree, baseBranch: "trunk").currentBaseBranch == "trunk")
    }

    /// A worktree removed or archived forgets its review status, so one
    /// restored or created again at its path is not shown the old one.
    @Test(arguments: [false, true])
    func reviewStatusIsForgottenWhenItsWorktreeLeaves(archived: Bool) async throws {
        let project = ProjectConfig(id: "p", name: "p", path: "/srv/repo", color: "blue", addedAt: .distantPast)
        let projects = ProjectsManager(persistedProjects: [project])
        let path = URL(fileURLWithPath: "/srv/feature")
        let worktree = Worktree(
            id: Worktree.makeId(path: path), projectId: "p", name: "feature", branch: "feature",
            path: path, status: .clean, lastActivity: .distantPast
        )
        projects.insertOptimisticWorktree(worktree)
        let host = AlasHost(core: AlasCoreContext(projects: projects, runHistoryStore: nil, attentionStore: .scratch()))
        let subscription = host.subscribe()
        defer { subscription.cancel() }
        // No remotes, so the read is local only.
        await host.core.reviewLoop(for: worktree, baseBranch: "main").refresh(local: ReviewLoopLocalState(
            branchName: "feature", headSHA: "abc", baseBranch: "main", hasWorkingTreeChanges: false,
            hasStagedChanges: false, aheadCommitCount: 1, hasUpstream: false, needsPush: true
        ), remotes: [])
        #expect(host.reviews.status(of: worktree.id) != nil)

        if archived {
            projects.setWorktreeHidden(projectId: "p", path: path, hidden: true)
        } else {
            projects.dropRemovedWorktree(id: worktree.id, projectId: "p")
        }

        try await eventually { @MainActor in host.reviews.status(of: worktree.id) == nil }
    }

    enum FollowEnd: CaseIterable {
        /// The last subscription following the worktree goes away.
        case lastFollowerCancels
        /// The worktree is removed while still followed.
        case worktreeRemoved
        /// The last follower's set of worktrees no longer includes it.
        case leftOutOfTheFollowedSet
    }

    /// A followed worktree's review status is read again at every interval
    /// while any subscription follows it, and the reads stop once the last
    /// follower lets go of it or the worktree is removed.
    @Test(arguments: FollowEnd.allCases)
    func followedReviewStatusRefreshesUntilItsFollowEnds(_ end: FollowEnd) async throws {
        let project = ProjectConfig(id: "p", name: "p", path: "/srv/repo", color: "blue", addedAt: .distantPast)
        let projects = ProjectsManager(persistedProjects: [project])
        let path = URL(fileURLWithPath: "/srv/feature")
        let worktree = Worktree(
            id: Worktree.makeId(path: path), projectId: "p", name: "feature", branch: "feature",
            path: path, status: .clean, lastActivity: .distantPast
        )
        projects.insertOptimisticWorktree(worktree)
        let core = AlasCoreContext(projects: projects, runHistoryStore: nil, attentionStore: .scratch())
        let probe = RefreshProbe()
        core.reviewStatusRefresh = { probe.refreshed.append($0) }
        core.reviewStatusPause = { _ in
            await withCheckedContinuation { probe.ticks.append($0) }
            probe.cancelledAtTick.append(Task.isCancelled)
        }
        let host = AlasHost(core: core)
        let first = host.subscribe()
        let second = host.subscribe()
        first.followWorktree(worktree.id)
        second.followWorktree(worktree.id)
        first.unfollowWorktree(worktree.id)

        try await eventually { @MainActor in probe.refreshed == [worktree.id] && probe.ticks.count == 1 }
        probe.ticks.removeFirst().resume()
        try await eventually { @MainActor in probe.refreshed.count == 2 && probe.ticks.count == 1 }

        switch end {
        case .lastFollowerCancels: second.cancel()
        case .worktreeRemoved: projects.dropRemovedWorktree(id: worktree.id, projectId: "p")
        case .leftOutOfTheFollowedSet: second.followWorktrees(exactly: [])
        }
        try await eventually { @MainActor in core.reviewRefreshes[worktree.id] == nil }
        probe.ticks.removeFirst().resume()
        try await eventually { @MainActor in probe.cancelledAtTick == [false, true] }
        #expect(probe.refreshed.count == 2)
    }

    /// A finished run's kept output is read back for its own project, and a
    /// run of another project is not found there.
    @Test func outputIsReadWithinTheRunsProject() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alas-run-output-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = ProjectsManager(persistedProjects: ["p1", "p2"].map {
            ProjectConfig(id: $0, name: $0, path: root.appendingPathComponent($0).path, color: "blue", addedAt: .distantPast)
        })
        for id in ["p1", "p2"] {
            projects.insertOptimisticWorktree(Worktree(
                id: "w-\(id)", projectId: id, name: id, branch: "main",
                path: root.appendingPathComponent(id), status: .clean, lastActivity: .distantPast
            ))
        }
        let history = try RunHistoryStore(path: root.appendingPathComponent("run-history.sqlite").path)
        for id in ["p1", "p2"] {
            _ = try await history.append(RunHistoryEntry(
                id: "run-\(id)", scriptKey: "dev", scriptName: "dev", worktreeID: "w-\(id)", branch: "main",
                target: RunExecutionTarget(host: nil, workingDirectory: root.path), endpoint: nil, outcome: .succeeded,
                startedAt: Date(timeIntervalSince1970: 1), finishedAt: Date(timeIntervalSince1970: 2), portConflict: nil,
                output: .available(text: "out \(id)\n", truncated: id == "p2")
            ))
        }
        let host = AlasHost(core: AlasCoreContext(projects: projects, runHistoryStore: history, attentionStore: .scratch()))

        #expect(await host.runs.output(of: "run-p1", projectID: "p1") == .text("out p1\n", truncated: false))
        #expect(await host.runs.output(of: "run-p2", projectID: "p1") == .unknownRun)
        // Only a tail was kept: the reader is told.
        #expect(await host.runs.output(of: "run-p2", projectID: "p2") == .text("out p2\n", truncated: true))
    }

    /// A headless host runs with its data directory's settings: its base
    /// branch and its registry agent, enabled, launchable and admitted, and
    /// not one the profile turned off.
    @Test func aHeadlessEnvironmentReadsItsDirectorysSettings() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("alas-boot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
            ACPLaunchCatalog.publishRegistryAgents([])
        }
        var config = AppConfig.defaults
        config.worktrees.baseBranch = "trunk"
        let agent = ACPRegistryInstalledAgent(
            registryID: "boot-fixture", displayName: "Fixture", version: "1",
            command: "/usr/bin/true", arguments: [], environment: [:], isEnabled: true
        )
        let disabled = ACPRegistryInstalledAgent(
            registryID: "boot-disabled", displayName: "Off", version: "1",
            command: "/usr/bin/true", arguments: [], environment: [:], isEnabled: false
        )
        config.agents.registry = [agent, disabled]
        try PersistenceStore().write(config, to: directory.appendingPathComponent("app.json"))

        let environment = HeadlessHostEnvironment(loadingFrom: directory)

        #expect(environment.configuration().worktrees.baseBranch == "trunk")
        #expect(environment.enabledAgents().contains { $0.id == agent.agentDefinition.id })
        #expect(ACPLaunchCatalog.spec(for: agent.agentDefinition.id) != nil)
        // A launch spec alone does not admit an agent the profile turned off.
        #expect(environment.admitsAgent(agent.agentDefinition.id, remoteHost: nil))
        #expect(!environment.admitsAgent(disabled.agentDefinition.id, remoteHost: nil))
    }

    /// An agent on a headless host can start a child session in a new
    /// worktree: it is created where its destination was recorded, and listed.
    @Test func aHeadlessHostCreatesADelegatedSessionsWorktree() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alas-delegated-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo")
        try GitTemplate.repository(at: repo)
        var config = AppConfig.defaults
        config.worktrees.rootPath = root.appendingPathComponent("worktrees").path
        let core = AlasCoreContext(
            projects: ProjectsManager(persistedProjects: []),
            projectsFile: root.appendingPathComponent("projects.json"),
            runHistoryStore: nil,
            workspaceStore: WorkspaceStore(url: root.appendingPathComponent("workspaces.json")),
            attentionStore: .scratch(),
            environment: HeadlessHostEnvironment(configuration: config)
        )
        let project = try await core.addProject(path: repo, displayName: "repo", icon: .default())
        let host = AlasHost(core: core)
        var recorded: URL?

        let result = await core.environment.createDelegatedWorktree(
            projectID: project.id, branch: "child", base: nil, recordDestination: { recorded = $0 }, in: core
        )

        guard case .success(let wt) = result else {
            Issue.record("expected a worktree, got \(result)")
            return
        }
        #expect(wt.branch == "child")
        #expect(recorded?.standardizedFileURL == wt.path.standardizedFileURL)
        #expect(host.worktrees.list().contains { $0.worktree.id == wt.id })
    }

    /// A host serves only its own process's data directory, so no store
    /// writes another profile's.
    @Test func bootRefusesAnotherProcesssDirectory() {
        let other = FileManager.default.temporaryDirectory.appendingPathComponent("alas-boot-\(UUID().uuidString)")
        #expect(throws: HostBootRefusal.notThisProcesssDirectory(other)) {
            _ = try AlasHost.boot(in: other)
        }
    }

    /// Once shutdown begins, nothing new starts: a run, a prompt or a
    /// worktree mutation a request was still on its way to is refused.
    @Test func aHostShuttingDownStartsNothingNew() async throws {
        let project = ProjectConfig(id: "p", name: "p", path: "/srv/repo", color: "blue", addedAt: .distantPast)
        let projects = ProjectsManager(persistedProjects: [project])
        let path = URL(fileURLWithPath: "/srv/feature")
        let worktree = Worktree(
            id: Worktree.makeId(path: path), projectId: "p", name: "feature", branch: "feature",
            path: path, status: .clean, lastActivity: .distantPast
        )
        projects.insertOptimisticWorktree(worktree)
        let host = AlasHost(core: AlasCoreContext(projects: projects, runHistoryStore: nil, attentionStore: .scratch()))
        let script = RunScript(
            scope: .repo, fileName: "dev.sh", fileURL: path.appendingPathComponent(".alas/scripts/dev.sh"),
            displayName: "Dev", onExit: .close, cwd: nil, isExecutable: true
        )

        await host.shutdown()

        #expect(host.runs.start(script, in: worktree, caller: .cli)
            == .refused(title: "Host stopping", message: "The host is stopping and starts no new runs."))
        await #expect(throws: SessionRefusal.ownerUnavailable(reason: "The host is stopping.")) {
            _ = try await host.sessions.submit("any", prompt: "hi", caller: .cli)
        }
        // Worktree mutations too: nothing Git or a repository hook would run.
        #expect(throws: HostStopping()) { _ = try host.worktrees.beginDelete(worktree, caller: .cli) }
        #expect(throws: HostStopping()) { try host.worktrees.unarchive(path: path, projectID: "p", caller: .cli) }
    }

    /// Shutdown ends the review refreshes of followed worktrees, and waits
    /// for one already reading rather than exiting under it.
    @Test func shutdownWaitsForAReviewRefreshUnderway() async throws {
        let project = ProjectConfig(id: "p", name: "p", path: "/srv/repo", color: "blue", addedAt: .distantPast)
        let projects = ProjectsManager(persistedProjects: [project])
        let path = URL(fileURLWithPath: "/srv/feature")
        let worktree = Worktree(
            id: Worktree.makeId(path: path), projectId: "p", name: "feature", branch: "feature",
            path: path, status: .clean, lastActivity: .distantPast
        )
        projects.insertOptimisticWorktree(worktree)
        let core = AlasCoreContext(projects: projects, runHistoryStore: nil, attentionStore: .scratch())
        let reading = AsyncStream<Void>.makeStream()
        // A Git or code-host call does not end when its task is cancelled.
        let probe = RefreshProbe()
        var rounds = 0
        core.reviewStatusRefresh = { _ in
            rounds += 1
            reading.continuation.yield()
            await withCheckedContinuation { probe.ticks.append($0) }
        }
        let host = AlasHost(core: core)
        let subscription = host.subscribe()
        subscription.followWorktree(worktree.id)
        for await _ in reading.stream { break }

        var shutdownFinished = false
        let shutdown = Task {
            await host.shutdown()
            shutdownFinished = true
        }
        for _ in 0..<50 { await Task.yield() }
        #expect(!shutdownFinished)
        probe.ticks.removeFirst().resume()
        await shutdown.value

        #expect(rounds == 1)
        #expect(core.reviewRefreshes.isEmpty)
    }

    /// A run a client stopped whose process has not exited yet (a script
    /// that delays its exit) is waited for at shutdown, not left behind.
    @Test func shutdownWaitsForAStoppedRunStillEnding() async throws {
        let project = ProjectConfig(id: "p", name: "p", path: "/srv/repo", color: "blue", addedAt: .distantPast)
        let projects = ProjectsManager(persistedProjects: [project])
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("alas-stopping-\(UUID().uuidString)")
        let scriptURL = path.appendingPathComponent(".alas/scripts/dev.sh")
        try FileManager.default.createDirectory(at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: scriptURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: path) }
        let worktree = Worktree(
            id: Worktree.makeId(path: path), projectId: "p", name: "feature", branch: "feature",
            path: path, status: .clean, lastActivity: .distantPast
        )
        projects.insertOptimisticWorktree(worktree)
        let environment = RunHoldingEnvironment()
        let host = AlasHost(core: AlasCoreContext(projects: projects, runHistoryStore: nil, attentionStore: .scratch(), environment: environment))
        let script = RunScript(
            scope: .repo, fileName: "dev.sh", fileURL: scriptURL,
            displayName: "Dev", onExit: .close, cwd: nil, isExecutable: true
        )
        let start = host.runs.start(script, in: worktree, caller: .cli)
        guard case .started = start else {
            Issue.record("expected the run to start, got \(start)")
            return
        }
        for await _ in environment.launcher.launched.stream { break }
        host.runs.stop(scriptKey: script.key, in: worktree, caller: .cli)

        var shutdownFinished = false
        let shutdown = Task {
            await host.shutdown()
            shutdownFinished = true
        }
        for _ in 0..<50 { await Task.yield() }
        #expect(!shutdownFinished)
        environment.launcher.held.removeFirst().resume()
        await shutdown.value
        #expect(shutdownFinished)
    }

    /// Changes made after a snapshot reach a subscriber holding its cursor,
    /// each with its latest state; what the snapshot already shows does not.
    @Test func subscribersSeeChangesAfterTheirSnapshot() async throws {
        let project = ProjectConfig(id: "p", name: "p", path: "/srv/repo", color: "blue", addedAt: .distantPast)
        let projects = ProjectsManager(persistedProjects: [project])
        let shown = Self.worktree("shown")
        let removed = Self.worktree("removed")
        projects.insertOptimisticWorktree(shown)
        projects.insertOptimisticWorktree(removed)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(url: directory.appendingPathComponent("workspaces.json"))
        let host = AlasHost(core: AlasCoreContext(projects: projects, runHistoryStore: nil, workspaceStore: store, attentionStore: .scratch()))

        let snapshot = try await host.snapshot()
        let subscription = host.subscribe(after: snapshot.cursor)
        projects.setOperationState(for: shown, state: .preparingDelete)
        projects.setOperationState(for: shown, state: .deleting(projectId: "p"))
        projects.removeOptimisticWorktree(id: removed.id, projectId: "p")
        let events = try #require(await Self.next(subscription))
        #expect(events.count == 2)
        #expect(events.contains(.worktreeChanged(WorktreeSnapshot(worktree: shown, operation: .deleting, isArchived: false))))
        #expect(events.contains(.worktreeRemoved(projectID: "p", worktreeID: removed.id)))

        let checkout = WorkspaceCheckout(
            workspaceID: nil, fallbackWorkspaceName: "w", executionLocation: .local,
            branch: "b", rootPath: "/srv/w", createdAt: .distantPast, members: []
        )
        try await store.mutate { $0.checkouts = [checkout] }
        #expect(await Self.next(subscription) == [.workspaceCheckoutChanged(WorkspaceAutomationService.summary(checkout))])
        try await store.mutate { $0.checkouts = [] }
        #expect(await Self.next(subscription) == [.workspaceCheckoutRemoved(id: checkout.id)])
    }

    /// Events a subscriber has not read yet coalesce per key, oldest key
    /// first, and the batch's cursor is the last event it covers, so a
    /// client that reconnects after it misses nothing and repeats nothing.
    @Test func unreadEventsCoalescePerKey() async {
        let log = HostEventLog()
        let subscription = log.subscribe(after: log.cursor)
        log.publish([.runRemoved(id: "a"), .projectRemoved(id: "p")])
        log.publish([.runRemoved(id: "b"), .projectRemoved(id: "p"), .runRemoved(id: "a")])
        #expect(await Self.next(subscription) == [.runRemoved(id: "a"), .projectRemoved(id: "p"), .runRemoved(id: "b")])
        #expect(subscription.cursor == log.cursor)

        subscription.cancel()
        log.publish([.runRemoved(id: "c")])
        #expect(await Self.next(log.subscribe(after: subscription.cursor)) == [.runRemoved(id: "c")])
    }

    /// A subscriber that falls too far behind, or asks for events the log no
    /// longer keeps or never issued, is told to resync instead.
    @Test func laggingSubscribersResync() async {
        let log = HostEventLog(retention: 2, pendingLimit: 2)
        let slow = log.subscribe(after: log.cursor)
        let start = log.cursor
        log.publish([.runRemoved(id: "a"), .runRemoved(id: "b"), .runRemoved(id: "c")])
        #expect(await Self.next(slow) == [.resync])
        #expect(await Self.next(log.subscribe(after: start)) == [.resync])

        let caughtUp = log.cursor
        log.publish([.runRemoved(id: "d")])
        #expect(await Self.next(log.subscribe(after: caughtUp)) == [.runRemoved(id: "d")])

        // A cursor from another log, such as the host's before a restart,
        // is never taken for one of this log's.
        let restarted = HostEventLog()
        restarted.publish([.runRemoved(id: "e")])
        #expect(await Self.next(restarted.subscribe(after: start)) == [.resync])
    }

    /// Sessions join the host's list and events, keyed by their owner.
    @Test func sessionsAreListedAndAnnounced() async throws {
        let project = ProjectConfig(id: "p", name: "p", path: "/srv/repo", color: "blue", addedAt: .distantPast)
        let projects = ProjectsManager(persistedProjects: [project])
        let shown = Self.worktree("shown")
        projects.insertOptimisticWorktree(shown)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let core = AlasCoreContext(
            projects: projects,
            runHistoryStore: nil,
            workspaceStore: WorkspaceStore(url: directory.appendingPathComponent("workspaces.json")),
            attentionStore: .scratch(),
            makeSessionManager: { owner, worktree in
                ACPSessionManager(
                    worktreeId: worktree.id,
                    worktreePath: worktree.path.path,
                    owner: owner,
                    persistence: ACPSessionPersistence(path: directory.appendingPathComponent("sessions.sqlite").path)
                )
            }
        )
        let host = AlasHost(core: core)
        let subscription = host.subscribe(after: try await host.snapshot().cursor)
        let owner = SessionOwnerID.worktree(shown.id)

        let manager = try core.sessionManager(for: shown)
        _ = manager.createSession(id: "s", agentId: "codex")
        // The manager's first read of its store may land after the session
        // exists and before its row is saved; the session stays listed.
        await manager.refreshRecentNow()
        let created = try #require(await Self.next(subscription) { events in
            events.contains { if case .sessionChanged(let summary) = $0 { summary.id == "s" } else { false } }
        })
        #expect(host.sessions.list().map(\.id) == ["s"])
        #expect(created.contains { if case .sessionChanged(let summary) = $0 { summary.owner == owner } else { false } })

        try await manager.deleteSession(id: "s")
        #expect(await Self.next(subscription) { $0.contains(.sessionRemoved(owner: owner, id: "s")) } != nil)
        #expect(host.sessions.list().isEmpty)
    }

    /// Archiving takes a while to stop everything in a worktree; a checkout
    /// another process switches meanwhile is refused instead of hidden.
    @Test func archivingRefusesACheckoutChangedWhileItStops() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alas-archive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "maintenance.auto", "false"], ["commit", "-q", "--allow-empty", "-m", "init"]] {
            let result = try await Process.git(args, cwd: repo)
            guard result.exitCode == 0 else { throw ProcessError.nonZeroExit(result.exitCode, result.stderr) }
        }
        let environment = SwitchingEnvironment()
        let core = AlasCoreContext(
            projects: ProjectsManager(persistedProjects: []),
            projectsFile: root.appendingPathComponent("projects.json"),
            runHistoryStore: nil,
            workspaceStore: WorkspaceStore(url: root.appendingPathComponent("workspaces.json")),
            attentionStore: .scratch(),
            environment: environment
        )
        let project = try await core.addProject(path: repo, displayName: "repo", icon: .default())
        let worktree = try await core.createWorktree(
            projectID: project.id, branch: "feature", base: "main", destination: root.appendingPathComponent("feature")
        )
        environment.onQuiesce = { worktree in
            _ = try? await Process.git(["switch", "-q", "-c", "other"], cwd: worktree.path)
        }

        await #expect(throws: WorktreeArchiveRefusal.changed("The checkout is on another branch")) {
            try await core.archiveWorktree(worktree, verifiesCheckout: true)
        }
        #expect(!core.projects.isWorktreeHidden(projectId: project.id, path: worktree.path))
    }

    private static func worktree(_ name: String) -> Worktree {
        let path = URL(fileURLWithPath: "/srv/\(name)")
        return Worktree(
            id: Worktree.makeId(path: path), projectId: "p", name: name, branch: name,
            path: path, status: .clean, lastActivity: .distantPast
        )
    }

    /// The subscription's next batch, or nil if none arrives in time.
    private static func next(_ subscription: HostSubscription) async -> [HostEvent]? {
        await next(subscription) { _ in true }
    }

    /// The first batch `matches` accepts, skipping others, or nil if none
    /// arrives in time.
    private static func next(_ subscription: HostSubscription, where matches: ([HostEvent]) -> Bool) async -> [HostEvent]? {
        let timeout = Task { @MainActor in
            try await Task.sleep(for: .seconds(5))
            subscription.cancel()
        }
        defer { timeout.cancel() }
        while let events = await subscription.next() {
            if matches(events) { return events }
        }
        return nil
    }
}

/// Runs `onQuiesce` where the host stops everything in a worktree.
@MainActor
private final class SwitchingEnvironment: AlasHostEnvironment {
    var onQuiesce: (Worktree) async -> Void = { _ in }

    func quiesceWorktree(_ worktree: Worktree, in core: AlasCoreContext) async throws {
        await onQuiesce(worktree)
    }
}

/// Refuses deletions as the app's Workspace checkouts and editors would.
@MainActor
private final class CheckingEnvironment: AlasHostEnvironment {
    var workspaceRefusal: String?
    var unsavedEdits = false

    func workspaceDeletionRefusal(for worktree: Worktree) -> String? { workspaceRefusal }
    func hasUnsavedEditorChanges(in worktree: Worktree) -> Bool { unsavedEdits }
}

/// Records each review status read, and holds each wait between reads
/// until the test resumes it.
@MainActor
private final class RefreshProbe {
    var refreshed: [String] = []
    var ticks: [CheckedContinuation<Void, Never>] = []
    var cancelledAtTick: [Bool] = []
}

/// Launches runs whose process outlives its cancellation until the test
/// lets it end, as a script that delays its exit does.
@MainActor
private final class HeldRunLauncher: RunLauncher {
    let launched = AsyncStream<Void>.makeStream()
    var held: [CheckedContinuation<Void, Never>] = []

    func launch(_ request: RunLaunchRequest, in core: AlasCoreContext) async throws -> RunLaunch {
        .process(Task { @MainActor in
            self.launched.continuation.yield()
            await withCheckedContinuation { self.held.append($0) }
            return RunScriptCompletion(exitCode: 0, transcript: nil, truncated: false)
        })
    }

    func runDidFinish(_ record: RunRecord, completion: RunScriptCompletion, script: RunScript, worktree: Worktree, sessionID: String?) {}
}

@MainActor
private final class RunHoldingEnvironment: AlasHostEnvironment {
    let launcher = HeldRunLauncher()
    var runLauncher: any RunLauncher { launcher }
}
