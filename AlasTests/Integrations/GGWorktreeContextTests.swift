import Testing
@testable import Alas

struct GGWorktreeContextTests {
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
