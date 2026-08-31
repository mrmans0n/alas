import Foundation
import Testing
@testable import Alas

@Suite struct WorkspaceCheckoutDetailModelTests {
    @Test func presentsLifecycleStatesWithCheckpointActions() {
        let ready = checkout(members: [member(name: "App", availability: .available, checkpoint: .setupComplete)])
        #expect(WorkspaceCheckoutDetailModel(checkout: ready).status == .ready("Ready"))
        #expect(WorkspaceCheckoutDetailModel(checkout: ready).primaryActions.map(\.kind) == [.archive, .deleteCheckout])

        var creatingMember = member(name: "API", availability: .pending, checkpoint: .worktreeCreating)
        creatingMember.cleanupOwnership = .init(worktreeCreated: false, branchOwnership: .created)
        let creating = checkout(operation: .creating, members: [creatingMember], stopAfterCurrentOperations: false)
        let creatingModel = WorkspaceCheckoutDetailModel(checkout: creating)
        #expect(creatingModel.status == .creating("Creating Workspace Checkout"))
        #expect(creatingModel.primaryActions.map(\.kind).contains(.resumeCreation))
        #expect(creatingModel.primaryActions.map(\.kind).contains(.stopAfterCurrentOperations))
        #expect(creatingModel.memberRows[0].detail.contains("Creating worktree"))

        let partial = checkout(members: [
            member(name: "App", availability: .available, checkpoint: .setupComplete),
            member(name: "API", availability: .missing, checkpoint: .setupComplete)
        ])
        #expect(WorkspaceCheckoutDetailModel(checkout: partial).status == .partial("Partially available"))

        let conflict = checkout(members: [member(name: "App", availability: .identityConflict, checkpoint: .worktreeCreated)])
        let conflictRow = WorkspaceCheckoutDetailModel(checkout: conflict).memberRows[0]
        #expect(conflictRow.status == .identityConflict)
        #expect(conflictRow.actions.map(\.kind).contains(.findExisting))

        let failedSetup = checkout(members: [member(name: "App", availability: .available, checkpoint: .failed, diagnostic: "Setup failed")])
        let failedRow = WorkspaceCheckoutDetailModel(checkout: failedSetup).memberRows[0]
        #expect(WorkspaceCheckoutDetailModel(checkout: failedSetup).status == .needsAttention("Needs Attention"))
        #expect(failedRow.actions.map(\.kind) == [.retrySetup])

        let deleted = checkout(members: [member(name: "App", availability: .explicitlyDeleted, checkpoint: .setupComplete)])
        let deletedRow = WorkspaceCheckoutDetailModel(checkout: deleted).memberRows[0]
        #expect(deletedRow.status == .explicitlyDeleted)
        #expect(deletedRow.actions.map(\.kind).contains(.recreateMember))
    }

    @Test func presentsArchivedAndFormerWorkspaceWithoutRepositoryMutationActions() {
        var archived = checkout(archivedAt: Date(timeIntervalSince1970: 10), members: [member(name: "App", availability: .available, checkpoint: .setupComplete)])
        archived.workspaceID = nil
        let model = WorkspaceCheckoutDetailModel(checkout: archived)

        #expect(model.status == .formerWorkspace("Former Workspace"))
        #expect(model.headerBadges.contains(.archived))
        #expect(model.headerBadges.contains(.formerWorkspace))
        #expect(model.primaryActions.map(\.kind) == [.unarchive])
    }

    @Test func reportsLiveProgressAndStopBoundary() {
        let creating = checkout(operation: .creating, members: [
            member(name: "One", availability: .available, checkpoint: .setupComplete),
            member(name: "Two", availability: .pending, checkpoint: .setupRunning),
            member(name: "Three", availability: .pending, checkpoint: .notStarted)
        ], stopAfterCurrentOperations: true)
        let model = WorkspaceCheckoutDetailModel(checkout: creating)

        #expect(model.progress == WorkspaceCheckoutProgress(completedMembers: 1, totalMembers: 3))
        #expect(model.stopMessage == "Stop requested. Current member operations will finish before the checkout pauses.")
        #expect(model.primaryActions.map(\.kind).contains(.resumeCreation))

        let deleting = checkout(operation: .deleting, members: [
            member(name: "One", availability: .available, checkpoint: .setupComplete)
        ])
        #expect(WorkspaceCheckoutDetailModel(checkout: deleting).primaryActions.map(\.kind) == [.deleteCheckout])

        let archiving = checkout(operation: .archiving, members: [
            member(name: "One", availability: .available, checkpoint: .setupComplete)
        ])
        #expect(WorkspaceCheckoutDetailModel(checkout: archiving).primaryActions.map(\.kind) == [.archive])

        let repairing = checkout(operation: .repairing, members: [
            member(name: "One", availability: .missing, checkpoint: .planPersisted)
        ])
        #expect(WorkspaceCheckoutDetailModel(checkout: repairing).primaryActions.map(\.kind).contains(.resumeCreation))
    }

    @Test func exposesPersistedDiagnosticsForNeedsAttention() {
        let checkout = WorkspaceCheckout(
            workspaceID: UUID(),
            fallbackWorkspaceName: "Release",
            executionLocation: .local,
            branch: "release/1091",
            rootPath: "/checkouts/release",
            members: [member(name: "App", availability: .available, checkpoint: .failed)],
            diagnostics: [
                WorkspaceDiagnostic(severity: .error, message: "Setup script failed")
            ]
        )

        let model = WorkspaceCheckoutDetailModel(checkout: checkout)

        #expect(model.diagnostics == ["Setup script failed"])
        #expect(model.status == .needsAttention("Needs Attention"))
    }

    @Test func choosesNearestPeerAfterSuccessfulDeletion() {
        let first = UUID()
        let deleted = UUID()
        let third = UUID()
        #expect(WorkspaceCheckoutDetailModel.nearestPeer(afterDeleting: deleted, orderedCheckoutIDs: [first, deleted, third]) == third)
        #expect(WorkspaceCheckoutDetailModel.nearestPeer(afterDeleting: third, orderedCheckoutIDs: [first, deleted, third]) == deleted)
        #expect(WorkspaceCheckoutDetailModel.nearestPeer(afterDeleting: first, orderedCheckoutIDs: [first]) == nil)
    }

    private func checkout(
        operation: WorkspaceCheckoutOperation = .idle,
        archivedAt: Date? = nil,
        members: [WorkspaceCheckoutMember],
        stopAfterCurrentOperations: Bool = false
    ) -> WorkspaceCheckout {
        WorkspaceCheckout(
            workspaceID: UUID(),
            fallbackWorkspaceName: "Release",
            executionLocation: .local,
            branch: "release/1091",
            rootPath: "/checkouts/release",
            archivedAt: archivedAt,
            operation: operation,
            members: members,
            stopAfterCurrentOperations: stopAfterCurrentOperations
        )
    }

    private func member(
        name: String,
        availability: WorkspaceCheckoutMemberAvailability,
        checkpoint: WorkspaceCheckoutCheckpoint,
        diagnostic: String? = nil
    ) -> WorkspaceCheckoutMember {
        var member = WorkspaceCheckoutMember(
            workspaceMemberID: UUID(),
            projectID: name.lowercased(),
            fallbackProjectName: name,
            fallbackRepositoryRoot: "/repos/\(name.lowercased())",
            worktreePath: "/checkouts/release/\(name.lowercased())",
            gitLineageID: "lineage-\(name)",
            availability: availability,
            checkpoint: checkpoint,
            cleanupOwnership: .init(worktreeCreated: true, branchOwnership: .created),
            plan: .init(
                checkoutMemberID: UUID(),
                projectID: name.lowercased(),
                sourceRepositoryPath: "/repos/\(name.lowercased())",
                destinationPath: "/checkouts/release/\(name.lowercased())",
                baseReference: "main",
                baseCommit: "abc",
                branchIntent: .create(atCommit: "abc")
            )
        )
        if let diagnostic {
            member.cleanup = WorkspaceCheckoutMemberCleanup(
                plan: WorkspaceCheckoutCleanupPlan(
                    checkoutID: UUID(),
                    memberID: member.id,
                    executionLocation: .local,
                    projectID: member.projectID,
                    sourceRepositoryPath: member.fallbackRepositoryRoot,
                    baseReference: "main",
                    baseCommit: "abc",
                    rootPath: "/checkouts/release",
                    managedMemberPaths: [member.worktreePath],
                    worktreePath: member.worktreePath,
                    branch: "release/1091",
                    expectedLineageID: "lineage-\(name)",
                    branchOwnership: .created
                ),
                checkpoint: .failed
            )
            _ = diagnostic
        }
        return member
    }
}
