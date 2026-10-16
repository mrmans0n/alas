import Foundation
import Testing
@_spi(Testing) @testable import AlasCore

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
        let host = AlasHost(core: AlasCoreContext(projects: projects, runHistoryStore: nil))

        #expect(host.worktrees.list() == [
            WorktreeSnapshot(worktree: busy, operation: .deleting, isArchived: false),
        ])
        #expect(Set(host.worktrees.list(includingArchived: true).map(\.worktree.id)) == [busy.id, archived.id])
        #expect(host.worktrees.list(includingArchived: true).first { $0.worktree.id == archived.id }?.isArchived == true)
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
        let host = AlasHost(core: AlasCoreContext(projects: projects, runHistoryStore: nil, workspaceStore: store))

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
