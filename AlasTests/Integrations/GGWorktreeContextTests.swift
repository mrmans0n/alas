import Foundation
import Testing
@testable import Alas

struct GGWorktreeContextTests {
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
        state.rightPaneStore.deactivate()

        pane.currentBranch = "main"
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
    }
}
