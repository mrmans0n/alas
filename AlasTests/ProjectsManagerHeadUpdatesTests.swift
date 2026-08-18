import Testing
import Foundation
@testable import Alas

@MainActor
struct ProjectsManagerHeadUpdatesTests {
    private struct MemoryStore: PersistenceStoreProtocol {
        var projectsFile: ProjectsFile

        func write<T: Encodable>(_ value: T, to url: URL) throws {}

        func readIfExists<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
            if type == ProjectsFile.self { return projectsFile as? T }
            if type == AppConfig.self { return AppConfig.defaults as? T }
            return nil
        }
    }

    private func makeManager() -> (ProjectsManager, ProjectConfig) {
        let project = ProjectConfig(
            id: "p1",
            name: "p1",
            path: "/repo",
            color: "blue",
            addedAt: Date()
        )
        let mgr = ProjectsManager(persistedProjects: [project])
        return (mgr, project)
    }

    private func seed(_ mgr: ProjectsManager, projectId: String, _ wts: [Worktree]) {
        for wt in wts { mgr.insertOptimisticWorktree(wt) }
        // insertOptimisticWorktree is the only public seed API; clear any
        // operation state it implicitly leaves so updates apply.
        for wt in wts { mgr.setOperationState(id: wt.id, state: nil) }
    }

    private func wt(path: String, branch: String, projectId: String = "p1") -> Worktree {
        let url = URL(fileURLWithPath: path)
        return Worktree(
            id: Worktree.makeId(path: url),
            projectId: projectId,
            name: branch,
            branch: branch,
            path: url,
            status: .clean,
            lastActivity: Date()
        )
    }

    @Test func updatesBranchForMatchingPath() {
        let (mgr, project) = makeManager()
        seed(mgr, projectId: project.id, [
            wt(path: "/repo", branch: "main"),
            wt(path: "/wts/feat", branch: "feat/foo"),
        ])

        mgr.applyHeadUpdates(
            projectId: project.id,
            branchByWorktreePath: [
                URL(fileURLWithPath: "/wts/feat"): "feat/bar"
            ]
        )

        let trees = mgr.worktrees(projectId: project.id)
        #expect(trees.first { $0.path.path == "/repo" }?.branch == "main")
        #expect(trees.first { $0.path.path == "/wts/feat" }?.branch == "feat/bar")
        #expect(trees.first { $0.path.path == "/wts/feat" }?.name == "feat/bar")
    }

    @Test func ignoresUnknownPaths() {
        let (mgr, project) = makeManager()
        seed(mgr, projectId: project.id, [wt(path: "/repo", branch: "main")])

        mgr.applyHeadUpdates(
            projectId: project.id,
            branchByWorktreePath: [
                URL(fileURLWithPath: "/wts/ghost"): "x"
            ]
        )

        #expect(mgr.worktrees(projectId: project.id).count == 1)
        #expect(mgr.worktrees(projectId: project.id).first?.branch == "main")
    }

    @Test func skipsRowsInCreatingState() {
        let (mgr, project) = makeManager()
        let row = wt(path: "/wts/feat", branch: "feat/intent")
        seed(mgr, projectId: project.id, [row])
        mgr.setOperationState(id: row.id, state: .creating)

        mgr.applyHeadUpdates(
            projectId: project.id,
            branchByWorktreePath: [row.path: "feat/disk"]
        )

        // Optimistic intent must win over disk truth while creating.
        #expect(mgr.worktrees(projectId: project.id).first?.branch == "feat/intent")
    }

    @Test func skipsRowsInCreateFailedState() {
        let (mgr, project) = makeManager()
        let row = wt(path: "/wts/feat", branch: "feat/intent")
        seed(mgr, projectId: project.id, [row])
        mgr.setOperationState(
            id: row.id,
            state: .createFailed(
                projectId: project.id,
                message: "x",
                base: "main",
                ggWorktreeMode: .inherit,
                launchSurface: .none,
                issueAttachment: nil
            )
        )

        mgr.applyHeadUpdates(
            projectId: project.id,
            branchByWorktreePath: [row.path: "feat/disk"]
        )
        #expect(mgr.worktrees(projectId: project.id).first?.branch == "feat/intent")
    }

    @Test func updatesRowsInDeletingState() {
        // .deleting / .deleteFailed correspond to real git worktrees that
        // happen to have a pending UI op; the branch label is still git's
        // truth and should refresh.
        let (mgr, project) = makeManager()
        let row = wt(path: "/wts/feat", branch: "old")
        seed(mgr, projectId: project.id, [row])
        mgr.setOperationState(id: row.id, state: .deleting)

        mgr.applyHeadUpdates(
            projectId: project.id,
            branchByWorktreePath: [row.path: "new"]
        )
        #expect(mgr.worktrees(projectId: project.id).first?.branch == "new")
    }

    @Test func unknownProjectIdIsNoop() {
        let (mgr, _) = makeManager()
        mgr.applyHeadUpdates(
            projectId: "does-not-exist",
            branchByWorktreePath: [URL(fileURLWithPath: "/x"): "y"]
        )
        // No crash, no state change. Nothing to assert beyond that.
    }

    @Test func appStateHeadUpdatesInvalidateFollowersAcrossProject() {
        let project = ProjectConfig(
            id: "p1",
            name: "p1",
            path: "/repo",
            color: "blue",
            addedAt: Date()
        )
        let state = AppState(store: MemoryStore(projectsFile: ProjectsFile(projects: [project])))
        let main = wt(path: "/repo", branch: "main")
        let linked = wt(path: "/wts/feature", branch: "feature")
        seed(state.projectsManager, projectId: project.id, [main, linked])

        state.handleProjectHeadUpdates(
            projectId: project.id,
            branchByWorktreePath: [main.path: "main-updated"]
        )

        #expect(state.revisionChangeGeneration(worktreeID: main.id) == 1)
        #expect(state.revisionChangeGeneration(worktreeID: linked.id) == 1)
        #expect(state.projectsManager.worktrees(projectId: project.id).first { $0.id == main.id }?.branch == "main-updated")
        #expect(state.projectsManager.worktrees(projectId: project.id).first { $0.id == linked.id }?.branch == "feature")
    }

    /// A follower's `.task(id:)` can restart on the synchronous generation
    /// bump before the async `GGStackCache` invalidation lands, and read a
    /// stale stack. The generation must bump again once invalidation
    /// actually completes so that follower gets a guaranteed-fresh reload.
    @Test func headUpdatesRebumpGenerationAfterCacheInvalidationCompletes() async throws {
        let project = ProjectConfig(
            id: "p1",
            name: "p1",
            path: "/repo",
            color: "blue",
            addedAt: Date()
        )
        let state = AppState(store: MemoryStore(projectsFile: ProjectsFile(projects: [project])))
        let main = wt(path: "/repo", branch: "main")
        seed(state.projectsManager, projectId: project.id, [main])

        state.handleProjectHeadUpdates(
            projectId: project.id,
            branchByWorktreePath: [main.path: "main-updated"]
        )
        #expect(state.revisionChangeGeneration(worktreeID: main.id) == 1)

        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(state.revisionChangeGeneration(worktreeID: main.id) == 2)
    }

    @Test func revisionWatcherInvalidatesGGStackCache() async throws {
        let project = ProjectConfig(
            id: "p1",
            name: "p1",
            path: "/repo",
            color: "blue",
            addedAt: Date()
        )
        let main = wt(path: "/repo", branch: "main")
        let gitDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-app-state-watcher-\(UUID().uuidString)/.git")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: gitDir.deletingLastPathComponent()) }

        let watcher = ProjectGitWatcher(
            repoPath: URL(fileURLWithPath: project.path),
            resolvedGitDir: gitDir,
            resolvedWorktreeRoot: main.path,
            headDebounceInterval: 0.05,
            headDebounceMaxWait: 0.2,
            topologyDebounceInterval: 0.05,
            topologyDebounceMaxWait: 0.2,
            startStreamOverride: { _, _ in }
        )
        let state = AppState(
            store: MemoryStore(projectsFile: ProjectsFile(projects: [project])),
            projectGitWatcherFactory: { _ in watcher }
        )
        seed(state.projectsManager, projectId: project.id, [main])

        actor LoadCounter {
            var count = 0
            func increment() { count += 1 }
        }
        let loads = LoadCounter()
        let cachePath = gitDir.appendingPathComponent("worktree")
        let stack = GGStack(
            name: "stack",
            base: "main",
            totalCommits: 1,
            syncedCommits: 0,
            currentPosition: 1,
            behindBase: 0,
            entries: []
        )

        await GGStackCache.shared.invalidate()
        defer { Task { await GGStackCache.shared.invalidate() } }
        _ = try await GGStackCache.shared.stack(at: cachePath) {
            await loads.increment()
            return stack
        }

        state.startProjectGitWatcher(for: project)
        watcher.processEvents([gitDir.appendingPathComponent("refs/heads/main").path])
        try await Task.sleep(nanoseconds: 50_000_000)

        _ = try await GGStackCache.shared.stack(at: cachePath) {
            await loads.increment()
            return stack
        }
        #expect(await loads.count == 2)
        state.stopProjectGitWatcher(projectId: project.id)
    }

    @Test func fetchHeadRevisionDoesNotInvalidateGGStackCache() async throws {
        let project = ProjectConfig(
            id: "p1",
            name: "p1",
            path: "/repo",
            color: "blue",
            addedAt: Date()
        )
        let main = wt(path: "/repo", branch: "main")
        let gitDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-app-state-fetch-head-\(UUID().uuidString)/.git")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: gitDir.deletingLastPathComponent()) }

        let watcher = ProjectGitWatcher(
            repoPath: URL(fileURLWithPath: project.path),
            resolvedGitDir: gitDir,
            resolvedWorktreeRoot: main.path,
            headDebounceInterval: 0.05,
            headDebounceMaxWait: 0.2,
            topologyDebounceInterval: 0.05,
            topologyDebounceMaxWait: 0.2,
            startStreamOverride: { _, _ in }
        )
        let state = AppState(
            store: MemoryStore(projectsFile: ProjectsFile(projects: [project])),
            projectGitWatcherFactory: { _ in watcher }
        )
        seed(state.projectsManager, projectId: project.id, [main])

        actor LoadCounter {
            var count = 0
            func increment() { count += 1 }
        }
        let loads = LoadCounter()
        let cachePath = gitDir.appendingPathComponent("worktree")
        let stack = GGStack(
            name: "stack",
            base: "main",
            totalCommits: 1,
            syncedCommits: 0,
            currentPosition: 1,
            behindBase: 0,
            entries: []
        )

        await GGStackCache.shared.invalidate()
        defer { Task { await GGStackCache.shared.invalidate() } }
        _ = try await GGStackCache.shared.stack(at: cachePath) {
            await loads.increment()
            return stack
        }

        state.startProjectGitWatcher(for: project)
        watcher.processEvents([gitDir.appendingPathComponent("FETCH_HEAD").path])
        try await Task.sleep(nanoseconds: 50_000_000)

        _ = try await GGStackCache.shared.stack(at: cachePath) {
            await loads.increment()
            return stack
        }
        #expect(state.revisionChangeGeneration(worktreeID: main.id) == 1)
        #expect(await loads.count == 1)
        state.stopProjectGitWatcher(projectId: project.id)
    }
}
