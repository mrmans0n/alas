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
            WorktreeSnapshot(worktree: busy, operation: .deleting(projectId: "p"), isArchived: false),
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
        #expect(events.contains(.worktreeChanged(WorktreeSnapshot(worktree: shown, operation: .deleting(projectId: "p"), isArchived: false))))
        #expect(events.contains(.worktreeRemoved(projectID: "p", worktreeID: removed.id)))

        let checkout = WorkspaceCheckout(
            workspaceID: nil, fallbackWorkspaceName: "w", executionLocation: .local,
            branch: "b", rootPath: "/srv/w", createdAt: .distantPast, members: []
        )
        try await store.mutate { $0.checkouts = [checkout] }
        #expect(await Self.next(subscription) == [.workspaceCheckoutChanged(checkout)])
        try await store.mutate { $0.checkouts = [] }
        #expect(await Self.next(subscription) == [.workspaceCheckoutRemoved(id: checkout.id)])
    }

    /// Events a subscriber has not read yet coalesce per key, oldest key first.
    @Test func unreadEventsCoalescePerKey() async {
        let log = HostEventLog()
        let subscription = log.subscribe(after: log.cursor)
        log.publish([.runRemoved(id: "a"), .projectRemoved(id: "p")])
        log.publish([.runRemoved(id: "b"), .projectRemoved(id: "p"), .runRemoved(id: "a")])
        #expect(await Self.next(subscription) == [.runRemoved(id: "a"), .projectRemoved(id: "p"), .runRemoved(id: "b")])
    }

    /// A subscriber that falls too far behind, or asks for events the log no
    /// longer keeps, is told to resync instead.
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
        let timeout = Task { @MainActor in
            try await Task.sleep(for: .seconds(5))
            subscription.cancel()
        }
        defer { timeout.cancel() }
        return await subscription.next()
    }
}
