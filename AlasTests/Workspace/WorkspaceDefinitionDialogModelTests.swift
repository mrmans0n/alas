import Foundation
import Testing
@testable import Alas

@Suite("Workspace definition dialog model")
struct WorkspaceDefinitionDialogModelTests {
    @Test func trimsNameFiltersToExactHostAndPreventsDuplicateMembers() {
        let local = project(id: "local", name: "Local", path: "/repos/local")
        let remote = project(id: "remote", name: "Remote", path: "/repos/remote", host: "builder")
        var model = WorkspaceDefinitionDialogModel(name: "  Release train  ", executionLocation: .local, projects: [local, remote])

        #expect(model.trimmedName == "Release train")
        #expect(model.eligibleProjects.map(\.id) == ["local"])
        let added = model.add(project: local)
        let duplicated = model.add(project: local)
        #expect(added)
        #expect(!duplicated)
        #expect(model.members.map(\.projectID) == ["local"])
    }

    @Test func preservesMemberIdentityAndOnlyChangesFutureDefinition() {
        let project = project(id: "one", name: "One", path: "/repos/one")
        let member = WorkspaceMember(projectID: project.id, fallbackProjectName: project.name, fallbackRepositoryRoot: project.path)
        let workspace = Workspace(name: "Release", executionLocation: .local, members: [member])
        var model = WorkspaceDefinitionDialogModel(editing: workspace, projects: [project])
        model.name = "  Next release "

        let definition = model.definition()

        #expect(definition.name == "Next release")
        #expect(definition.members.map(\.id) == [member.id])
        #expect(definition.id == workspace.id)
        #expect(model.saveTitle == "Save for Future Checkouts")
    }

    @Test func keepsOrderedMembershipWhenMovingMembers() {
        let one = project(id: "one", name: "One", path: "/repos/one")
        let two = project(id: "two", name: "Two", path: "/repos/two")
        var model = WorkspaceDefinitionDialogModel(name: "Release", executionLocation: .local, projects: [one, two])
        _ = model.add(project: one)
        _ = model.add(project: two)

        model.moveMember(from: 1, to: 0)

        #expect(model.members.map(\.projectID) == ["two", "one"])
    }

    @Test @MainActor func typedPlacementRetainsLegacyProjectProjection() {
        let space = SpaceConfig(id: "main", name: "Main", emoji: "🏠", projectIds: ["one", "two"], members: nil, lastSelectedWorktreeId: nil, createdAt: .distantPast)
        let manager = SpacesManager(file: .init(activeSpaceId: "main", spaces: [space]))
        let workspaceID = UUID()

        let legacyMembers = manager.activeSpace?.members ?? manager.activeSpace?.projectIds.map(SpaceMemberReference.project) ?? []
        manager.setTypedMembers(legacyMembers + [.workspace(workspaceID)], forSpace: "main")

        #expect(manager.activeSpace?.members == [.project("one"), .project("two"), .workspace(workspaceID)])
        #expect(manager.activeSpace?.projectIds == ["one", "two"])
    }
}

private func project(id: String, name: String, path: String, host: String? = nil) -> ProjectConfig {
    ProjectConfig(id: id, name: name, path: path, color: "#fff", addedAt: .distantPast, host: host)
}
