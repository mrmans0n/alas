import Foundation
import Testing
@testable import Alas

private actor HeadUpdateCountingGGRunner: GGCommandRunning {
    private var callCount = 0

    func run(args _: [String], cwd _: URL?) async throws -> ProcessResult {
        callCount += 1
        return ProcessResult(
            exitCode: 0,
            stdout: #"{"version":1,"stack":null}"#,
            stderr: ""
        )
    }

    func calls() -> Int {
        callCount
    }
}

struct GGWorktreeContextTests {
    @Test func policyResolverPreservesWorktreeSemantics() {
        #expect(GGWorktreeContextResolver.isPolicyEnabled(
            projectMode: .auto,
            worktreeOverride: .inherit,
            isMainWorktree: false,
            repoHasGGConfig: true
        ))
        #expect(!GGWorktreeContextResolver.isPolicyEnabled(
            projectMode: .on,
            worktreeOverride: .inherit,
            isMainWorktree: true,
            repoHasGGConfig: true
        ))
        #expect(GGWorktreeContextResolver.isPolicyEnabled(
            projectMode: .off,
            worktreeOverride: .on,
            isMainWorktree: false,
            repoHasGGConfig: false
        ))
        #expect(!GGWorktreeContextResolver.isPolicyEnabled(
            projectMode: .on,
            worktreeOverride: .off,
            isMainWorktree: false,
            repoHasGGConfig: true
        ))
    }

    private func project(mode: GGProjectMode, host: String? = nil) -> ProjectConfig {
        ProjectConfig(
            id: "project",
            name: "Alas",
            path: "/tmp/alas",
            color: "teal",
            addedAt: .now,
            host: host,
            ggMode: mode
        )
    }

    private func resolve(
        masterEnabled: Bool = true,
        ggInstalled: Bool = true,
        isRemoteProject: Bool = false,
        projectMode: GGProjectMode = .auto,
        worktreeOverride: GGWorktreeMode = .inherit,
        isMainWorktree: Bool = false,
        repoHasGGConfig: Bool = true,
        branchUsername: String? = "nacho",
        branch: String = "nacho/my-stack"
    ) -> GGWorktreeContext {
        GGWorktreeContextResolver.resolve(
            masterEnabled: masterEnabled,
            ggInstalled: ggInstalled,
            isRemoteProject: isRemoteProject,
            projectMode: projectMode,
            worktreeOverride: worktreeOverride,
            isMainWorktree: isMainWorktree,
            repoHasGGConfig: repoHasGGConfig,
            branchUsername: branchUsername,
            branch: branch
        )
    }

    @Test(arguments: [
        (GGProjectMode.off, true, GGWorktreeContext.inactive(reason: .policyOff)),
        (.auto, false, .inactive(reason: .policyOff)),
        (.auto, true, .active(stackName: "my-stack")),
        (.on, false, .active(stackName: "my-stack")),
    ])
    func linkedWorktreeUsesProjectMode(
        mode: GGProjectMode,
        hasConfig: Bool,
        expected: GGWorktreeContext
    ) {
        #expect(resolve(projectMode: mode, repoHasGGConfig: hasConfig) == expected)
    }

    @Test(arguments: GGProjectMode.allCases)
    func mainWorktreeInheritedDefaultIsOff(mode: GGProjectMode) {
        #expect(resolve(projectMode: mode, isMainWorktree: true) == .inactive(reason: .policyOff))
    }

    @Test func explicitOverridesWinInBothDirections() {
        #expect(resolve(projectMode: .off, worktreeOverride: .on) == .active(stackName: "my-stack"))
        #expect(resolve(projectMode: .on, worktreeOverride: .off) == .inactive(reason: .policyOff))
        #expect(resolve(projectMode: .off, worktreeOverride: .on, isMainWorktree: true) == .active(stackName: "my-stack"))
    }

    @Test func globalCLIAndRemoteChecksAreHardStops() {
        #expect(resolve(masterEnabled: false, worktreeOverride: .on) == .inactive(reason: .masterDisabled))
        #expect(resolve(ggInstalled: false, worktreeOverride: .on) == .inactive(reason: .cliMissing))
        #expect(resolve(isRemoteProject: true, worktreeOverride: .on) == .inactive(reason: .remoteProject))
    }

    @Test func missingBranchUsernameIsInactive() {
        #expect(resolve(branchUsername: nil) == .inactive(reason: .branchUsernameMissing))
        #expect(resolve(branchUsername: "") == .inactive(reason: .branchUsernameMissing))
    }

    @Test func stackNameAcceptsSimpleAndNestedNames() {
        #expect(GGWorktreeContextResolver.stackName(branch: "nacho/feature", username: "nacho") == "feature")
        #expect(GGWorktreeContextResolver.stackName(branch: "nacho/team/feature", username: "nacho") == "team/feature")
        #expect(resolve(branch: "nacho/team/feature") == .active(stackName: "team/feature"))
        #expect(resolve(branch: "nacho/team/feature").isActive)
    }

    @Test func stackNameRejectsEmptyNameAndWrongPrefix() {
        #expect(GGWorktreeContextResolver.stackName(branch: "nacho/", username: "nacho") == nil)
        #expect(GGWorktreeContextResolver.stackName(branch: "other/feature", username: "nacho") == nil)
        #expect(resolve(branch: "nacho/") == .inactive(reason: .branchPrefixMismatch(expectedPrefix: "nacho/")))
        #expect(resolve(branch: "other/feature") == .inactive(reason: .branchPrefixMismatch(expectedPrefix: "nacho/")))
        #expect(!resolve(branch: "other/feature").isActive)
    }

    @Test func appStateMappingPropagatesProjectModeAndRepoConfig() {
        #expect(AppState.resolveGGWorktreeContext(
            masterEnabled: true,
            ggInstalled: true,
            project: project(mode: .auto),
            worktreeOverride: .inherit,
            isMainWorktree: false,
            repoHasGGConfig: false,
            branchUsername: "nacho",
            branch: "nacho/feature"
        ) == .inactive(reason: .policyOff))
        #expect(AppState.resolveGGWorktreeContext(
            masterEnabled: true,
            ggInstalled: true,
            project: project(mode: .auto),
            worktreeOverride: .inherit,
            isMainWorktree: false,
            repoHasGGConfig: true,
            branchUsername: "nacho",
            branch: "nacho/feature"
        ) == .active(stackName: "feature"))
    }

    @Test func appStateMappingPropagatesMasterAndAvailability() {
        #expect(AppState.resolveGGWorktreeContext(
            masterEnabled: false,
            ggInstalled: true,
            project: project(mode: .on),
            worktreeOverride: .on,
            isMainWorktree: false,
            repoHasGGConfig: true,
            branchUsername: "nacho",
            branch: "nacho/feature"
        ) == .inactive(reason: .masterDisabled))
        #expect(AppState.resolveGGWorktreeContext(
            masterEnabled: true,
            ggInstalled: false,
            project: project(mode: .on),
            worktreeOverride: .on,
            isMainWorktree: false,
            repoHasGGConfig: true,
            branchUsername: "nacho",
            branch: "nacho/feature"
        ) == .inactive(reason: .cliMissing))
    }

    @Test func appStateMappingPropagatesOverrideAndMainIdentity() {
        #expect(AppState.resolveGGWorktreeContext(
            masterEnabled: true,
            ggInstalled: true,
            project: project(mode: .off),
            worktreeOverride: .on,
            isMainWorktree: true,
            repoHasGGConfig: false,
            branchUsername: "nacho",
            branch: "nacho/forced"
        ) == .active(stackName: "forced"))
        #expect(AppState.resolveGGWorktreeContext(
            masterEnabled: true,
            ggInstalled: true,
            project: project(mode: .on),
            worktreeOverride: .inherit,
            isMainWorktree: true,
            repoHasGGConfig: true,
            branchUsername: "nacho",
            branch: "nacho/main"
        ) == .inactive(reason: .policyOff))
    }

    @Test func appStateMappingPropagatesRemoteAndLiveBranch() {
        #expect(AppState.resolveGGWorktreeContext(
            masterEnabled: true,
            ggInstalled: true,
            project: project(mode: .on, host: "build-host"),
            worktreeOverride: .on,
            isMainWorktree: false,
            repoHasGGConfig: true,
            branchUsername: "nacho",
            branch: "nacho/live-branch"
        ) == .inactive(reason: .remoteProject))
        #expect(AppState.resolveGGWorktreeContext(
            masterEnabled: true,
            ggInstalled: true,
            project: project(mode: .on),
            worktreeOverride: .inherit,
            isMainWorktree: false,
            repoHasGGConfig: true,
            branchUsername: "nacho",
            branch: "other/live-branch"
        ) == .inactive(reason: .branchPrefixMismatch(expectedPrefix: "nacho/")))
    }
}

@MainActor
struct ProjectsManagerGGWorktreeModeTests {
    @Test func managerGetsSetsAndRemovesSparseOverrides() {
        let project = ProjectConfig(
            id: "project", name: "Alas", path: "/tmp/alas", color: "teal", addedAt: .now
        )
        let manager = ProjectsManager(persistedProjects: [project])

        #expect(manager.ggWorktreeMode(projectId: project.id, worktreeId: "worktree") == .inherit)

        manager.setGGWorktreeMode(projectId: project.id, worktreeId: "worktree", mode: .on)
        #expect(manager.ggWorktreeMode(projectId: project.id, worktreeId: "worktree") == .on)
        #expect(manager.projects[0].ggWorktreeModes == ["worktree": .on])

        manager.setGGWorktreeMode(projectId: project.id, worktreeId: "worktree", mode: .inherit)
        #expect(manager.ggWorktreeMode(projectId: project.id, worktreeId: "worktree") == .inherit)
        #expect(manager.projects[0].ggWorktreeModes.isEmpty)

        manager.setGGWorktreeMode(projectId: project.id, worktreeId: "worktree", mode: .off)
        manager.removeGGWorktreeMode(projectId: project.id, worktreeId: "worktree")
        #expect(manager.ggWorktreeMode(projectId: project.id, worktreeId: "worktree") == .inherit)
    }

    @Test func managerIgnoresUnknownProjects() {
        let manager = ProjectsManager(persistedProjects: [])
        manager.setGGWorktreeMode(projectId: "missing", worktreeId: "worktree", mode: .on)
        manager.removeGGWorktreeMode(projectId: "missing", worktreeId: "worktree")
        #expect(manager.ggWorktreeMode(projectId: "missing", worktreeId: "worktree") == .inherit)
        #expect(manager.projects.isEmpty)
    }
}

@MainActor
@Suite(.serialized)
struct AppStateGGACPWorktreeContextTests {
    private struct MemoryStore: PersistenceStoreProtocol {
        let projectsFile: ProjectsFile

        func write<T: Encodable>(_: T, to _: URL) throws {}

        func readIfExists<T: Decodable>(_ type: T.Type, from _: URL) throws -> T? {
            type == ProjectsFile.self ? projectsFile as? T : nil
        }
    }

    @Test func topologyBranchChangeClearsCachedSidebarSummary() {
        let project = ProjectConfig(
            id: "project",
            name: "Alas",
            path: "/tmp/alas-summary-project",
            color: "teal",
            addedAt: .now
        )
        let state = AppState(store: MemoryStore(projectsFile: ProjectsFile(projects: [project])))
        let path = URL(fileURLWithPath: "/tmp/alas-summary-linked")
        let worktree = Worktree(
            id: Worktree.makeId(path: path),
            projectId: project.id,
            name: "nacho/old-stack",
            branch: "nacho/old-stack",
            path: path,
            status: .clean,
            lastActivity: .now
        )
        state.projectsManager.insertOptimisticWorktree(worktree)
        GGStackSummaryStore.shared.summaries[path.path] = GGStackSummary(merged: 1, total: 2)
        defer { GGStackSummaryStore.shared.summaries[path.path] = nil }

        state.handleProjectHeadUpdates(
            projectId: project.id,
            branchByWorktreePath: [path: "nacho/new-stack"]
        )

        #expect(GGStackSummaryStore.shared.summaries[path.path] == nil)
    }

    @Test func sameLabelDetachedHeadUpdateClearsOnlyReportedSidebarSummary() {
        let project = ProjectConfig(
            id: "project",
            name: "Alas",
            path: "/tmp/alas-detached-summary-project",
            color: "teal",
            addedAt: .now
        )
        let state = AppState(store: MemoryStore(projectsFile: ProjectsFile(projects: [project])))
        let changedPath = URL(fileURLWithPath: "/tmp/alas-detached-summary-changed")
        let unchangedPath = URL(fileURLWithPath: "/tmp/alas-detached-summary-unchanged")
        for path in [changedPath, unchangedPath] {
            state.projectsManager.insertOptimisticWorktree(Worktree(
                id: Worktree.makeId(path: path),
                projectId: project.id,
                name: "(detached)",
                branch: "(detached)",
                path: path,
                status: .clean,
                lastActivity: .now
            ))
        }
        let changedSummary = GGStackSummary(merged: 1, total: 2)
        let unchangedSummary = GGStackSummary(merged: 2, total: 3)
        GGStackSummaryStore.shared.summaries[changedPath.path] = changedSummary
        GGStackSummaryStore.shared.summaries[unchangedPath.path] = unchangedSummary
        defer {
            GGStackSummaryStore.shared.summaries[changedPath.path] = nil
            GGStackSummaryStore.shared.summaries[unchangedPath.path] = nil
        }

        state.handleProjectHeadUpdates(
            projectId: project.id,
            branchByWorktreePath: [changedPath: "(detached)"]
        )

        #expect(GGStackSummaryStore.shared.summaries[changedPath.path] == nil)
        #expect(GGStackSummaryStore.shared.summaries[unchangedPath.path] == unchangedSummary)
    }

    @Test func fullTopologyRefreshClearsCachedSidebarSummaryWhenBranchChanges() async throws {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-gg-summary-topology-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "init"], cwd: repo)
        let state = AppState(store: MemoryStore(projectsFile: ProjectsFile(projects: [])))
        let project = try await state.projectsManager.addProject(
            path: repo,
            displayName: "topology",
            color: "teal"
        )
        await state.refreshProjectTopology(projectId: project.id)
        let worktreePath = try #require(state.projectsManager.worktrees(projectId: project.id).first?.path.path)
        GGStackSummaryStore.shared.summaries[worktreePath] = GGStackSummary(merged: 1, total: 2)
        defer { GGStackSummaryStore.shared.summaries[worktreePath] = nil }
        state.stopAllProjectGitWatchers()

        _ = try await Process.git(["checkout", "-q", "-b", "nacho/new-stack"], cwd: repo)
        await state.refreshProjectTopology(projectId: project.id)

        #expect(GGStackSummaryStore.shared.summaries[worktreePath] == nil)
    }

    @Test func cachedLiveBranchOverridesStaleTopologyForACPDecisions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-gg-acp-live-branch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git/gg"),
            withIntermediateDirectories: true
        )
        try Data(#"{"defaults":{"branch_username":"nacho"}}"#.utf8).write(
            to: root.appendingPathComponent(".git/gg/config.json")
        )

        let project = ProjectConfig(
            id: "project",
            name: "Alas",
            path: root.path,
            color: "teal",
            addedAt: .now,
            ggMode: .off
        )
        let state = AppState(store: MemoryStore(projectsFile: ProjectsFile(projects: [project])))
        let path = root.appendingPathComponent("linked")
        let topologyWorktree = Worktree(
            id: Worktree.makeId(path: path),
            projectId: project.id,
            name: "nacho/old-stack",
            branch: "nacho/old-stack",
            path: path,
            status: .clean,
            lastActivity: .now
        )
        state.projectsManager.insertOptimisticWorktree(topologyWorktree)
        state.projectsManager.setGGWorktreeMode(
            projectId: project.id,
            worktreeId: topologyWorktree.id,
            mode: .on
        )
        let fallback = try #require(state.ggACPWorktreeIntegration(
            worktreePath: path.path,
            ggInstalled: true
        ))
        #expect(fallback.context == .active(stackName: "old-stack"))

        let pane = state.rightPaneStore.state(
            for: topologyWorktree,
            baseBranch: "main",
            comparisonMode: .manual
        )

        pane.currentBranch = "main"
        _ = state.rightPaneStore.state(
            for: topologyWorktree,
            baseBranch: "main",
            comparisonMode: .manual
        )
        #expect(pane.currentBranch == "main")
        let plain = try #require(state.ggACPWorktreeIntegration(
            worktreePath: path.path,
            ggInstalled: true
        ))
        #expect(!AppState.shouldAttachGGMCP(context: plain.context))
        #expect(AppState.ggPreambleSignal(context: plain.context, snapshot: nil) == .none)

        state.projectsManager.applyHeadUpdates(
            projectId: project.id,
            branchByWorktreePath: [path: "main"]
        )
        #expect(state.projectsManager.worktrees(projectId: project.id).first?.branch == "main")
        pane.currentBranch = "nacho/new-stack"
        let stacked = try #require(state.ggACPWorktreeIntegration(
            worktreePath: path.path,
            ggInstalled: true
        ))
        #expect(AppState.shouldAttachGGMCP(context: stacked.context))
        #expect(AppState.ggPreambleSignal(context: stacked.context, snapshot: nil) == .generic)
        #expect(stacked.context == .active(stackName: "new-stack"))

        state.rightPaneStore.deactivate()
        let quiescent = try #require(state.ggACPWorktreeIntegration(
            worktreePath: path.path,
            ggInstalled: true
        ))
        #expect(!AppState.shouldAttachGGMCP(context: quiescent.context))
        #expect(AppState.ggPreambleSignal(context: quiescent.context, snapshot: nil) == .none)
        #expect(quiescent.context == .inactive(reason: .branchPrefixMismatch(expectedPrefix: "nacho/")))

        pane.currentBranch = "main"
        state.projectsManager.applyHeadUpdates(
            projectId: project.id,
            branchByWorktreePath: [path: "nacho/reactivated-stack"]
        )
        let reactivatedWorktree = try #require(
            state.projectsManager.worktrees(projectId: project.id).first
        )
        _ = state.rightPaneStore.state(
            for: reactivatedWorktree,
            baseBranch: "main",
            comparisonMode: .manual
        )
        let reactivated = try #require(state.ggACPWorktreeIntegration(
            worktreePath: path.path,
            ggInstalled: true
        ))
        #expect(AppState.shouldAttachGGMCP(context: reactivated.context))
        #expect(AppState.ggPreambleSignal(context: reactivated.context, snapshot: nil) == .generic)
        #expect(reactivated.context == .active(stackName: "reactivated-stack"))
    }

    @Test func quiescentDetachedTopologyLabelRetainsRecoveredStackForACP() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-gg-acp-detached-topology-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git/gg"),
            withIntermediateDirectories: true
        )
        try Data(#"{"defaults":{"branch_username":"nacho"}}"#.utf8).write(
            to: root.appendingPathComponent(".git/gg/config.json")
        )

        let project = ProjectConfig(
            id: "project",
            name: "Alas",
            path: root.path,
            color: "teal",
            addedAt: .now,
            ggMode: .off
        )
        let state = AppState(store: MemoryStore(projectsFile: ProjectsFile(projects: [project])))
        let path = root.appendingPathComponent("linked")
        let worktree = Worktree(
            id: Worktree.makeId(path: path),
            projectId: project.id,
            name: "nacho/old-stack",
            branch: "nacho/old-stack",
            path: path,
            status: .clean,
            lastActivity: .now
        )
        state.projectsManager.insertOptimisticWorktree(worktree)
        state.projectsManager.setGGWorktreeMode(
            projectId: project.id,
            worktreeId: worktree.id,
            mode: .on
        )
        let pane = state.rightPaneStore.state(
            for: worktree,
            baseBranch: "main",
            comparisonMode: .manual
        )
        state.rightPaneStore.deactivate()
        pane.currentBranch = ""
        pane.ggContext = .active(stackName: "agent-inbox")
        pane.ggStack = try GGStackSnapshot.decode(
            fromJSON: Data(GGStackModelsTests.fixture.utf8)
        ).stack
        pane.ggStackLoadState = .loaded
        pane.ggStackCommitsKey = pane.currentGGStackCommitsKey
        state.projectsManager.applyHeadUpdates(
            projectId: project.id,
            branchByWorktreePath: [path: "(detached)"]
        )
        #expect(state.projectsManager.worktrees(projectId: project.id).first?.branch == "(detached)")

        let integration = try #require(state.ggACPWorktreeIntegration(
            worktreePath: path.path,
            ggInstalled: true
        ))
        #expect(integration.context == .active(stackName: "agent-inbox"))
        let snapshot = try #require(state.rightPaneStore.ggStackSnapshotForWorktreePath(
            path.path,
            effectiveContext: integration.context,
            liveBranch: "(detached)"
        ))
        #expect(snapshot.loadState == .loaded)
    }

    @Test func detachedHeadUpdateScopesRecoveredStackInvalidationToReportedWorktree() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-gg-acp-detached-revision-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git/gg"),
            withIntermediateDirectories: true
        )
        try Data(#"{"defaults":{"branch_username":"nacho"}}"#.utf8).write(
            to: root.appendingPathComponent(".git/gg/config.json")
        )

        let project = ProjectConfig(
            id: "project",
            name: "Alas",
            path: root.path,
            color: "teal",
            addedAt: .now,
            ggMode: .off
        )
        let state = AppState(store: MemoryStore(projectsFile: ProjectsFile(projects: [project])))
        let changedPath = root.appendingPathComponent("changed")
        let unchangedPath = root.appendingPathComponent("unchanged")
        let changedWorktree = Worktree(
            id: Worktree.makeId(path: changedPath),
            projectId: project.id,
            name: "(detached)",
            branch: "(detached)",
            path: changedPath,
            status: .clean,
            lastActivity: .now
        )
        let unchangedWorktree = Worktree(
            id: Worktree.makeId(path: unchangedPath),
            projectId: project.id,
            name: "(detached)",
            branch: "(detached)",
            path: unchangedPath,
            status: .clean,
            lastActivity: .now
        )
        for worktree in [changedWorktree, unchangedWorktree] {
            state.projectsManager.insertOptimisticWorktree(worktree)
            state.projectsManager.setGGWorktreeMode(
                projectId: project.id,
                worktreeId: worktree.id,
                mode: .on
            )
        }
        let changedPane = state.rightPaneStore.state(
            for: changedWorktree,
            baseBranch: "main",
            comparisonMode: .manual
        )
        let unchangedPane = state.rightPaneStore.state(
            for: unchangedWorktree,
            baseBranch: "main",
            comparisonMode: .manual
        )
        changedPane.stop()
        unchangedPane.stop()
        defer { state.rightPaneStore.deactivate() }

        let stack = try GGStackSnapshot.decode(
            fromJSON: Data(GGStackModelsTests.fixture.utf8)
        ).stack
        changedPane.currentBranch = ""
        changedPane.ggContext = .active(stackName: "detached-a")
        changedPane.ggStack = stack
        changedPane.ggStackLoadState = .loaded
        changedPane.ggStackCommitsKey = changedPane.currentGGStackCommitsKey
        unchangedPane.currentBranch = ""
        unchangedPane.ggContext = .active(stackName: "detached-b")
        unchangedPane.ggStack = stack
        unchangedPane.ggStackLoadState = .loaded
        unchangedPane.ggStackCommitsKey = unchangedPane.currentGGStackCommitsKey
        let unchangedKey = try #require(unchangedPane.ggStackCommitsKey)
        let unchangedRunner = HeadUpdateCountingGGRunner()
        unchangedPane.ggService = GGService(runner: unchangedRunner)

        let beforeRevision = try #require(state.ggACPWorktreeIntegration(
            worktreePath: changedPath.path,
            ggInstalled: true
        ))
        #expect(beforeRevision.context == .active(stackName: "detached-a"))
        let beforeSnapshot = try #require(state.rightPaneStore.ggStackSnapshotForWorktreePath(
            changedPath.path,
            effectiveContext: beforeRevision.context,
            liveBranch: "(detached)"
        ))
        #expect(beforeSnapshot.loadState == .loaded)

        // A second detached SHA is indistinguishable in topology because the
        // watcher reports the same label for every detached HEAD.
        state.handleProjectHeadUpdates(
            projectId: project.id,
            branchByWorktreePath: [changedPath: "(detached)"]
        )
        #expect(state.revisionChangeGeneration(worktreeID: changedWorktree.id) == 1)

        let afterRevision = try #require(state.ggACPWorktreeIntegration(
            worktreePath: changedPath.path,
            ggInstalled: true
        ))
        #expect(afterRevision.context == .inactive(reason: .branchPrefixMismatch(expectedPrefix: "nacho/")))
        let afterSnapshot = try #require(state.rightPaneStore.ggStackSnapshotForWorktreePath(
            changedPath.path,
            effectiveContext: afterRevision.context,
            liveBranch: "(detached)"
        ))
        #expect(afterSnapshot.loadState == .inactive)

        let unchangedIntegration = try #require(state.ggACPWorktreeIntegration(
            worktreePath: unchangedPath.path,
            ggInstalled: true
        ))
        #expect(unchangedIntegration.context == .active(stackName: "detached-b"))
        let unchangedSnapshot = try #require(state.rightPaneStore.ggStackSnapshotForWorktreePath(
            unchangedPath.path,
            effectiveContext: unchangedIntegration.context,
            liveBranch: "(detached)"
        ))
        #expect(unchangedSnapshot.loadState == .loaded)
        #expect(unchangedPane.ggStackCommitsKey == unchangedKey)
        await Task.yield()
        #expect(await unchangedRunner.calls() == 0)
    }
}
