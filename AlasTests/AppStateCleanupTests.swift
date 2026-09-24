import Testing
import Foundation
@testable import Alas

@MainActor
private final class WorktreeCleanupProbe {
    weak var state: AppState?
    var worktreeID = ""
    var launchedTickets: [WorktreeTrashCleanupTicket] = []
    var tabsWereEmptyAtLaunch = false
    var appendFinishedAtLaunch = false
}

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
        var spacesFile: SpacesFile? = nil

        func write<T: Encodable>(_: T, to _: URL) throws {}

        func readIfExists<T: Decodable>(_: T.Type, from _: URL) throws -> T? {
            if T.self == AppConfig.self {
                return config as? T
            }
            if T.self == ProjectsFile.self {
                return projectsFile as? T
            }
            if T.self == SpacesFile.self {
                return spacesFile as? T
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
            for: worktree,
            state: .createFailed(
                projectId: project.id,
                message: "transient",
                base: "main",
                ggWorktreeMode: .off,
                launchSurface: .none,
                issueAttachment: nil
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

    @Test func topologyRefreshHandlesDuplicatePersistedProjectIDs() async throws {
        let repo = try await makeRepo(name: "duplicate-project-id")
        defer { try? FileManager.default.removeItem(at: repo) }

        let project = ProjectConfig(
            id: "duplicate",
            name: "first",
            path: repo.path,
            color: "#5fb7c4",
            addedAt: .now
        )
        let duplicate = ProjectConfig(
            id: "duplicate",
            name: "second",
            path: repo.path,
            color: "#5fb7c4",
            addedAt: .now
        )
        let state = AppState(store: MemoryStore(projectsFile: ProjectsFile(projects: [project, duplicate])))

        #expect(state.projects.count == 1)
        await state.refreshProjectTopology(projectId: project.id)

        #expect(state.projectsManager.worktrees(projectId: project.id).count == 1)
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

        await state.cleanupMissingWorktrees(beforeIds: beforeIds)

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

        await state.cleanupMissingWorktrees(beforeIds: beforeIds)

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

        await state.cleanupMissingWorktrees(beforeIds: beforeIds)

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
        #expect(state.projectsManager.operationState(forWorktreeId: id, projectId: project.id) == .creating)

        try await waitForOperationState(state.projectsManager, id: id, projectId: project.id, equals: nil)
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
        #expect(state.projectsManager.operationState(forWorktreeId: id, projectId: project.id) == .creating)
        #expect(state.selectedWorktreeId == id)

        try await waitForOperationState(state.projectsManager, id: id, projectId: project.id, equals: nil)
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
        try await waitForOperationState(state.projectsManager, id: id, projectId: project.id, equals: nil)
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

        try await waitForOperationStateMatching(state.projectsManager, id: id, projectId: project.id) {
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

        #expect(state.projectsManager.operationState(forWorktreeId: id, projectId: project.id) == .creating)
        #expect(store.writtenProjectsFile != nil)
        #expect(store.writtenProjectsFile?.projects.first(where: { $0.id == project.id })?.ggWorktreeModes[id] == nil)
        try await waitForOperationState(state.projectsManager, id: id, projectId: project.id, equals: nil)
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
        #expect(state.projectsManager.operationState(forWorktreeId: existing.id, projectId: project.id) == nil)
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

        try await waitForOperationStateMatching(state.projectsManager, id: id, projectId: project.id) { state in
            if case .createFailed = state { return true }
            return false
        }

        #expect(state.projectsManager.worktrees(projectId: project.id).contains { $0.id == id })
        if case .createFailed(_, let message, _, _, _, _) = state.projectsManager.operationState(forWorktreeId: id, projectId: project.id) {
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
        try await waitForOperationStateMatching(state.projectsManager, id: failedId, projectId: project.id) { state in
            if case .createFailed = state { return true }
            return false
        }
        let failedWorktree = try #require(
            state.projectsManager.worktrees(projectId: project.id).first(where: { $0.id == failedId })
        )
        #expect(state.ggWorktreeMenuModel(project: project, worktree: failedWorktree).selectedMode == .inherit)

        guard case .createFailed(_, _, let failedBase, let failedMode, _, _) =
            state.projectsManager.operationState(forWorktreeId: failedId, projectId: project.id)
        else {
            Issue.record("Expected createFailed state")
            return
        }
        #expect(failedBase == retryBase)
        #expect(failedMode == mode)

        let retryParameters = SidebarView.retryCreateParameters(
            operationState: state.projectsManager.operationState(forWorktreeId: failedId, projectId: project.id),
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
        #expect(state.projectsManager.operationState(forWorktreeId: retryId, projectId: project.id) == .creating)
        try await waitForOperationState(state.projectsManager, id: retryId, projectId: project.id, equals: nil)
        #expect(state.projectsManager.worktrees(projectId: project.id).contains { $0.id == retryId })
        #expect(state.projectsManager.ggWorktreeMode(projectId: project.id, worktreeId: retryId) == mode)
        #expect(state.projects.first(where: { $0.id == project.id })?.ggWorktreeModes[retryId] == mode)
    }

    @Test func createWorktreeRetryPreservesIssueLaunchMetadata() async throws {
        let repo = try await makeRepo(name: "create-retry-issue")
        defer { try? FileManager.default.removeItem(at: repo) }
        let store = RecordingStore()
        let state = AppState(store: store)
        let project = try await state.projectsManager.addProject(
            path: repo,
            displayName: "create-retry-issue",
            color: "#5fb7c4"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)

        let attachment = IssueAttachment(
            canonicalURL: URL(string: "https://github.com/acme/alas/issues/42")!,
            providerLabel: "GitHub",
            displayReference: "#42",
            title: "Fix retry"
        )
        let preparedPrompt = PreparedWorktreeACPPrompt(
            sessionID: "retry-issue-session",
            promptID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            text: "Fix issue #42."
        )
        let branch = "retry-issue"
        let retryBase = "retry-issue-base"
        let destination = repo.appendingPathComponent("wt-retry-issue")
        let failedId = await state.createWorktree(
            projectId: project.id,
            base: retryBase,
            branch: branch,
            destination: destination,
            runStartup: false,
            launchSurface: .acp(agentId: "missing-acp-agent", preparedPrompt: preparedPrompt),
            issueAttachment: attachment
        )
        try await waitForOperationStateMatching(state.projectsManager, id: failedId, projectId: project.id) { state in
            if case .createFailed = state { return true }
            return false
        }

        let retryParameters = SidebarView.retryCreateParameters(
            operationState: state.projectsManager.operationState(forWorktreeId: failedId, projectId: project.id),
            defaultBase: state.config.worktrees.baseBranch
        )
        #expect(retryParameters.launchSurface == .acp(agentId: "missing-acp-agent", preparedPrompt: preparedPrompt))
        #expect(retryParameters.issueAttachment == attachment)

        _ = try await Process.git(["branch", retryBase, "main"], cwd: repo)
        let retryId = await state.createWorktree(
            projectId: project.id,
            base: retryParameters.base,
            branch: branch,
            destination: destination,
            runStartup: false,
            launchSurface: retryParameters.launchSurface,
            ggWorktreeMode: retryParameters.ggWorktreeMode,
            issueAttachment: retryParameters.issueAttachment
        )

        #expect(retryId == failedId)
        try await waitForOperationState(state.projectsManager, id: retryId, projectId: project.id, equals: nil)
        try await waitForACPTab(
            state,
            worktreeId: retryId,
            sessionId: preparedPrompt.sessionID
        )
        #expect(state.projectsManager.issueAttachment(projectId: project.id, worktreeId: retryId) == attachment)
        let acpTabs = state.tabs.tabs(forWorktree: retryId).compactMap { tab -> ACPSessionTabState? in
            if case .acpSession(let session) = tab { return session }
            return nil
        }
        #expect(acpTabs.map(\.sessionId) == [preparedPrompt.sessionID])
    }

    @Test func reconciledCreateFailureCompletesIssueLaunchMetadata() async throws {
        let repo = try await makeRepo(name: "create-reconcile-issue")
        defer { try? FileManager.default.removeItem(at: repo) }
        let state = AppState(store: RecordingStore())
        let project = try await state.projectsManager.addProject(
            path: repo,
            displayName: "create-reconcile-issue",
            color: "#5fb7c4"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)

        let destination = repo.appendingPathComponent("wt-reconciled-issue")
        _ = try await Process.git(["worktree", "add", destination.path, "-b", "reconciled-issue", "main"], cwd: repo)
        let worktreeID = Worktree.makeId(path: destination)
        let attachment = IssueAttachment(
            canonicalURL: URL(string: "https://github.com/acme/alas/issues/43")!,
            providerLabel: "GitHub",
            displayReference: "#43",
            title: "Fix reconciled retry"
        )
        let preparedPrompt = PreparedWorktreeACPPrompt(
            sessionID: "reconciled-issue-session",
            promptID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            text: "Fix issue #43."
        )
        state.projectsManager.setOperationState(
            forWorktreeId: worktreeID,
            projectId: project.id,
                        state: .createFailed(
                projectId: project.id,
                message: "refresh failed",
                base: "main",
                ggWorktreeMode: .inherit,
                launchSurface: .acp(agentId: "missing-acp-agent", preparedPrompt: preparedPrompt),
                issueAttachment: attachment
            )
        )

        await state.refreshProjectTopology(projectId: project.id)

        #expect(state.projectsManager.operationState(forWorktreeId: worktreeID, projectId: project.id) == nil)
        #expect(state.projectsManager.issueAttachment(projectId: project.id, worktreeId: worktreeID) == attachment)
        let acpTabs = state.tabs.tabs(forWorktree: worktreeID).compactMap { tab -> ACPSessionTabState? in
            if case .acpSession(let session) = tab { return session }
            return nil
        }
        #expect(acpTabs.map(\.sessionId) == [preparedPrompt.sessionID])
    }

    @Test func refreshAllCompletesReconciledCreateFailureIssueLaunchMetadata() async throws {
        let repo = try await makeRepo(name: "create-reconcile-all-issue")
        defer { try? FileManager.default.removeItem(at: repo) }
        let state = AppState(store: RecordingStore())
        let project = try await state.projectsManager.addProject(
            path: repo,
            displayName: "create-reconcile-all-issue",
            color: "#5fb7c4"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)

        let destination = repo.appendingPathComponent("wt-reconciled-all-issue")
        _ = try await Process.git(["worktree", "add", destination.path, "-b", "reconciled-all-issue", "main"], cwd: repo)
        let worktreeID = Worktree.makeId(path: destination)
        let attachment = IssueAttachment(
            canonicalURL: URL(string: "https://github.com/acme/alas/issues/44")!,
            providerLabel: "GitHub",
            displayReference: "#44",
            title: "Fix refresh-all reconcile"
        )
        let preparedPrompt = PreparedWorktreeACPPrompt(
            sessionID: "reconciled-all-issue-session",
            promptID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            text: "Fix issue #44."
        )
        state.projectsManager.setOperationState(
            forWorktreeId: worktreeID,
            projectId: project.id,
                        state: .createFailed(
                projectId: project.id,
                message: "refresh all failed",
                base: "main",
                ggWorktreeMode: .inherit,
                launchSurface: .acp(agentId: "missing-acp-agent", preparedPrompt: preparedPrompt),
                issueAttachment: attachment
            )
        )

        await state.refreshAllProjectTopologies()

        #expect(state.projectsManager.operationState(forWorktreeId: worktreeID, projectId: project.id) == nil)
        #expect(state.projectsManager.issueAttachment(projectId: project.id, worktreeId: worktreeID) == attachment)
        let acpTabs = state.tabs.tabs(forWorktree: worktreeID).compactMap { tab -> ACPSessionTabState? in
            if case .acpSession(let session) = tab { return session }
            return nil
        }
        #expect(acpTabs.map(\.sessionId) == [preparedPrompt.sessionID])
    }

    @Test func reconciledCreateFailureLaunchReplayIsIdempotentForSameSnapshot() async throws {
        let repo = try await makeRepo(name: "create-reconcile-idempotent")
        defer { try? FileManager.default.removeItem(at: repo) }
        var openedWorktreeIds: [String] = []
        let state = AppState(
            store: RecordingStore(),
            terminalSessionOpener: { worktree, _, _, _, _, _, _, _, _ in
                openedWorktreeIds.append(worktree.id)
                return AppState.OpenedTerminalSession(
                    id: "reconciled-terminal-\(openedWorktreeIds.count)",
                    foregroundPid: { nil }
                )
            }
        )
        let project = try await state.projectsManager.addProject(
            path: repo,
            displayName: "create-reconcile-idempotent",
            color: "#5fb7c4"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)

        let destination = repo.appendingPathComponent("wt-reconciled-idempotent")
        _ = try await Process.git(["worktree", "add", destination.path, "-b", "reconciled-idempotent", "main"], cwd: repo)
        let worktreeID = Worktree.makeId(path: destination)
        state.projectsManager.setOperationState(
            forWorktreeId: worktreeID,
            projectId: project.id,
                        state: .createFailed(
                projectId: project.id,
                message: "refresh failed",
                base: "main",
                ggWorktreeMode: .inherit,
                launchSurface: .terminal(agentId: nil),
                issueAttachment: nil
            )
        )
        let previousOperationStates = state.projectsManager.operationStatesSnapshot()
        try await state.projectsManager.refreshWorktrees(projectId: project.id)

        _ = await state.completeReconciledCreateFailuresForTesting(
            projectId: project.id,
            previousOperationStates: previousOperationStates
        )
        _ = await state.completeReconciledCreateFailuresForTesting(
            projectId: project.id,
            previousOperationStates: previousOperationStates
        )

        #expect(openedWorktreeIds == [worktreeID])
    }

    /// Regression: two projects can hold reconciled `.createFailed` rows at
    /// the same path-derived id. The completion claim used to be keyed by id
    /// alone, so the first project's completion made the second project's
    /// reconciliation look already done and its issue attachment and launch
    /// surface were never applied.
    @Test func reconciledCreateFailureCompletionRunsForEveryProjectSharingAnID() async throws {
        let repo = try await makeRepo(name: "create-reconcile-two-projects")
        defer { try? FileManager.default.removeItem(at: repo) }
        let sharedID = "/srv/checkouts/member"
        let otherProject = ProjectConfig(
            id: "other-project",
            name: "Other",
            path: "/repos/other",
            color: "#fff",
            addedAt: .distantPast,
            host: "other-host"
        )
        let store = MemoryStore(projectsFile: ProjectsFile(projects: [otherProject]))
        let state = AppState(store: store)
        let project = try await state.projectsManager.addProject(
            path: repo,
            displayName: "create-reconcile-two-projects",
            color: "#5fb7c4"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)

        // Both projects carry a live row at the same path-derived id, each
        // with its own pending attachment to replay.
        let otherRow = Worktree(
            id: sharedID,
            projectId: otherProject.id,
            name: "feature",
            branch: "feature",
            path: URL(fileURLWithPath: sharedID),
            status: .clean,
            lastActivity: .distantPast
        )
        state.projectsManager.insertOptimisticWorktree(otherRow)
        let thisProjectRow = Worktree(
            id: sharedID,
            projectId: project.id,
            name: "feature",
            branch: "feature",
            path: URL(fileURLWithPath: sharedID),
            status: .clean,
            lastActivity: .distantPast
        )
        state.projectsManager.insertOptimisticWorktree(thisProjectRow)

        let attachments: [String: IssueAttachment] = [
            otherProject.id: IssueAttachment(
                canonicalURL: URL(string: "https://github.com/acme/alas/issues/51")!,
                providerLabel: "GitHub",
                displayReference: "#51",
                title: "other"
            ),
            project.id: IssueAttachment(
                canonicalURL: URL(string: "https://github.com/acme/alas/issues/52")!,
                providerLabel: "GitHub",
                displayReference: "#52",
                title: "this"
            ),
        ]
        for owner in [otherProject, project] {
            state.projectsManager.setOperationState(
                forWorktreeId: sharedID,
                projectId: owner.id,
                state: .createFailed(
                    projectId: owner.id,
                    message: "refresh failed",
                    base: "main",
                    ggWorktreeMode: .inherit,
                    launchSurface: .none,
                    issueAttachment: attachments[owner.id]
                )
            )
        }
        let previousOperationStates = state.projectsManager.operationStatesSnapshot()
        // The refresh clears a reconciled claim once the worktree is live in
        // git; completion then runs against the pre-refresh snapshot. Model
        // that ordering: both projects' claims are cleared before either
        // completion runs.
        for owner in [otherProject, project] {
            state.projectsManager.setOperationState(
                forWorktreeId: sharedID,
                projectId: owner.id,
                state: nil
            )
        }

        for owner in [otherProject, project] {
            _ = await state.completeReconciledCreateFailuresForTesting(
                projectId: owner.id,
                previousOperationStates: previousOperationStates
            )
        }

        // Each project replayed its own attachment: the second project's
        // completion was not treated as already claimed by the first's.
        for owner in [otherProject, project] {
            #expect(state.projectsManager.issueAttachment(
                projectId: owner.id,
                worktreeId: sharedID
            ) == attachments[owner.id])
        }
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

        try await waitForOperationState(state.projectsManager, id: id, projectId: project.id, equals: nil)
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

        state.projectsManager.setOperationState(forWorktreeId: wt.id, projectId: project.id, state: .deleting(projectId: project.id))
        #expect(state.projectsManager.operationState(forWorktreeId: wt.id, projectId: project.id) == .deleting(projectId: project.id))
    }

    @Test func deleteWorktreeCleansAppStateBeforeLaunchingFileCleanup() async throws {
        let repo = try await makeRepo(name: "delete-staged")
        let linked = repo.deletingLastPathComponent()
            .appendingPathComponent("delete-staged-linked-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: linked)
            try? FileManager.default.removeItem(at: repo)
        }
        let history = try RunHistoryStore(path: repo.appendingPathComponent("run-history.sqlite").path)
        var appendFinished = false
        let probe = WorktreeCleanupProbe()
        let state = AppState(
            runHistoryStore: history,
            worktreeCleanupLauncher: { ticket in
                probe.launchedTickets.append(ticket)
                probe.tabsWereEmptyAtLaunch = probe.state?.tabs
                    .tabs(forWorktree: probe.worktreeID)
                    .isEmpty == true
                probe.appendFinishedAtLaunch = appendFinished
            }
        )
        probe.state = state
        let project = try await state.projectsManager.addProject(
            path: repo,
            displayName: "delete-staged",
            color: "#5fb7c4"
        )
        let worktree = try await WorktreeService().add(
            repoPath: repo,
            base: "main",
            branch: "feature/staged",
            destination: linked,
            projectId: project.id
        )
        probe.worktreeID = worktree.id
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        state.tabs.appendTerminal(worktreeId: worktree.id, title: "term", sessionId: "session")
        state.selectWorktree(id: worktree.id)
        let entry = RunHistoryEntry(
            id: "delayed-delete-run",
            scriptKey: "repo:dev.sh",
            scriptName: "Dev",
            worktreeID: worktree.id,
            projectId: project.id,
            branch: worktree.branch,
            target: .init(host: nil, workingDirectory: worktree.path.path),
            endpoint: nil,
            outcome: .succeeded,
            startedAt: Date(timeIntervalSince1970: 1),
            finishedAt: Date(timeIntervalSince1970: 2),
            portConflict: nil,
            output: .available(text: "late\n", truncated: false)
        )
        state.runHistoryPersistenceTaskOwners[entry.id] = RunHistoryOwner(worktreeID: worktree.id, projectId: project.id)
        state.runHistoryPersistenceTasks[entry.id] = Task { @MainActor [history] in
            try? await Task.sleep(for: .seconds(1))
            _ = try? await history.append(entry)
            appendFinished = true
        }

        #expect(await state.cliDeleteWorktree(worktree, force: true, keepBranch: true) == .ok)
        try await waitForOperationState(state.projectsManager, id: worktree.id, projectId: project.id, equals: nil)
        try await waitForWorktreeRemoved(
            state.projectsManager,
            projectId: project.id,
            worktreeId: worktree.id
        )
        try await waitForSelectedWorktree(state, equals: Worktree.makeId(path: repo))

        let ticket = try #require(probe.launchedTickets.first)
        defer { try? FileManager.default.removeItem(at: ticket.trashRoot) }
        #expect(probe.launchedTickets.count == 1)
        #expect(probe.tabsWereEmptyAtLaunch)
        #expect(probe.appendFinishedAtLaunch)
        #expect(try await history.entry(id: entry.id) == nil)
        #expect(FileManager.default.fileExists(atPath: ticket.stagedPath.path))
    }

    @Test func singleDeleteReconcilesSelectionWhenDuplicateIsOutsideActiveSpace() async throws {
        let repo = try await makeRepo(name: "delete-selection-space")
        let linked = repo.deletingLastPathComponent()
            .appendingPathComponent("delete-selection-space-linked-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: linked)
            try? FileManager.default.removeItem(at: repo)
        }

        let activeProject = ProjectConfig(
            id: "active-space-project",
            name: "Active project",
            path: repo.path,
            color: "#5fb7c4",
            addedAt: .distantPast
        )
        let otherSpaceProject = ProjectConfig(
            id: "other-space-project",
            name: "Other-space project",
            path: "/repos/other",
            color: "#5fb7c4",
            addedAt: .distantPast,
            host: "other-host"
        )
        let spaces = SpacesFile(
            activeSpaceId: "active-space",
            spaces: [
                SpaceConfig(
                    id: "active-space",
                    name: "Active",
                    emoji: "🏠",
                    projectIds: [activeProject.id],
                    lastSelectedWorktreeId: nil,
                    createdAt: .distantPast
                ),
                SpaceConfig(
                    id: "other-space",
                    name: "Other",
                    emoji: "💼",
                    projectIds: [otherSpaceProject.id],
                    lastSelectedWorktreeId: nil,
                    createdAt: .distantPast
                ),
            ]
        )
        let state = AppState(
            store: MemoryStore(
                projectsFile: ProjectsFile(projects: [activeProject, otherSpaceProject]),
                spacesFile: spaces
            ),
            runHistoryStore: try RunHistoryStore(
                path: repo.appendingPathComponent("run-history.sqlite").path
            )
        )
        let projectWorktree = try await WorktreeService().add(
            repoPath: repo,
            base: "main",
            branch: "feature/active-space-delete",
            destination: linked,
            projectId: activeProject.id
        )
        try await state.projectsManager.refreshWorktrees(projectId: activeProject.id)
        let target = try #require(state.projectsManager.worktrees(projectId: activeProject.id)
            .first(where: { $0.id == projectWorktree.id }))
        let otherSpaceDuplicate = Worktree(
            id: target.id,
            projectId: otherSpaceProject.id,
            name: target.name,
            branch: target.branch,
            path: target.path,
            status: .clean,
            lastActivity: .distantPast
        )
        state.projectsManager.insertOptimisticWorktree(otherSpaceDuplicate)
        #expect(state.activeSpaceProjects.map(\.id) == [activeProject.id])
        state.selectWorktree(id: target.id)

        #expect(await state.cliDeleteWorktree(target, force: true, keepBranch: true) == .ok)
        try await waitForOperationState(state.projectsManager, id: target.id, projectId: activeProject.id, equals: nil)
        try await waitForWorktreeRemoved(
            state.projectsManager,
            projectId: activeProject.id,
            worktreeId: target.id
        )

        let mainWorktreeID = try #require(state.projectsManager.worktrees(projectId: activeProject.id).first?.id)
        #expect(state.projectsManager.worktrees(projectId: otherSpaceProject.id).contains { $0.id == target.id })
        try await waitForSelectedWorktree(state, equals: mainWorktreeID)
        #expect(state.selectedWorktreeId == mainWorktreeID)
    }

    /// A checkout recreated at the deleted path before the post-delete refresh
    /// keeps the same path-derived id, so the refresh cannot tell the new row
    /// apart from the removed one and leaves the `.deleting` claim in place —
    /// hiding the new checkout from the right pane and blocking its sessions
    /// forever. The removal has succeeded by then, so the claim is released
    /// regardless of what now holds that id.
    @Test func singleDeleteReleasesTheClaimWhenThePathIsRecreated() async throws {
        final class Recreation {
            var repoPath: URL?
            var deletedPath: URL?
            var templatePath: URL?
            var recreated = false
        }
        let recreation = Recreation()
        // Runs after the removal succeeded and before the post-delete refresh.
        let probe = WorktreeCleanupProbe()
        let state = AppState(
            worktreeCleanupLauncher: { ticket in
                probe.launchedTickets.append(ticket)
                guard let repoPath = recreation.repoPath,
                      let deletedPath = recreation.deletedPath,
                      let templatePath = recreation.templatePath,
                      !recreation.recreated
                else { return }
                recreation.recreated = true
                try Process.registerWorktree(
                    deletedPath,
                    branch: "feature/recreated-path-template",
                    repoPath: repoPath,
                    template: templatePath
                )
            }
        )
        let repo = try await makeRepo(name: "delete-recreated-path")
        let linked = repo.deletingLastPathComponent()
            .appendingPathComponent("delete-recreated-path-linked-\(UUID().uuidString)")
        let template = repo.deletingLastPathComponent()
            .appendingPathComponent("delete-recreated-path-template-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: linked)
            try? FileManager.default.removeItem(at: template)
            try? FileManager.default.removeItem(at: repo)
            for ticket in probe.launchedTickets {
                try? FileManager.default.removeItem(at: ticket.trashRoot)
            }
        }
        let project = try await state.projectsManager.addProject(
            path: repo,
            displayName: "delete-recreated-path",
            color: "#5fb7c4"
        )
        let worktree = try await WorktreeService().add(
            repoPath: repo,
            base: "main",
            branch: "feature/recreated-path",
            destination: linked,
            projectId: project.id
        )
        // A sibling that survives this deletion, so the recreated checkout has
        // a live git-administrative directory to copy.
        _ = try await WorktreeService().add(
            repoPath: repo,
            base: "main",
            branch: "feature/recreated-path-template",
            destination: template,
            projectId: project.id
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        recreation.repoPath = repo
        recreation.deletedPath = linked
        recreation.templatePath = template

        #expect(await state.cliDeleteWorktree(worktree, force: true, keepBranch: true) == .ok)
        try await waitForOperationState(state.projectsManager, id: worktree.id, projectId: project.id, equals: nil)

        #expect(recreation.recreated)
        // The recreated checkout carries the same path-derived id, so the
        // refresh lists it and cannot clear the claim itself. The claim must
        // not survive: it would hide the new checkout from the right pane and
        // block its sessions for good.
        #expect(state.projectsManager
            .worktrees(projectId: project.id)
            .contains { $0.id == worktree.id })
        #expect(state.projectsManager.operationState(for: worktree) == nil)
    }

    @Test func cleanupLaunchFailureLeavesWorktreeDeletedForStaleRecovery() async throws {
        let repo = try await makeRepo(name: "delete-cleanup-launch-failure")
        let linked = repo.deletingLastPathComponent()
            .appendingPathComponent("delete-cleanup-launch-failure-linked-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: linked)
            try? FileManager.default.removeItem(at: repo)
        }
        let probe = WorktreeCleanupProbe()
        let state = AppState(
            worktreeCleanupLauncher: { ticket in
                probe.launchedTickets.append(ticket)
                throw CocoaError(.fileWriteUnknown)
            }
        )
        let project = try await state.projectsManager.addProject(
            path: repo,
            displayName: "delete-cleanup-launch-failure",
            color: "#5fb7c4"
        )
        let worktree = try await WorktreeService().add(
            repoPath: repo,
            base: "main",
            branch: "feature/cleanup-launch-failure",
            destination: linked,
            projectId: project.id
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)

        #expect(await state.cliDeleteWorktree(worktree, force: true, keepBranch: true) == .ok)
        try await waitForOperationState(state.projectsManager, id: worktree.id, projectId: project.id, equals: nil)
        try await waitForWorktreeRemoved(
            state.projectsManager,
            projectId: project.id,
            worktreeId: worktree.id
        )

        let ticket = try #require(probe.launchedTickets.first)
        defer { try? FileManager.default.removeItem(at: ticket.trashRoot) }
        #expect(probe.launchedTickets.count == 1)
        #expect(FileManager.default.fileExists(atPath: ticket.stagedPath.path))
        #expect(!state.projectsManager.worktrees(projectId: project.id).contains { $0.id == worktree.id })
        #expect(state.projectsManager.operationState(for: worktree) == nil)
    }

    // MARK: - Dirty-worktree force-delete state

    @Test func removalRefusalMatchesDirtyAndLockedButNotSubmodules() {
        #expect(AppState.requiresForceRetry(forRemovalRefusal: "Cannot delete a dirty worktree"))
        #expect(AppState.requiresForceRetry(forRemovalRefusal: "fatal: 'foo' contains modified or untracked files"))
        #expect(AppState.requiresForceRetry(forRemovalRefusal: "worktree is dirty and cannot be removed"))
        #expect(AppState.requiresForceRetry(forRemovalRefusal: "fatal: cannot remove a locked working tree;\nuse 'remove -f -f' to override or unlock first"))
        // Git's submodule refusal is answered inside WorktreeService, never by
        // asking the user to force.
        #expect(!AppState.requiresForceRetry(forRemovalRefusal: "fatal: working trees containing submodules cannot be moved or removed"))
        #expect(!AppState.requiresForceRetry(forRemovalRefusal: "fatal: not a git repository"))
        #expect(!AppState.requiresForceRetry(forRemovalRefusal: ""))
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

    @Test func deleteConfirmationAnnouncesBranchDeletion() {
        let confirmation = AppState.deleteConfirmation(branch: "feature/clean", keepBranch: false)

        #expect(confirmation == AppState.WorktreeDeleteConfirmation(
            title: "Delete worktree 'feature/clean'?",
            message: "This removes its files from disk. The local branch will be deleted if merged."
        ))
    }

    @Test func deleteConfirmationAnnouncesBranchRetention() {
        let confirmation = AppState.deleteConfirmation(branch: "feature/keep", keepBranch: true)

        #expect(confirmation == AppState.WorktreeDeleteConfirmation(
            title: "Delete worktree 'feature/keep'?",
            message: "This removes its files from disk. The local branch will be kept."
        ))
    }

    @Test func submoduleRemoveErrorIsNotUserForceable() {
        let worktree = Worktree(
            id: "wt-submodule",
            projectId: "project",
            name: "feature/submodule",
            branch: "feature/submodule",
            path: URL(fileURLWithPath: "/tmp/repo-worktree"),
            status: .clean,
            lastActivity: Date(timeIntervalSince1970: 0)
        )

        let pending = AppState.pendingForceDelete(
            for: worktree,
            repoPath: URL(fileURLWithPath: "/tmp/repo"),
            deleteBranchIfMerged: true,
            removedIndex: 2,
            stderr: "fatal: working trees containing submodules cannot be moved or removed"
        )

        #expect(pending == nil)
    }

    /// Regression: a locked worktree used to have no path back to the force
    /// confirmation — the row failed with git's raw refusal and every retry
    /// failed identically, since only dirty/submodule stderr was recognized.
    @Test func lockedRemoveErrorBuildsPendingForceDeleteFallback() {
        let repoPath = URL(fileURLWithPath: "/tmp/repo")
        let worktreePath = URL(fileURLWithPath: "/tmp/repo-worktree-locked")
        let worktree = Worktree(
            id: "wt-locked",
            projectId: "project",
            name: "feature/locked",
            branch: "feature/locked",
            path: worktreePath,
            status: .clean,
            lastActivity: Date(timeIntervalSince1970: 0)
        )

        let pending = AppState.pendingForceDelete(
            for: worktree,
            repoPath: repoPath,
            deleteBranchIfMerged: true,
            removedIndex: 3,
            stderr: "fatal: cannot remove a locked working tree;\nuse 'remove -f -f' to override or unlock first"
        )

        #expect(pending?.id == worktree.id)
        #expect(pending?.worktreePath == worktreePath)
        #expect(pending?.removedIndex == 3)
    }

    @Test func dirtyRemoveErrorBuildsPendingForceDeleteFallback() {
        let repoPath = URL(fileURLWithPath: "/tmp/repo")
        let worktreePath = URL(fileURLWithPath: "/tmp/repo-worktree")
        let worktree = Worktree(
            id: "wt-dirty",
            projectId: "project",
            name: "feature/dirty",
            branch: "feature/dirty",
            path: worktreePath,
            status: .clean,
            lastActivity: Date(timeIntervalSince1970: 0)
        )

        let pending = AppState.pendingForceDelete(
            for: worktree,
            repoPath: repoPath,
            deleteBranchIfMerged: true,
            removedIndex: 2,
            stderr: "fatal: 'foo' contains modified or untracked files"
        )

        #expect(pending?.id == worktree.id)
        #expect(pending?.branch == worktree.branch)
        #expect(pending?.projectId == worktree.projectId)
        #expect(pending?.repoPath == repoPath)
        #expect(pending?.worktreePath == worktreePath)
        #expect(pending?.deleteBranchIfMerged == true)
        #expect(pending?.removedIndex == 2)
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
            removedIndex: 0
        )
        #expect(state.pendingForceDeleteWorktree != nil)

        state.cancelForceDeletePendingWorktree()
        #expect(state.pendingForceDeleteWorktree == nil)
        #expect(state.projectsManager.operationState(forWorktreeId: wt.id, projectId: project.id) == nil)
    }

    /// Regression: the force-delete alert used to clear operation state to
    /// `nil` while it waited on the user, leaving the worktree unclaimed —
    /// a scheduled run or remote session could be admitted during that
    /// window, then have its writes silently discarded once the user
    /// confirmed force delete (which skips the cleanliness audits).
    @Test func preparingDeleteDuringForceAlertBlocksAdmissionUntilResolved() async throws {
        let repo = try await makeRepo(name: "force-alert-claim")
        defer { try? FileManager.default.removeItem(at: repo) }
        let state = AppState()
        let project = try await state.projectsManager.addProject(path: repo, displayName: "force-alert-claim", color: "#5fb7c4")
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        let trees = state.projectsManager.worktrees(projectId: project.id)
        let wt = try #require(trees.first)

        state.projectsManager.setOperationState(forWorktreeId: wt.id, projectId: project.id, state: .preparingDelete)
        state.pendingForceDeleteWorktree = AppState.PendingForceDeleteWorktree(
            id: wt.id,
            branch: wt.branch,
            projectId: wt.projectId,
            repoPath: repo,
            worktreePath: wt.path,
            deleteBranchIfMerged: false,
            removedIndex: 0
        )

        #expect(AppState.blocksWorktreeSessionAdmission(state.projectsManager.operationState(forWorktreeId: wt.id, projectId: project.id)))

        state.cancelForceDeletePendingWorktree()

        #expect(state.pendingForceDeleteWorktree == nil)
        #expect(state.projectsManager.operationState(forWorktreeId: wt.id, projectId: project.id) == nil)
    }

    /// Regression: a worktree removed externally (another terminal, `git
    /// worktree prune`) while its `.preparingDelete` claim was still up had
    /// nothing to ever clear that claim — confirming looks the worktree up
    /// by id, fails, and returns before touching operation state;
    /// cancelling only clears it when the state still matches
    /// `.preparingDelete` for a *live* worktree. A worktree recreated at
    /// the same path reuses the id, so the stale claim would block its new
    /// incarnation from session admission until app restart.
    @Test func preparingDeleteClaimClearsWhenWorktreeIsRemovedExternally() async throws {
        let repo = try await makeRepo(name: "external-removal")
        defer { try? FileManager.default.removeItem(at: repo) }
        let state = AppState()
        let project = try await state.projectsManager.addProject(path: repo, displayName: "external-removal", color: "#5fb7c4")
        let worktreePath = repo.deletingLastPathComponent().appendingPathComponent("external-removal-target")
        defer { try? FileManager.default.removeItem(at: worktreePath) }
        _ = try await Process.git(["worktree", "add", "-q", "-b", "external-removal-target", worktreePath.path, "main"], cwd: repo)
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        let target = try #require(state.projectsManager.worktrees(projectId: project.id).first { $0.branch == "external-removal-target" })

        state.projectsManager.setOperationState(forWorktreeId: target.id, projectId: project.id, state: .preparingDelete)

        _ = try await Process.git(["worktree", "remove", "--force", worktreePath.path], cwd: repo)
        try await state.projectsManager.refreshWorktrees(projectId: project.id)

        #expect(state.projectsManager.operationState(forWorktreeId: target.id, projectId: project.id) == nil)
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

    @Test func removingSharedPathProjectClosesOnlyItsOwnedTabsAndManager() throws {
        let sharedPath = "/tmp/alas-cleanup-shared-\(UUID().uuidString)"
        let projectA = ProjectConfig(
            id: "host-a-\(UUID().uuidString)",
            name: "Host A",
            path: "/repos/a",
            color: "blue",
            addedAt: .distantPast,
            host: "host-a"
        )
        let projectB = ProjectConfig(
            id: "host-b-\(UUID().uuidString)",
            name: "Host B",
            path: "/repos/b",
            color: "green",
            addedAt: .distantPast,
            host: "host-b"
        )
        let state = AppState(store: MemoryStore(projectsFile: ProjectsFile(projects: [projectA, projectB])))
        let first = Worktree(
            id: sharedPath,
            projectId: projectA.id,
            name: "shared",
            branch: "main",
            path: URL(fileURLWithPath: sharedPath),
            status: .clean,
            lastActivity: .distantPast
        )
        let second = Worktree(
            id: sharedPath,
            projectId: projectB.id,
            name: "shared",
            branch: "main",
            path: URL(fileURLWithPath: sharedPath),
            status: .clean,
            lastActivity: .distantPast
        )
        let ownerA = SessionOwnerID.projectWorktree(projectId: projectA.id, worktreeId: sharedPath)
        let ownerB = SessionOwnerID.projectWorktree(projectId: projectB.id, worktreeId: sharedPath)
        let databases = [Paths.acpSessionsDB(for: ownerA), Paths.acpSessionsDB(for: ownerB)]
        defer {
            try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: sharedPath))
            for database in databases {
                try? FileManager.default.removeItem(at: database)
                try? FileManager.default.removeItem(atPath: database.path + "-wal")
                try? FileManager.default.removeItem(atPath: database.path + "-shm")
            }
        }
        state.projectsManager.insertOptimisticWorktree(first)
        state.projectsManager.insertOptimisticWorktree(second)

        let managerA = try #require(state.acpManager(for: first))
        let managerB = try #require(state.acpManager(for: second))
        let sessionA = managerA.createSession(agentId: "test-agent")
        let sessionB = managerB.createSession(agentId: "test-agent")
        let tabA = state.tabs.append(acpSession: .init(
            sessionId: sessionA.id,
            title: "Host A session",
            projectId: projectA.id
        ), to: sharedPath)
        let tabB = state.tabs.append(acpSession: .init(
            sessionId: sessionB.id,
            title: "Host B session",
            projectId: projectB.id
        ), to: sharedPath)
        let terminalA = state.tabs.appendTerminal(
            worktreeId: sharedPath,
            projectId: projectA.id,
            title: "Host A terminal",
            sessionId: "host-a-terminal"
        )
        let terminalB = state.tabs.appendTerminal(
            worktreeId: sharedPath,
            projectId: projectB.id,
            title: "Host B terminal",
            sessionId: "host-b-terminal"
        )
        let sharedTerminal = state.tabs.appendTerminal(
            worktreeId: sharedPath,
            title: "Legacy shared terminal",
            sessionId: "shared-terminal"
        )

        state.removeProject(id: projectA.id)

        #expect(state.acpManager(for: ownerA) == nil)
        #expect(state.acpManager(for: ownerB) === managerB)
        let remainingTabs = state.tabs.tabs(forWorktree: sharedPath)
        #expect(!remainingTabs.contains(where: { $0.id == tabA.id }))
        #expect(remainingTabs.contains(where: { $0.id == tabB.id }))
        #expect(!remainingTabs.contains(where: { $0.id == terminalA.id }))
        #expect(remainingTabs.contains(where: { $0.id == terminalB.id }))
        #expect(remainingTabs.contains(where: { $0.id == sharedTerminal.id }))
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
        state.projectsManager.setOperationState(forWorktreeId: wt.id, projectId: project.id, state: .deleteFailed(message: "permission denied"))
        state.projectsManager.setGGWorktreeMode(projectId: project.id, worktreeId: wt.id, mode: .on)
        state.selectedWorktreeId = wt.id

        // Archive should succeed and hide the worktree.
        state.archiveWorktree(wt)

        #expect(state.projectsManager.isWorktreeHidden(projectId: project.id, path: wt.path))
        #expect(state.projectsManager.archivedWorktrees(projectId: project.id).count == 1)
        #expect(state.projectsManager.visibleWorktrees(projectId: project.id).isEmpty)
        #expect(state.projectsManager.ggWorktreeMode(projectId: project.id, worktreeId: wt.id) == .on)
        // Operation state should be cleared.
        #expect(state.projectsManager.operationState(forWorktreeId: wt.id, projectId: project.id) == nil)
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

        state.projectsManager.setOperationState(forWorktreeId: wt.id, projectId: project.id, state: .deleteFailed(message: "permission denied"))
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
        projectId: String,
        equals expected: WorktreeOperationState?
    ) async throws {
        try await waitForOperationStateMatching(manager, id: id, projectId: projectId) { $0 == expected }
    }

    private func waitForOperationStateMatching(
        _ manager: ProjectsManager,
        id: String,
        projectId: String,
        matches: (WorktreeOperationState?) -> Bool
    ) async throws {
        for _ in 0..<80 {
            if matches(manager.operationState(forWorktreeId: id, projectId: projectId)) {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        Issue.record("Timed out waiting for operation state")
    }

    private func waitForWorktreeRemoved(
        _ manager: ProjectsManager,
        projectId: String,
        worktreeId: String
    ) async throws {
        for _ in 0..<80 {
            if !manager.worktrees(projectId: projectId).contains(where: { $0.id == worktreeId }) {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        Issue.record("Timed out waiting for worktree removal")
    }

    private func waitForACPTab(
        _ state: AppState,
        worktreeId: String,
        sessionId: String
    ) async throws {
        for _ in 0..<80 {
            if state.tabs.tabs(forWorktree: worktreeId).contains(where: { tab in
                guard case .acpSession(let session) = tab else { return false }
                return session.sessionId == sessionId
            }) {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        Issue.record("Timed out waiting for ACP launch completion")
    }

    private func waitForSelectedWorktree(
        _ state: AppState,
        equals expected: String
    ) async throws {
        for _ in 0..<80 {
            if state.selectedWorktreeId == expected {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        Issue.record("Timed out waiting for selected worktree")
    }
}
