import Foundation
import Testing
@testable import Alas

@Suite("Workspace checkout lifecycle")
struct WorkspaceCheckoutLifecycleTests {
    @Test func archivingAnIdleCheckoutStopsItsOwnedSessionsAndRetainsMembers() async throws {
        let fixture = try await Fixture.make()
        let sessions = LifecycleSessions()
        let coordinator = WorkspaceCheckoutCoordinator(
            store: fixture.store,
            git: FixtureGit(),
            scripts: FixtureScripts(),
            sessions: sessions,
            lifecycle: FixtureLifecycle()
        )

        let archived = try await coordinator.archive(checkoutID: fixture.checkout.id)

        #expect(archived.archivedAt != nil)
        #expect(archived.members == fixture.checkout.members)
        #expect(await sessions.stopped == [fixture.checkout.id])
    }

    @Test func archivingDuringMutationFailsWithoutStoppingSessions() async throws {
        let fixture = try await Fixture.make(operation: .creating)
        let sessions = LifecycleSessions()
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: FixtureGit(), scripts: FixtureScripts(), sessions: sessions, lifecycle: FixtureLifecycle())

        await #expect(throws: WorkspaceCheckoutCoordinatorError.operationInProgress) {
            try await coordinator.archive(checkoutID: fixture.checkout.id)
        }
        #expect(await sessions.stopped.isEmpty)
    }

    @Test func archivedCheckoutsRejectMemberMutationEntryPoints() async throws {
        let fixture = try await Fixture.make()
        try await fixture.store.mutate { state in
            state.checkouts[0].archivedAt = Date(timeIntervalSince1970: 1_000)
            state.checkouts[0].members[0].availability = .missing
            state.checkouts[0].members[0].checkpoint = .failed
        }
        let lifecycle = FixtureLifecycle()
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: FixtureGit(), scripts: FixtureScripts(), sessions: LifecycleSessions(), lifecycle: lifecycle)

        await #expect(throws: WorkspaceCheckoutCoordinatorError.operationInProgress) {
            try await coordinator.previewMemberDeletion(checkoutID: fixture.checkout.id, memberID: fixture.member.id)
        }
        await #expect(throws: WorkspaceCheckoutCoordinatorError.operationInProgress) {
            try await coordinator.deleteMember(checkoutID: fixture.checkout.id, memberID: fixture.member.id)
        }
        await #expect(throws: WorkspaceCheckoutCoordinatorError.operationInProgress) {
            try await coordinator.deleteMemberSnapshot(checkoutID: fixture.checkout.id, memberID: fixture.member.id)
        }
        await #expect(throws: WorkspaceCheckoutCoordinatorError.operationInProgress) {
            try await coordinator.useExistingVerifiedCandidate(
                checkoutID: fixture.checkout.id,
                memberID: fixture.member.id,
                candidate: .init(path: fixture.member.worktreePath, lineageID: fixture.member.gitLineageID ?? "", isExactMatch: true)
            )
        }
        await #expect(throws: WorkspaceCheckoutCoordinatorError.operationInProgress) {
            try await coordinator.deleteCheckout(checkoutID: fixture.checkout.id)
        }
        await #expect(throws: WorkspaceCheckoutCoordinatorError.operationInProgress) {
            try await coordinator.forget(checkoutID: fixture.checkout.id, confirmedPreserveArtifacts: true)
        }
        await #expect(throws: WorkspaceCheckoutCoordinatorError.operationInProgress) {
            try await coordinator.retrySetup(checkoutID: fixture.checkout.id, memberID: fixture.member.id)
        }
        await #expect(throws: WorkspaceCheckoutCoordinatorError.operationInProgress) {
            try await coordinator.resumeCreation(checkoutID: fixture.checkout.id)
        }
        #expect(await lifecycle.removedMembers.isEmpty)
    }

    @Test func interruptedArchivingCheckoutCanResumeAndFinalize() async throws {
        let fixture = try await Fixture.make(operation: .archiving)
        let sessions = LifecycleSessions()
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: FixtureGit(), scripts: FixtureScripts(), sessions: sessions, lifecycle: FixtureLifecycle())

        let archived = try await coordinator.archive(checkoutID: fixture.checkout.id)

        #expect(archived.archivedAt != nil)
        #expect(archived.operation == .idle)
        #expect(await sessions.stopped == [fixture.checkout.id])
    }

    @Test func archivingRetainsTheDurableClaimWhenSessionShutdownFails() async throws {
        let fixture = try await Fixture.make()
        let coordinator = WorkspaceCheckoutCoordinator(
            store: fixture.store,
            git: FixtureGit(),
            scripts: FixtureScripts(),
            sessions: FailingLifecycleSessions(),
            lifecycle: FixtureLifecycle()
        )

        await #expect(throws: TestLifecycleError.failed) {
            try await coordinator.archive(checkoutID: fixture.checkout.id)
        }
        guard case .loaded(let state) = await fixture.store.load(),
              let checkout = state.checkouts.first(where: { $0.id == fixture.checkout.id })
        else {
            Issue.record("Expected checkout to remain persisted")
            return
        }
        #expect(checkout.archivedAt == nil)
        #expect(checkout.operation == .archiving)
    }

    @Test func deletingAMemberPersistsTheFrozenCleanupPlanBeforeRemovingTheWorktree() async throws {
        let fixture = try await Fixture.make()
        try await fixture.store.mutate { state in
            state.checkouts[0].members[0].recreationSourceCheckpoint = .setupComplete
            state.checkouts[0].members[0].recreationWorktreeCreationBegan = true
        }
        let lifecycle = PersistedCleanupLifecycle(store: fixture.store, checkoutID: fixture.checkout.id)
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: FixtureGit(), scripts: FixtureScripts(), sessions: LifecycleSessions(), lifecycle: lifecycle)

        let checkout = try await coordinator.deleteMember(checkoutID: fixture.checkout.id, memberID: fixture.member.id)

        #expect(await lifecycle.sawPersistedCleanupPlan)
        #expect(checkout.members[0].availability == .explicitlyDeleted)
        #expect(checkout.members[0].checkpoint == .planPersisted)
        #expect(checkout.members[0].gitLineageID == nil)
        #expect(checkout.members[0].cleanupOwnership.worktreeCreated == false)
        #expect(checkout.members[0].cleanup?.worktreeRemoved == true)
        #expect(checkout.members[0].recreationSourceCheckpoint == nil)
        #expect(checkout.members[0].recreationWorktreeCreationBegan == false)
    }

    @Test func resumingCreatedReplacementFinalizesPendingStaleRegistrationTombstone() async throws {
        let fixture = try await Fixture.make(operation: .creating)
        try await fixture.store.mutate { state in
            state.checkouts[0].members[0].checkpoint = .failed
            state.checkouts[0].members[0].availability = .unavailable
            state.checkouts[0].members[0].recreationSourceCheckpoint = .setupComplete
            state.checkouts[0].members[0].recreationWorktreeCreationBegan = true
        }
        let lifecycle = FixtureLifecycle()
        let coordinator = WorkspaceCheckoutCoordinator(
            store: fixture.store,
            git: FixtureGit(existingCreatedLineageID: "lineage-a"),
            scripts: FixtureScripts(),
            sessions: LifecycleSessions(),
            lifecycle: lifecycle
        )

        _ = try await coordinator.resumeCreation(checkoutID: fixture.checkout.id)

        #expect(await lifecycle.finalizedRegistrations == [fixture.member.id])
    }

    @Test func resumingMarkerlessCreatedReplacementRecordsLineageAndFinalizesTombstone() async throws {
        let fixture = try await Fixture.make(operation: .creating)
        try await fixture.store.mutate { state in
            state.checkouts[0].members[0].checkpoint = .failed
            state.checkouts[0].members[0].availability = .unavailable
            state.checkouts[0].members[0].recreationSourceCheckpoint = .setupComplete
            state.checkouts[0].members[0].recreationWorktreeCreationBegan = true
        }
        let lifecycle = FixtureLifecycle(hasPendingStaleRegistrationCleanup: true)
        let coordinator = WorkspaceCheckoutCoordinator(
            store: fixture.store,
            git: FixtureGit(recoveredCreatedLineageID: "lineage-a"),
            scripts: FixtureScripts(),
            sessions: LifecycleSessions(),
            lifecycle: lifecycle
        )

        let checkout = try await coordinator.resumeCreation(checkoutID: fixture.checkout.id)

        #expect(await lifecycle.finalizedRegistrations == [fixture.member.id])
        #expect(await lifecycle.clearedRegistrations.isEmpty)
        #expect(checkout.members[0].checkpoint == .setupComplete)
        #expect(checkout.members[0].gitLineageID == "lineage-a")
        #expect(checkout.members[0].recreationSourceCheckpoint == nil)
        #expect(checkout.members[0].recreationWorktreeCreationBegan == false)
    }

    @Test func resumingMarkedCreatedReplacementWithAdvancedHeadFinalizesTombstone() async throws {
        let fixture = try await Fixture.make(operation: .creating)
        try await fixture.store.mutate { state in
            state.checkouts[0].members[0].checkpoint = .failed
            state.checkouts[0].members[0].availability = .unavailable
            state.checkouts[0].members[0].recreationSourceCheckpoint = .setupComplete
            state.checkouts[0].members[0].recreationWorktreeCreationBegan = true
        }
        let lifecycle = FixtureLifecycle(hasPendingStaleRegistrationCleanup: true)
        let coordinator = WorkspaceCheckoutCoordinator(
            store: fixture.store,
            git: FixtureGit(existingCreatedIgnoringHeadLineageID: "lineage-a"),
            scripts: FixtureScripts(),
            sessions: LifecycleSessions(),
            lifecycle: lifecycle
        )

        let checkout = try await coordinator.resumeCreation(checkoutID: fixture.checkout.id)

        #expect(await lifecycle.finalizedRegistrations == [fixture.member.id])
        #expect(await lifecycle.clearedRegistrations.isEmpty)
        #expect(checkout.members[0].checkpoint == .setupComplete)
        #expect(checkout.members[0].gitLineageID == "lineage-a")
    }

    @Test func resumingMarkerlessCreatedReplacementRequiresPendingTombstone() async throws {
        let fixture = try await Fixture.make(operation: .creating)
        try await fixture.store.mutate { state in
            state.checkouts[0].members[0].checkpoint = .failed
            state.checkouts[0].members[0].availability = .unavailable
            state.checkouts[0].members[0].recreationSourceCheckpoint = .setupComplete
            state.checkouts[0].members[0].recreationWorktreeCreationBegan = true
        }
        let lifecycle = FixtureLifecycle(hasPendingStaleRegistrationCleanup: false)
        let coordinator = WorkspaceCheckoutCoordinator(
            store: fixture.store,
            git: FixtureGit(recoveredCreatedLineageID: "lineage-a"),
            scripts: FixtureScripts(),
            sessions: LifecycleSessions(),
            lifecycle: lifecycle
        )

        let checkout = try await coordinator.resumeCreation(checkoutID: fixture.checkout.id)

        #expect(await lifecycle.finalizedRegistrations.isEmpty)
        #expect(checkout.members[0].checkpoint == .failed)
    }

    @Test func recreatingRecoverableReturnedTombstoneRunsStaleCleanupBeforeLineageCheck() async throws {
        let fixture = try await Fixture.make(operation: .creating)
        let lifecycle = FixtureLifecycle(clearError: WorkspaceCheckoutCoordinatorError.completedWorktreeReturned)
        let coordinator = WorkspaceCheckoutCoordinator(
            store: fixture.store,
            git: FixtureGit(
                preparedBranchMatches: true,
                frozenWorktreeMissingResults: [true, false]
            ),
            scripts: FixtureScripts(),
            sessions: LifecycleSessions(),
            lifecycle: lifecycle
        )

        _ = try await coordinator.resumeCreation(checkoutID: fixture.checkout.id)

        #expect(await lifecycle.recoveredRegistrations == [fixture.member.id])
        #expect(await lifecycle.clearedRegistrations.isEmpty)
    }

    @Test func recreatingPendingTombstoneRunsRecoveryBeforeBranchValidation() async throws {
        let fixture = try await Fixture.make(operation: .creating)
        let lifecycle = FixtureLifecycle()
        let coordinator = WorkspaceCheckoutCoordinator(
            store: fixture.store,
            git: FixtureGit(preparedBranchMatches: false),
            scripts: FixtureScripts(),
            sessions: LifecycleSessions(),
            lifecycle: lifecycle
        )

        _ = try await coordinator.resumeCreation(checkoutID: fixture.checkout.id)

        #expect(await lifecycle.recoveredRegistrations == [fixture.member.id])
        #expect(await lifecycle.clearedRegistrations.isEmpty)
    }

    @Test func recreatingReturnedCompletedTombstoneRestoresCompletionBeforeBranchValidation() async throws {
        let fixture = try await Fixture.make(operation: .creating)
        try await fixture.store.mutate { state in
            state.checkouts[0].members[0].checkpoint = .failed
            state.checkouts[0].members[0].availability = .unavailable
            state.checkouts[0].members[0].recreationSourceCheckpoint = .setupComplete
            state.checkouts[0].members[0].recreationWorktreeCreationBegan = true
        }
        let lifecycle = FixtureLifecycle()
        let coordinator = WorkspaceCheckoutCoordinator(
            store: fixture.store,
            git: FixtureGit(
                preparedBranchMatches: false,
                frozenWorktreeMissingResults: [false]
            ),
            scripts: FixtureScripts(),
            sessions: LifecycleSessions(),
            lifecycle: lifecycle
        )

        let checkout = try await coordinator.resumeCreation(checkoutID: fixture.checkout.id)

        #expect(await lifecycle.recoveredRegistrations == [fixture.member.id])
        #expect(await lifecycle.clearedRegistrations.isEmpty)
        #expect(checkout.members[0].checkpoint == .setupComplete)
        #expect(checkout.members[0].availability == .available)
        #expect(checkout.members[0].recreationSourceCheckpoint == nil)
        #expect(checkout.members[0].recreationWorktreeCreationBegan == false)
    }

    @Test func explicitDeletionRechecksRisksWhenMissingWorktreeReturnsDuringStaleCleanup() async throws {
        let fixture = try await Fixture.make()
        try await fixture.store.mutate { state in
            state.checkouts[0].members[0].availability = .missing
        }
        let lifecycle = FixtureLifecycle(
            preflight: .init(reasons: [.dirty]),
            clearError: WorkspaceCheckoutCoordinatorError.completedWorktreeReturned
        )
        let coordinator = WorkspaceCheckoutCoordinator(
            store: fixture.store,
            git: FixtureGit(),
            scripts: FixtureScripts(),
            sessions: LifecycleSessions(),
            lifecycle: lifecycle
        )

        await #expect(throws: WorkspaceCheckoutCoordinatorError.cleanupConfirmationRequired) {
            try await coordinator.deleteMember(checkoutID: fixture.checkout.id, memberID: fixture.member.id)
        }

        #expect(await lifecycle.removedMembers.isEmpty)
    }

    @Test func explicitDeletionRejectsReturnedWorktreeWithUnexpectedLineage() async throws {
        let fixture = try await Fixture.make()
        try await fixture.store.mutate { state in
            state.checkouts[0].members[0].availability = .missing
        }
        let lifecycle = FixtureLifecycle(
            verification: .missing,
            preflight: .init(reasons: []),
            clearError: WorkspaceCheckoutCoordinatorError.completedWorktreeReturned
        )
        let coordinator = WorkspaceCheckoutCoordinator(
            store: fixture.store,
            git: FixtureGit(),
            scripts: FixtureScripts(),
            sessions: LifecycleSessions(),
            lifecycle: lifecycle
        )

        await #expect(throws: WorkspaceCheckoutCoordinatorError.cleanupIdentityConflict) {
            try await coordinator.deleteMember(checkoutID: fixture.checkout.id, memberID: fixture.member.id)
        }

        #expect(await lifecycle.removedMembers.isEmpty)
    }

    @Test func deletionPreviewAllowsMissingAttemptOwnedMembers() async throws {
        let fixture = try await Fixture.make()
        try await fixture.store.mutate { state in
            state.checkouts[0].members[0].availability = .missing
        }
        let lifecycle = FixtureLifecycle(
            verification: .missing,
            preflight: .init(reasons: [.dirty])
        )
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: FixtureGit(), scripts: FixtureScripts(), sessions: LifecycleSessions(), lifecycle: lifecycle)

        let preview = try await coordinator.previewMemberDeletion(checkoutID: fixture.checkout.id, memberID: fixture.member.id)

        #expect(preview.member.availability == .missing)
        #expect(preview.preflight.reasons.isEmpty)
        #expect(preview.plan.expectedLineageID == fixture.member.gitLineageID)
    }

    @Test func interruptedDeletingCheckoutCanResumeFromPersistedCleanup() async throws {
        let fixture = try await Fixture.make()
        let plan = WorkspaceCheckoutCleanupPlan(
            checkoutID: fixture.checkout.id,
            memberID: fixture.member.id,
            executionLocation: fixture.checkout.executionLocation,
            projectID: fixture.member.projectID,
            sourceRepositoryPath: fixture.member.plan!.sourceRepositoryPath,
            baseReference: fixture.member.plan!.baseReference,
            baseCommit: fixture.member.plan!.baseCommit,
            rootPath: fixture.checkout.rootPath,
            managedMemberPaths: [fixture.member.worktreePath],
            worktreePath: fixture.member.worktreePath,
            branch: fixture.checkout.branch,
            expectedLineageID: fixture.member.gitLineageID!,
            branchOwnership: .reused
        )
        try await fixture.store.mutate { state in
            state.checkouts[0].operation = .deleting
            state.checkouts[0].members[0].cleanup = .init(
                plan: plan,
                checkpoint: .worktreeRemoved,
                worktreeRemoved: true
            )
        }
        let lifecycle = FixtureLifecycle(verification: .missing)
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: FixtureGit(), scripts: FixtureScripts(), sessions: LifecycleSessions(), lifecycle: lifecycle)

        let checkout = try await coordinator.deleteMember(checkoutID: fixture.checkout.id, memberID: fixture.member.id)

        #expect(checkout.operation == .idle)
        #expect(checkout.members[0].availability == .explicitlyDeleted)
        #expect(await lifecycle.removedMembers.isEmpty)
    }

    @Test func interruptedDeletionKeepsAlreadyRemovedBranchComplete() async throws {
        let fixture = try await Fixture.make()
        let plan = WorkspaceCheckoutCleanupPlan(
            checkoutID: fixture.checkout.id,
            memberID: fixture.member.id,
            executionLocation: fixture.checkout.executionLocation,
            projectID: fixture.member.projectID,
            sourceRepositoryPath: fixture.member.plan!.sourceRepositoryPath,
            baseReference: fixture.member.plan!.baseReference,
            baseCommit: fixture.member.plan!.baseCommit,
            rootPath: fixture.checkout.rootPath,
            managedMemberPaths: [fixture.member.worktreePath],
            worktreePath: fixture.member.worktreePath,
            branch: fixture.checkout.branch,
            expectedLineageID: fixture.member.gitLineageID!,
            branchOwnership: .created
        )
        try await fixture.store.mutate { state in
            state.checkouts[0].operation = .deleting
            state.checkouts[0].members[0].cleanup = .init(
                plan: plan,
                checkpoint: .complete,
                worktreeRemoved: true,
                branchRemoved: true
            )
        }
        let lifecycle = FixtureLifecycle(verification: .missing)
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: FixtureGit(), scripts: FixtureScripts(), sessions: LifecycleSessions(), lifecycle: lifecycle)

        let checkout = try await coordinator.deleteMember(checkoutID: fixture.checkout.id, memberID: fixture.member.id)

        #expect(checkout.members[0].cleanup?.branchRemoved == true)
        #expect(checkout.members[0].cleanup?.checkpoint == .complete)
        #expect(await lifecycle.deletedBranches.isEmpty)
    }

    @Test func interruptedDeletionTreatsMissingWorktreeAsRemovedWhenCleanupPlanWasDurable() async throws {
        let fixture = try await Fixture.make()
        let plan = WorkspaceCheckoutCleanupPlan(
            checkoutID: fixture.checkout.id,
            memberID: fixture.member.id,
            executionLocation: fixture.checkout.executionLocation,
            projectID: fixture.member.projectID,
            sourceRepositoryPath: fixture.member.plan!.sourceRepositoryPath,
            baseReference: fixture.member.plan!.baseReference,
            baseCommit: fixture.member.plan!.baseCommit,
            rootPath: fixture.checkout.rootPath,
            managedMemberPaths: [fixture.member.worktreePath],
            worktreePath: fixture.member.worktreePath,
            branch: fixture.checkout.branch,
            expectedLineageID: fixture.member.gitLineageID!,
            branchOwnership: .reused
        )
        try await fixture.store.mutate { state in
            state.checkouts[0].operation = .deleting
            state.checkouts[0].members[0].cleanup = .init(plan: plan)
        }
        let lifecycle = FixtureLifecycle(verification: .missing)
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: FixtureGit(), scripts: FixtureScripts(), sessions: LifecycleSessions(), lifecycle: lifecycle)

        let checkout = try await coordinator.deleteMember(checkoutID: fixture.checkout.id, memberID: fixture.member.id)

        #expect(checkout.operation == .idle)
        #expect(checkout.members[0].cleanup?.worktreeRemoved == true)
        #expect(checkout.members[0].cleanup?.checkpoint == .worktreeRemoved)
        #expect(checkout.members[0].availability == .explicitlyDeleted)
        #expect(await lifecycle.removedMembers.isEmpty)
    }

    @Test func missingWorktreeClearsStaleGitRegistrationBeforeRecordingRemoval() async throws {
        let fixture = try await Fixture.make()
        let plan = WorkspaceCheckoutCleanupPlan(
            checkoutID: fixture.checkout.id,
            memberID: fixture.member.id,
            executionLocation: fixture.checkout.executionLocation,
            projectID: fixture.member.projectID,
            sourceRepositoryPath: fixture.member.plan!.sourceRepositoryPath,
            baseReference: fixture.member.plan!.baseReference,
            baseCommit: fixture.member.plan!.baseCommit,
            rootPath: fixture.checkout.rootPath,
            managedMemberPaths: [fixture.member.worktreePath],
            worktreePath: fixture.member.worktreePath,
            branch: fixture.checkout.branch,
            expectedLineageID: fixture.member.gitLineageID!,
            branchOwnership: .reused
        )
        try await fixture.store.mutate { state in
            state.checkouts[0].operation = .deleting
            state.checkouts[0].members[0].cleanup = .init(plan: plan)
        }
        let lifecycle = FixtureLifecycle(verification: .missing)
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: FixtureGit(), scripts: FixtureScripts(), sessions: LifecycleSessions(), lifecycle: lifecycle)

        let checkout = try await coordinator.deleteMember(checkoutID: fixture.checkout.id, memberID: fixture.member.id)

        #expect(await lifecycle.clearedRegistrations == [fixture.member.id])
        #expect(await lifecycle.removedMembers.isEmpty)
        #expect(checkout.members[0].cleanup?.worktreeRemoved == true)
        #expect(checkout.members[0].cleanup?.checkpoint == .worktreeRemoved)
    }

    @Test func deleteSnapshotForIdentityConflictDoesNotVerifyOrRemoveAWorktree() async throws {
        let fixture = try await Fixture.make()
        try await fixture.store.mutate { state in
            state.checkouts[0].members[0].availability = .identityConflict
        }
        let lifecycle = FixtureLifecycle()
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: FixtureGit(), scripts: FixtureScripts(), sessions: LifecycleSessions(), lifecycle: lifecycle)

        let checkout = try await coordinator.deleteMemberSnapshot(checkoutID: fixture.checkout.id, memberID: fixture.member.id)

        #expect(checkout.members[0].availability == .explicitlyDeleted)
        #expect(checkout.members[0].checkpoint == .planPersisted)
        #expect(checkout.members[0].cleanup?.worktreeRemoved == true)
        #expect(await lifecycle.removedMembers.isEmpty)
    }

    @Test func deleteSnapshotForReconciledIdentityConflictDoesNotRequirePersistedConflict() async throws {
        let fixture = try await Fixture.make()
        let lifecycle = FixtureLifecycle(verification: .identityConflict("replacement"))
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: FixtureGit(), scripts: FixtureScripts(), sessions: LifecycleSessions(), lifecycle: lifecycle)

        let checkout = try await coordinator.deleteMemberSnapshot(checkoutID: fixture.checkout.id, memberID: fixture.member.id)

        #expect(checkout.members[0].availability == .explicitlyDeleted)
        #expect(checkout.members[0].cleanup?.worktreeRemoved == true)
        #expect(await lifecycle.removedMembers.isEmpty)
    }

    @Test func confirmedForgetCanDiscardSnapshotOnlyDeletion() async throws {
        let fixture = try await Fixture.make()
        try await fixture.store.mutate { state in
            state.checkouts[0].members[0].availability = .identityConflict
        }
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: FixtureGit(), scripts: FixtureScripts(), sessions: LifecycleSessions(), lifecycle: FixtureLifecycle())
        _ = try await coordinator.deleteMemberSnapshot(checkoutID: fixture.checkout.id, memberID: fixture.member.id)

        try await coordinator.forget(checkoutID: fixture.checkout.id, confirmedPreserveArtifacts: true)

        guard case .loaded(let state) = await fixture.store.load() else {
            Issue.record("Expected loaded Workspace state")
            return
        }
        #expect(state.checkouts.isEmpty)
    }

    @Test func deleteCheckoutDiscardsFailedMemberThatNeverCreatedAWorktree() async throws {
        let fixture = try await Fixture.make(branchOwnership: .reused)
        try await fixture.store.mutate { state in
            state.checkouts[0].members[0].availability = .unavailable
            state.checkouts[0].members[0].checkpoint = .failed
            state.checkouts[0].members[0].gitLineageID = nil
            state.checkouts[0].members[0].cleanupOwnership = .init(worktreeCreated: false, branchOwnership: .reused)
            state.checkouts[0].members[0].cleanup = nil
        }
        let lifecycle = FixtureLifecycle()
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: FixtureGit(), scripts: FixtureScripts(), sessions: LifecycleSessions(), lifecycle: lifecycle)

        let checkout = try await coordinator.deleteCheckout(checkoutID: fixture.checkout.id)

        #expect(checkout.members[0].availability == .explicitlyDeleted)
        #expect(checkout.members[0].cleanup == nil)
        #expect(await lifecycle.removedMembers.isEmpty)
    }

    @Test func deleteCheckoutRemovesAttemptCreatedBranchBeforeDiscardingSnapshotOnlyMember() async throws {
        let fixture = try await Fixture.make()
        try await fixture.store.mutate { state in
            state.checkouts[0].members[0].availability = .unavailable
            state.checkouts[0].members[0].checkpoint = .failed
            state.checkouts[0].members[0].gitLineageID = nil
            state.checkouts[0].members[0].cleanupOwnership = .init(worktreeCreated: false, branchOwnership: .created)
            state.checkouts[0].members[0].cleanup = nil
        }
        let lifecycle = FixtureLifecycle()
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: FixtureGit(), scripts: FixtureScripts(), sessions: LifecycleSessions(), lifecycle: lifecycle)

        let checkout = try await coordinator.deleteCheckout(checkoutID: fixture.checkout.id)

        #expect(checkout.members[0].availability == .explicitlyDeleted)
        #expect(checkout.members[0].cleanup?.worktreeRemoved == true)
        #expect(checkout.members[0].cleanup?.branchRemoved == true)
        #expect(await lifecycle.deletedBranches == [fixture.member.id])
        #expect(await lifecycle.removedMembers.isEmpty)
    }

    @Test func forgettingACheckoutStopsOwnedSessionsBeforeRemovingTheSnapshot() async throws {
        let fixture = try await Fixture.make()
        try await fixture.store.mutate { state in
            state.checkouts[0].members[0].cleanup = .init(
                plan: WorkspaceCheckoutCleanupPlan(
                    checkoutID: fixture.checkout.id,
                    memberID: fixture.member.id,
                    executionLocation: .local,
                    projectID: "a",
                    sourceRepositoryPath: "/repo/a",
                    baseReference: "main",
                    baseCommit: "abc",
                    rootPath: "/checkout",
                    managedMemberPaths: ["/checkout/a"],
                    worktreePath: "/checkout/a",
                    branch: "feature/a",
                    expectedLineageID: "lineage-a",
                    branchOwnership: .created
                ),
                worktreeRemoved: true,
                branchRemoved: true
            )
        }
        let sessions = LifecycleSessions()
        let coordinator = WorkspaceCheckoutCoordinator(
            store: fixture.store,
            git: FixtureGit(),
            scripts: FixtureScripts(),
            sessions: sessions,
            lifecycle: FixtureLifecycle()
        )

        try await coordinator.forget(checkoutID: fixture.checkout.id)

        #expect(await sessions.stopped == [fixture.checkout.id])
        guard case .loaded(let state) = await fixture.store.load() else {
            Issue.record("Expected loaded Workspace state")
            return
        }
        #expect(state.checkouts.isEmpty)
    }

    @Test func forgettingCanResumeAfterPersistedDeletingClaim() async throws {
        let fixture = try await Fixture.make()
        try await fixture.store.mutate { state in
            state.checkouts[0].operation = .deleting
            state.checkouts[0].members[0].cleanup = .init(
                plan: WorkspaceCheckoutCleanupPlan(
                    checkoutID: fixture.checkout.id,
                    memberID: fixture.member.id,
                    executionLocation: .local,
                    projectID: "a",
                    sourceRepositoryPath: "/repo/a",
                    baseReference: "main",
                    baseCommit: "abc",
                    rootPath: "/checkout",
                    managedMemberPaths: ["/checkout/a"],
                    worktreePath: "/checkout/a",
                    branch: "feature/a",
                    expectedLineageID: "lineage-a",
                    branchOwnership: .created
                ),
                worktreeRemoved: true,
                branchRemoved: true
            )
        }
        let sessions = LifecycleSessions()
        let coordinator = WorkspaceCheckoutCoordinator(
            store: fixture.store,
            git: FixtureGit(),
            scripts: FixtureScripts(),
            sessions: sessions,
            lifecycle: FixtureLifecycle()
        )

        try await coordinator.forget(checkoutID: fixture.checkout.id)

        #expect(await sessions.stopped == [fixture.checkout.id])
        guard case .loaded(let state) = await fixture.store.load() else {
            Issue.record("Expected loaded Workspace state")
            return
        }
        #expect(state.checkouts.isEmpty)
    }

    @Test func deletionNeverRemovesAReusedBranch() async throws {
        let fixture = try await Fixture.make(branchOwnership: .reused)
        let lifecycle = FixtureLifecycle()
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: FixtureGit(), scripts: FixtureScripts(), sessions: LifecycleSessions(), lifecycle: lifecycle)

        _ = try await coordinator.deleteMember(checkoutID: fixture.checkout.id, memberID: fixture.member.id)

        #expect(await lifecycle.deletedBranches.isEmpty)
    }

    @Test func wrongLineageFailsClosedBeforeRemovingAnything() async throws {
        let fixture = try await Fixture.make()
        let lifecycle = FixtureLifecycle(verification: .identityConflict("other"))
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: FixtureGit(), scripts: FixtureScripts(), sessions: LifecycleSessions(), lifecycle: lifecycle)

        await #expect(throws: WorkspaceCheckoutCoordinatorError.cleanupIdentityConflict) {
            try await coordinator.deleteMember(checkoutID: fixture.checkout.id, memberID: fixture.member.id)
        }
        #expect(await lifecycle.removedMembers.isEmpty)
    }

    @Test func riskyWorktreeRequiresAnExplicitCleanupConfirmationWithoutAForcePath() async throws {
        let fixture = try await Fixture.make()
        let lifecycle = FixtureLifecycle(preflight: .init(reasons: [.dirty]))
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: FixtureGit(), scripts: FixtureScripts(), sessions: LifecycleSessions(), lifecycle: lifecycle)

        await #expect(throws: WorkspaceCheckoutCoordinatorError.cleanupConfirmationRequired) {
            try await coordinator.deleteMember(checkoutID: fixture.checkout.id, memberID: fixture.member.id)
        }
        #expect(await lifecycle.removedMembers.isEmpty)
    }

    @Test func confirmedRiskPassesForceToWorktreeRemoval() async throws {
        let fixture = try await Fixture.make()
        let lifecycle = FixtureLifecycle(preflight: .init(reasons: [.dirty]))
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: FixtureGit(), scripts: FixtureScripts(), sessions: LifecycleSessions(), lifecycle: lifecycle)

        _ = try await coordinator.deleteMember(checkoutID: fixture.checkout.id, memberID: fixture.member.id, confirmingRisks: true)

        let decisions = await lifecycle.removeForces
        #expect(decisions.map { $0.force } == [true])
        #expect(decisions.map { $0.forceTwice } == [false])
    }

    @Test func confirmedLockedWorktreePassesDoubleForceToWorktreeRemoval() async throws {
        let fixture = try await Fixture.make()
        let lifecycle = FixtureLifecycle(preflight: .init(reasons: [.locked]))
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: FixtureGit(), scripts: FixtureScripts(), sessions: LifecycleSessions(), lifecycle: lifecycle)

        _ = try await coordinator.deleteMember(checkoutID: fixture.checkout.id, memberID: fixture.member.id, confirmingRisks: true)

        let decisions = await lifecycle.removeForces
        #expect(decisions.map { $0.force } == [true])
        #expect(decisions.map { $0.forceTwice } == [true])
    }

    @Test func wholeDeletionRequiresRiskConfirmationBeforeRemovingAnyMember() async throws {
        let fixture = try await Fixture.make(memberCount: 2)
        let lifecycle = FixtureLifecycle(preflight: .init(reasons: [.dirty]))
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: FixtureGit(), scripts: FixtureScripts(), sessions: LifecycleSessions(), lifecycle: lifecycle)

        let result = try await coordinator.deleteCheckout(checkoutID: fixture.checkout.id)

        #expect(result.members.allSatisfy { $0.availability == .available })
        #expect(await lifecycle.removedMembers.isEmpty)
    }

    @Test func confirmedWholeDeletionPassesRiskConfirmationToEveryMember() async throws {
        let fixture = try await Fixture.make(memberCount: 2)
        let lifecycle = FixtureLifecycle(preflight: .init(reasons: [.dirty]))
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: FixtureGit(), scripts: FixtureScripts(), sessions: LifecycleSessions(), lifecycle: lifecycle)

        let result = try await coordinator.deleteCheckout(checkoutID: fixture.checkout.id, confirmingRisks: true)

        #expect(result.members.allSatisfy { $0.availability == .explicitlyDeleted })
        let decisions = await lifecycle.removeForces
        #expect(decisions.map { $0.force } == [true, true])
        #expect(decisions.map { $0.forceTwice } == [false, false])
    }

    @Test func wholeDeletionContinuesAfterOneMemberFails() async throws {
        let fixture = try await Fixture.make(memberCount: 2)
        let lifecycle = FixtureLifecycle(failingMember: fixture.checkout.members[0].id)
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: FixtureGit(), scripts: FixtureScripts(), sessions: LifecycleSessions(), lifecycle: lifecycle)

        let result = try await coordinator.deleteCheckout(checkoutID: fixture.checkout.id)

        #expect(result.members[0].availability == .available)
        #expect(result.members[1].availability == .explicitlyDeleted)
    }

    @Test func wholeDeletionRecordsADiagnosticForEachFailedMember() async throws {
        let fixture = try await Fixture.make(memberCount: 2)
        let failing = fixture.checkout.members[0]
        let lifecycle = FixtureLifecycle(failingMember: failing.id)
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: FixtureGit(), scripts: FixtureScripts(), sessions: LifecycleSessions(), lifecycle: lifecycle)

        let result = try await coordinator.deleteCheckout(checkoutID: fixture.checkout.id)

        let failures = result.diagnostics.filter { $0.severity == .error && $0.memberID == failing.id }
        #expect(failures.map(\.message) == ["Could not delete \(failing.fallbackProjectName)."])
        #expect(failures.first?.detail?.isEmpty == false)
        #expect(result.members[0].cleanup?.checkpoint == .failed)
        #expect(result.diagnostics.contains { $0.memberID == fixture.checkout.members[1].id } == false)
    }

    @Test func directMemberRetryClearsTheEarlierWholeCheckoutFailureDiagnostic() async throws {
        // A whole-checkout deletion records a failure diagnostic for a
        // member that couldn't be removed. The details view offers that
        // member its own direct "Delete Worktree" retry, which calls
        // deleteMember directly rather than going through the whole-checkout
        // loop — a successful retry there must still clear the diagnostic,
        // not just a retry of the whole checkout.
        let fixture = try await Fixture.make(memberCount: 2)
        let failing = fixture.checkout.members[0]
        let failingLifecycle = FixtureLifecycle(failingMember: failing.id)
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: FixtureGit(), scripts: FixtureScripts(), sessions: LifecycleSessions(), lifecycle: failingLifecycle)
        let afterFailure = try await coordinator.deleteCheckout(checkoutID: fixture.checkout.id)
        #expect(afterFailure.diagnostics.contains { $0.memberID == failing.id })

        let retryCoordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: FixtureGit(), scripts: FixtureScripts(), sessions: LifecycleSessions(), lifecycle: FixtureLifecycle())
        let afterRetry = try await retryCoordinator.deleteMember(checkoutID: fixture.checkout.id, memberID: failing.id)

        #expect(!afterRetry.diagnostics.contains { $0.memberID == failing.id })
        #expect(afterRetry.members.first(where: { $0.id == failing.id })?.availability == .explicitlyDeleted)
    }

    @Test func wholeDeletionReplacesTheEarlierFailureDiagnosticWhenRetried() async throws {
        let fixture = try await Fixture.make(memberCount: 2)
        let failing = fixture.checkout.members[0]
        let lifecycle = FixtureLifecycle(failingMember: failing.id)
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: FixtureGit(), scripts: FixtureScripts(), sessions: LifecycleSessions(), lifecycle: lifecycle)

        _ = try await coordinator.deleteCheckout(checkoutID: fixture.checkout.id)
        let result = try await coordinator.deleteCheckout(checkoutID: fixture.checkout.id)

        #expect(result.diagnostics.filter { $0.memberID == failing.id }.count == 1)
    }

    @Test func deletingAndForgettingDropsTheRecordOnceEveryMemberIsRemoved() async throws {
        let fixture = try await Fixture.make(memberCount: 2)
        let sessions = LifecycleSessions()
        let lifecycle = FixtureLifecycle()
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: FixtureGit(), scripts: FixtureScripts(), sessions: sessions, lifecycle: lifecycle)

        let outcome = try await coordinator.deleteCheckoutAndForget(checkoutID: fixture.checkout.id)

        #expect(outcome == .forgotten)
        #expect(await sessions.stopped == [fixture.checkout.id])
        #expect(await lifecycle.removedRootArtifacts == [fixture.checkout.id])
        guard case .loaded(let state) = await fixture.store.load() else {
            Issue.record("Expected loaded Workspace state")
            return
        }
        #expect(state.checkouts.isEmpty)
    }

    @Test func deletingAndForgettingKeepsTheRecordWhenAMemberCannotBeRemoved() async throws {
        let fixture = try await Fixture.make(memberCount: 2)
        let failing = fixture.checkout.members[0]
        let sessions = LifecycleSessions()
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: FixtureGit(), scripts: FixtureScripts(), sessions: sessions, lifecycle: FixtureLifecycle(failingMember: failing.id))

        let outcome = try await coordinator.deleteCheckoutAndForget(checkoutID: fixture.checkout.id)

        guard case .retained(let checkout, let failures) = outcome else {
            Issue.record("Expected the checkout to be retained, got \(outcome)")
            return
        }
        #expect(checkout.id == fixture.checkout.id)
        #expect(failures.map(\.memberID) == [failing.id])
        #expect(failures.map(\.memberName) == [failing.fallbackProjectName])
        #expect(failures.first?.message.isEmpty == false)
        #expect(await sessions.stopped.isEmpty)
        guard case .loaded(let state) = await fixture.store.load() else {
            Issue.record("Expected loaded Workspace state")
            return
        }
        #expect(state.checkouts.count == 1)
    }

    @Test func deletingAndForgettingStopsAtTheArtifactAcknowledgement() async throws {
        let fixture = try await Fixture.make()
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: FixtureGit(), scripts: FixtureScripts(), sessions: LifecycleSessions(), lifecycle: FixtureLifecycle(leftovers: ["notes.txt"]))

        let outcome = try await coordinator.deleteCheckoutAndForget(checkoutID: fixture.checkout.id)

        guard case .artifactsNeedConfirmation(let checkout) = outcome else {
            Issue.record("Expected an artifact acknowledgement, got \(outcome)")
            return
        }
        #expect(checkout.members.allSatisfy { $0.availability == .explicitlyDeleted })
        #expect(checkout.members[0].cleanup?.sharedRootLeftovers == ["notes.txt"])
        guard case .loaded(let state) = await fixture.store.load() else {
            Issue.record("Expected loaded Workspace state")
            return
        }
        #expect(state.checkouts.count == 1)
    }

    @Test func deletingAndForgettingWithAcknowledgedArtifactsDropsTheRecord() async throws {
        let fixture = try await Fixture.make()
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: FixtureGit(), scripts: FixtureScripts(), sessions: LifecycleSessions(), lifecycle: FixtureLifecycle(leftovers: ["notes.txt"], branchRemoved: false))

        let outcome = try await coordinator.deleteCheckoutAndForget(checkoutID: fixture.checkout.id, confirmedPreserveArtifacts: true)

        #expect(outcome == .forgotten)
        guard case .loaded(let state) = await fixture.store.load() else {
            Issue.record("Expected loaded Workspace state")
            return
        }
        #expect(state.checkouts.isEmpty)
    }

    @Test func deletingAndForgettingHonorsAStopRequestWithoutReportingFailures() async throws {
        let fixture = try await Fixture.make(memberCount: 2)
        try await fixture.store.mutate { state in state.checkouts[0].stopAfterCurrentOperations = true }
        let lifecycle = FixtureLifecycle()
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: FixtureGit(), scripts: FixtureScripts(), sessions: LifecycleSessions(), lifecycle: lifecycle)

        let outcome = try await coordinator.deleteCheckoutAndForget(checkoutID: fixture.checkout.id)

        guard case .retained(let checkout, let failures) = outcome else {
            Issue.record("Expected the checkout to be retained, got \(outcome)")
            return
        }
        #expect(failures.isEmpty)
        #expect(checkout.operation == .idle)
        #expect(await lifecycle.removedMembers.isEmpty)
    }

    @Test func wholeDeletionRetainsTheCheckoutClaimUntilTheOuterLoopFinishes() async throws {
        let fixture = try await Fixture.make(memberCount: 2)
        let lifecycle = StoreInspectingLifecycle(store: fixture.store, checkoutID: fixture.checkout.id)
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: FixtureGit(), scripts: FixtureScripts(), sessions: LifecycleSessions(), lifecycle: lifecycle)

        let result = try await coordinator.deleteCheckout(checkoutID: fixture.checkout.id)

        #expect(await lifecycle.operationsDuringRemoval == [.deleting, .deleting])
        #expect(result.operation == .idle)
        #expect(result.members.allSatisfy { $0.availability == .explicitlyDeleted })
    }

    @Test func concurrentWholeDeletionRejectsTheSecondLiveRequest() async throws {
        let fixture = try await Fixture.make(memberCount: 2)
        let lifecycle = BlockingLifecycle()
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: FixtureGit(), scripts: FixtureScripts(), sessions: LifecycleSessions(), lifecycle: lifecycle)

        let first = Task { try await coordinator.deleteCheckout(checkoutID: fixture.checkout.id) }
        await lifecycle.waitUntilRemoving()

        await #expect(throws: WorkspaceCheckoutCoordinatorError.operationInProgress) {
            try await coordinator.deleteCheckout(checkoutID: fixture.checkout.id)
        }

        await lifecycle.release()
        _ = try await first.value
    }

    @Test func forgettingRequiresResolvedSharedRootLeftovers() async throws {
        let fixture = try await Fixture.make()
        let lifecycle = FixtureLifecycle(leftovers: ["notes.txt"])
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: FixtureGit(), scripts: FixtureScripts(), sessions: LifecycleSessions(), lifecycle: lifecycle)
        _ = try await coordinator.deleteMember(checkoutID: fixture.checkout.id, memberID: fixture.member.id)

        await #expect(throws: WorkspaceCheckoutCoordinatorError.cleanupIncomplete) {
            try await coordinator.forget(checkoutID: fixture.checkout.id)
        }
    }

    @Test func confirmedForgetPreservesSharedRootLeftovers() async throws {
        let fixture = try await Fixture.make(branchOwnership: .reused)
        let lifecycle = FixtureLifecycle(leftovers: [WorkspaceCheckoutManifest.fileName, "notes.txt"])
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: FixtureGit(), scripts: FixtureScripts(), sessions: LifecycleSessions(), lifecycle: lifecycle)
        _ = try await coordinator.deleteMember(checkoutID: fixture.checkout.id, memberID: fixture.member.id)

        try await coordinator.forget(checkoutID: fixture.checkout.id, confirmedPreserveArtifacts: true)

        guard case .loaded(let state) = await fixture.store.load() else { Issue.record("Expected stored state")
            return
        }
        #expect(state.checkouts.contains(where: { $0.id == fixture.checkout.id }) == false)
    }

    @Test func forgetRemovesOwnedCheckoutRootArtifactsBeforeDroppingTheRecord() async throws {
        let fixture = try await Fixture.make(branchOwnership: .reused)
        let lifecycle = FixtureLifecycle()
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: FixtureGit(), scripts: FixtureScripts(), sessions: LifecycleSessions(), lifecycle: lifecycle)
        _ = try await coordinator.deleteMember(checkoutID: fixture.checkout.id, memberID: fixture.member.id)

        try await coordinator.forget(checkoutID: fixture.checkout.id)

        #expect(await lifecycle.removedRootArtifacts == [fixture.checkout.id])
    }

    @Test func forgetRemovesOwnedCheckoutRootArtifactsEvenWithoutMemberCleanupPlan() async throws {
        let fixture = try await Fixture.make(branchOwnership: .reused)
        try await fixture.store.mutate { state in
            state.checkouts[0].members[0].cleanup = nil
            state.checkouts[0].members[0].cleanupOwnership = .init()
            state.checkouts[0].members[0].availability = .explicitlyDeleted
        }
        let lifecycle = FixtureLifecycle()
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: FixtureGit(), scripts: FixtureScripts(), sessions: LifecycleSessions(), lifecycle: lifecycle)

        try await coordinator.forget(checkoutID: fixture.checkout.id, confirmedPreserveArtifacts: true)

        #expect(await lifecycle.removedRootArtifacts == [fixture.checkout.id])
        guard case .loaded(let state) = await fixture.store.load() else {
            Issue.record("Expected Workspace state to remain readable")
            return
        }
        #expect(state.checkouts.contains(where: { $0.id == fixture.checkout.id }) == false)
    }

    @Test func forgettingARetainedAttemptCreatedBranchRequiresSeparateConfirmation() async throws {
        let fixture = try await Fixture.make()
        let lifecycle = FixtureLifecycle(branchRemoved: false)
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: FixtureGit(), scripts: FixtureScripts(), sessions: LifecycleSessions(), lifecycle: lifecycle)
        _ = try await coordinator.deleteMember(checkoutID: fixture.checkout.id, memberID: fixture.member.id)

        await #expect(throws: WorkspaceCheckoutCoordinatorError.cleanupIncomplete) {
            try await coordinator.forget(checkoutID: fixture.checkout.id)
        }
        try await coordinator.forget(checkoutID: fixture.checkout.id, confirmedPreserveArtifacts: true)
        guard case .loaded(let state) = await fixture.store.load() else { Issue.record("Expected stored state")
        return }
        #expect(state.checkouts.contains(where: { $0.id == fixture.checkout.id }) == false)
    }

    @Test func concreteLifecycleUsesSSHTransportForCleanup() async throws {
        let runner = RemoteLifecycleRunner(results: [
            .init(exitCode: 0, stdout: " M file.txt\n", stderr: ""),
            .init(exitCode: 0, stdout: "", stderr: ""),
            .init(exitCode: 0, stdout: "worktree /checkout/a\nHEAD abc\nbranch refs/heads/feature\n", stderr: ""),
            .init(exitCode: 0, stdout: "", stderr: ""),
            .init(exitCode: 0, stdout: "", stderr: ""),
            .init(exitCode: 1, stdout: "", stderr: "not merged"),
            .init(exitCode: 0, stdout: ".alas-workspace-checkout.json\nnotes.txt\n", stderr: ""),
        ])
        let lifecycle = WorkspaceCheckoutLifecycleOperator(remote: .init { executable, args, timeout in
            try await runner.run(executable: executable, args: args, timeout: timeout)
        })
        let plan = WorkspaceCheckoutCleanupPlan(
            checkoutID: UUID(),
            memberID: UUID(),
            executionLocation: .ssh("example.com"),
            projectID: "project",
            sourceRepositoryPath: "/repo",
            baseReference: "main",
            baseCommit: "abc",
            branchCommit: "abc",
            rootPath: "/checkout",
            managedMemberPaths: ["/checkout/a"],
            worktreePath: "/checkout/a",
            branch: "feature",
            expectedLineageID: "lineage",
            branchOwnership: .created
        )

        let preflight = try await lifecycle.deletePreflight(plan)
        try await lifecycle.removeWorktree(plan, force: true, forceTwice: true)
        let branchRemoved = try await lifecycle.deleteMergedBranch(plan)
        let root = await lifecycle.inspectRoot(plan)

        #expect(preflight.reasons == [.dirty])
        #expect(branchRemoved == false)
        #expect(root.leftovers == ["notes.txt"])
        let commands = await runner.commands.joined(separator: "\n")
        #expect(commands.contains("worktree remove -f -f --"))
        #expect(commands.contains("rev-parse --verify"))
        #expect(commands.contains("branch -d") == false)
        #expect(commands.contains("m=$(cd") == false)
    }

    /// Regression: git's refusal to remove a worktree holding an
    /// initialized submodule is structural, not a data-loss signal, so a
    /// clean remote worktree must still delete without the caller having
    /// pre-approved force. Matches the local `WorktreeService.remove` path.
    ///
    /// The generated command is a self-contained POSIX shell script, not a
    /// sequence of independently mockable SSH round trips (that was the bug
    /// Codex flagged — see `sshRemovalScript`'s doc comment), so this
    /// exercises the script for real via `/bin/sh -c` against a local
    /// repository standing in for the remote one, rather than a canned
    /// `RemoteLifecycleRunner` queue.
    @Test func sshRemovalScriptForcesCleanInitializedSubmoduleWithoutPriorApproval() async throws {
        let fixture = try await Self.makeSubmoduleFixture(suffix: "ssh-script-clean")
        defer { fixture.removeFiles() }

        let script = WorkspaceCheckoutLifecycleOperator.sshRemovalScript(
            sourceRepositoryPath: fixture.repo.path,
            worktreePath: fixture.worktree.path,
            force: false
        )
        let result = try await Process.run("/bin/sh", args: ["-c", script])

        #expect(result.exitCode == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.worktree.path))
        let registrations = try await Process.git(["worktree", "list", "--porcelain"], cwd: fixture.repo, usesRemoteHostRegistry: false)
        #expect(!registrations.stdout.contains(fixture.worktree.path))
    }

    /// Regression: a submodule with `submodule.<name>.ignore = all` hides its
    /// dirty content from a plain superproject `git status`, and a submodule
    /// with its own `status.showUntrackedFiles = no` hides untracked files
    /// even from an unignored one — only an explicit `--ignore-submodules=none`
    /// plus a recursive `submodule foreach` override sees either. Without
    /// both, an auto-force retry would silently discard that content.
    @Test func sshRemovalScriptRefusesSubmoduleWithContentHiddenFromPlainStatus() async throws {
        let fixture = try await Self.makeSubmoduleFixture(suffix: "ssh-script-hidden-dirty")
        defer { fixture.removeFiles() }
        try await Self.runGit(
            ["config", "submodule.sub.ignore", "all"],
            cwd: URL(fileURLWithPath: fixture.worktree.path)
        )
        try "dirty".write(
            toFile: fixture.worktree.path + "/sub/tracked.txt",
            atomically: true,
            encoding: .utf8
        )

        let script = WorkspaceCheckoutLifecycleOperator.sshRemovalScript(
            sourceRepositoryPath: fixture.repo.path,
            worktreePath: fixture.worktree.path,
            force: false
        )
        let result = try await Process.run("/bin/sh", args: ["-c", script])

        #expect(result.exitCode != 0)
        #expect(FileManager.default.fileExists(atPath: fixture.worktree.path))
        #expect(FileManager.default.fileExists(atPath: fixture.worktree.path + "/sub/tracked.txt"))
    }

    @Test func concreteLocalCleanupRemovesOnlyTheTargetStaleRegistrationMetadata() async throws {
        let temp = FileManager.default.temporaryDirectory
        let canonicalTemp = temp.path.hasPrefix("/var/")
            ? URL(fileURLWithPath: "/private\(temp.path)", isDirectory: true)
            : temp.resolvingSymlinksInPath()
        let root = canonicalTemp
            .appendingPathComponent("alas-lifecycle-\(UUID().uuidString)", isDirectory: true)
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        let target = root.appendingPathComponent("foo.alas-removing-bar", isDirectory: true)
        let unrelated = root.appendingPathComponent("unrelated", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await Self.runGit(["init", repo.path], cwd: root)
        try await Self.runGit(["config", "user.email", "test@example.com"], cwd: repo)
        try await Self.runGit(["config", "user.name", "Test"], cwd: repo)
        try "a\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try await Self.runGit(["add", "a.txt"], cwd: repo)
        try await Self.runGit(["commit", "-m", "init"], cwd: repo)
        try await Self.runGit(["worktree", "add", target.path], cwd: repo)
        try await Self.runGit(["worktree", "add", unrelated.path], cwd: repo)
        _ = WorktreeService.localLineageID(forWorktreeAt: target, candidateID: "lineage")
        _ = WorktreeService.localLineageID(forWorktreeAt: unrelated, candidateID: "other-lineage")
        try FileManager.default.removeItem(at: target)
        let lifecycle = WorkspaceCheckoutLifecycleOperator()
        var plan = Self.localCleanupPlan(repo: repo.path, worktree: target.path)

        try await lifecycle.clearStaleRegistration(plan)

        let registrations = try await Process.git(["worktree", "list", "--porcelain"], cwd: repo, usesRemoteHostRegistry: false)
        #expect(Self.porcelainOutput(registrations.stdout, containsWorktree: target.path) == false)
        #expect(Self.porcelainOutput(registrations.stdout, containsWorktree: unrelated.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(try Self.tombstoneAdminDirectories(repo: repo).count == 1)
        try await lifecycle.finalizeStaleRegistrationCleanup(plan)
        #expect(try Self.tombstoneAdminDirectories(repo: repo).isEmpty)
        plan.worktreePath = unrelated.path
        await #expect(throws: WorkspaceCheckoutCoordinatorError.completedWorktreeReturned) {
            try await lifecycle.clearStaleRegistration(plan)
        }
    }

    @Test func concreteLocalCleanupMatchesResolvedPorcelainWorktreePath() async throws {
        let temp = FileManager.default.temporaryDirectory
        let canonicalTemp = temp.path.hasPrefix("/var/")
            ? URL(fileURLWithPath: "/private\(temp.path)", isDirectory: true)
            : temp.resolvingSymlinksInPath()
        let root = canonicalTemp
            .appendingPathComponent("alas-lifecycle-\(UUID().uuidString)", isDirectory: true)
        let physicalRoot = root.appendingPathComponent("physical", isDirectory: true)
        let linkedRoot = root.appendingPathComponent("linked", isDirectory: true)
        let repo = physicalRoot.appendingPathComponent("repo", isDirectory: true)
        let physicalTarget = physicalRoot.appendingPathComponent("target", isDirectory: true)
        let linkedTarget = linkedRoot.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: physicalRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: physicalRoot)
        defer { try? FileManager.default.removeItem(at: root) }
        try await Self.runGit(["init", repo.path], cwd: physicalRoot)
        try await Self.runGit(["config", "user.email", "test@example.com"], cwd: repo)
        try await Self.runGit(["config", "user.name", "Test"], cwd: repo)
        try "a\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try await Self.runGit(["add", "a.txt"], cwd: repo)
        try await Self.runGit(["commit", "-m", "init"], cwd: repo)
        try await Self.runGit(["worktree", "add", physicalTarget.path], cwd: repo)
        _ = WorktreeService.localLineageID(forWorktreeAt: physicalTarget, candidateID: "lineage")
        try FileManager.default.removeItem(at: physicalTarget)
        let lifecycle = WorkspaceCheckoutLifecycleOperator()

        try await lifecycle.clearStaleRegistration(Self.localCleanupPlan(repo: repo.path, worktree: linkedTarget.path))

        let registrations = try await Process.git(["worktree", "list", "--porcelain"], cwd: repo, usesRemoteHostRegistry: false)
        #expect(Self.porcelainOutput(registrations.stdout, containsWorktree: physicalTarget.path) == false)
    }

    @Test func concreteLocalCleanupRejectsStaleRegistrationWithDifferentLineage() async throws {
        let temp = FileManager.default.temporaryDirectory
        let canonicalTemp = temp.path.hasPrefix("/var/")
            ? URL(fileURLWithPath: "/private\(temp.path)", isDirectory: true)
            : temp.resolvingSymlinksInPath()
        let root = canonicalTemp
            .appendingPathComponent("alas-lifecycle-\(UUID().uuidString)", isDirectory: true)
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        let target = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await Self.runGit(["init", repo.path], cwd: root)
        try await Self.runGit(["config", "user.email", "test@example.com"], cwd: repo)
        try await Self.runGit(["config", "user.name", "Test"], cwd: repo)
        try "a\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try await Self.runGit(["add", "a.txt"], cwd: repo)
        try await Self.runGit(["commit", "-m", "init"], cwd: repo)
        try await Self.runGit(["worktree", "add", target.path], cwd: repo)
        _ = WorktreeService.localLineageID(forWorktreeAt: target, candidateID: "other-lineage")
        try FileManager.default.removeItem(at: target)
        let lifecycle = WorkspaceCheckoutLifecycleOperator()

        await #expect(throws: WorkspaceCheckoutCoordinatorError.cleanupIdentityConflict) {
            try await lifecycle.clearStaleRegistration(Self.localCleanupPlan(repo: repo.path, worktree: target.path))
        }

        let registrations = try await Process.git(["worktree", "list", "--porcelain"], cwd: repo, usesRemoteHostRegistry: false)
        #expect(Self.porcelainOutput(registrations.stdout, containsWorktree: target.path))
    }

    @Test func concreteLocalExplicitCleanupRejectsStaleRegistrationWithDifferentLineage() async throws {
        let temp = FileManager.default.temporaryDirectory
        let canonicalTemp = temp.path.hasPrefix("/var/")
            ? URL(fileURLWithPath: "/private\(temp.path)", isDirectory: true)
            : temp.resolvingSymlinksInPath()
        let root = canonicalTemp
            .appendingPathComponent("alas-lifecycle-\(UUID().uuidString)", isDirectory: true)
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        let target = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await Self.runGit(["init", repo.path], cwd: root)
        try await Self.runGit(["config", "user.email", "test@example.com"], cwd: repo)
        try await Self.runGit(["config", "user.name", "Test"], cwd: repo)
        try "a\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try await Self.runGit(["add", "a.txt"], cwd: repo)
        try await Self.runGit(["commit", "-m", "init"], cwd: repo)
        try await Self.runGit(["worktree", "add", target.path], cwd: repo)
        _ = WorktreeService.localLineageID(forWorktreeAt: target, candidateID: "other-lineage")
        try FileManager.default.removeItem(at: target)
        let lifecycle = WorkspaceCheckoutLifecycleOperator()

        await #expect(throws: WorkspaceCheckoutCoordinatorError.cleanupIdentityConflict) {
            try await lifecycle.clearStaleRegistrationForExplicitDeletion(Self.localCleanupPlan(repo: repo.path, worktree: target.path))
        }

        let registrations = try await Process.git(["worktree", "list", "--porcelain"], cwd: repo, usesRemoteHostRegistry: false)
        #expect(Self.porcelainOutput(registrations.stdout, containsWorktree: target.path))
    }

    @Test func concreteLocalExplicitCleanupRemovesRecoveredPendingTombstoneRegistration() async throws {
        let temp = FileManager.default.temporaryDirectory
        let canonicalTemp = temp.path.hasPrefix("/var/")
            ? URL(fileURLWithPath: "/private\(temp.path)", isDirectory: true)
            : temp.resolvingSymlinksInPath()
        let root = canonicalTemp
            .appendingPathComponent("alas-lifecycle-\(UUID().uuidString)", isDirectory: true)
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        let target = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await Self.runGit(["init", repo.path], cwd: root)
        try await Self.runGit(["config", "user.email", "test@example.com"], cwd: repo)
        try await Self.runGit(["config", "user.name", "Test"], cwd: repo)
        try "a\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try await Self.runGit(["add", "a.txt"], cwd: repo)
        try await Self.runGit(["commit", "-m", "init"], cwd: repo)
        try await Self.runGit(["worktree", "add", target.path], cwd: repo)
        _ = WorktreeService.localLineageID(forWorktreeAt: target, candidateID: "lineage")
        let lifecycle = WorkspaceCheckoutLifecycleOperator()
        try FileManager.default.removeItem(at: target)
        try await lifecycle.clearStaleRegistration(Self.localCleanupPlan(repo: repo.path, worktree: target.path))
        #expect(try Self.tombstoneAdminDirectories(repo: repo).count == 1)

        try await lifecycle.clearStaleRegistrationForExplicitDeletion(Self.localCleanupPlan(repo: repo.path, worktree: target.path))

        #expect(try Self.tombstoneAdminDirectories(repo: repo).isEmpty)
        let registrations = try await Process.git(["worktree", "list", "--porcelain"], cwd: repo, usesRemoteHostRegistry: false)
        #expect(Self.porcelainOutput(registrations.stdout, containsWorktree: target.path) == false)
    }

    @Test func concreteLocalExplicitCleanupRestoresReturnedPendingTombstoneBeforePreflight() async throws {
        let temp = FileManager.default.temporaryDirectory
        let canonicalTemp = temp.path.hasPrefix("/var/")
            ? URL(fileURLWithPath: "/private\(temp.path)", isDirectory: true)
            : temp.resolvingSymlinksInPath()
        let root = canonicalTemp
            .appendingPathComponent("alas-lifecycle-\(UUID().uuidString)", isDirectory: true)
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        let target = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await Self.runGit(["init", repo.path], cwd: root)
        try await Self.runGit(["config", "user.email", "test@example.com"], cwd: repo)
        try await Self.runGit(["config", "user.name", "Test"], cwd: repo)
        try "a\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try await Self.runGit(["add", "a.txt"], cwd: repo)
        try await Self.runGit(["commit", "-m", "init"], cwd: repo)
        try await Self.runGit(["worktree", "add", target.path], cwd: repo)
        _ = WorktreeService.localLineageID(forWorktreeAt: target, candidateID: "lineage")
        let lifecycle = WorkspaceCheckoutLifecycleOperator()
        try FileManager.default.removeItem(at: target)
        try await lifecycle.clearStaleRegistration(Self.localCleanupPlan(repo: repo.path, worktree: target.path))
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        await #expect(throws: WorkspaceCheckoutCoordinatorError.completedWorktreeReturned) {
            try await lifecycle.clearStaleRegistrationForExplicitDeletion(Self.localCleanupPlan(repo: repo.path, worktree: target.path))
        }

        #expect(try Self.tombstoneAdminDirectories(repo: repo).isEmpty)
        let registrations = try await Process.git(["worktree", "list", "--porcelain"], cwd: repo, usesRemoteHostRegistry: false)
        #expect(Self.porcelainOutput(registrations.stdout, containsWorktree: target.path))
    }

    @Test func concreteLocalCleanupRecoversInterruptedTombstoneBeforeReturnedWorktreeCheck() async throws {
        let temp = FileManager.default.temporaryDirectory
        let canonicalTemp = temp.path.hasPrefix("/var/")
            ? URL(fileURLWithPath: "/private\(temp.path)", isDirectory: true)
            : temp.resolvingSymlinksInPath()
        let root = canonicalTemp
            .appendingPathComponent("alas-lifecycle-\(UUID().uuidString)", isDirectory: true)
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        let target = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await Self.runGit(["init", repo.path], cwd: root)
        try await Self.runGit(["config", "user.email", "test@example.com"], cwd: repo)
        try await Self.runGit(["config", "user.name", "Test"], cwd: repo)
        try "a\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try await Self.runGit(["add", "a.txt"], cwd: repo)
        try await Self.runGit(["commit", "-m", "init"], cwd: repo)
        try await Self.runGit(["worktree", "add", target.path], cwd: repo)
        _ = WorktreeService.localLineageID(forWorktreeAt: target, candidateID: "lineage")
        let admin = try await Self.registeredAdminDirectory(repo: repo, worktree: target)
        let tombstoneRoot = repo.appendingPathComponent(".git/alas-stale-worktree-tombstones", isDirectory: true)
        try FileManager.default.createDirectory(at: tombstoneRoot, withIntermediateDirectories: true)
        let tombstone = tombstoneRoot.appendingPathComponent("\(admin.lastPathComponent).alas-removing-test")
        try FileManager.default.moveItem(at: admin, to: tombstone)
        try "lineage\n".write(
            to: tombstone.appendingPathComponent("alas-stale-registration-tombstone"),
            atomically: true,
            encoding: .utf8
        )
        try "\(admin.lastPathComponent)\n".write(
            to: tombstone.appendingPathComponent("alas-stale-registration-original-name"),
            atomically: true,
            encoding: .utf8
        )
        let incorrectlyRestored = admin.deletingLastPathComponent().appendingPathComponent("foo")
        let lifecycle = WorkspaceCheckoutLifecycleOperator()

        await #expect(throws: WorkspaceCheckoutCoordinatorError.completedWorktreeReturned) {
            try await lifecycle.clearStaleRegistration(Self.localCleanupPlan(repo: repo.path, worktree: target.path))
        }

        #expect(FileManager.default.fileExists(atPath: admin.path))
        #expect(FileManager.default.fileExists(atPath: incorrectlyRestored.path) == false)
        #expect(FileManager.default.fileExists(atPath: tombstone.path) == false)
    }

    @Test func concreteLocalCleanupIgnoresUnmarkedAdminNamesContainingTombstoneText() async throws {
        let temp = FileManager.default.temporaryDirectory
        let canonicalTemp = temp.path.hasPrefix("/var/")
            ? URL(fileURLWithPath: "/private\(temp.path)", isDirectory: true)
            : temp.resolvingSymlinksInPath()
        let root = canonicalTemp
            .appendingPathComponent("alas-lifecycle-\(UUID().uuidString)", isDirectory: true)
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        let target = root.appendingPathComponent("foo.alas-removing-bar", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await Self.runGit(["init", repo.path], cwd: root)
        try await Self.runGit(["config", "user.email", "test@example.com"], cwd: repo)
        try await Self.runGit(["config", "user.name", "Test"], cwd: repo)
        try "a\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try await Self.runGit(["add", "a.txt"], cwd: repo)
        try await Self.runGit(["commit", "-m", "init"], cwd: repo)
        try await Self.runGit(["worktree", "add", target.path], cwd: repo)
        _ = WorktreeService.localLineageID(forWorktreeAt: target, candidateID: "lineage")
        let admin = try await Self.registeredAdminDirectory(repo: repo, worktree: target)
        let incorrectlyRestored = admin.deletingLastPathComponent().appendingPathComponent("foo")
        let lifecycle = WorkspaceCheckoutLifecycleOperator()

        await #expect(throws: WorkspaceCheckoutCoordinatorError.completedWorktreeReturned) {
            try await lifecycle.clearStaleRegistration(Self.localCleanupPlan(repo: repo.path, worktree: target.path))
        }

        #expect(FileManager.default.fileExists(atPath: admin.path))
        #expect(FileManager.default.fileExists(atPath: incorrectlyRestored.path) == false)
    }

    @Test func concreteRemoteCleanupRemovesOnlyTheTargetStaleRegistration() async throws {
        let runner = RemoteLifecycleRunner(results: [
            .init(exitCode: 0, stdout: "/checkout/a\n", stderr: ""),
            .init(exitCode: 0, stdout: "worktree /checkout/a\nprunable gitdir file points to non-existent location\n", stderr: ""),
            .init(exitCode: 0, stdout: "", stderr: ""),
            .init(exitCode: 0, stdout: "worktree /checkout/a\nprunable gitdir file points to non-existent location\n", stderr: ""),
            .init(exitCode: 1, stdout: "", stderr: ""),
            .init(exitCode: 0, stdout: "", stderr: ""),
            .init(exitCode: 0, stdout: "", stderr: ""),
            .init(exitCode: 0, stdout: "", stderr: ""),
        ])
        let lifecycle = WorkspaceCheckoutLifecycleOperator(remote: .init { executable, args, timeout in
            try await runner.run(executable: executable, args: args, timeout: timeout)
        })

        let plan = Self.sshCleanupPlan()
        try await lifecycle.clearStaleRegistration(plan)
        try await lifecycle.finalizeStaleRegistrationCleanup(plan)

        let commands = await runner.commands.joined(separator: "\n")
        #expect(commands.contains("worktree list --porcelain"))
        #expect(commands.contains("/checkout/a"))
        #expect(commands.contains("rev-parse --git-common-dir"))
        #expect(commands.contains("target_real"))
        #expect(commands.contains(".alas-removing"))
        #expect(commands.contains("alas-stale-registration-tombstone"))
        #expect(commands.contains("rm -f -- \"$tomb/$marker_name\" \"$tomb/$original_name_marker\"; mv") == false)
        #expect(commands.contains("worktree remove -f -f --") == false)
        #expect(commands.contains("/checkout/a"))
        #expect(commands.contains("worktree prune") == false)
    }

    @Test func concreteRemoteCleanupRetainsAWorktreeThatReturnsBeforeTargetedRemoval() async throws {
        let runner = RemoteLifecycleRunner(results: [
            .init(exitCode: 0, stdout: "/checkout/a\n", stderr: ""),
            .init(exitCode: 0, stdout: "worktree /checkout/a\nprunable gitdir file points to non-existent location\n", stderr: ""),
            .init(exitCode: 0, stdout: "", stderr: ""),
            .init(exitCode: 0, stdout: "worktree /checkout/a\nprunable gitdir file points to non-existent location\n", stderr: ""),
            .init(exitCode: 0, stdout: "", stderr: ""),
        ])
        let lifecycle = WorkspaceCheckoutLifecycleOperator(remote: .init { executable, args, timeout in
            try await runner.run(executable: executable, args: args, timeout: timeout)
        })

        await #expect(throws: WorkspaceCheckoutCoordinatorError.completedWorktreeReturned) {
            try await lifecycle.clearStaleRegistration(Self.sshCleanupPlan())
        }

        let commands = await runner.commands.joined(separator: "\n")
        #expect(commands.contains("worktree remove -f -f --") == false)
    }

    @Test func concreteRemoteCleanupRetainsLockedMissingWorktreeRegistration() async throws {
        let runner = RemoteLifecycleRunner(results: [
            .init(exitCode: 0, stdout: "/checkout/a\n", stderr: ""),
            .init(exitCode: 0, stdout: "worktree /checkout/a\nlocked\nprunable gitdir file points to non-existent location\n", stderr: ""),
            .init(exitCode: 0, stdout: "", stderr: ""),
            .init(exitCode: 0, stdout: "worktree /checkout/a\nlocked\nprunable gitdir file points to non-existent location\n", stderr: ""),
        ])
        let lifecycle = WorkspaceCheckoutLifecycleOperator(remote: .init { executable, args, timeout in
            try await runner.run(executable: executable, args: args, timeout: timeout)
        })

        await #expect(throws: WorkspaceCheckoutCoordinatorError.lockedStaleRegistration) {
            try await lifecycle.clearStaleRegistration(Self.sshCleanupPlan())
        }

        let commands = await runner.commands.joined(separator: "\n")
        #expect(commands.contains("worktree unlock --") == false)
        #expect(commands.contains("worktree remove -f -f") == false)
    }

    @Test func concreteRemoteCleanupRetainsRegistrationLockedAfterInspection() async throws {
        let runner = RemoteLifecycleRunner(results: [
            .init(exitCode: 0, stdout: "/checkout/a\n", stderr: ""),
            .init(exitCode: 0, stdout: "worktree /checkout/a\nprunable gitdir file points to non-existent location\n", stderr: ""),
            .init(exitCode: 0, stdout: "", stderr: ""),
            .init(exitCode: 0, stdout: "worktree /checkout/a\nprunable gitdir file points to non-existent location\n", stderr: ""),
            .init(exitCode: 1, stdout: "", stderr: ""),
            .init(exitCode: 9, stdout: "", stderr: "locked"),
        ])
        let lifecycle = WorkspaceCheckoutLifecycleOperator(remote: .init { executable, args, timeout in
            try await runner.run(executable: executable, args: args, timeout: timeout)
        })

        await #expect(throws: WorkspaceCheckoutCoordinatorError.lockedStaleRegistration) {
            try await lifecycle.clearStaleRegistration(Self.sshCleanupPlan())
        }

        let commands = await runner.commands.joined(separator: "\n")
        #expect(commands.contains("worktree remove -f -f") == false)
        #expect(commands.contains("worktree prune") == false)
    }

    @Test func concreteRemoteCleanupRejectsStaleRegistrationWithDifferentLineage() async throws {
        let runner = RemoteLifecycleRunner(results: [
            .init(exitCode: 0, stdout: "/checkout/a\n", stderr: ""),
            .init(exitCode: 0, stdout: "worktree /checkout/a\nprunable gitdir file points to non-existent location\n", stderr: ""),
            .init(exitCode: 0, stdout: "", stderr: ""),
            .init(exitCode: 0, stdout: "worktree /checkout/a\nprunable gitdir file points to non-existent location\n", stderr: ""),
            .init(exitCode: 1, stdout: "", stderr: ""),
            .init(exitCode: 13, stdout: "", stderr: "lineage mismatch"),
        ])
        let lifecycle = WorkspaceCheckoutLifecycleOperator(remote: .init { executable, args, timeout in
            try await runner.run(executable: executable, args: args, timeout: timeout)
        })

        await #expect(throws: WorkspaceCheckoutCoordinatorError.cleanupIdentityConflict) {
            try await lifecycle.clearStaleRegistration(Self.sshCleanupPlan())
        }

        let commands = await runner.commands.joined(separator: "\n")
        #expect(commands.contains("alas-worktree-lineage"))
        #expect(commands.contains("lineage"))
        #expect(commands.contains("worktree remove -f -f") == false)
        #expect(commands.contains("worktree prune") == false)
    }

    @Test func concreteRemoteCleanupRecoversInterruptedTombstoneBeforeReturnedWorktreeCheck() async throws {
        let runner = RemoteLifecycleRunner(results: [
            .init(exitCode: 0, stdout: "/checkout/a\n", stderr: ""),
            .init(exitCode: 0, stdout: "", stderr: ""),
            .init(exitCode: 0, stdout: "", stderr: ""),
            .init(exitCode: 0, stdout: "worktree /checkout/a\nprunable gitdir file points to non-existent location\n", stderr: ""),
            .init(exitCode: 0, stdout: "", stderr: ""),
        ])
        let lifecycle = WorkspaceCheckoutLifecycleOperator(remote: .init { executable, args, timeout in
            try await runner.run(executable: executable, args: args, timeout: timeout)
        })

        await #expect(throws: WorkspaceCheckoutCoordinatorError.completedWorktreeReturned) {
            try await lifecycle.clearStaleRegistration(Self.sshCleanupPlan())
        }

        let commands = await runner.commands.joined(separator: "\n")
        #expect(commands.contains(".alas-removing-"))
        #expect(commands.contains("base=${found##*/}"))
        #expect(commands.contains("alas-stale-registration-original-name"))
        #expect(commands.contains("restored_base=${base%%.alas-removing-*}") == false)
        #expect(commands.contains("restored=\"$parent/$restored_base\""))
        #expect(commands.contains("restored=${found%%.alas-removing-*}") == false)
        #expect(commands.contains("alas-stale-registration-tombstone"))
        #expect(commands.contains("[ -s \"$marker\" ] || exit 0"))
        #expect(commands.contains("rm -f -- \"$marker\"; mv") == false)
        #expect(commands.contains("worktree remove -f -f") == false)
    }

    @Test func concreteRemoteExplicitCleanupUnlocksLockedMissingWorktreeRegistration() async throws {
        let runner = RemoteLifecycleRunner(results: [
            .init(exitCode: 0, stdout: "/checkout/a\n", stderr: ""),
            .init(exitCode: 0, stdout: "worktree /checkout/a\nlocked portable volume\nprunable gitdir file points to non-existent location\n", stderr: ""),
            .init(exitCode: 0, stdout: "", stderr: ""),
            .init(exitCode: 0, stdout: "worktree /checkout/a\nlocked portable volume\nprunable gitdir file points to non-existent location\n", stderr: ""),
            .init(exitCode: 1, stdout: "", stderr: ""),
            .init(exitCode: 0, stdout: "", stderr: ""),
            .init(exitCode: 1, stdout: "", stderr: ""),
            .init(exitCode: 0, stdout: "", stderr: ""),
            .init(exitCode: 0, stdout: "", stderr: ""),
        ])
        let lifecycle = WorkspaceCheckoutLifecycleOperator(remote: .init { executable, args, timeout in
            try await runner.run(executable: executable, args: args, timeout: timeout)
        })

        try await lifecycle.clearStaleRegistrationForExplicitDeletion(Self.sshCleanupPlan())

        let commands = await runner.commands.joined(separator: "\n")
        #expect(commands.contains("worktree unlock --") == false)
        #expect(commands.contains("worktree remove -f -f --"))
        #expect(commands.contains("/checkout/a"))
    }

    @Test func concreteRemoteExplicitCleanupValidatesLineageBeforeForcedRemoval() async throws {
        let runner = RemoteLifecycleRunner(results: [
            .init(exitCode: 0, stdout: "/checkout/a\n", stderr: ""),
            .init(exitCode: 0, stdout: "worktree /checkout/a\nprunable gitdir file points to non-existent location\n", stderr: ""),
            .init(exitCode: 0, stdout: "", stderr: ""),
            .init(exitCode: 0, stdout: "worktree /checkout/a\nprunable gitdir file points to non-existent location\n", stderr: ""),
            .init(exitCode: 1, stdout: "", stderr: ""),
            .init(exitCode: 13, stdout: "", stderr: "lineage mismatch"),
        ])
        let lifecycle = WorkspaceCheckoutLifecycleOperator(remote: .init { executable, args, timeout in
            try await runner.run(executable: executable, args: args, timeout: timeout)
        })

        await #expect(throws: WorkspaceCheckoutCoordinatorError.cleanupIdentityConflict) {
            try await lifecycle.clearStaleRegistrationForExplicitDeletion(Self.sshCleanupPlan())
        }

        let commands = await runner.commands.joined(separator: "\n")
        #expect(commands.contains("alas-worktree-lineage"))
        #expect(commands.contains("worktree remove -f -f") == false)
    }

    @Test func concreteRemoteExplicitCleanupRemovesRecoveredPendingTombstoneRegistration() async throws {
        let runner = RemoteLifecycleRunner(results: [
            .init(exitCode: 0, stdout: "/checkout/a\n", stderr: ""),
            .init(exitCode: 0, stdout: "", stderr: ""),
            .init(exitCode: 0, stdout: "", stderr: ""),
            .init(exitCode: 0, stdout: "worktree /checkout/a\nprunable gitdir file points to non-existent location\n", stderr: ""),
            .init(exitCode: 1, stdout: "", stderr: ""),
            .init(exitCode: 0, stdout: "", stderr: ""),
            .init(exitCode: 1, stdout: "", stderr: ""),
            .init(exitCode: 0, stdout: "", stderr: ""),
            .init(exitCode: 0, stdout: "", stderr: ""),
        ])
        let lifecycle = WorkspaceCheckoutLifecycleOperator(remote: .init { executable, args, timeout in
            try await runner.run(executable: executable, args: args, timeout: timeout)
        })

        try await lifecycle.clearStaleRegistrationForExplicitDeletion(Self.sshCleanupPlan())

        let commands = await runner.commands.joined(separator: "\n")
        #expect(commands.contains("alas-stale-worktree-tombstones"))
        #expect(commands.contains("mv \"$found\" \"$restored\""))
        #expect(commands.contains("alas-worktree-lineage"))
        #expect(commands.contains("worktree remove -f -f --"))
    }

    @Test func concreteRemoteExplicitCleanupRestoresReturnedPendingTombstoneBeforePreflight() async throws {
        let runner = RemoteLifecycleRunner(results: [
            .init(exitCode: 0, stdout: "/checkout/a\n", stderr: ""),
            .init(exitCode: 0, stdout: "", stderr: ""),
            .init(exitCode: 0, stdout: "", stderr: ""),
            .init(exitCode: 0, stdout: "worktree /checkout/a\nprunable gitdir file points to non-existent location\n", stderr: ""),
            .init(exitCode: 0, stdout: "", stderr: ""),
        ])
        let lifecycle = WorkspaceCheckoutLifecycleOperator(remote: .init { executable, args, timeout in
            try await runner.run(executable: executable, args: args, timeout: timeout)
        })

        await #expect(throws: WorkspaceCheckoutCoordinatorError.completedWorktreeReturned) {
            try await lifecycle.clearStaleRegistrationForExplicitDeletion(Self.sshCleanupPlan())
        }

        let commands = await runner.commands.joined(separator: "\n")
        #expect(commands.contains("alas-stale-worktree-tombstones"))
        #expect(commands.contains("mv \"$found\" \"$restored\""))
        #expect(commands.contains("worktree remove -f -f") == false)
    }

    @Test func remoteMergedBranchDeletionRechecksWorktreeUsageAfterExpectedTipDeletion() async throws {
        let runner = RemoteLifecycleRunner(results: [
            .init(exitCode: 0, stdout: "abc\n", stderr: ""),
            .init(exitCode: 0, stdout: "", stderr: ""),
            .init(exitCode: 0, stdout: "", stderr: ""),
            .init(exitCode: 0, stdout: "", stderr: ""),
            .init(exitCode: 0, stdout: "", stderr: ""),
        ])
        let lifecycle = WorkspaceCheckoutLifecycleOperator(remote: .init { executable, args, timeout in
            try await runner.run(executable: executable, args: args, timeout: timeout)
        })

        let removed = try await lifecycle.deleteMergedBranch(Self.sshCleanupPlan())

        #expect(removed)
        let commands = await runner.commands.joined(separator: "\n")
        #expect(commands.contains("merge-base --is-ancestor"))
        #expect(commands.contains("worktree list --porcelain"))
        #expect(commands.contains("update-ref -d"))
        #expect(commands.contains("branch -d --") == false)
        #expect(commands.contains("abc"))
    }

    @Test func remoteMergedBranchDeletionRestoresExpectedTipWhenCheckoutAppearsDuringDeletion() async throws {
        let runner = RemoteLifecycleRunner(results: [
            .init(exitCode: 0, stdout: "abc\n", stderr: ""),
            .init(exitCode: 0, stdout: "", stderr: ""),
            .init(exitCode: 0, stdout: "", stderr: ""),
            .init(exitCode: 0, stdout: "", stderr: ""),
            .init(exitCode: 0, stdout: "worktree /other\nbranch refs/heads/feature\n", stderr: ""),
            .init(exitCode: 0, stdout: "sha256\n", stderr: ""),
            .init(exitCode: 0, stdout: "", stderr: ""),
        ])
        let lifecycle = WorkspaceCheckoutLifecycleOperator(remote: .init { executable, args, timeout in
            try await runner.run(executable: executable, args: args, timeout: timeout)
        })

        let removed = try await lifecycle.deleteMergedBranch(Self.sshCleanupPlan())

        #expect(removed == false)
        let commands = await runner.commands.joined(separator: "\n")
        #expect(commands.contains("update-ref -d"))
        #expect(commands.contains("rev-parse --show-object-format"))
        #expect(commands.contains(#"update-ref '\''refs/heads/feature'\'' '\''abc'\'' 0000000000000000000000000000000000000000000000000000000000000000"#))
    }

    @Test func remoteMergedBranchDeletionFailsWhenConcurrentCheckoutCannotBeRestored() async throws {
        let runner = RemoteLifecycleRunner(results: [
            .init(exitCode: 0, stdout: "abc\n", stderr: ""),
            .init(exitCode: 0, stdout: "", stderr: ""),
            .init(exitCode: 0, stdout: "", stderr: ""),
            .init(exitCode: 0, stdout: "", stderr: ""),
            .init(exitCode: 0, stdout: "worktree /other\nbranch refs/heads/feature\n", stderr: ""),
            .init(exitCode: 0, stdout: "sha1\n", stderr: ""),
            .init(exitCode: 1, stdout: "", stderr: "ref locked"),
            .init(exitCode: 1, stdout: "", stderr: "missing"),
        ])
        let lifecycle = WorkspaceCheckoutLifecycleOperator(remote: .init { executable, args, timeout in
            try await runner.run(executable: executable, args: args, timeout: timeout)
        })

        await #expect(throws: WorktreeService.WorktreeError.self) {
            try await lifecycle.deleteMergedBranch(Self.sshCleanupPlan())
        }
    }

    private static func sshCleanupPlan() -> WorkspaceCheckoutCleanupPlan {
        WorkspaceCheckoutCleanupPlan(
            checkoutID: UUID(),
            memberID: UUID(),
            executionLocation: .ssh("example.com"),
            projectID: "project",
            sourceRepositoryPath: "/repo",
            baseReference: "main",
            baseCommit: "abc",
            branchCommit: "abc",
            rootPath: "/checkout",
            managedMemberPaths: ["/checkout/a"],
            worktreePath: "/checkout/a",
            branch: "feature",
            expectedLineageID: "lineage",
            branchOwnership: .created
        )
    }

    private static func localCleanupPlan(repo: String, worktree: String) -> WorkspaceCheckoutCleanupPlan {
        WorkspaceCheckoutCleanupPlan(
            checkoutID: UUID(),
            memberID: UUID(),
            executionLocation: .local,
            projectID: "project",
            sourceRepositoryPath: repo,
            baseReference: "main",
            baseCommit: "abc",
            branchCommit: "abc",
            rootPath: URL(fileURLWithPath: worktree).deletingLastPathComponent().path,
            managedMemberPaths: [worktree],
            worktreePath: worktree,
            branch: URL(fileURLWithPath: worktree).lastPathComponent,
            expectedLineageID: "lineage",
            branchOwnership: .created
        )
    }

    private static func runGit(_ args: [String], cwd: URL) async throws {
        let result = try await Process.git(args, cwd: cwd, usesRemoteHostRegistry: false)
        guard result.exitCode == 0 else {
            throw WorktreeService.WorktreeError.gitFailed(result.stderr)
        }
    }

    private struct SSHScriptSubmoduleFixture {
        let repo: URL
        let submoduleRepo: URL
        let worktree: URL

        func removeFiles() {
            try? FileManager.default.removeItem(at: worktree)
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: submoduleRepo)
        }
    }

    /// Builds a real local repository with an initialized submodule, used to
    /// stand in for a remote host when exercising `sshRemovalScript` for
    /// real via `/bin/sh -c`.
    private static func makeSubmoduleFixture(suffix: String) async throws -> SSHScriptSubmoduleFixture {
        let root = FileManager.default.temporaryDirectory
        let uniqueSuffix = "\(suffix)-\(UUID().uuidString)"

        let repo = root.appendingPathComponent("alas-ssh-script-repo-\(uniqueSuffix)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try await runGit(["init", "-q", "-b", "main"], cwd: repo)
        try await runGit(["config", "user.email", "test@example.com"], cwd: repo)
        try await runGit(["config", "user.name", "Test"], cwd: repo)
        try "root".write(to: repo.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try await runGit(["add", "tracked.txt"], cwd: repo)
        try await runGit(["commit", "-q", "-m", "root init"], cwd: repo)

        let submoduleRepo = root.appendingPathComponent("alas-ssh-script-submodule-\(uniqueSuffix)")
        try FileManager.default.createDirectory(at: submoduleRepo, withIntermediateDirectories: true)
        try await runGit(["init", "-q", "-b", "main"], cwd: submoduleRepo)
        try await runGit(["config", "user.email", "test@example.com"], cwd: submoduleRepo)
        try await runGit(["config", "user.name", "Test"], cwd: submoduleRepo)
        try "initial".write(to: submoduleRepo.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try await runGit(["add", "tracked.txt"], cwd: submoduleRepo)
        try await runGit(["commit", "-q", "-m", "submodule init"], cwd: submoduleRepo)

        try await runGit(
            ["-c", "protocol.file.allow=always", "submodule", "add", "-q", submoduleRepo.path, "sub"],
            cwd: repo
        )
        try await runGit(["commit", "-q", "-am", "add submodule"], cwd: repo)

        let worktree = root.appendingPathComponent("alas-ssh-script-worktree-\(uniqueSuffix)")
        try await runGit(["worktree", "add", "-q", worktree.path, "-b", "feature-\(uniqueSuffix)"], cwd: repo)
        try await runGit(
            ["-c", "protocol.file.allow=always", "submodule", "update", "--init", "-q"],
            cwd: worktree
        )

        return SSHScriptSubmoduleFixture(repo: repo, submoduleRepo: submoduleRepo, worktree: worktree)
    }

    private static func registeredAdminDirectory(repo: URL, worktree: URL) async throws -> URL {
        let result = try await Process.git(["rev-parse", "--absolute-git-dir"], cwd: worktree, usesRemoteHostRegistry: false)
        guard result.exitCode == 0 else {
            throw WorktreeService.WorktreeError.gitFailed(result.stderr)
        }
        return URL(fileURLWithPath: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func tombstoneAdminDirectories(repo: URL) throws -> [URL] {
        let tombstonesDir = repo.appendingPathComponent(".git/alas-stale-worktree-tombstones")
        let entries = (try? FileManager.default.contentsOfDirectory(at: tombstonesDir, includingPropertiesForKeys: nil)) ?? []
        return entries.filter {
            $0.lastPathComponent.contains(".alas-removing-")
                && FileManager.default.fileExists(atPath: $0.appendingPathComponent("alas-stale-registration-tombstone").path)
        }
    }

    private static func porcelainOutput(_ output: String, containsWorktree path: String) -> Bool {
        output.split(separator: "\n").contains("worktree \(path)")
    }

    @Test func concreteLifecycleRefusesToDeleteAReplacedOwnedBranch() async throws {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-cleanup-branch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: repo) }
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "base"], cwd: repo)
        let original = try await Process.git(["rev-parse", "HEAD"], cwd: repo)
        let originalCommit = original.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await Process.git(["branch", "feature/workspace", originalCommit], cwd: repo)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "replacement"], cwd: repo)
        let replacement = try await Process.git(["rev-parse", "HEAD"], cwd: repo)
        let replacementCommit = replacement.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await Process.git(["branch", "-f", "feature/workspace", replacementCommit], cwd: repo)
        let plan = WorkspaceCheckoutCleanupPlan(
            checkoutID: UUID(),
            memberID: UUID(),
            executionLocation: .local,
            projectID: "project",
            sourceRepositoryPath: repo.path,
            baseReference: "main",
            baseCommit: originalCommit,
            branchCommit: originalCommit,
            rootPath: repo.deletingLastPathComponent().path,
            managedMemberPaths: [],
            worktreePath: repo.path,
            branch: "feature/workspace",
            expectedLineageID: "lineage",
            branchOwnership: .created
        )

        let removed = try await WorkspaceCheckoutLifecycleOperator().deleteMergedBranch(plan)

        #expect(removed == false)
        let current = try await Process.git(["rev-parse", "feature/workspace"], cwd: repo)
        #expect(current.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == replacementCommit)
    }

    @Test func concreteLifecycleRetainsAMergedBranchCheckedOutByAnotherWorktree() async throws {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-cleanup-checked-out-\(UUID().uuidString)")
        let independent = repo.deletingLastPathComponent().appendingPathComponent("workspace-independent-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: independent)
        }
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "base"], cwd: repo)
        let base = try await Process.git(["rev-parse", "HEAD"], cwd: repo)
        let commit = base.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await Process.git(["branch", "feature/workspace", commit], cwd: repo)
        _ = try await Process.git(["worktree", "add", "-q", independent.path, "feature/workspace"], cwd: repo)
        let plan = WorkspaceCheckoutCleanupPlan(
            checkoutID: UUID(), memberID: UUID(), executionLocation: .local, projectID: "project",
            sourceRepositoryPath: repo.path, baseReference: "main", baseCommit: commit, branchCommit: commit,
            rootPath: repo.deletingLastPathComponent().path, managedMemberPaths: [], worktreePath: repo.path,
            branch: "feature/workspace", expectedLineageID: "lineage", branchOwnership: .created
        )

        let removed = try await WorkspaceCheckoutLifecycleOperator().deleteMergedBranch(plan)

        #expect(removed == false)
        let head = try await Process.git(["rev-parse", "--verify", "HEAD"], cwd: independent)
        #expect(head.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == commit)
    }

    @Test func localRootInspectionIgnoresTheManagedCheckoutManifest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-cleanup-root-\(UUID().uuidString)")
        let member = root.appendingPathComponent("a")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: member, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent(WorkspaceCheckoutManifest.fileName))
        try Data().write(to: root.appendingPathComponent("notes.txt"))
        let plan = WorkspaceCheckoutCleanupPlan(
            checkoutID: UUID(),
            memberID: UUID(),
            executionLocation: .local,
            projectID: "project",
            sourceRepositoryPath: "/repo",
            baseReference: "main",
            baseCommit: "abc",
            rootPath: root.path,
            managedMemberPaths: [member.path],
            worktreePath: member.path,
            branch: "feature",
            expectedLineageID: "lineage",
            branchOwnership: .created
        )

        let inspection = await WorkspaceCheckoutLifecycleOperator().inspectRoot(plan)

        #expect(inspection.isContained)
        #expect(inspection.leftovers == ["notes.txt"])
    }

    @Test func localRootInspectionTreatsANonRegularFileNamedFinderMetadataAsARealLeftover() async throws {
        // A FIFO, socket, or device node sharing Finder's metadata filename
        // is not disposable metadata either — "not a directory" is not the
        // same contract as "is a regular file".
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-cleanup-root-\(UUID().uuidString)")
        let member = root.appendingPathComponent("a")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: member, withIntermediateDirectories: true)
        let fifoPath = root.appendingPathComponent(".DS_Store").path
        let mkfifoResult = try await Process.run("/usr/bin/mkfifo", args: [fifoPath])
        #expect(mkfifoResult.exitCode == 0)
        let plan = WorkspaceCheckoutCleanupPlan(
            checkoutID: UUID(),
            memberID: UUID(),
            executionLocation: .local,
            projectID: "project",
            sourceRepositoryPath: "/repo",
            baseReference: "main",
            baseCommit: "abc",
            rootPath: root.path,
            managedMemberPaths: [member.path],
            worktreePath: member.path,
            branch: "feature",
            expectedLineageID: "lineage",
            branchOwnership: .created
        )

        let inspection = await WorkspaceCheckoutLifecycleOperator().inspectRoot(plan)

        #expect(inspection.leftovers == [".DS_Store"])
    }

    @Test func localRootInspectionTreatsADirectoryNamedFinderMetadataAsARealLeftover() async throws {
        // A directory happening to share Finder's metadata filename (a
        // copied folder, a deliberate rename) is not disposable metadata —
        // matching by name alone would hide real user files from the
        // leftover list that gates the forget confirmation.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-cleanup-root-\(UUID().uuidString)")
        let member = root.appendingPathComponent("a")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: member, withIntermediateDirectories: true)
        let metadataDirectory = root.appendingPathComponent(".DS_Store")
        try FileManager.default.createDirectory(at: metadataDirectory, withIntermediateDirectories: true)
        try Data("real data".utf8).write(to: metadataDirectory.appendingPathComponent("important.txt"))
        let plan = WorkspaceCheckoutCleanupPlan(
            checkoutID: UUID(),
            memberID: UUID(),
            executionLocation: .local,
            projectID: "project",
            sourceRepositoryPath: "/repo",
            baseReference: "main",
            baseCommit: "abc",
            rootPath: root.path,
            managedMemberPaths: [member.path],
            worktreePath: member.path,
            branch: "feature",
            expectedLineageID: "lineage",
            branchOwnership: .created
        )

        let inspection = await WorkspaceCheckoutLifecycleOperator().inspectRoot(plan)

        #expect(inspection.leftovers == [".DS_Store"])
    }

    @Test func localRootCleanupNeverRecursivelyDeletesADirectoryNamedFinderMetadata() async throws {
        let checkoutID = UUID()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-cleanup-root-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let metadataDirectory = root.appendingPathComponent(".DS_Store")
        try FileManager.default.createDirectory(at: metadataDirectory, withIntermediateDirectories: true)
        let importantFile = metadataDirectory.appendingPathComponent("important.txt")
        try Data("real data".utf8).write(to: importantFile)
        let checkout = WorkspaceCheckout(
            id: checkoutID,
            workspaceID: nil,
            fallbackWorkspaceName: "Release",
            executionLocation: .local,
            branch: "feature",
            rootPath: root.path,
            members: []
        )

        try await WorkspaceCheckoutLifecycleOperator().removeCheckoutRootArtifacts(for: checkout)

        #expect(FileManager.default.fileExists(atPath: root.path))
        #expect(FileManager.default.fileExists(atPath: importantFile.path))
    }

    @Test func localRootInspectionIgnoresFinderMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-cleanup-root-\(UUID().uuidString)")
        let member = root.appendingPathComponent("a")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: member, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent(".DS_Store"))
        try Data().write(to: root.appendingPathComponent("notes.txt"))
        let plan = WorkspaceCheckoutCleanupPlan(
            checkoutID: UUID(),
            memberID: UUID(),
            executionLocation: .local,
            projectID: "project",
            sourceRepositoryPath: "/repo",
            baseReference: "main",
            baseCommit: "abc",
            rootPath: root.path,
            managedMemberPaths: [member.path],
            worktreePath: member.path,
            branch: "feature",
            expectedLineageID: "lineage",
            branchOwnership: .created
        )

        let inspection = await WorkspaceCheckoutLifecycleOperator().inspectRoot(plan)

        #expect(inspection.leftovers == ["notes.txt"])
    }

    @Test func remoteRootInspectionOnlySkipsFinderMetadataThatIsARegularFile() async throws {
        let runner = RemoteLifecycleRunner(results: [.init(exitCode: 0, stdout: "", stderr: "")])
        let lifecycle = WorkspaceCheckoutLifecycleOperator(remote: .init { executable, args, timeout in
            try await runner.run(executable: executable, args: args, timeout: timeout)
        })
        let plan = WorkspaceCheckoutCleanupPlan(
            checkoutID: UUID(),
            memberID: UUID(),
            executionLocation: .ssh("example.com"),
            projectID: "project",
            sourceRepositoryPath: "/repo",
            baseReference: "main",
            baseCommit: "abc",
            rootPath: "/checkout",
            managedMemberPaths: ["/checkout/a"],
            worktreePath: "/checkout/a",
            branch: "feature",
            expectedLineageID: "lineage",
            branchOwnership: .created
        )

        _ = await lifecycle.inspectRoot(plan)

        let command = await runner.commands.joined(separator: "\n")
        #expect(command.contains("[ -f \"$p\" ]"))
        // `test -f` follows symlinks, so a symlink to a regular file
        // elsewhere must be excluded separately or it would also pass.
        #expect(command.contains("[ ! -L \"$p\" ]"))
    }

    @Test func remoteRootCleanupOnlySkipsFinderMetadataThatIsARegularFile() async throws {
        let runner = RemoteLifecycleRunner(results: [.init(exitCode: 0, stdout: "", stderr: "")])
        let lifecycle = WorkspaceCheckoutLifecycleOperator(remote: .init { executable, args, timeout in
            try await runner.run(executable: executable, args: args, timeout: timeout)
        })
        let checkout = WorkspaceCheckout(
            workspaceID: nil,
            fallbackWorkspaceName: "Release",
            executionLocation: .ssh("example.com"),
            branch: "feature",
            rootPath: "/checkout",
            members: []
        )

        try await lifecycle.removeCheckoutRootArtifacts(for: checkout)

        let command = await runner.commands.joined(separator: "\n")
        #expect(command.contains("[ -f \"$p\" ]"))
        #expect(command.contains("[ ! -L \"$p\" ]"))
    }

    @Test func remoteRootInspectionIgnoresFinderMetadata() async throws {
        // The script itself now decides what counts as disposable Finder
        // metadata (it alone can check the remote entry's type), so a
        // regular-file `.DS_Store` never appears in what it prints — this
        // models that server-side behavior rather than re-filtering client-side.
        let runner = RemoteLifecycleRunner(results: [
            .init(exitCode: 0, stdout: "notes.txt\n", stderr: ""),
        ])
        let lifecycle = WorkspaceCheckoutLifecycleOperator(remote: .init { executable, args, timeout in
            try await runner.run(executable: executable, args: args, timeout: timeout)
        })
        let plan = WorkspaceCheckoutCleanupPlan(
            checkoutID: UUID(),
            memberID: UUID(),
            executionLocation: .ssh("example.com"),
            projectID: "project",
            sourceRepositoryPath: "/repo",
            baseReference: "main",
            baseCommit: "abc",
            rootPath: "/checkout",
            managedMemberPaths: ["/checkout/a"],
            worktreePath: "/checkout/a",
            branch: "feature",
            expectedLineageID: "lineage",
            branchOwnership: .created
        )

        let root = await lifecycle.inspectRoot(plan)

        #expect(root.leftovers == ["notes.txt"])
    }

    @Test func localRootCleanupRemovesFinderMetadataAlongWithTheEmptyRoot() async throws {
        let checkoutID = UUID()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-cleanup-root-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest = WorkspaceCheckoutManifest(checkoutID: checkoutID, rootPath: root.path, branch: "feature", members: [])
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent(WorkspaceCheckoutManifest.fileName))
        try Data().write(to: root.appendingPathComponent(".DS_Store"))
        let checkout = WorkspaceCheckout(
            id: checkoutID,
            workspaceID: nil,
            fallbackWorkspaceName: "Release",
            executionLocation: .local,
            branch: "feature",
            rootPath: root.path,
            members: []
        )

        try await WorkspaceCheckoutLifecycleOperator().removeCheckoutRootArtifacts(for: checkout)

        #expect(FileManager.default.fileExists(atPath: root.path) == false)
    }

    @Test func localRootCleanupKeepsARootThatStillHoldsUserFiles() async throws {
        let checkoutID = UUID()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-cleanup-root-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent(".DS_Store"))
        try Data().write(to: root.appendingPathComponent("notes.txt"))
        let checkout = WorkspaceCheckout(
            id: checkoutID,
            workspaceID: nil,
            fallbackWorkspaceName: "Release",
            executionLocation: .local,
            branch: "feature",
            rootPath: root.path,
            members: []
        )

        try await WorkspaceCheckoutLifecycleOperator().removeCheckoutRootArtifacts(for: checkout)

        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("notes.txt").path))
    }

    @Test func remoteRootCleanupRemovesFinderMetadataBeforeRemovingTheRoot() async throws {
        let runner = RemoteLifecycleRunner(results: [.init(exitCode: 0, stdout: "", stderr: "")])
        let lifecycle = WorkspaceCheckoutLifecycleOperator(remote: .init { executable, args, timeout in
            try await runner.run(executable: executable, args: args, timeout: timeout)
        })
        let checkout = WorkspaceCheckout(
            workspaceID: nil,
            fallbackWorkspaceName: "Release",
            executionLocation: .ssh("example.com"),
            branch: "feature",
            rootPath: "/checkout",
            members: []
        )

        try await lifecycle.removeCheckoutRootArtifacts(for: checkout)

        let command = await runner.commands.joined(separator: "\n")
        #expect(command.contains("rm -f") && command.contains(".DS_Store"))
        #expect(command.contains("rmdir"))
    }

    @Test func localRootCleanupRemovesOwnedManifestAndEmptyRoot() async throws {
        let checkoutID = UUID()
        let memberID = UUID()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-cleanup-root-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest = WorkspaceCheckoutManifest(
            checkoutID: checkoutID,
            rootPath: root.path,
            branch: "feature",
            members: [
                .init(
                    id: memberID,
                    projectID: "project",
                    path: root.appendingPathComponent("a").path,
                    availability: .explicitlyDeleted
                )
            ]
        )
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent(WorkspaceCheckoutManifest.fileName))
        let checkout = WorkspaceCheckout(
            id: checkoutID,
            workspaceID: nil,
            fallbackWorkspaceName: "Release",
            executionLocation: .local,
            branch: "feature",
            rootPath: root.path,
            members: []
        )

        try await WorkspaceCheckoutLifecycleOperator().removeCheckoutRootArtifacts(for: checkout)

        #expect(FileManager.default.fileExists(atPath: root.path) == false)
    }

    @Test func localRootCleanupRejectsCopiedManifestWithDifferentRoot() async throws {
        let checkoutID = UUID()
        let originalRoot = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-cleanup-original-\(UUID().uuidString)")
        let copiedRoot = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-cleanup-copy-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: originalRoot)
            try? FileManager.default.removeItem(at: copiedRoot)
        }
        try FileManager.default.createDirectory(at: originalRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: copiedRoot, withIntermediateDirectories: true)
        let manifest = WorkspaceCheckoutManifest(
            checkoutID: checkoutID,
            rootPath: originalRoot.path,
            branch: "feature",
            members: []
        )
        try JSONEncoder().encode(manifest).write(to: copiedRoot.appendingPathComponent(WorkspaceCheckoutManifest.fileName))
        let checkout = WorkspaceCheckout(
            id: checkoutID,
            workspaceID: nil,
            fallbackWorkspaceName: "Release",
            executionLocation: .local,
            branch: "feature",
            rootPath: copiedRoot.path,
            members: []
        )

        await #expect(throws: WorkspaceCheckoutCoordinatorError.cleanupIdentityConflict) {
            try await WorkspaceCheckoutLifecycleOperator().removeCheckoutRootArtifacts(for: checkout)
        }

        #expect(FileManager.default.fileExists(atPath: copiedRoot.appendingPathComponent(WorkspaceCheckoutManifest.fileName).path))
    }

    private struct Fixture {
        let store: WorkspaceStore
        let checkout: WorkspaceCheckout
        let member: WorkspaceCheckoutMember

        static func make(operation: WorkspaceCheckoutOperation = .idle, branchOwnership: WorkspaceBranchOwnership = .created, memberCount: Int = 1) async throws -> Fixture {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-lifecycle-\(UUID().uuidString).json")
            let store = WorkspaceStore(url: url)
            let memberID = UUID()
            let member = WorkspaceCheckoutMember(
                id: memberID, workspaceMemberID: UUID(), projectID: "a", fallbackProjectName: "A", fallbackRepositoryRoot: "/repo/a",
                worktreePath: "/checkout/a", gitLineageID: "lineage-a", availability: .available, checkpoint: .setupComplete,
                cleanupOwnership: .init(worktreeCreated: true, branchOwnership: branchOwnership),
                plan: .init(checkoutMemberID: memberID, projectID: "a", sourceRepositoryPath: "/repo/a", destinationPath: "/checkout/a", baseReference: "main", baseCommit: "abc", branchIntent: .create(atCommit: "abc"))
            )
            let members = [member] + (1 ..< memberCount).map { index in
                WorkspaceCheckoutMember(id: UUID(), workspaceMemberID: UUID(), projectID: "a-\(index)", fallbackProjectName: "A \(index)", fallbackRepositoryRoot: "/repo/a-\(index)", worktreePath: "/checkout/a-\(index)", gitLineageID: "lineage-a-\(index)", availability: .available, checkpoint: .setupComplete, cleanupOwnership: .init(worktreeCreated: true, branchOwnership: branchOwnership), plan: .init(checkoutMemberID: UUID(), projectID: "a-\(index)", sourceRepositoryPath: "/repo/a-\(index)", destinationPath: "/checkout/a-\(index)", baseReference: "main", baseCommit: "abc", branchIntent: .create(atCommit: "abc")))
            }
            let normalized = members.map { member -> WorkspaceCheckoutMember in var copy = member
            if copy.plan?.checkoutMemberID != copy.id { copy.plan?.checkoutMemberID = copy.id }
            return copy }
            let checkout = WorkspaceCheckout(workspaceID: UUID(), fallbackWorkspaceName: "Release", executionLocation: .local, branch: "feature", rootPath: "/checkout", operation: operation, members: normalized)
            try await store.checkpoint(.init(checkouts: [checkout]))
            return .init(store: store, checkout: checkout, member: member)
        }
    }
}

private actor FixtureGit: WorkspaceGitOperating {
    var existingCreatedLineageID: String? = nil
    var existingCreatedIgnoringHeadLineageID: String? = nil
    var recoveredCreatedLineageID: String? = nil
    var preparedBranchMatches = false
    var frozenWorktreeMissingResults: [Bool] = []

    init(
        existingCreatedLineageID: String? = nil,
        existingCreatedIgnoringHeadLineageID: String? = nil,
        recoveredCreatedLineageID: String? = nil,
        preparedBranchMatches: Bool = false,
        frozenWorktreeMissingResults: [Bool] = []
    ) {
        self.existingCreatedLineageID = existingCreatedLineageID
        self.existingCreatedIgnoringHeadLineageID = existingCreatedIgnoringHeadLineageID
        self.recoveredCreatedLineageID = recoveredCreatedLineageID
        self.preparedBranchMatches = preparedBranchMatches
        self.frozenWorktreeMissingResults = frozenWorktreeMissingResults
    }

    func prepareBranch(_ operation: WorkspaceFrozenWorktreeOperation) async throws {}
    func preparedBranchMatchesFrozenBase(_ operation: WorkspaceFrozenWorktreeOperation) async throws -> Bool {
        preparedBranchMatches
    }
    func createWorktree(_ operation: WorkspaceFrozenWorktreeOperation) async throws -> String? { nil }
    func existingCreatedWorktreeLineage(_ operation: WorkspaceFrozenWorktreeOperation) async throws -> String? {
        existingCreatedLineageID
    }
    func existingCreatedWorktreeLineageIgnoringHead(_ operation: WorkspaceFrozenWorktreeOperation) async throws -> String? {
        existingCreatedIgnoringHeadLineageID
    }
    func recoverCreatedWorktreeLineage(_ operation: WorkspaceFrozenWorktreeOperation) async throws -> String? {
        recoveredCreatedLineageID
    }
    func frozenWorktreeIsMissing(_ operation: WorkspaceFrozenWorktreeOperation) async throws -> Bool {
        if frozenWorktreeMissingResults.isEmpty {
            return existingCreatedLineageID == nil
        }
        return frozenWorktreeMissingResults.removeFirst()
    }
}
private struct FixtureScripts: WorkspaceScriptRunning { func runSetup(for operation: WorkspaceCheckoutSetupOperation) async throws {} }
private actor LifecycleSessions: WorkspaceCheckoutSessionStopping {
    private(set) var stopped: [UUID] = []
    func stopSessions(for checkoutID: UUID) async throws { stopped.append(checkoutID) }
}
private struct FailingLifecycleSessions: WorkspaceCheckoutSessionStopping {
    func stopSessions(for checkoutID: UUID) async throws { throw TestLifecycleError.failed }
}
private actor FixtureLifecycle: WorkspaceCheckoutLifecycleOperating {
    let verification: WorkspaceCheckoutMemberObservation
    private(set) var removedMembers: [UUID] = []
    private(set) var deletedBranches: [UUID] = []
    private(set) var recoveredRegistrations: [UUID] = []
    private(set) var clearedRegistrations: [UUID] = []
    private(set) var finalizedRegistrations: [UUID] = []
    private(set) var removeForces: [(force: Bool, forceTwice: Bool)] = []
    private(set) var removedRootArtifacts: [UUID] = []
    let preflight: WorktreeDeletePreflight
    let leftovers: [String]
    let failingMember: UUID?
    let branchRemoved: Bool
    let clearError: (any Error)?
    let pendingStaleRegistrationCleanup: Bool
    init(verification: WorkspaceCheckoutMemberObservation = .exactLineage("lineage-a"), preflight: WorktreeDeletePreflight = .init(reasons: []), leftovers: [String] = [], failingMember: UUID? = nil, branchRemoved: Bool = true, clearError: (any Error)? = nil, hasPendingStaleRegistrationCleanup: Bool = true) { self.verification = verification
    self.preflight = preflight
    self.leftovers = leftovers
    self.failingMember = failingMember
    self.branchRemoved = branchRemoved
    self.clearError = clearError
    self.pendingStaleRegistrationCleanup = hasPendingStaleRegistrationCleanup }
    func deletePreflight(_ plan: WorkspaceCheckoutCleanupPlan) async throws -> WorktreeDeletePreflight { preflight }
    func inspectRoot(_ plan: WorkspaceCheckoutCleanupPlan) async -> WorkspaceCheckoutCleanupRootObservation { .init(isContained: true, leftovers: leftovers) }
    func verifyCleanup(_ plan: WorkspaceCheckoutCleanupPlan) async -> WorkspaceCheckoutMemberObservation {
        if verification == .exactLineage("lineage-a") { return .exactLineage(plan.expectedLineageID) }
        return verification
    }
    func recoverStaleRegistrationCleanup(_ plan: WorkspaceCheckoutCleanupPlan) async throws {
        recoveredRegistrations.append(plan.memberID)
    }
    func hasPendingStaleRegistrationCleanup(_ plan: WorkspaceCheckoutCleanupPlan) async throws -> Bool {
        pendingStaleRegistrationCleanup
    }
    func clearStaleRegistration(_ plan: WorkspaceCheckoutCleanupPlan) async throws {
        clearedRegistrations.append(plan.memberID)
        if let clearError { throw clearError }
    }
    func finalizeStaleRegistrationCleanup(_ plan: WorkspaceCheckoutCleanupPlan) async throws {
        finalizedRegistrations.append(plan.memberID)
    }
    func removeWorktree(_ plan: WorkspaceCheckoutCleanupPlan, force: Bool, forceTwice: Bool) async throws { if failingMember == plan.memberID { throw TestLifecycleError.failed }
    removeForces.append((force, forceTwice))
    removedMembers.append(plan.memberID) }
    func removeCheckoutRootArtifacts(for checkout: WorkspaceCheckout) async throws { removedRootArtifacts.append(checkout.id) }
    func deleteMergedBranch(_ plan: WorkspaceCheckoutCleanupPlan) async throws -> Bool { deletedBranches.append(plan.memberID)
    return branchRemoved }
}

private actor StoreInspectingLifecycle: WorkspaceCheckoutLifecycleOperating {
    let store: WorkspaceStore
    let checkoutID: UUID
    private(set) var operationsDuringRemoval: [WorkspaceCheckoutOperation] = []

    init(store: WorkspaceStore, checkoutID: UUID) {
        self.store = store
        self.checkoutID = checkoutID
    }

    func deletePreflight(_ plan: WorkspaceCheckoutCleanupPlan) async throws -> WorktreeDeletePreflight {
        .init(reasons: [])
    }

    func inspectRoot(_ plan: WorkspaceCheckoutCleanupPlan) async -> WorkspaceCheckoutCleanupRootObservation {
        .init(isContained: true, leftovers: [])
    }

    func verifyCleanup(_ plan: WorkspaceCheckoutCleanupPlan) async -> WorkspaceCheckoutMemberObservation {
        .exactLineage(plan.expectedLineageID)
    }

    func removeWorktree(_ plan: WorkspaceCheckoutCleanupPlan, force: Bool, forceTwice: Bool) async throws {
        if let checkout = await store.checkout(id: checkoutID) {
            operationsDuringRemoval.append(checkout.operation)
        }
    }

    func removeCheckoutRootArtifacts(for checkout: WorkspaceCheckout) async throws {}

    func deleteMergedBranch(_ plan: WorkspaceCheckoutCleanupPlan) async throws -> Bool {
        true
    }
}
private actor PersistedCleanupLifecycle: WorkspaceCheckoutLifecycleOperating {
    let store: WorkspaceStore
    let checkoutID: UUID
    private(set) var sawPersistedCleanupPlan = false
    init(store: WorkspaceStore, checkoutID: UUID) { self.store = store
    self.checkoutID = checkoutID }
    func deletePreflight(_ plan: WorkspaceCheckoutCleanupPlan) async throws -> WorktreeDeletePreflight { .init(reasons: []) }
    func inspectRoot(_ plan: WorkspaceCheckoutCleanupPlan) async -> WorkspaceCheckoutCleanupRootObservation { .init(isContained: true, leftovers: []) }
    func verifyCleanup(_ plan: WorkspaceCheckoutCleanupPlan) async -> WorkspaceCheckoutMemberObservation { .exactLineage("lineage-a") }
    func removeWorktree(_ plan: WorkspaceCheckoutCleanupPlan, force: Bool, forceTwice: Bool) async throws {
        guard case .loaded(let state) = await store.load(),
              state.checkouts.first(where: { $0.id == checkoutID })?.members.first?.cleanup?.plan == plan else { return }
        sawPersistedCleanupPlan = true
    }
    func removeCheckoutRootArtifacts(for checkout: WorkspaceCheckout) async throws {}
    func deleteMergedBranch(_ plan: WorkspaceCheckoutCleanupPlan) async throws -> Bool { true }
}
private enum TestLifecycleError: Error { case failed }

private actor BlockingLifecycle: WorkspaceCheckoutLifecycleOperating {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func deletePreflight(_ plan: WorkspaceCheckoutCleanupPlan) async throws -> WorktreeDeletePreflight {
        .init(reasons: [])
    }

    func inspectRoot(_ plan: WorkspaceCheckoutCleanupPlan) async -> WorkspaceCheckoutCleanupRootObservation {
        .init(isContained: true, leftovers: [])
    }

    func verifyCleanup(_ plan: WorkspaceCheckoutCleanupPlan) async -> WorkspaceCheckoutMemberObservation {
        .exactLineage(plan.expectedLineageID)
    }

    func removeWorktree(_ plan: WorkspaceCheckoutCleanupPlan, force: Bool, forceTwice: Bool) async throws {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        if !released {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
    }

    func removeCheckoutRootArtifacts(for checkout: WorkspaceCheckout) async throws {}

    func deleteMergedBranch(_ plan: WorkspaceCheckoutCleanupPlan) async throws -> Bool { true }

    func waitUntilRemoving() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private actor RemoteLifecycleRunner {
    private var results: [ProcessResult]
    private(set) var commands: [String] = []

    init(results: [ProcessResult]) {
        self.results = results
    }

    func run(executable: String, args: [String], timeout: TimeInterval) async throws -> ProcessResult {
        commands.append(args.joined(separator: " "))
        return results.isEmpty ? .init(exitCode: 0, stdout: "", stderr: "") : results.removeFirst()
    }
}
