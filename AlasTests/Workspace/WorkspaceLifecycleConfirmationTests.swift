import Foundation
import Testing
@testable import Alas

@Suite struct WorkspaceLifecycleConfirmationTests {
    @Test func riskyMemberDeletionRequiresCoordinatorConfirmation() {
        let member = checkoutMember()
        let plan = WorkspaceLifecycleConfirmationModel.memberDeletion(
            member: member,
            preflight: WorktreeDeletePreflight(reasons: [.dirty], submoduleLocalState: .present)
        )

        #expect(plan.requiresConfirmation == true)
        #expect(plan.title == "Delete Workspace Member Worktree?")
        #expect(plan.risks.contains("Uncommitted changes"))
        #expect(plan.risks.contains("Initialized submodules"))
        #expect(plan.confirmAction == .deleteMember(confirmingRisks: true))
        #expect(plan.canForceDelete == false)
    }

    @Test func riskyCheckoutDeletionAggregatesMemberRisks() {
        let plan = WorkspaceLifecycleConfirmationModel.checkoutDeletion(risks: [
            "App: Uncommitted changes",
            "API: Initialized submodules",
        ])

        #expect(plan.requiresConfirmation == true)
        #expect(plan.title == "Delete Workspace Checkout?")
        #expect(plan.risks == ["App: Uncommitted changes", "API: Initialized submodules"])
        #expect(plan.confirmAction == .deleteCheckout(confirmingRisks: true))
        #expect(plan.canForceDelete == false)
    }

    @Test func cleanCheckoutDeletionDoesNotRequireConfirmation() {
        let plan = WorkspaceLifecycleConfirmationModel.checkoutDeletion(risks: [])

        #expect(plan.requiresConfirmation == false)
        #expect(plan.confirmAction == .deleteCheckout(confirmingRisks: false))
        #expect(plan.canForceDelete == false)
    }

    @MainActor
    @Test func checkoutDeletionConfirmationAllowsSnapshotOnlyMembers() async throws {
        let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-confirmation-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let store = WorkspaceStore(url: storeURL)
        var member = checkoutMember()
        member.availability = .unavailable
        member.checkpoint = .failed
        member.gitLineageID = nil
        member.cleanup = nil
        member.cleanupOwnership = .init(worktreeCreated: false, branchOwnership: .reused)
        let checkout = WorkspaceCheckout(
            workspaceID: UUID(),
            fallbackWorkspaceName: "Release",
            executionLocation: .local,
            branch: "release/1091",
            rootPath: "/checkouts/release",
            members: [member]
        )
        try await store.checkpoint(.init(checkouts: [checkout]))
        let bridge = WorkspaceSpacePersistenceBridge(workspaceStore: store)
        let manager = WorkspacesManager(bridge: bridge)
        _ = await manager.setEnabled(true, spacesFile: SpacesFile(activeSpaceId: "space", spaces: [
            SpaceConfig(id: "space", name: "Default", emoji: "folder", projectIds: [], lastSelectedWorktreeId: nil, createdAt: .distantPast)
        ]))
        let state = AppState(
            store: WorkspaceConfirmationMemoryStore(),
            workspacesManager: manager,
            workspaceStore: store
        )
        state.config.workspacesEnabled = true

        let model = try await state.workspaceCheckoutDeletionConfirmation(checkoutID: checkout.id)

        #expect(model.requiresConfirmation == false)
        #expect(model.confirmAction == .deleteCheckout(confirmingRisks: false))
    }

    @Test func verifiedFindExistingCandidatesAreExplicitRepairChoices() {
        let candidates = [
            WorkspaceRepairCandidate(path: "/checkouts/release/app", lineageID: "lineage-a", isExactMatch: true),
            WorkspaceRepairCandidate(path: "/tmp/other", lineageID: "other", isExactMatch: false)
        ]
        let sheet = WorkspaceRepairPlanModel(memberName: "App", candidates: candidates)

        #expect(sheet.verifiedCandidates.map(\.path) == ["/checkouts/release/app"])
        #expect(sheet.actions(for: candidates[0]) == [.useExistingVerifiedCandidate])
        #expect(sheet.actions(for: candidates[1]).isEmpty)
    }

    @Test func leftoversAndRetainedBranchesBlockForgetUntilSeparateConfirmation() {
        let cleanup = WorkspaceCheckoutMemberCleanup(
            plan: cleanupPlan(branchOwnership: .created),
            checkpoint: .branchDeleteAttempted,
            worktreeRemoved: true,
            branchRemoved: false,
            sharedRootLeftovers: ["notes.txt"]
        )
        let model = WorkspaceLifecycleConfirmationModel.forgetCheckout(cleanups: [cleanup], confirmedPreserveArtifacts: false)

        #expect(model.requiresConfirmation == true)
        #expect(model.risks.contains("notes.txt"))
        #expect(model.risks.contains("Retained branch release/1091"))
        #expect(model.confirmAction == .forgetCheckout(confirmedPreserveArtifacts: true))
    }

    @Test func cleanForgetHasNoDestructiveForceOption() {
        let cleanup = WorkspaceCheckoutMemberCleanup(
            plan: cleanupPlan(branchOwnership: .reused),
            checkpoint: .complete,
            worktreeRemoved: true,
            branchRemoved: false
        )
        let model = WorkspaceLifecycleConfirmationModel.forgetCheckout(cleanups: [cleanup], confirmedPreserveArtifacts: false)

        #expect(model.requiresConfirmation == false)
        #expect(model.canForceDelete == false)
        #expect(model.confirmAction == .forgetCheckout(confirmedPreserveArtifacts: false))
    }

    private func checkoutMember() -> WorkspaceCheckoutMember {
        var member = WorkspaceCheckoutMember(
            workspaceMemberID: UUID(),
            projectID: "app",
            fallbackProjectName: "App",
            fallbackRepositoryRoot: "/repos/app",
            worktreePath: "/checkouts/release/app",
            gitLineageID: "lineage-a",
            availability: .available,
            checkpoint: .setupComplete,
            cleanupOwnership: .init(worktreeCreated: true, branchOwnership: .created),
            plan: .init(
                checkoutMemberID: UUID(),
                projectID: "app",
                sourceRepositoryPath: "/repos/app",
                destinationPath: "/checkouts/release/app",
                baseReference: "main",
                baseCommit: "abc",
                branchIntent: .create(atCommit: "abc")
            )
        )
        member.cleanup = .init(plan: cleanupPlan(branchOwnership: .created))
        return member
    }

    private func cleanupPlan(branchOwnership: WorkspaceBranchOwnership) -> WorkspaceCheckoutCleanupPlan {
        WorkspaceCheckoutCleanupPlan(
            checkoutID: UUID(),
            memberID: UUID(),
            executionLocation: .local,
            projectID: "app",
            sourceRepositoryPath: "/repos/app",
            baseReference: "main",
            baseCommit: "abc",
            rootPath: "/checkouts/release",
            managedMemberPaths: ["/checkouts/release/app"],
            worktreePath: "/checkouts/release/app",
            branch: "release/1091",
            expectedLineageID: "lineage-a",
            branchOwnership: branchOwnership
        )
    }
}

private final class WorkspaceConfirmationMemoryStore: PersistenceStoreProtocol {
    func readIfExists<T>(_ type: T.Type, from url: URL) throws -> T? where T: Decodable {
        nil
    }

    func write<T>(_ value: T, to url: URL) throws where T: Encodable {}
}
