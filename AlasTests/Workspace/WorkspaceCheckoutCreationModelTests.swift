import Foundation
import Testing
@testable import Alas

@Suite("Workspace checkout creation model")
struct WorkspaceCheckoutCreationModelTests {
    @Test func advancesThroughThreeStepsOnlyWithSharedBranchAndRoot() {
        let workspace = fixtureWorkspace()
        var model = WorkspaceCheckoutCreationModel(workspace: workspace, rootPath: "")

        #expect(model.step == .details)
        #expect(model.advance() == .failure("A shared branch is required."))
        model.branch = "release/1091"
        #expect(model.advance() == .failure("Checkout root is required."))
        model.rootPath = "/checkouts/release"
        #expect(model.advance() == .success)
        #expect(model.step == .preflight)
    }

    @Test func acceptsMemberBaseOverridesAndShowsEveryPreflightFailureWithoutArtifacts() {
        let workspace = fixtureWorkspace()
        var model = WorkspaceCheckoutCreationModel(workspace: workspace, branch: "release/1091", rootPath: "/checkouts/release", baseReference: "main")
        model.memberBaseReferences[workspace.members[1].id] = "stable"
        let diagnostics = [
            WorkspaceDiagnostic(severity: .error, message: "One failed."),
            WorkspaceDiagnostic(severity: .error, message: "Two failed.")
        ]

        model.receivePreflight(.failure(diagnostics))

        #expect(model.preflightMessages == ["One failed.", "Two failed."])
        #expect(model.selectedCheckoutID == nil)
        #expect(model.beginCreation() == false)
    }

    @Test func selectsOnlyAfterFrozenPlanWasPersistedAndProgressComesFromCheckout() {
        let workspace = fixtureWorkspace()
        var model = WorkspaceCheckoutCreationModel(workspace: workspace, branch: "release/1091", rootPath: "/checkouts/release", baseReference: "main")
        let plan = FrozenWorkspaceCheckoutPlan(checkoutID: UUID(), workspaceID: workspace.id, executionLocation: .local, branch: model.branch, rootPath: model.rootPath, members: [])
        model.receivePreflight(.success(plan))

        let beganCreation = model.beginCreation()
        #expect(beganCreation)
        #expect(model.step == .creating)
        #expect(model.selectedCheckoutID == nil)
        model.didPersist(checkoutID: plan.checkoutID)
        #expect(model.selectedCheckoutID == plan.checkoutID)

        let checkout = WorkspaceCheckout(id: plan.checkoutID, workspaceID: workspace.id, fallbackWorkspaceName: workspace.name, executionLocation: .local, branch: plan.branch, rootPath: plan.rootPath, members: [
            WorkspaceCheckoutMember(workspaceMemberID: workspace.members[0].id, projectID: "one", fallbackProjectName: "One", fallbackRepositoryRoot: "/repos/one", worktreePath: "/checkouts/release/one", checkpoint: .worktreeCreated),
            WorkspaceCheckoutMember(workspaceMemberID: workspace.members[1].id, projectID: "two", fallbackProjectName: "Two", fallbackRepositoryRoot: "/repos/two", worktreePath: "/checkouts/release/two", checkpoint: .setupComplete)
        ])
        #expect(model.progress(for: checkout) == WorkspaceCheckoutCreationProgress(completedMembers: 1, totalMembers: 2))
    }
}

private func fixtureWorkspace() -> Workspace {
    Workspace(name: "Release", executionLocation: .local, members: [
        WorkspaceMember(projectID: "one", fallbackProjectName: "One", fallbackRepositoryRoot: "/repos/one"),
        WorkspaceMember(projectID: "two", fallbackProjectName: "Two", fallbackRepositoryRoot: "/repos/two")
    ])
}
