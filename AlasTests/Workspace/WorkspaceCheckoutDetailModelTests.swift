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
        var archived = checkout(archivedAt: Date(timeIntervalSince1970: 10), members: [
            member(name: "Available", availability: .available, checkpoint: .setupComplete),
            member(name: "Missing", availability: .missing, checkpoint: .setupComplete),
            member(name: "Failed", availability: .available, checkpoint: .failed),
            member(name: "Deleted", availability: .explicitlyDeleted, checkpoint: .setupComplete),
        ])
        archived.workspaceID = nil
        let model = WorkspaceCheckoutDetailModel(checkout: archived)

        #expect(model.status == .formerWorkspace("Former Workspace"))
        #expect(model.headerBadges.contains(.archived))
        #expect(model.headerBadges.contains(.formerWorkspace))
        #expect(model.primaryActions.map(\.kind) == [.unarchive])
        #expect(model.memberRows.allSatisfy { $0.actions.isEmpty })
    }

    @Test func fullyDeletedCheckoutOnlyOffersForgettingTheRecord() {
        let deleted = checkout(members: [
            member(name: "App", availability: .explicitlyDeleted, checkpoint: .planPersisted),
            member(name: "API", availability: .explicitlyDeleted, checkpoint: .planPersisted),
        ])
        let model = WorkspaceCheckoutDetailModel(checkout: deleted)

        #expect(deleted.health == .deleted)
        #expect(model.status == .deleted("Worktrees deleted"))
        #expect(model.primaryActions.map(\.kind) == [.forgetCheckout])
    }

    @Test func memberWhoseDeletionFailedNeedsAttentionWithTheRecordedReason() {
        var failed = member(name: "App", availability: .available, checkpoint: .setupComplete, diagnostic: "failed")
        failed.cleanup?.checkpoint = .failed
        var checkout = checkout(members: [failed])
        checkout.diagnostics = [
            .init(severity: .error, message: "Could not delete App.", memberID: failed.id, detail: "worktree is locked"),
        ]
        let model = WorkspaceCheckoutDetailModel(checkout: checkout)

        #expect(checkout.health == .needsAttention)
        #expect(model.status == .needsAttention("Needs Attention"))
        #expect(model.memberRows[0].status == .needsAttention)
        #expect(model.memberRows[0].detail == "Could not delete App. worktree is locked")
        #expect(model.memberRows[0].actions.map(\.kind) == [.deleteMember])
    }

    @Test func missingMemberWhoseDeletionFailedOffersTheDeletionRetryNotFindExisting() {
        // A missing-but-owned member's own deletion attempt can itself fail
        // (e.g. clearing a stale Git registration) without ever changing
        // availability away from `.missing`. The detail text already says
        // to delete again; the action must match, not Find Existing /
        // Resume Creation.
        var failed = member(name: "App", availability: .missing, checkpoint: .setupComplete, diagnostic: "failed")
        failed.cleanup?.checkpoint = .failed
        let checkout = checkout(members: [failed])
        let model = WorkspaceCheckoutDetailModel(checkout: checkout)

        #expect(model.memberRows[0].actions.map(\.kind) == [.deleteMember])
    }

    @Test func deletionFailureTakesPrecedenceOverAnEarlierSetupFailure() {
        // A member whose setup already failed (checkpoint == .failed) and
        // whose subsequent deletion attempt also failed must show the more
        // recent deletion failure and its working retry, not the stale
        // setup-failure message with a "Retry Setup" that doesn't address
        // what's actually blocking it now.
        var failed = member(name: "App", availability: .available, checkpoint: .failed, diagnostic: "failed")
        failed.cleanup?.checkpoint = .failed
        var checkout = checkout(members: [failed])
        checkout.diagnostics = [
            .init(severity: .error, message: "Could not delete App.", memberID: failed.id, detail: "worktree is locked"),
        ]
        let model = WorkspaceCheckoutDetailModel(checkout: checkout)

        #expect(model.memberRows[0].detail == "Could not delete App. worktree is locked")
        #expect(model.memberRows[0].actions.map(\.kind) == [.deleteMember])
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

    @Test func exposesResumeCreationForPausedPendingMembers() {
        let checkout = checkout(operation: .idle, members: [
            member(name: "Done", availability: .available, checkpoint: .setupComplete),
            member(name: "Paused", availability: .pending, checkpoint: .planPersisted)
        ])
        let model = WorkspaceCheckoutDetailModel(checkout: checkout)

        #expect(model.primaryActions.map(\.kind).contains(.resumeCreation))
        #expect(model.memberRows[1].actions.map(\.kind).contains(.resumeCreation))
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

        #expect(model.diagnostics.map(\.message) == ["Setup script failed"])
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

    @Test func unavailableMembersNeverClaimToBeReady() {
        let checkout = checkout(members: [
            member(name: "Missing", availability: .missing, checkpoint: .setupComplete),
            member(name: "Remote", availability: .unavailable, checkpoint: .setupComplete),
            member(name: "Replaced", availability: .identityConflict, checkpoint: .setupComplete),
            member(name: "Deleted", availability: .explicitlyDeleted, checkpoint: .setupComplete),
        ])
        let rows = WorkspaceCheckoutDetailModel(checkout: checkout).memberRows
        #expect(rows.map(\.status) == [.missing, .unavailable, .identityConflict, .explicitlyDeleted])
        #expect(rows.allSatisfy { !$0.detail.contains("Ready") })
        #expect(rows[0].detail.contains("not found"))
        #expect(rows[1].detail.contains("Could not access"))
    }

    @Test func preservesDiagnosticIdentitySeverityAndErrorDetails() {
        var checkout = checkout(members: [])
        checkout.diagnostics = [
            .init(severity: .warning, message: "Using cached main"),
            .init(severity: .error, message: "Setup failed", detail: "tool: command not found"),
            .init(severity: .error, message: "Setup failed", detail: "Permission denied"),
        ]
        let diagnostics = WorkspaceCheckoutDetailModel(checkout: checkout).diagnostics
        #expect(diagnostics == checkout.diagnostics)
        #expect(Set(diagnostics.map(\.id)).count == 3)
    }

    @Test func hidesMemberMutationActionsWhileCheckoutIsBusy() {
        for operation in [WorkspaceCheckoutOperation.creating, .repairing, .deleting, .archiving, .cleaning] {
            let checkout = checkout(operation: operation, members: [
                member(name: "Failed", availability: .available, checkpoint: .failed),
                member(name: "Ready", availability: .available, checkpoint: .setupComplete),
            ])
            #expect(WorkspaceCheckoutDetailModel(checkout: checkout).memberRows.allSatisfy { $0.actions.isEmpty })
        }
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
            // Only attaches a cleanup record for the caller to further shape
            // (e.g. setting `.cleanup?.checkpoint = .failed` to model a
            // deletion failure); it must not default to `.failed` itself, or
            // every setup-failure fixture using this parameter would also
            // read as a deletion failure via `member.deletionFailed`.
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
                )
            )
            _ = diagnostic
        }
        return member
    }
}
