import Foundation

/// Loads local inventories independently of right-pane activation. Network
/// work goes through the same inbox store used by the tab, not a second feed.
@MainActor
final class GGSidebarRefreshController {
    struct Worktree: Equatable {
        let path: String
        let stackName: String?
    }

    struct Project: Equatable {
        let id: String
        let path: String
        let worktrees: [Worktree]
        var ambiguousStackNames: Set<String> = []
    }

    private let summaries: GGStackSummaryStore
    private let inbox: GGInboxStore
    private let load: (String) async throws -> GGStack?
    private let refreshInbox: (String, String) async -> Void
    private let now: () -> Date
    private let debounce: Duration
    private var projects: [String: Project] = [:]
    private var generations: [String: UInt64] = [:]
    private var pending: Set<String> = []
    private var tasks: [String: Task<Void, Never>] = [:]
    private var attemptedAt: [String: Date] = [:]

    init(
        summaries: GGStackSummaryStore = .shared,
        inbox: GGInboxStore = .shared,
        service: GGService = GGService(),
        debounce: Duration = .milliseconds(250),
        now: @escaping () -> Date = Date.init,
        load: ((String) async throws -> GGStack?)? = nil,
        refreshInbox: ((String, String) async -> Void)? = nil
    ) {
        self.summaries = summaries
        self.inbox = inbox
        self.debounce = debounce
        self.now = now
        self.load = load ?? { try await service.currentStack(worktreePath: $0, refreshRemote: false) }
        self.refreshInbox = refreshInbox ?? { id, path in
            await inbox.refreshIfStale(projectId: id, repoPath: path, service: service)
        }
        inbox.onInvalidation = { [weak self] id in self?.invalidate(projectId: id) }
    }

    func refresh(projects requested: [Project]) {
        let next = Dictionary(uniqueKeysWithValues: requested.map { ($0.id, $0) })
        for id in projects.keys where next[id] == nil {
            generations[id, default: 0] &+= 1
            pending.remove(id)
            attemptedAt[id] = nil
            tasks[id]?.cancel()
        }
        for project in requested {
            if projects[project.id] != project {
                if let previous = projects[project.id], previous.path != project.path {
                    tasks[project.id]?.cancel()
                    inbox.remove(projectId: project.id)
                    summaries.remove(projectId: project.id)
                }
                generations[project.id, default: 0] &+= 1
                pending.insert(project.id)
            } else if tasks[project.id] == nil,
                      GGInboxStore.isStale(fetchedAt: attemptedAt[project.id], now: now()) {
                pending.insert(project.id)
            }
            for worktree in project.worktrees {
                summaries.prepare(path: worktree.path, projectId: project.id, stackName: worktree.stackName)
            }
        }
        projects = next
        summaries.retainManagedPaths(Set(requested.flatMap { $0.worktrees.map(\.path) }))
        startPending()
    }

    /// Also called when a mutation invalidates the inbox while its tab is closed.
    private func invalidate(projectId: String) {
        guard projects[projectId] != nil else { return }
        generations[projectId, default: 0] &+= 1
        pending.insert(projectId)
        startPending()
    }

    private func startPending() {
        // Each gg inbox itself has four PR workers. Bound project concurrency
        // too so a large sidebar cannot multiply this without limit.
        for id in pending.sorted() where tasks.count < 2 && tasks[id] == nil {
            guard let project = projects[id] else { continue }
            pending.remove(id)
            tasks[id] = Task { [weak self] in
                guard let self else { return }
                do { try await Task.sleep(for: debounce) } catch {
                    tasks[id] = nil
                    startPending()
                    return
                }
                // Read generation after debounce so a burst is one scan.
                let generation = generations[id, default: 0]
                pending.remove(id)
                let current = projects[id] ?? project
                await refresh(current, generation: generation)
                tasks[id] = nil
                startPending()
            }
        }
    }

    private func refresh(_ project: Project, generation: UInt64) async {
        attemptedAt[project.id] = now()
        for worktree in project.worktrees {
            do {
                let stack = try await load(worktree.path)
                guard isCurrent(project, generation: generation) else { return }
                summaries.update(
                    path: worktree.path, projectId: project.id,
                    stackName: worktree.stackName,
                    stack: stack.flatMap { project.ambiguousStackNames.contains($0.name) ? nil : $0 }
                )
            } catch {
                // Keep a known local inventory on transient failures.
                guard isCurrent(project, generation: generation) else { return }
            }
        }
        guard isCurrent(project, generation: generation),
              GGInboxStore.isStale(fetchedAt: inbox.states[project.id]?.fetchedAt, now: now()) else { return }
        await refreshInbox(project.id, project.path)
    }

    private func isCurrent(_ project: Project, generation: UInt64) -> Bool {
        !Task.isCancelled && projects[project.id] == project && generations[project.id, default: 0] == generation
    }
}
