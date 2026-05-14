import Foundation
import Testing
@testable import Alas

struct NewWorktreeDialogTests {
    @Test func repositorySelectorShowsForGlobalCreation() {
        #expect(NewWorktreeDialog.showsRepositorySelector(
            presetProjectId: nil,
            projects: [Self.project(id: "repo-a")]
        ))
    }

    @Test func repositorySelectorIsHiddenForValidPreset() {
        #expect(!NewWorktreeDialog.showsRepositorySelector(
            presetProjectId: "repo-a",
            projects: [Self.project(id: "repo-a"), Self.project(id: "repo-b")]
        ))
    }

    @Test func repositorySelectorShowsForStalePreset() {
        #expect(NewWorktreeDialog.showsRepositorySelector(
            presetProjectId: "missing",
            projects: [Self.project(id: "repo-a")]
        ))
    }

    @Test func repositorySelectorStaysHiddenWhenThereAreNoProjects() {
        #expect(!NewWorktreeDialog.showsRepositorySelector(
            presetProjectId: nil,
            projects: []
        ))
    }

    @Test func resolvedPresetProjectReturnsMatchingProject() {
        let projects = [Self.project(id: "repo-a"), Self.project(id: "repo-b")]

        #expect(NewWorktreeDialog.resolvedPresetProject(
            presetProjectId: "repo-b",
            projects: projects
        )?.id == "repo-b")
    }

    @Test func preferredBaseBranchChoosesMainWhenNoConfiguredDefault() {
        let selected = NewWorktreeDialog.preferredBaseBranch(
            availableBranches: ["trunk", "master", "main"],
            configuredDefault: ""
        )

        #expect(selected == "main")
    }

    @Test func preferredBaseBranchUsesConfiguredDefaultOverMain() {
        let selected = NewWorktreeDialog.preferredBaseBranch(
            availableBranches: ["trunk", "master", "main", "develop"],
            configuredDefault: "develop"
        )

        #expect(selected == "develop")
    }

    @Test func preferredBaseBranchChoosesMasterBeforeTrunk() {
        let selected = NewWorktreeDialog.preferredBaseBranch(
            availableBranches: ["trunk", "master"],
            configuredDefault: ""
        )

        #expect(selected == "master")
    }

    @Test func preferredBaseBranchUsesConfiguredDefaultWhenAvailable() {
        let selected = NewWorktreeDialog.preferredBaseBranch(
            availableBranches: ["release/1.0", "develop"],
            configuredDefault: "develop"
        )

        #expect(selected == "develop")
    }

    @Test func preferredBaseBranchUsesFirstAvailableBeforeUnavailableDefault() {
        let selected = NewWorktreeDialog.preferredBaseBranch(
            availableBranches: ["release/1.0", "develop"],
            configuredDefault: "integration"
        )

        #expect(selected == "release/1.0")
    }

    @Test func preferredBaseBranchPreservesDefaultWhenNoBranchesAvailable() {
        let selected = NewWorktreeDialog.preferredBaseBranch(
            availableBranches: [],
            configuredDefault: "integration"
        )

        #expect(selected == "integration")
    }

    @Test func canCreateRequiresProjects() {
        #expect(!NewWorktreeDialog.canCreate(projectsEmpty: true, branchEmpty: false))
    }

    @Test func canCreateRequiresBranch() {
        #expect(!NewWorktreeDialog.canCreate(projectsEmpty: false, branchEmpty: true))
    }

    @Test func canCreateSucceedsWithProjectsAndBranch() {
        #expect(NewWorktreeDialog.canCreate(projectsEmpty: false, branchEmpty: false))
    }

    private static func project(id: String) -> ProjectConfig {
        ProjectConfig(
            id: id,
            name: "nacho/\(id)",
            path: "/tmp/\(id)",
            color: "#5fb7c4",
            addedAt: Date(timeIntervalSince1970: 0)
        )
    }
}
