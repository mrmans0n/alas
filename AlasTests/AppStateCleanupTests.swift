import Testing
import Foundation
@testable import Alas

@Suite(.serialized)
@MainActor
struct AppStateCleanupTests {
    enum AnchorRefreshPath {
        case refreshAll
        case clearProjectsWithoutWorktrees
    }

    private struct MemoryStore: PersistenceStoreProtocol {
        var config: AppConfig? = nil
        var projectsFile: ProjectsFile? = nil

        func write<T: Encodable>(_: T, to _: URL) throws {}

        func readIfExists<T: Decodable>(_: T.Type, from _: URL) throws -> T? {
            if T.self == AppConfig.self {
                return config as? T
            }
            if T.self == ProjectsFile.self {
                return projectsFile as? T
            }
            return nil
        }
    }

    private final class RecordingStore: PersistenceStoreProtocol, @unchecked Sendable {
        var writtenProjectsFile: ProjectsFile?

        func write<T: Encodable>(_ value: T, to _: URL) throws {
            if let projectsFile = value as? ProjectsFile {
                writtenProjectsFile = projectsFile
            }
        }

        func readIfExists<T: Decodable>(_: T.Type, from _: URL) throws -> T? {
            nil
        }
    }

    private func makeRepo(name: String) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-cleanup-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: dir)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "init"], cwd: dir)
        return dir
    }

    @Test func piMCPExcludeRetriesForUnchangedManagedConfig() {
        #expect(AppState.piMCPGeneratedConfigExcludePath == ".pi/mcp.json")
        #expect(AppState.shouldExcludePiDirectory(after: .wrote))
        #expect(AppState.shouldExcludePiDirectory(after: .unchanged))
        #expect(!AppState.shouldExcludePiDirectory(after: .failed))
        #expect(!AppState.shouldExcludePiDirectory(after: .refusedUnmanaged))
        #expect(!AppState.shouldExcludePiDirectory(after: .removedManaged))
        #expect(!AppState.shouldExcludePiDirectory(after: .noServers))
    }

    @Test func allWorktreeIdsReturnsIdsAfterRefresh() async throws {
        let repo = try await makeRepo(name: "all-ids")
        defer { try? FileManager.default.removeItem(at: repo) }

        let state = AppState()
        let project = try await state.projectsManager.addProject(
            path: repo, displayName: "test", color: "#5fb7c4"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)

        let ids = state.allWorktreeIds()
        let trees = state.projectsManager.worktrees(projectId: project.id)
        #expect(!ids.isEmpty)
        #expect(ids == Set(trees.map(\.id)))
    }

    @Test func topologyRefreshReevaluatesCachedGGGateAfterPromotingRecoveredMode() async throws {
        let repo = try await makeRepo(name: "recovered-gg-gate")
        defer { try? FileManager.default.removeItem(at: repo) }
        let state = AppState(store: MemoryStore())
        let project = try await state.projectsManager.addProject(
            path: repo,
            displayName: "recovered-gg-gate",
            color: "#5fb7c4"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        let worktree = try #require(state.projectsManager.worktrees(projectId: project.id).first)
        let pane = state.rightPaneStore.state(
            for: worktree,
            baseBranch: state.config.worktrees.baseBranch,
            comparisonMode: state.config.changes.comparisonMode
        )
        state.rightPaneStore.deactivate()
        pane.baseBranchProbeTask?.cancel()
        pane.baseBranchProbeTask = nil

        var gateEvaluationCount = 0
        pane.ggContextProvider = { _ in
            gateEvaluationCount += 1
            return .inactive(reason: .policyOff)
        }
        await pane.reevaluateGGGate().value
        pane.stop()
        try await Task.sleep(for: .milliseconds(250))
        pane.stop()
        gateEvaluationCount = 0

        state.projectsManager.setOperationState(
            id: worktree.id,
            state: .createFailed(
                projectId: project.id,
                message: "transient",
                base: "main",
                ggWorktreeMode: .off
            )
        )

        await state.refreshProjectTopology(projectId: project.id)
        for _ in 0..<20 where gateEvaluationCount == 0 {
            await Task.yield()
        }

        #expect(state.projectsManager.ggWorktreeMode(
            projectId: project.id,
            worktreeId: worktree.id
        ) == .off)
        #expect(gateEvaluationCount == 1)
    }

    @Test func allWorktreeIdsEmptyBeforeRefresh() async throws {
        let repo = try await makeRepo(name: "empty-ids")
        defer { try? FileManager.default.removeItem(at: repo) }

        let state = AppState()
        _ = try await state.projectsManager.addProject(
            path: repo, displayName: "test", color: "#5fb7c4"
        )

        let ids = state.allWorktreeIds()
        #expect(ids.isEmpty)
    }

    @Test func cleanupMissingWorktreesClosesTabsForDisappearedWorktree() async throws {
        let repo = try await makeRepo(name: "cleanup-tabs")
        defer { try? FileManager.default.removeItem(at: repo) }

        let state = AppState()
        let project = try await state.projectsManager.addProject(
            path: repo, displayName: "cleanup", color: "#5fb7c4"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)

        let trees = state.projectsManager.worktrees(projectId: project.id)
        #expect(trees.count == 1)
        let wt = trees[0]

        state.tabs.appendTerminal(worktreeId: wt.id, title: "term", sessionId: "s1")
        #expect(state.tabs.tabs(forWorktree: wt.id).count == 1)

        let beforeIds = state.allWorktreeIds()
        #expect(beforeIds.contains(wt.id))

        state.projectsManager.removeProject(id: project.id)
        #expect(state.allWorktreeIds().isEmpty)

        state.cleanupMissingWorktrees(beforeIds: beforeIds)

        #expect(state.tabs.tabs(forWorktree: wt.id).isEmpty)
    }

    @Test func cleanupMissingWorktreesResetsSelection() async throws {
        let repoA = try await makeRepo(name: "sel-a")
        let repoB = try await makeRepo(name: "sel-b")
        defer {
            try? FileManager.default.removeItem(at: repoA)
            try? FileManager.default.removeItem(at: repoB)
        }

        let state = AppState()
        let projectA = try await state.projectsManager.addProject(
            path: repoA, displayName: "projA", color: "#5fb7c4"
        )
        let projectB = try await state.projectsManager.addProject(
            path: repoB, displayName: "projB", color: "#c89d6f"
        )
        try await state.projectsManager.refreshWorktrees(projectId: projectA.id)
        try await state.projectsManager.refreshWorktrees(projectId: projectB.id)

        let treesA = state.projectsManager.worktrees(projectId: projectA.id)
        let treesB = state.projectsManager.worktrees(projectId: projectB.id)
        #expect(treesA.count == 1)
        #expect(treesB.count == 1)

        state.selectedWorktreeId = treesA[0].id
        #expect(state.selectedWorktreeId == treesA[0].id)

        let beforeIds = state.allWorktreeIds()

        state.projectsManager.removeProject(id: projectA.id)
        #expect(!state.allWorktreeIds().contains(treesA[0].id))

        state.cleanupMissingWorktrees(beforeIds: beforeIds)

        #expect(state.selectedWorktreeId == treesB[0].id)
    }

    @Test func cleanupMissingWorktreesPreservesExistingWorktreeTabs() async throws {
        let repoA = try await makeRepo(name: "keep-a")
        let repoB = try await makeRepo(name: "keep-b")
        defer {
            try? FileManager.default.removeItem(at: repoA)
            try? FileManager.default.removeItem(at: repoB)
        }

        let state = AppState()
        let projectA = try await state.projectsManager.addProject(
            path: repoA, displayName: "keepA", color: "#5fb7c4"
        )
        let projectB = try await state.projectsManager.addProject(
            path: repoB, displayName: "keepB", color: "#c89d6f"
        )
        try await state.projectsManager.refreshWorktrees(projectId: projectA.id)
        try await state.projectsManager.refreshWorktrees(projectId: projectB.id)

        let treesA = state.projectsManager.worktrees(projectId: projectA.id)
        let treesB = state.projectsManager.worktrees(projectId: projectB.id)
        #expect(treesA.count == 1)
        #expect(treesB.count == 1)

        state.tabs.appendTerminal(worktreeId: treesA[0].id, title: "termA", sessionId: "sA")
        state.tabs.appendTerminal(worktreeId: treesB[0].id, title: "termB", sessionId: "sB")
        #expect(state.tabs.tabs(forWorktree: treesA[0].id).count == 1)
        #expect(state.tabs.tabs(forWorktree: treesB[0].id).count == 1)

        let beforeIds = state.allWorktreeIds()

        state.projectsManager.removeProject(id: projectA.id)

        state.cleanupMissingWorktrees(beforeIds: beforeIds)

        #expect(state.tabs.tabs(forWorktree: treesA[0].id).isEmpty)
        #expect(state.tabs.tabs(forWorktree: treesB[0].id).count == 1)
    }

    @Test func topologyRefreshLoadsPersistedTabsForNewWorktrees() async throws {
        let repo = try await makeRepo(name: "topology-load-tabs")
        let linked = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-cleanup-linked-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: linked)
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: Worktree.makeId(path: linked)))
        }

        let state = AppState()
        let project = try await state.projectsManager.addProject(
            path: repo, displayName: "topology-load-tabs", color: "#5fb7c4"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        #expect(state.projectsManager.worktrees(projectId: project.id).count == 1)

        _ = try await Process.git(["worktree", "add", "-q", "-b", "linked-tabs", linked.path, "HEAD"], cwd: repo)
        let linkedId = Worktree.makeId(path: linked)
        let seededTabs = TabsManager()
        seededTabs.appendTerminal(worktreeId: linkedId, title: "persisted", sessionId: "s1")

        await state.refreshProjectTopology(projectId: project.id)

        #expect(state.projectsManager.worktrees(projectId: project.id).contains { $0.id == linkedId })
        #expect(state.tabs.tabs(forWorktree: linkedId).map(\.title) == ["persisted"])
    }

    @Test(arguments: [AnchorRefreshPath.refreshAll, .clearProjectsWithoutWorktrees])
    func refreshRestartsWatcherWhenProjectAnchorChanges(_ refreshPath: AnchorRefreshPath) async throws {
        let repo = try await makeRepo(name: "topology-anchor-watcher")
        let linked = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-cleanup-linked-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: linked)
            try? FileManager.default.removeItem(at: repo)
        }

        let projectId = "topology-anchor-watcher"
        let worktreeService = WorktreeService()
        let linkedWorktree = try await worktreeService.add(
            repoPath: repo,
            base: "main",
            branch: "linked-anchor",
            destination: linked,
            projectId: projectId
        )
        let project = ProjectConfig(
            id: projectId,
            name: "topology-anchor-watcher",
            path: linked.path,
            color: "#5fb7c4",
            addedAt: Date()
        )
        var watchedPaths: [URL] = []
        let state = AppState(
            store: MemoryStore(projectsFile: ProjectsFile(projects: [project])),
            projectGitWatcherFactory: { path in
                watchedPaths.append(path.standardizedFileURL)
                return ProjectGitWatcher(
                    repoPath: path,
                    resolvedGitDir: repo.appendingPathComponent(".git"),
                    resolvedWorktreeRoot: path,
                    headDebounceInterval: 0.01,
                    headDebounceMaxWait: 0.02,
                    topologyDebounceInterval: 0.01,
                    topologyDebounceMaxWait: 0.02,
                    startStreamOverride: { _, _ in }
                )
            }
        )
        try await state.projectsManager.refreshWorktrees(projectId: projectId)
        state.startProjectGitWatcher(for: project)

        try await worktreeService.remove(
            repoPath: repo,
            worktree: linkedWorktree,
            deleteBranchIfMerged: false,
            force: false
        )
        switch refreshPath {
        case .refreshAll:
            await state.refreshAllProjectTopologies()
        case .clearProjectsWithoutWorktrees:
            let removed = await state.clearProjectsWithoutWorktrees()
            #expect(removed == 0)
        }

        #expect(watchedPaths.map(\.path) == [linked.standardizedFileURL.path, repo.standardizedFileURL.path])
    }

    @Test func createWorktreeInsertsOptimisticRowImmediately() async throws {
        let repo = try await makeRepo(name: "create-opt")
        defer { try? FileManager.default.removeItem(at: repo) }
        let state = AppState()
        let project = try await state.projectsManager.addProject(path: repo, displayName: "create-opt", color: "#5fb7c4")
        try await state.projectsManager.refreshWorktrees(projectId: project.id)

        let dest = repo.appendingPathComponent("wt-opt")
        let id = await state.createWorktree(
            projectId: project.id,
            base: "main",
            branch: "opt-b",
            destination: dest,
            runStartup: false,
            launchSurface: .none
        )
        #expect(!id.isEmpty)
        let trees = state.projectsManager.worktrees(projectId: project.id)
        #expect(trees.contains { $0.id == id })
        #expect(state.projectsManager.operationState(for: id) == .creating)

        try await waitForOperationState(state.projectsManager, id: id, equals: nil)
        #expect(state.projectsManager.worktrees(projectId: project.id).contains { $0.id == id })
    }

    @Test func createWorktreeSelectsOptimisticRowImmediately() async throws {
        let repo = try await makeRepo(name: "create-select-opt")
        defer { try? FileManager.default.removeItem(at: repo) }
        let state = AppState()
        let project = try await state.projectsManager.addProject(path: repo, displayName: "create-select-opt", color: "#5fb7c4")
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        let existing = try #require(state.projectsManager.worktrees(projectId: project.id).first)
        state.selectedWorktreeId = existing.id

        let dest = repo.appendingPathComponent("wt-select-opt")
        let id = await state.createWorktree(
            projectId: project.id,
            base: "main",
            branch: "select-opt-b",
            destination: dest,
            runStartup: false,
            launchSurface: .none
        )

        #expect(!id.isEmpty)
        #expect(state.projectsManager.operationState(for: id) == .creating)
        #expect(state.selectedWorktreeId == id)

        try await waitForOperationState(state.projectsManager, id: id, equals: nil)
    }

    @Test func createWorktreeAppliesAndKeepsExplicitGGMode() async throws {
        let repo = try await makeRepo(name: "create-gg-off")
        defer { try? FileManager.default.removeItem(at: repo) }
        let state = AppState()
        let project = try await state.projectsManager.addProject(
            path: repo,
            displayName: "create-gg-off",
            color: "#5fb7c4"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)

        let id = await state.createWorktree(
            projectId: project.id,
            base: "main",
            branch: "regular-branch",
            destination: repo.appendingPathComponent("wt-gg-off"),
            runStartup: false,
            launchSurface: .none,
            ggWorktreeMode: .off
        )

        #expect(state.selectedWorktreeId == id)
        let optimistic = try #require(
            state.projectsManager.worktrees(projectId: project.id).first(where: { $0.id == id })
        )
        #expect(state.ggWorktreeMenuModel(project: project, worktree: optimistic).selectedMode == .off)
        try await waitForOperationState(state.projectsManager, id: id, equals: nil)
        #expect(state.projectsManager.ggWorktreeMode(projectId: project.id, worktreeId: id) == .off)
    }

    @Test func failedCreateRemovesUnpersistedGGMode() async throws {
        let repo = try await makeRepo(name: "create-gg-fail")
        defer { try? FileManager.default.removeItem(at: repo) }
        let state = AppState()
        let project = try await state.projectsManager.addProject(
            path: repo,
            displayName: "create-gg-fail",
            color: "#5fb7c4"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)

        let id = await state.createWorktree(
            projectId: project.id,
            base: "missing-base",
            branch: "failed-stack",
            destination: repo.appendingPathComponent("wt-gg-fail"),
            runStartup: false,
            launchSurface: .none,
            ggWorktreeMode: .on
        )

        try await waitForOperationStateMatching(state.projectsManager, id: id) {
            if case .createFailed = $0 { return true }
            return false
        }
        #expect(state.projectsManager.ggWorktreeMode(projectId: project.id, worktreeId: id) == .inherit)
    }

    @Test func createWorktreeDoesNotPersistGGModeBeforeReconciliation() async throws {
        let repo = try await makeRepo(name: "create-gg-save")
        defer { try? FileManager.default.removeItem(at: repo) }
        let store = RecordingStore()
        let state = AppState(store: store)
        let project = try await state.projectsManager.addProject(
            path: repo,
            displayName: "create-gg-save",
            color: "#5fb7c4"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)

        let id = await state.createWorktree(
            projectId: project.id,
            base: "main",
            branch: "persist-after-reconcile",
            destination: repo.appendingPathComponent("wt-gg-save"),
            runStartup: false,
            launchSurface: .none,
            ggWorktreeMode: .on
        )
        state.setWorktreeLaunchDefaults(
            projectId: project.id,
            openAfterCreate: false,
            launcherMode: .terminal
        )

        #expect(state.projectsManager.operationState(for: id) == .creating)
        #expect(store.writtenProjectsFile != nil)
        #expect(store.writtenProjectsFile?.projects.first(where: { $0.id == project.id })?.ggWorktreeModes[id] == nil)
        try await waitForOperationState(state.projectsManager, id: id, equals: nil)
        #expect(store.writtenProjectsFile?.projects.first(where: { $0.id == project.id })?.ggWorktreeModes[id] == .on)
    }

    @Test func createWorktreeRejectsExistingDestination() async throws {
        let repo = try await makeRepo(name: "create-existing-destination")
        defer { try? FileManager.default.removeItem(at: repo) }
        let state = AppState()
        let project = try await state.projectsManager.addProject(
            path: repo,
            displayName: "create-existing-destination",
            color: "#5fb7c4"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        let existing = try #require(state.projectsManager.worktrees(projectId: project.id).first)

        let id = await state.createWorktree(
            projectId: project.id,
            base: "main",
            branch: "existing-path",
            destination: existing.path,
            runStartup: false,
            launchSurface: .none
        )

        #expect(id.isEmpty)
        #expect(state.projectsManager.operationState(for: existing.id) == nil)
        #expect(state.projectsManager.worktrees(projectId: project.id).filter { $0.id == existing.id }.count == 1)
    }

    @Test func createWorktreeFailureLeavesFailedRow() async throws {
        let repo = try await makeRepo(name: "create-fail")
        defer { try? FileManager.default.removeItem(at: repo) }
        let state = AppState()
        let project = try await state.projectsManager.addProject(path: repo, displayName: "create-fail", color: "#5fb7c4")
        try await state.projectsManager.refreshWorktrees(projectId: project.id)

        let dest = repo.appendingPathComponent("wt-fail")
        let id = await state.createWorktree(
            projectId: project.id,
            base: "missing-base",
            branch: "fail-b",
            destination: dest,
            runStartup: false,
            launchSurface: .none
        )

        try await waitForOperationStateMatching(state.projectsManager, id: id) { state in
            if case .createFailed = state { return true }
            return false
        }

        #expect(state.projectsManager.worktrees(projectId: project.id).contains { $0.id == id })
        if case .createFailed(_, let message, _, _) = state.projectsManager.operationState(for: id) {
            #expect(!message.isEmpty)
        } else {
            Issue.record("Expected createFailed state")
        }
    }

    @Test(arguments: [GGWorktreeMode.on, .off])
    func createWorktreeRetryPreservesExplicitGGMode(mode: GGWorktreeMode) async throws {
        let modeName = mode == .on ? "on" : "off"
        let repo = try await makeRepo(name: "create-retry-\(modeName)")
        defer { try? FileManager.default.removeItem(at: repo) }
        let state = AppState()
        let project = try await state.projectsManager.addProject(
            path: repo,
            displayName: "create-retry-\(modeName)",
            color: "#5fb7c4"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)

        let retryBase = "retry-base-\(modeName)"
        let branch = "retry-\(modeName)"
        let dest = repo.appendingPathComponent("wt-retry-\(modeName)")
        let failedId = await state.createWorktree(
            projectId: project.id,
            base: retryBase,
            branch: branch,
            destination: dest,
            runStartup: false,
            launchSurface: .none,
            ggWorktreeMode: mode
        )
        try await waitForOperationStateMatching(state.projectsManager, id: failedId) { state in
            if case .createFailed = state { return true }
            return false
        }
        let failedWorktree = try #require(
            state.projectsManager.worktrees(projectId: project.id).first(where: { $0.id == failedId })
        )
        #expect(state.ggWorktreeMenuModel(project: project, worktree: failedWorktree).selectedMode == .inherit)

        guard case .createFailed(_, _, let failedBase, let failedMode) =
            state.projectsManager.operationState(for: failedId)
        else {
            Issue.record("Expected createFailed state")
            return
        }
        #expect(failedBase == retryBase)
        #expect(failedMode == mode)

        let retryParameters = SidebarView.retryCreateParameters(
            operationState: state.projectsManager.operationState(for: failedId),
            defaultBase: state.config.worktrees.baseBranch
        )
        #expect(retryParameters.base == retryBase)
        #expect(retryParameters.ggWorktreeMode == mode)

        _ = try await Process.git(["branch", retryBase, "main"], cwd: repo)

        let retryId = await state.createWorktree(
            projectId: project.id,
            base: retryParameters.base,
            branch: branch,
            destination: dest,
            runStartup: false,
            launchSurface: .none,
            ggWorktreeMode: retryParameters.ggWorktreeMode
        )

        #expect(retryId == failedId)
        #expect(state.projectsManager.operationState(for: retryId) == .creating)
        try await waitForOperationState(state.projectsManager, id: retryId, equals: nil)
        #expect(state.projectsManager.worktrees(projectId: project.id).contains { $0.id == retryId })
        #expect(state.projectsManager.ggWorktreeMode(projectId: project.id, worktreeId: retryId) == mode)
        #expect(state.projects.first(where: { $0.id == project.id })?.ggWorktreeModes[retryId] == mode)
    }

    @Test func successfulInheritCreationKeepsGGWorktreeModesSparse() async throws {
        let repo = try await makeRepo(name: "create-inherit-sparse")
        defer { try? FileManager.default.removeItem(at: repo) }
        let store = RecordingStore()
        let state = AppState(store: store)
        let project = try await state.projectsManager.addProject(
            path: repo,
            displayName: "create-inherit-sparse",
            color: "#5fb7c4"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)

        let id = await state.createWorktree(
            projectId: project.id,
            base: "main",
            branch: "inherit-sparse",
            destination: repo.appendingPathComponent("wt-inherit-sparse"),
            runStartup: false,
            launchSurface: .none,
            ggWorktreeMode: .inherit
        )

        try await waitForOperationState(state.projectsManager, id: id, equals: nil)
        #expect(state.projects.first(where: { $0.id == project.id })?.ggWorktreeModes[id] == nil)

        state.setWorktreeLaunchDefaults(
            projectId: project.id,
            openAfterCreate: false,
            launcherMode: .terminal
        )
        #expect(store.writtenProjectsFile?.projects.first(where: { $0.id == project.id })?.ggWorktreeModes[id] == nil)
    }

    @Test func deleteWorktreeMarksDeletingImmediately() async throws {
        let repo = try await makeRepo(name: "delete-mark")
        defer { try? FileManager.default.removeItem(at: repo) }
        let state = AppState()
        let project = try await state.projectsManager.addProject(path: repo, displayName: "delete-mark", color: "#5fb7c4")
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        let trees = state.projectsManager.worktrees(projectId: project.id)
        #expect(trees.count == 1)
        let wt = trees[0]

        state.projectsManager.setOperationState(id: wt.id, state: .deleting)
        #expect(state.projectsManager.operationState(for: wt.id) == .deleting)
    }

    // MARK: - Dirty-worktree force-delete state

    @Test func looksLikeDirtyWorktreeErrorMatchesKnownPatterns() {
        #expect(AppState.forceDeleteReason(for: "Cannot delete a dirty worktree") == .dirty)
        #expect(AppState.forceDeleteReason(for: "fatal: 'foo' contains modified or untracked files") == .dirty)
        #expect(AppState.forceDeleteReason(for: "worktree is dirty and cannot be removed") == .dirty)
        #expect(AppState.forceDeleteReason(for: "fatal: working trees containing submodules cannot be moved or removed") == .containsSubmodules)
        #expect(AppState.forceDeleteReason(for: "fatal: not a git repository") == nil)
        #expect(AppState.forceDeleteReason(for: "") == nil)
    }

    @Test func resolveDeleteBranchIfMergedRespectsKeepBranchOverride() {
        // Global on, no override → delete branch.
        #expect(AppState.resolveDeleteBranchIfMerged(globalDeleteOnRemove: true, keepBranch: false) == true)
        // Global on, override on → keep branch.
        #expect(AppState.resolveDeleteBranchIfMerged(globalDeleteOnRemove: true, keepBranch: true) == false)
        // Global off, no override → keep branch (existing behavior).
        #expect(AppState.resolveDeleteBranchIfMerged(globalDeleteOnRemove: false, keepBranch: false) == false)
        // Global off, override on → keep branch.
        #expect(AppState.resolveDeleteBranchIfMerged(globalDeleteOnRemove: false, keepBranch: true) == false)
    }

    @Test func deleteConfirmationForCleanPreflightUsesDeleteAndBranchDeletionCopy() {
        let confirmation = AppState.deleteConfirmation(
            branch: "feature/clean",
            keepBranch: false,
            preflight: WorktreeDeletePreflight(reasons: [], submoduleLocalState: .none)
        )

        #expect(confirmation == AppState.WorktreeDeleteConfirmation(
            title: "Delete worktree 'feature/clean'?",
            message: "This removes its files from disk. The local branch will be deleted if merged.",
            buttonTitle: "Delete",
            force: false
        ))
    }

    @Test func deleteConfirmationForDirtyPreflightUsesForceAndKeepBranchCopy() {
        let confirmation = AppState.deleteConfirmation(
            branch: "feature/dirty",
            keepBranch: true,
            preflight: WorktreeDeletePreflight(reasons: [.dirty], submoduleLocalState: .none)
        )

        #expect(confirmation.title == "Delete worktree 'feature/dirty'?")
        #expect(confirmation.buttonTitle == "Force Delete")
        #expect(confirmation.force == true)
        #expect(confirmation.message.contains("This removes its files from disk."))
        #expect(confirmation.message.contains("The local branch will be kept."))
        #expect(confirmation.message.contains("This worktree has modified or untracked files. Force delete will permanently remove them from disk."))
    }

    @Test func deleteConfirmationForSubmoduleLocalStateIncludesSubmoduleWarnings() {
        let confirmation = AppState.deleteConfirmation(
            branch: "feature/submodule",
            keepBranch: false,
            preflight: WorktreeDeletePreflight(
                reasons: [.containsInitializedSubmodules],
                submoduleLocalState: .present
            )
        )

        #expect(confirmation.buttonTitle == "Force Delete")
        #expect(confirmation.force == true)
        #expect(confirmation.message.contains("This worktree contains initialized submodules. Git requires force delete to remove it."))
        #expect(confirmation.message.contains("Preflight found local-only submodule state that may only exist inside this worktree."))
    }

    @Test func deleteConfirmationForUnknownWithoutSubmoduleReasonUsesNormalCopy() {
        let confirmation = AppState.deleteConfirmation(
            branch: "feature/unknown",
            keepBranch: false,
            preflight: WorktreeDeletePreflight(reasons: [], submoduleLocalState: .unknown)
        )

        #expect(confirmation.buttonTitle == "Delete")
        #expect(confirmation.force == false)
        #expect(!confirmation.message.contains("initialized submodules"))
        #expect(!confirmation.message.contains("could not verify"))
    }

    @Test func deleteConfirmationForDirtyAndSubmodulePreflightIncludesBothWarnings() {
        let confirmation = AppState.deleteConfirmation(
            branch: "feature/combined",
            keepBranch: false,
            preflight: WorktreeDeletePreflight(
                reasons: [.dirty, .containsInitializedSubmodules],
                submoduleLocalState: .none
            )
        )

        #expect(confirmation.buttonTitle == "Force Delete")
        #expect(confirmation.force == true)
        #expect(confirmation.message.contains("This worktree has modified or untracked files. Force delete will permanently remove them from disk."))
        #expect(confirmation.message.contains("This worktree contains initialized submodules. Git requires force delete to remove it."))
    }

    @Test func resolveDeleteDecisionReturnsForceDecisionWhenConfirmed() {
        let preflight = WorktreeDeletePreflight(
            reasons: [.containsInitializedSubmodules],
            submoduleLocalState: .none
        )

        let decision = AppState.resolveDeleteDecision(
            branch: "feature/submodule",
            keepBranch: false,
            preflight: preflight,
            userConfirmed: true
        )

        #expect(decision == AppState.WorktreeDeleteDecision(
            confirmation: AppState.deleteConfirmation(
                branch: "feature/submodule",
                keepBranch: false,
                preflight: preflight
            ),
            force: true
        ))
        #expect(decision?.confirmation.buttonTitle == "Force Delete")
    }

    @Test func resolveDeleteDecisionReturnsNilWhenCancelled() {
        let decision = AppState.resolveDeleteDecision(
            branch: "feature/cancel",
            keepBranch: false,
            preflight: WorktreeDeletePreflight(reasons: [.dirty], submoduleLocalState: .none),
            userConfirmed: false
        )

        #expect(decision == nil)
    }

    @Test func submoduleRemoveErrorBuildsPendingForceDeleteFallback() {
        let repoPath = URL(fileURLWithPath: "/tmp/repo")
        let worktreePath = URL(fileURLWithPath: "/tmp/repo-worktree")
        let worktree = Worktree(
            id: "wt-submodule",
            projectId: "project",
            name: "feature/submodule",
            branch: "feature/submodule",
            path: worktreePath,
            status: .clean,
            lastActivity: Date(timeIntervalSince1970: 0)
        )

        let pending = AppState.pendingForceDelete(
            for: worktree,
            repoPath: repoPath,
            deleteBranchIfMerged: true,
            removedIndex: 2,
            stderr: "fatal: working trees containing submodules cannot be moved or removed"
        )

        #expect(pending?.id == worktree.id)
        #expect(pending?.branch == worktree.branch)
        #expect(pending?.projectId == worktree.projectId)
        #expect(pending?.repoPath == repoPath)
        #expect(pending?.worktreePath == worktreePath)
        #expect(pending?.deleteBranchIfMerged == true)
        #expect(pending?.removedIndex == 2)
        #expect(pending?.reason == .containsSubmodules)
    }

    @Test func cancelForceDeleteClearsPendingState() async throws {
        let repo = try await makeRepo(name: "cancel-force")
        defer { try? FileManager.default.removeItem(at: repo) }
        let state = AppState()
        let project = try await state.projectsManager.addProject(path: repo, displayName: "cancel-force", color: "#5fb7c4")
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        let trees = state.projectsManager.worktrees(projectId: project.id)
        let wt = try #require(trees.first)

        state.pendingForceDeleteWorktree = AppState.PendingForceDeleteWorktree(
            id: wt.id,
            branch: wt.branch,
            projectId: wt.projectId,
            repoPath: repo,
            worktreePath: wt.path,
            deleteBranchIfMerged: false,
            removedIndex: 0,
            reason: .dirty
        )
        #expect(state.pendingForceDeleteWorktree != nil)

        state.cancelForceDeletePendingWorktree()
        #expect(state.pendingForceDeleteWorktree == nil)
        #expect(state.projectsManager.operationState(for: wt.id) == nil)
    }

    @Test func removeProjectClosesTabsForProjectWorktrees() async throws {
        let repo = try await makeRepo(name: "remove-tabs")
        defer { try? FileManager.default.removeItem(at: repo) }

        let state = AppState()
        let project = try await state.projectsManager.addProject(
            path: repo, displayName: "remove", color: "#5fb7c4"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)

        let trees = state.projectsManager.worktrees(projectId: project.id)
        #expect(trees.count == 1)
        let wt = trees[0]

        state.tabs.appendTerminal(worktreeId: wt.id, title: "term", sessionId: "s1")
        #expect(state.tabs.tabs(forWorktree: wt.id).count == 1)

        state.removeProject(id: project.id)

        #expect(state.projects.contains(where: { $0.id == project.id }) == false)
        #expect(state.tabs.tabs(forWorktree: wt.id).isEmpty)
    }

    @Test func clearAllProjectsRemovesEveryProject() async throws {
        let repoA = try await makeRepo(name: "clear-all-a")
        let repoB = try await makeRepo(name: "clear-all-b")
        defer {
            try? FileManager.default.removeItem(at: repoA)
            try? FileManager.default.removeItem(at: repoB)
        }

        let state = AppState(store: MemoryStore())
        let projectA = try await state.projectsManager.addProject(
            path: repoA, displayName: "clearA", color: "#5fb7c4"
        )
        let projectB = try await state.projectsManager.addProject(
            path: repoB, displayName: "clearB", color: "#c89d6f"
        )
        try await state.projectsManager.refreshWorktrees(projectId: projectA.id)
        try await state.projectsManager.refreshWorktrees(projectId: projectB.id)

        let worktreeId = try #require(state.projectsManager.worktrees(projectId: projectA.id).first?.id)
        state.selectedWorktreeId = worktreeId
        state.tabs.appendTerminal(worktreeId: worktreeId, title: "term", sessionId: "s1")

        let removed = state.clearAllProjects()

        #expect(removed == 2)
        #expect(state.projects.isEmpty)
        #expect(state.selectedWorktreeId == nil)
        #expect(state.tabs.tabs(forWorktree: worktreeId).isEmpty)
    }

    @Test func clearProjectsWithoutWorktreesKeepsProjectsWithLiveWorktrees() async throws {
        let repo = try await makeRepo(name: "clear-without-worktrees-keep")
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-missing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: repo) }

        let liveProject = ProjectConfig(
            id: UUID().uuidString,
            name: "live",
            path: repo.path,
            color: "#5fb7c4",
            addedAt: Date()
        )
        let staleProject = ProjectConfig(
            id: UUID().uuidString,
            name: "stale",
            path: missing.path,
            color: "#c89d6f",
            addedAt: Date()
        )
        let state = AppState(
            store: MemoryStore(projectsFile: ProjectsFile(projects: [liveProject, staleProject]))
        )

        let removed = await state.clearProjectsWithoutWorktrees()

        #expect(removed == 1)
        #expect(state.projects.map(\.id) == [liveProject.id])
        #expect(state.projectsManager.worktrees(projectId: liveProject.id).isEmpty == false)
    }

    @Test func clearProjectsWithoutWorktreesRemovesMissingProjectWithStaleRows() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-missing-\(UUID().uuidString)")
        let staleProject = ProjectConfig(
            id: UUID().uuidString,
            name: "stale",
            path: missing.path,
            color: "#c89d6f",
            addedAt: Date()
        )
        let state = AppState(
            store: MemoryStore(projectsFile: ProjectsFile(projects: [staleProject]))
        )
        let staleWorktree = Worktree(
            id: Worktree.makeId(path: missing),
            projectId: staleProject.id,
            name: "main",
            branch: "main",
            path: missing,
            status: .clean,
            lastActivity: Date()
        )
        state.projectsManager.insertOptimisticWorktree(staleWorktree)
        #expect(state.projectsManager.worktrees(projectId: staleProject.id).isEmpty == false)

        let removed = await state.clearProjectsWithoutWorktrees()

        #expect(removed == 1)
        #expect(state.projects.isEmpty)
    }

    @Test func clearProjectsWithoutWorktreesKeepsProjectWhenRefreshFailsButPathExists() async throws {
        let nonRepo = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-refresh-fails-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: nonRepo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: nonRepo) }

        let project = ProjectConfig(
            id: UUID().uuidString,
            name: "non-repo",
            path: nonRepo.path,
            color: "#5fb7c4",
            addedAt: Date()
        )
        let state = AppState(
            store: MemoryStore(projectsFile: ProjectsFile(projects: [project]))
        )

        let removed = await state.clearProjectsWithoutWorktrees()

        #expect(removed == 0)
        #expect(state.projects.map(\.id) == [project.id])
    }

    @Test func clearProjectsWithoutWorktreesKeepsRemoteProjectWhenRefreshFails() async throws {
        let project = ProjectConfig(
            id: UUID().uuidString,
            name: "remote",
            path: "/srv/offline-repo-\(UUID().uuidString)",
            color: "#5fb7c4",
            addedAt: Date(),
            host: "localhost"
        )
        defer { RemoteHostRegistry.shared.unregister(root: project.path) }
        let state = AppState(
            store: MemoryStore(projectsFile: ProjectsFile(projects: [project]))
        )

        let removed = await state.clearProjectsWithoutWorktrees()

        #expect(removed == 0)
        #expect(state.projects.map(\.id) == [project.id])
    }

    @Test func removeProjectResetsSelectionWhenSelectedWorktreeIsRemoved() async throws {
        let repoA = try await makeRepo(name: "remove-sel-a")
        let repoB = try await makeRepo(name: "remove-sel-b")
        defer {
            try? FileManager.default.removeItem(at: repoA)
            try? FileManager.default.removeItem(at: repoB)
        }

        let state = AppState()
        let projectA = try await state.projectsManager.addProject(
            path: repoA, displayName: "projA", color: "#5fb7c4"
        )
        let projectB = try await state.projectsManager.addProject(
            path: repoB, displayName: "projB", color: "#c89d6f"
        )
        try await state.projectsManager.refreshWorktrees(projectId: projectA.id)
        try await state.projectsManager.refreshWorktrees(projectId: projectB.id)

        let treesA = state.projectsManager.worktrees(projectId: projectA.id)
        let treesB = state.projectsManager.worktrees(projectId: projectB.id)
        #expect(treesA.count == 1)
        #expect(treesB.count == 1)

        state.selectedWorktreeId = treesA[0].id
        state.removeProject(id: projectA.id)

        #expect(state.selectedWorktreeId == treesB[0].id)
    }

    @Test func removeProjectClearsSelectionWhenNoWorktreesRemain() async throws {
        let repo = try await makeRepo(name: "remove-last")
        defer { try? FileManager.default.removeItem(at: repo) }

        let state = AppState()
        let project = try await state.projectsManager.addProject(
            path: repo, displayName: "only", color: "#5fb7c4"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)

        let trees = state.projectsManager.worktrees(projectId: project.id)
        state.selectedWorktreeId = trees[0].id

        state.removeProject(id: project.id)

        #expect(state.projects.contains(where: { $0.id == project.id }) == false)
        #expect(state.selectedWorktreeId == nil)
    }

    @Test func removeProjectClosesTabsForUnrefreshedMainWorktree() async throws {
        let repo = try await makeRepo(name: "remove-unrefreshed")
        defer { try? FileManager.default.removeItem(at: repo) }

        let state = AppState()
        let project = try await state.projectsManager.addProject(
            path: repo, displayName: "unrefreshed", color: "#5fb7c4"
        )
        // Deliberately skip refreshWorktrees: worktreesByProject is empty,
        // simulating the post-launch window before refreshAll completes.
        #expect(state.projectsManager.worktrees(projectId: project.id).isEmpty)

        let mainWorktreeId = Worktree.makeId(path: URL(fileURLWithPath: project.path))
        state.tabs.appendTerminal(worktreeId: mainWorktreeId, title: "term", sessionId: "s1")
        #expect(state.tabs.tabs(forWorktree: mainWorktreeId).count == 1)

        state.removeProject(id: project.id)

        #expect(state.projects.contains(where: { $0.id == project.id }) == false)
        #expect(state.tabs.tabs(forWorktree: mainWorktreeId).isEmpty)
    }

    @Test func removeProjectDeletesPersistedTabsFile() async throws {
        let repo = try await makeRepo(name: "remove-persisted")
        defer { try? FileManager.default.removeItem(at: repo) }

        let state = AppState()
        let project = try await state.projectsManager.addProject(
            path: repo, displayName: "persisted", color: "#5fb7c4"
        )
        let mainWorktreeId = Worktree.makeId(path: URL(fileURLWithPath: project.path))

        state.tabs.appendTerminal(worktreeId: mainWorktreeId, title: "term", sessionId: "s1")
        let tabsFile = Paths.tabsFile(forWorktreeId: mainWorktreeId)
        #expect(FileManager.default.fileExists(atPath: tabsFile.path))

        state.removeProject(id: project.id)

        #expect(FileManager.default.fileExists(atPath: tabsFile.path) == false)
    }

    @Test func removeProjectWithNoDirtyBuffersProceedsWithoutPrompt() async throws {
        let repo = try await makeRepo(name: "remove-no-dirty")
        defer { try? FileManager.default.removeItem(at: repo) }

        let state = AppState()
        let project = try await state.projectsManager.addProject(
            path: repo, displayName: "no-dirty", color: "#5fb7c4"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)

        let trees = state.projectsManager.worktrees(projectId: project.id)
        let wt = trees[0]
        state.tabs.appendTerminal(worktreeId: wt.id, title: "term", sessionId: "s1")
        #expect(state.tabs.tabs(forWorktree: wt.id).count == 1)

        // No editor tabs with unsaved changes → no prompt → proceed directly.
        state.removeProject(id: project.id)

        #expect(state.projects.contains(where: { $0.id == project.id }) == false)
        #expect(state.tabs.tabs(forWorktree: wt.id).isEmpty)
    }

    @Test func removeProjectLoadsPersistedTabsForMainWorktreeBeforeDeletion() async throws {
        let repo = try await makeRepo(name: "remove-load-first")
        defer { try? FileManager.default.removeItem(at: repo) }

        let state = AppState()
        let project = try await state.projectsManager.addProject(
            path: repo, displayName: "load-first", color: "#5fb7c4"
        )
        // Skip refreshWorktrees — worktreesByProject stays empty.
        #expect(state.projectsManager.worktrees(projectId: project.id).isEmpty)

        let mainId = Worktree.makeId(path: URL(fileURLWithPath: project.path))
        // Seed an on-disk tabs file (no in-memory entry).
        state.tabs.appendTerminal(worktreeId: mainId, title: "term", sessionId: "s1")
        let tabsFile = Paths.tabsFile(forWorktreeId: mainId)
        #expect(FileManager.default.fileExists(atPath: tabsFile.path))

        state.removeProject(id: project.id)

        // After removal, the persisted tabs file is gone.
        #expect(FileManager.default.fileExists(atPath: tabsFile.path) == false)
        #expect(state.projects.contains(where: { $0.id == project.id }) == false)
    }

    // MARK: - Archive from delete-failed state

    @Test func archiveWorktreeFromDeleteFailedStateHidesWorktree() async throws {
        let repo = try await makeRepo(name: "archive-from-failed")
        defer { try? FileManager.default.removeItem(at: repo) }

        let state = AppState()
        let project = try await state.projectsManager.addProject(path: repo, displayName: "archive", color: "#5fb7c4")
        try await state.projectsManager.refreshWorktrees(projectId: project.id)

        let trees = state.projectsManager.worktrees(projectId: project.id)
        #expect(trees.count == 1)
        let wt = trees[0]

        // Simulate a failed delete.
        state.projectsManager.setOperationState(id: wt.id, state: .deleteFailed(message: "permission denied"))
        state.projectsManager.setGGWorktreeMode(projectId: project.id, worktreeId: wt.id, mode: .on)
        state.selectedWorktreeId = wt.id

        // Archive should succeed and hide the worktree.
        state.archiveWorktree(wt)

        #expect(state.projectsManager.isWorktreeHidden(projectId: project.id, path: wt.path))
        #expect(state.projectsManager.archivedWorktrees(projectId: project.id).count == 1)
        #expect(state.projectsManager.visibleWorktrees(projectId: project.id).isEmpty)
        #expect(state.projectsManager.ggWorktreeMode(projectId: project.id, worktreeId: wt.id) == .on)
        // Operation state should be cleared.
        #expect(state.projectsManager.operationState(for: wt.id) == nil)
        // Selection should move away because the worktree is no longer visible.
        #expect(state.selectedWorktreeId != wt.id)
    }

    @Test func archiveWorktreeFromDeleteFailedStateClosesTabs() async throws {
        let repo = try await makeRepo(name: "archive-from-failed-tabs")
        defer { try? FileManager.default.removeItem(at: repo) }

        let state = AppState()
        let project = try await state.projectsManager.addProject(path: repo, displayName: "archive-tabs", color: "#5fb7c4")
        try await state.projectsManager.refreshWorktrees(projectId: project.id)

        let wt = state.projectsManager.worktrees(projectId: project.id)[0]
        state.tabs.appendTerminal(worktreeId: wt.id, title: "term", sessionId: "s1")
        #expect(state.tabs.tabs(forWorktree: wt.id).count == 1)

        state.projectsManager.setOperationState(id: wt.id, state: .deleteFailed(message: "permission denied"))
        state.selectedWorktreeId = wt.id

        state.archiveWorktree(wt)

        // Tabs should be closed.
        #expect(state.tabs.tabs(forWorktree: wt.id).isEmpty)
        // And selection updated.
        #expect(state.selectedWorktreeId != wt.id)
    }

    @Test func createWorktreeAfterProjectRemovalDoesNotMutateState() async throws {
        let repo = try await makeRepo(name: "create-after-remove")
        defer { try? FileManager.default.removeItem(at: repo) }

        let state = AppState()
        let project = try await state.projectsManager.addProject(
            path: repo, displayName: "race", color: "#5fb7c4"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)

        let destination = repo.deletingLastPathComponent()
            .appendingPathComponent("race-wt-\(UUID().uuidString)")
        _ = await state.createWorktree(
            projectId: project.id,
            base: "main",
            branch: "race/wt",
            destination: destination,
            runStartup: false,
            launchSurface: .none
        )

        // Immediately remove the project — before the async create finishes.
        state.removeProject(id: project.id)
        #expect(state.projects.contains(where: { $0.id == project.id }) == false)

        // Yield long enough for the create Task to complete and the guard to fire.
        // The create writes to disk via `git worktree add` and may take ~1s on
        // typical hardware. Sleep is the simplest way to wait without exposing
        // Task handles through AppState.
        try? await Task.sleep(nanoseconds: 3_000_000_000)

        // Project remained removed; no selection was set for the orphan worktree.
        #expect(state.projects.contains(where: { $0.id == project.id }) == false)
        let orphanId = Worktree.makeId(path: destination)
        #expect(state.selectedWorktreeId != orphanId)
        // Best-effort cleanup of the orphan worktree directory on disk.
        try? FileManager.default.removeItem(at: destination)
    }

    private func waitForOperationState(
        _ manager: ProjectsManager,
        id: String,
        equals expected: WorktreeOperationState?
    ) async throws {
        try await waitForOperationStateMatching(manager, id: id) { $0 == expected }
    }

    private func waitForOperationStateMatching(
        _ manager: ProjectsManager,
        id: String,
        matches: (WorktreeOperationState?) -> Bool
    ) async throws {
        for _ in 0..<80 {
            if matches(manager.operationState(for: id)) {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        Issue.record("Timed out waiting for operation state")
    }
}
