import Foundation
import Testing
@testable import Alas

struct NewWorktreeDialogTests {
    @Test func repositorySelectorShowsForGlobalCreation() {
        #expect(NewWorktreeDialog.showsRepositorySelector(
            presetProjectId: nil,
            projects: [project(id: "repo-a")]
        ))
    }

    @Test func repositorySelectorIsHiddenForValidPreset() {
        #expect(!NewWorktreeDialog.showsRepositorySelector(
            presetProjectId: "repo-a",
            projects: [project(id: "repo-a"), project(id: "repo-b")]
        ))
    }

    @Test func repositorySelectorShowsForStalePreset() {
        #expect(NewWorktreeDialog.showsRepositorySelector(
            presetProjectId: "missing",
            projects: [project(id: "repo-a")]
        ))
    }

    @Test func repositorySelectorStaysHiddenWhenThereAreNoProjects() {
        #expect(!NewWorktreeDialog.showsRepositorySelector(
            presetProjectId: nil,
            projects: []
        ))
    }

    @Test func resolvedPresetProjectReturnsMatchingProject() {
        let projects = [project(id: "repo-a"), project(id: "repo-b")]

        #expect(NewWorktreeDialog.resolvedPresetProject(
            presetProjectId: "repo-b",
            projects: projects
        )?.id == "repo-b")
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
