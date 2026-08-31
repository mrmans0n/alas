import Foundation
import Testing
@testable import Alas

@Suite("Workspace checkout repair")
struct WorkspaceCheckoutRepairTests {
    @Test func reconciliationOnlyReportsAVerifiedFrozenWorktree() async throws {
        let fixture = try await persistedFixture(checkpoint: .branchPrepared, lineageID: "lineage-a")
        let observer = RepairObserver(result: .exactLineage("lineage-a"))
        let reconciler = WorkspaceCheckoutReconciler(store: fixture.store, observer: observer)
        let before = await fixture.store.load().loadedCheckout(id: fixture.checkout.id)

        let report = try await reconciler.reconcile(checkoutID: fixture.checkout.id)

        #expect(report.observations[fixture.checkout.members[0].id] == .exactLineage("lineage-a"))
        #expect(await fixture.store.load().loadedCheckout(id: fixture.checkout.id) == before)
        #expect(await observer.observationCount == 1)
    }

    @Test func reconciliationDoesNotAdoptAnIdentityConflict() async throws {
        let fixture = try await persistedFixture(checkpoint: .branchPrepared)
        let reconciler = WorkspaceCheckoutReconciler(
            store: fixture.store,
            observer: RepairObserver(result: .identityConflict("other-lineage"))
        )
        let before = await fixture.store.load().loadedCheckout(id: fixture.checkout.id)

        let report = try await reconciler.reconcile(checkoutID: fixture.checkout.id)

        #expect(report.observations[fixture.checkout.members[0].id] == .identityConflict("other-lineage"))
        #expect(await fixture.store.load().loadedCheckout(id: fixture.checkout.id) == before)
    }

    @Test func sshConnectionFailureIsUnavailableNotMissing() async throws {
        let memberID = UUID()
        let member = WorkspaceCheckoutMember(
            id: memberID,
            workspaceMemberID: UUID(),
            projectID: "project-a",
            fallbackProjectName: "A",
            fallbackRepositoryRoot: "/repos/a",
            worktreePath: "/remote/checkouts/a",
            gitLineageID: "lineage-a",
            availability: .available,
            checkpoint: .setupComplete,
            cleanupOwnership: .init(worktreeCreated: true, branchOwnership: .created),
            plan: .init(
                checkoutMemberID: memberID,
                projectID: "project-a",
                sourceRepositoryPath: "/remote/repos/a",
                destinationPath: "/remote/checkouts/a",
                baseReference: "main",
                baseCommit: "abc",
                branchIntent: .create(atCommit: "abc")
            )
        )
        let checkout = WorkspaceCheckout(workspaceID: UUID(), fallbackWorkspaceName: "Release", executionLocation: .ssh("ssh-host"), branch: "feature", rootPath: "/remote/checkouts", members: [member])
        let observer = WorkspaceCheckoutObserver(remote: .init { _, _, _ in
            ProcessResult(exitCode: 255, stdout: "", stderr: "ssh: connect failed")
        })

        let observation = await observer.observe(member, in: checkout)

        guard case .unavailable = observation else {
            Issue.record("Expected SSH connection failures to stay unavailable, got \(observation)")
            return
        }
    }

    @Test func sshAbsentDestinationIsMissingButUnmarkedExistingDestinationIsConflict() async throws {
        let memberID = UUID()
        let member = WorkspaceCheckoutMember(
            id: memberID,
            workspaceMemberID: UUID(),
            projectID: "project-a",
            fallbackProjectName: "A",
            fallbackRepositoryRoot: "/repos/a",
            worktreePath: "/remote/checkouts/a",
            gitLineageID: "lineage-a",
            availability: .available,
            checkpoint: .setupComplete,
            cleanupOwnership: .init(worktreeCreated: true, branchOwnership: .created),
            plan: .init(
                checkoutMemberID: memberID,
                projectID: "project-a",
                sourceRepositoryPath: "/remote/repos/a",
                destinationPath: "/remote/checkouts/a",
                baseReference: "main",
                baseCommit: "abc",
                branchIntent: .create(atCommit: "abc")
            )
        )
        let checkout = WorkspaceCheckout(workspaceID: UUID(), fallbackWorkspaceName: "Release", executionLocation: .ssh("ssh-host"), branch: "feature", rootPath: "/remote/checkouts", members: [member])

        let absent = WorkspaceCheckoutObserver(remote: .init { _, _, _ in
            ProcessResult(exitCode: 2, stdout: "", stderr: "")
        })
        let unmarked = WorkspaceCheckoutObserver(remote: .init { _, _, _ in
            ProcessResult(exitCode: 4, stdout: "", stderr: "")
        })

        #expect(await absent.observe(member, in: checkout) == .missing)
        #expect(await unmarked.observe(member, in: checkout) == .identityConflict(nil))
    }

    @Test func localDanglingSymlinkDestinationIsIdentityConflictNotMissing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-dangling-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("member")
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: root.appendingPathComponent("missing-target"))
        defer { try? FileManager.default.removeItem(at: root) }
        let memberID = UUID()
        let member = WorkspaceCheckoutMember(
            id: memberID,
            workspaceMemberID: UUID(),
            projectID: "project-a",
            fallbackProjectName: "A",
            fallbackRepositoryRoot: "/repos/a",
            worktreePath: destination.path,
            gitLineageID: "lineage-a",
            availability: .available,
            checkpoint: .setupComplete,
            cleanupOwnership: .init(worktreeCreated: true, branchOwnership: .created),
            plan: .init(
                checkoutMemberID: memberID,
                projectID: "project-a",
                sourceRepositoryPath: "/repos/a",
                destinationPath: destination.path,
                baseReference: "main",
                baseCommit: "abc",
                branchIntent: .create(atCommit: "abc")
            )
        )
        let checkout = WorkspaceCheckout(workspaceID: UUID(), fallbackWorkspaceName: "Release", executionLocation: .local, branch: "feature", rootPath: root.path, members: [member])

        #expect(await WorkspaceCheckoutObserver().observe(member, in: checkout) == .identityConflict(nil))
    }

    @Test func retrySetupUsesTheFrozenWorktreeAndNeverRepeatsASuccess() async throws {
        let fixture = try await persistedFixture(checkpoint: .worktreeCreated, worktreeCreated: true, lineageID: "lineage-a")
        let scripts = RepairScriptRunner()
        let lifecycle = RepairLifecycle(result: .exactLineage("lineage-a"))
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: RepairGit(), scripts: scripts, projectMutationGate: ProjectMutationGate(), lifecycle: lifecycle)

        _ = try await coordinator.retrySetup(checkoutID: fixture.checkout.id, memberID: fixture.checkout.members[0].id)
        _ = try await coordinator.retrySetup(checkoutID: fixture.checkout.id, memberID: fixture.checkout.members[0].id)

        #expect(await scripts.paths == ["/checkouts/a"])
        #expect(await fixture.store.load().loadedCheckout(id: fixture.checkout.id)?.members[0].checkpoint == .setupComplete)
    }

    @Test func retrySetupDoesNotRunInheritedGlobalSetupTwice() async throws {
        let fixture = try await persistedFixture(checkpoint: .worktreeCreated, worktreeCreated: true, lineageID: "lineage-a")
        let member = fixture.checkout.members[0]
        try await fixture.store.mutate { state in
            state.checkouts[0].configurationSnapshot = WorkspaceCheckoutConfigurationSnapshot(
                capturedAt: Date(timeIntervalSince1970: 0),
                shared: .init(
                    sessionOpenScript: "",
                    worktreeCreateScript: "echo global",
                    creationLaunchPreference: .inherit
                ),
                members: [
                    member.workspaceMemberID: .init(
                        setupScript: "echo global\necho project",
                        ggMode: .off,
                        mcpServers: []
                    )
                ]
            )
        }
        let scripts = RepairScriptRunner()
        let lifecycle = RepairLifecycle(result: .exactLineage("lineage-a"))
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: RepairGit(), scripts: scripts, projectMutationGate: ProjectMutationGate(), lifecycle: lifecycle)

        _ = try await coordinator.retrySetup(checkoutID: fixture.checkout.id, memberID: member.id)

        #expect(await scripts.scripts == ["echo global\necho project"])
    }

    @Test func concurrentRetrySetupRejectsTheSecondLiveSetup() async throws {
        let fixture = try await persistedFixture(checkpoint: .worktreeCreated, worktreeCreated: true, lineageID: "lineage-a")
        let scripts = BlockingRepairScriptRunner()
        let lifecycle = RepairLifecycle(result: .exactLineage("lineage-a"))
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: RepairGit(), scripts: scripts, projectMutationGate: ProjectMutationGate(), lifecycle: lifecycle)
        let memberID = fixture.checkout.members[0].id

        let first = Task { try await coordinator.retrySetup(checkoutID: fixture.checkout.id, memberID: memberID) }
        await scripts.waitUntilStarted()

        await #expect(throws: WorkspaceCheckoutCoordinatorError.operationInProgress) {
            try await coordinator.retrySetup(checkoutID: fixture.checkout.id, memberID: memberID)
        }

        await scripts.release()
        _ = try await first.value
        #expect(await scripts.runCount == 1)
    }

    @Test func retrySetupDoesNotRunWhenTheFrozenWorktreeLineageNoLongerMatches() async throws {
        let fixture = try await persistedFixture(checkpoint: .failed, worktreeCreated: true, lineageID: "lineage-a", branchOwnership: .created)
        let scripts = RepairScriptRunner()
        let lifecycle = RepairLifecycle(result: .identityConflict("replacement-lineage"))
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: RepairGit(), scripts: scripts, projectMutationGate: ProjectMutationGate(), lifecycle: lifecycle)

        let checkout = try await coordinator.retrySetup(checkoutID: fixture.checkout.id, memberID: fixture.checkout.members[0].id)

        #expect(checkout.members[0].checkpoint == .failed)
        #expect(await scripts.paths.isEmpty)
        #expect(await lifecycle.observationCount == 1)
    }

    @Test func retrySetupDoesNotRunWhileCheckoutDeletionIsInProgress() async throws {
        let fixture = try await persistedFixture(
            checkpoint: .failed,
            worktreeCreated: true,
            lineageID: "lineage-a",
            branchOwnership: .created,
            operation: .deleting
        )
        let scripts = RepairScriptRunner()
        let lifecycle = RepairLifecycle(result: .exactLineage("lineage-a"))
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: RepairGit(), scripts: scripts, projectMutationGate: ProjectMutationGate(), lifecycle: lifecycle)

        await #expect(throws: WorkspaceCheckoutCoordinatorError.operationInProgress) {
            try await coordinator.retrySetup(checkoutID: fixture.checkout.id, memberID: fixture.checkout.members[0].id)
        }
        #expect(await scripts.paths.isEmpty)
        #expect(await fixture.store.load().loadedCheckout(id: fixture.checkout.id)?.operation == .deleting)
    }

    @Test func resumeCreationUsesThePersistedFrozenPlan() async throws {
        let fixture = try await persistedFixture(checkpoint: .planPersisted)
        let git = ResumeGit()
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: git, scripts: RepairScriptRunner(), projectMutationGate: ProjectMutationGate())

        _ = try await coordinator.resumeCreation(checkoutID: fixture.checkout.id)

        #expect(await git.operations.map(\.destinationPath) == ["/checkouts/a", "/checkouts/a"])
    }

    @Test func resumeCreationAcceptsInterruptedCreatingCheckout() async throws {
        let fixture = try await persistedFixture(checkpoint: .planPersisted, operation: .creating)
        let git = ResumeGit()
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: git, scripts: RepairScriptRunner(), projectMutationGate: ProjectMutationGate())

        let checkout = try await coordinator.resumeCreation(checkoutID: fixture.checkout.id)

        #expect(checkout.operation == .idle)
        #expect(await git.operations.map(\.destinationPath) == ["/checkouts/a", "/checkouts/a"])
    }

    @Test func resumeCreationAcceptsPersistedRepairingCheckoutAfterRelaunch() async throws {
        let fixture = try await persistedFixture(checkpoint: .planPersisted, operation: .repairing)
        let git = ResumeGit()
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: git, scripts: RepairScriptRunner(), projectMutationGate: ProjectMutationGate())

        let checkout = try await coordinator.resumeCreation(checkoutID: fixture.checkout.id)

        #expect(checkout.operation == .idle)
        #expect(await git.operations.map(\.destinationPath) == ["/checkouts/a", "/checkouts/a"])
    }

    @Test func recreationClearsStaleCleanupBeforePersistingNewLineage() async throws {
        let fixture = try await persistedFixture(checkpoint: .planPersisted, operation: .idle)
        try await fixture.store.mutate { state in
            let checkout = state.checkouts[0]
            let member = checkout.members[0]
            state.checkouts[0].members[0].availability = .explicitlyDeleted
            state.checkouts[0].members[0].cleanup = WorkspaceCheckoutMemberCleanup(
                plan: WorkspaceCheckoutCleanupPlan(
                    checkoutID: checkout.id,
                    memberID: member.id,
                    executionLocation: checkout.executionLocation,
                    projectID: member.projectID,
                    sourceRepositoryPath: member.plan!.sourceRepositoryPath,
                    baseReference: member.plan!.baseReference,
                    baseCommit: member.plan!.baseCommit,
                    rootPath: checkout.rootPath,
                    managedMemberPaths: [member.worktreePath],
                    worktreePath: member.worktreePath,
                    branch: checkout.branch,
                    expectedLineageID: "old-lineage",
                    branchOwnership: .created
                ),
                checkpoint: .complete,
                worktreeRemoved: true,
                branchRemoved: true
            )
        }
        let git = ResumeGit()
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: git, scripts: RepairScriptRunner(), projectMutationGate: ProjectMutationGate())

        let checkout = try await coordinator.resumeCreation(checkoutID: fixture.checkout.id)

        #expect(checkout.members[0].availability == .available)
        #expect(checkout.members[0].gitLineageID == "lineage-a")
        #expect(checkout.members[0].cleanup == nil)
    }

    @Test func resumeCreationContinuesFromBranchPreparedWithoutPreparingAgain() async throws {
        let fixture = try await persistedFixture(checkpoint: .branchPrepared, branchOwnership: .created, operation: .creating)
        let git = CountingResumeGit()
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: git, scripts: RepairScriptRunner(), projectMutationGate: ProjectMutationGate())

        _ = try await coordinator.resumeCreation(checkoutID: fixture.checkout.id)

        #expect(await git.prepareCount == 0)
        #expect(await git.createCount == 1)
    }

    @Test func resumeCreationRetriesSetupRunningWithoutRepeatingGit() async throws {
        let fixture = try await persistedFixture(checkpoint: .setupRunning, worktreeCreated: true, lineageID: "lineage-a", branchOwnership: .created, operation: .creating)
        let git = CountingResumeGit()
        let scripts = RepairScriptRunner()
        let lifecycle = RepairLifecycle(result: .exactLineage("lineage-a"))
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: git, scripts: scripts, projectMutationGate: ProjectMutationGate(), lifecycle: lifecycle)

        let checkout = try await coordinator.resumeCreation(checkoutID: fixture.checkout.id)

        #expect(checkout.operation == .idle)
        #expect(checkout.members[0].checkpoint == .setupComplete)
        #expect(await git.prepareCount == 0)
        #expect(await git.createCount == 0)
        #expect(await scripts.paths == ["/checkouts/a"])
    }

    @Test func resumeCreationDoesNotRunSetupWhenTheFrozenWorktreeLineageNoLongerMatches() async throws {
        let fixture = try await persistedFixture(checkpoint: .setupRunning, worktreeCreated: true, lineageID: "lineage-a", branchOwnership: .created, operation: .creating)
        let git = CountingResumeGit()
        let scripts = RepairScriptRunner()
        let lifecycle = RepairLifecycle(result: .identityConflict("replacement-lineage"))
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: git, scripts: scripts, projectMutationGate: ProjectMutationGate(), lifecycle: lifecycle)

        let checkout = try await coordinator.resumeCreation(checkoutID: fixture.checkout.id)

        #expect(checkout.members[0].checkpoint == .setupRunning)
        #expect(checkout.operation == .idle)
        #expect(await scripts.paths.isEmpty)
        #expect(await lifecycle.observationCount == 1)
    }

    @Test func resumeCreationRetriesSetupFromWorktreeCreatedWithoutRepeatingGit() async throws {
        let fixture = try await persistedFixture(checkpoint: .worktreeCreated, worktreeCreated: true, lineageID: "lineage-a", branchOwnership: .created, operation: .creating)
        let git = CountingResumeGit()
        let scripts = RepairScriptRunner()
        let lifecycle = RepairLifecycle(result: .exactLineage("lineage-a"))
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: git, scripts: scripts, projectMutationGate: ProjectMutationGate(), lifecycle: lifecycle)

        let checkout = try await coordinator.resumeCreation(checkoutID: fixture.checkout.id)

        #expect(checkout.operation == .idle)
        #expect(checkout.members[0].checkpoint == .setupComplete)
        #expect(await git.prepareCount == 0)
        #expect(await git.createCount == 0)
        #expect(await scripts.paths == ["/checkouts/a"])
    }

    @Test func resumeCreationReusesAnAlreadyCreatedWorktreeAtTheCreatingCheckpoint() async throws {
        let fixture = try await persistedFixture(checkpoint: .worktreeCreating, branchOwnership: .created, operation: .creating)
        let git = CountingResumeGit(existingLineage: "lineage-a")
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: git, scripts: RepairScriptRunner(), projectMutationGate: ProjectMutationGate())

        let checkout = try await coordinator.resumeCreation(checkoutID: fixture.checkout.id)

        #expect(checkout.operation == .idle)
        #expect(checkout.members[0].gitLineageID == "lineage-a")
        #expect(checkout.members[0].checkpoint == .setupComplete)
        #expect(await git.prepareCount == 0)
        let calls = await git.calls
        #expect(calls == ["existing"], "calls: \(calls)")
        #expect(await git.existingLineageChecks == 1)
        #expect(await git.createCount == 0)
    }

    @Test func resumeCreationNeverReplaysGitAfterASetupFailure() async throws {
        let fixture = try await persistedFixture(checkpoint: .failed, worktreeCreated: true)
        let git = ResumeGit()
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: git, scripts: RepairScriptRunner(), projectMutationGate: ProjectMutationGate())

        _ = try await coordinator.resumeCreation(checkoutID: fixture.checkout.id)

        #expect(await git.operations.isEmpty)
    }

    @Test func resumeCreationRecreatesACompletedMemberWhoseFrozenWorktreeIsMissing() async throws {
        let fixture = try await persistedFixture(
            checkpoint: .setupComplete,
            worktreeCreated: true,
            lineageID: "lineage-a",
            branchOwnership: .created,
            operation: .creating
        )
        let git = CountingResumeGit(existingLineage: nil)
        let scripts = RepairScriptRunner()
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: git, scripts: scripts, projectMutationGate: ProjectMutationGate())

        let checkout = try await coordinator.resumeCreation(checkoutID: fixture.checkout.id)

        #expect(checkout.operation == .idle)
        #expect(checkout.members[0].checkpoint == .setupComplete)
        #expect(checkout.members[0].availability == .available)
        #expect(checkout.members[0].gitLineageID == "lineage-a")
        #expect(await git.prepareCount == 0)
        #expect(await git.createCount == 1)
        #expect(await git.existingLineageChecks == 2)
        #expect(await scripts.paths == ["/checkouts/a"])
    }

    @Test func recreateMemberOnlyUsesTheSelectedFrozenMemberPlan() async throws {
        let fixture = try await persistedFixture(checkpoint: .planPersisted, operation: .idle)
        let second = checkoutMember(
            id: UUID(),
            workspaceMemberID: UUID(),
            projectID: "project-b",
            name: "B",
            sourcePath: "/repos/b",
            destinationPath: "/checkouts/b",
            checkpoint: .planPersisted,
            availability: .explicitlyDeleted
        )
        try await fixture.store.mutate { state in
            state.checkouts[0].members[0].availability = .explicitlyDeleted
            state.checkouts[0].members.append(second)
        }
        let git = ResumeGit()
        let scripts = RepairScriptRunner()
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: git, scripts: scripts, projectMutationGate: ProjectMutationGate())

        let checkout = try await coordinator.resumeCreation(checkoutID: fixture.checkout.id, memberID: fixture.checkout.members[0].id)

        #expect(checkout.operation == .idle)
        #expect(checkout.members[0].checkpoint == .setupComplete)
        #expect(checkout.members[1].checkpoint == .planPersisted)
        #expect(checkout.members[1].availability == .explicitlyDeleted)
        #expect(await scripts.paths == ["/checkouts/a"])
        #expect(await git.operations.map(\.destinationPath) == ["/checkouts/a", "/checkouts/a"])
    }

    @Test func resumeCreationDoesNotResetCompletedSiblingUnlessItsFrozenPathIsAbsent() async throws {
        let fixture = try await persistedFixture(checkpoint: .planPersisted, operation: .creating)
        let completed = checkoutMember(
            id: UUID(),
            workspaceMemberID: UUID(),
            projectID: "project-b",
            name: "B",
            sourcePath: "/repos/b",
            destinationPath: "/checkouts/b",
            lineageID: "lineage-b",
            checkpoint: .setupComplete,
            availability: .available,
            worktreeCreated: true,
            branchOwnership: .created
        )
        try await fixture.store.mutate { state in
            state.checkouts[0].members.append(completed)
        }
        let git = NonMissingCompletedGit(nonMissingDestinations: ["/checkouts/b"])
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: git, scripts: RepairScriptRunner(), projectMutationGate: ProjectMutationGate())

        let checkout = try await coordinator.resumeCreation(checkoutID: fixture.checkout.id)

        #expect(checkout.members[1].checkpoint == .setupComplete)
        #expect(checkout.members[1].availability == .available)
        #expect(checkout.members[1].gitLineageID == "lineage-b")
        #expect(await git.createdDestinations == ["/checkouts/a"])
        #expect(await git.missingChecks == ["/checkouts/b"])
    }

    @Test func useExistingRepairCandidateOnlyAcceptsExactFrozenLineage() async throws {
        let fixture = try await persistedFixture(checkpoint: .failed, worktreeCreated: true, lineageID: "lineage-a")
        try await fixture.store.mutate { state in
            state.checkouts[0].members[0].availability = .missing
        }
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: RepairGit(), scripts: RepairScriptRunner(), projectMutationGate: ProjectMutationGate())

        await #expect(throws: WorkspaceCheckoutCoordinatorError.cleanupIdentityConflict) {
            try await coordinator.useExistingVerifiedCandidate(
                checkoutID: fixture.checkout.id,
                memberID: fixture.checkout.members[0].id,
                candidate: .init(path: "/tmp/other", lineageID: "lineage-a", isExactMatch: true)
            )
        }

        let repaired = try await coordinator.useExistingVerifiedCandidate(
            checkoutID: fixture.checkout.id,
            memberID: fixture.checkout.members[0].id,
            candidate: .init(path: "/checkouts/a", lineageID: "lineage-a", isExactMatch: true)
        )

        #expect(repaired.members[0].availability == .available)
        #expect(repaired.members[0].checkpoint == .failed)
        #expect(repaired.members[0].cleanupOwnership.worktreeCreated == true)
    }

    @Test func concurrentResumeCreationRejectsTheSecondRepairClaim() async throws {
        let fixture = try await persistedFixture(checkpoint: .planPersisted)
        let git = BlockingResumeGit()
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: git, scripts: RepairScriptRunner(), projectMutationGate: ProjectMutationGate())

        let first = Task { try await coordinator.resumeCreation(checkoutID: fixture.checkout.id) }
        await git.waitUntilStarted()

        await #expect(throws: WorkspaceCheckoutCoordinatorError.operationInProgress) {
            try await coordinator.resumeCreation(checkoutID: fixture.checkout.id)
        }

        await git.release()
        _ = try await first.value
        #expect(await git.operations == ["prepare", "existing", "create"])
    }

    @Test func resumeCreationRejectsLiveSetupRetryOwnership() async throws {
        let fixture = try await persistedFixture(
            checkpoint: .worktreeCreated,
            worktreeCreated: true,
            lineageID: "lineage-a",
            branchOwnership: .created
        )
        let scripts = BlockingRepairScriptRunner()
        let lifecycle = RepairLifecycle(result: .exactLineage("lineage-a"))
        let coordinator = WorkspaceCheckoutCoordinator(
            store: fixture.store,
            git: CountingResumeGit(),
            scripts: scripts,
            projectMutationGate: ProjectMutationGate(),
            lifecycle: lifecycle
        )

        let retry = Task { try await coordinator.retrySetup(checkoutID: fixture.checkout.id, memberID: fixture.checkout.members[0].id) }
        await scripts.waitUntilStarted()

        await #expect(throws: WorkspaceCheckoutCoordinatorError.operationInProgress) {
            try await coordinator.resumeCreation(checkoutID: fixture.checkout.id)
        }

        await scripts.release()
        _ = try await retry.value
    }

    private func persistedFixture(
        checkpoint: WorkspaceCheckoutCheckpoint,
        worktreeCreated: Bool = false,
        lineageID: String? = nil,
        branchOwnership: WorkspaceBranchOwnership = .unknown,
        operation: WorkspaceCheckoutOperation = .idle
    ) async throws -> (store: WorkspaceStore, checkout: WorkspaceCheckout) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-repair-\(UUID().uuidString).json")
        let store = WorkspaceStore(url: url)
        let checkoutMemberID = UUID()
        let member = WorkspaceCheckoutMember(
            id: checkoutMemberID,
            workspaceMemberID: UUID(), projectID: "project-a", fallbackProjectName: "A", fallbackRepositoryRoot: "/repos/a",
            worktreePath: "/checkouts/a", gitLineageID: lineageID, checkpoint: checkpoint,
            cleanupOwnership: .init(worktreeCreated: worktreeCreated, branchOwnership: branchOwnership),
            plan: .init(checkoutMemberID: checkoutMemberID, projectID: "project-a", sourceRepositoryPath: "/repos/a", destinationPath: "/checkouts/a", baseReference: "main", baseCommit: "abc", branchIntent: .create(atCommit: "abc"))
        )
        let checkout = WorkspaceCheckout(workspaceID: UUID(), fallbackWorkspaceName: "Release", executionLocation: .local, branch: "release/1091", rootPath: "/checkouts", operation: operation, members: [member])
        try await store.checkpoint(.init(checkouts: [checkout]))
        return (store, checkout)
    }

    private func checkoutMember(
        id: UUID,
        workspaceMemberID: UUID,
        projectID: String,
        name: String,
        sourcePath: String,
        destinationPath: String,
        lineageID: String? = nil,
        checkpoint: WorkspaceCheckoutCheckpoint,
        availability: WorkspaceCheckoutMemberAvailability = .pending,
        worktreeCreated: Bool = false,
        branchOwnership: WorkspaceBranchOwnership = .unknown
    ) -> WorkspaceCheckoutMember {
        WorkspaceCheckoutMember(
            id: id,
            workspaceMemberID: workspaceMemberID,
            projectID: projectID,
            fallbackProjectName: name,
            fallbackRepositoryRoot: sourcePath,
            worktreePath: destinationPath,
            gitLineageID: lineageID,
            availability: availability,
            checkpoint: checkpoint,
            cleanupOwnership: .init(worktreeCreated: worktreeCreated, branchOwnership: branchOwnership),
            plan: .init(
                checkoutMemberID: id,
                projectID: projectID,
                sourceRepositoryPath: sourcePath,
                destinationPath: destinationPath,
                baseReference: "main",
                baseCommit: "abc",
                branchIntent: .create(atCommit: "abc")
            )
        )
    }
}

private actor RepairObserver: WorkspaceCheckoutObserving {
    let result: WorkspaceCheckoutMemberObservation
    private(set) var observationCount = 0

    init(result: WorkspaceCheckoutMemberObservation) { self.result = result }

    func observe(_ member: WorkspaceCheckoutMember, in checkout: WorkspaceCheckout) async -> WorkspaceCheckoutMemberObservation {
        observationCount += 1
        return result
    }
}

private actor RepairLifecycle: WorkspaceCheckoutLifecycleOperating {
    let result: WorkspaceCheckoutMemberObservation
    private(set) var observationCount = 0

    init(result: WorkspaceCheckoutMemberObservation) { self.result = result }

    func deletePreflight(_ plan: WorkspaceCheckoutCleanupPlan) async throws -> WorktreeDeletePreflight {
        .init(reasons: [], submoduleLocalState: .none)
    }

    func inspectRoot(_ plan: WorkspaceCheckoutCleanupPlan) async -> WorkspaceCheckoutCleanupRootObservation {
        .init(isContained: true, leftovers: [])
    }

    func verifyCleanup(_ plan: WorkspaceCheckoutCleanupPlan) async -> WorkspaceCheckoutMemberObservation {
        observationCount += 1
        return result
    }

    func removeWorktree(_ plan: WorkspaceCheckoutCleanupPlan, force: Bool) async throws {}

    func deleteMergedBranch(_ plan: WorkspaceCheckoutCleanupPlan) async throws -> Bool { true }
}

private struct RepairGit: WorkspaceGitOperating {
    func prepareBranch(_ operation: WorkspaceFrozenWorktreeOperation) async throws {}
    func createWorktree(_ operation: WorkspaceFrozenWorktreeOperation) async throws -> String? { nil }
}

private actor RepairScriptRunner: WorkspaceScriptRunning {
    private(set) var paths: [String] = []
    private(set) var scripts: [String] = []
    func runSetup(for operation: WorkspaceCheckoutSetupOperation) async throws {
        paths.append(operation.worktreePath)
        scripts.append(operation.script)
    }
}

private actor BlockingRepairScriptRunner: WorkspaceScriptRunning {
    private(set) var runCount = 0
    private var started = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func runSetup(for operation: WorkspaceCheckoutSetupOperation) async throws {
        runCount += 1
        started = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
        if !released {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private actor ResumeGit: WorkspaceGitOperating {
    private(set) var operations: [WorkspaceFrozenWorktreeOperation] = []
    func prepareBranch(_ operation: WorkspaceFrozenWorktreeOperation) async throws { operations.append(operation) }
    func createWorktree(_ operation: WorkspaceFrozenWorktreeOperation) async throws -> String? { operations.append(operation)
    return "lineage-a" }
}

private actor BlockingResumeGit: WorkspaceGitOperating {
    private(set) var operations: [String] = []
    private var started = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func prepareBranch(_ operation: WorkspaceFrozenWorktreeOperation) async throws {
        operations.append("prepare")
        started = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
        if !released {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
    }

    func existingCreatedWorktreeLineage(_ operation: WorkspaceFrozenWorktreeOperation) async throws -> String? {
        operations.append("existing")
        return nil
    }

    func createWorktree(_ operation: WorkspaceFrozenWorktreeOperation) async throws -> String? {
        operations.append("create")
        return "lineage-a"
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private actor CountingResumeGit: WorkspaceGitOperating {
    let existingLineage: String?
    private(set) var calls: [String] = []
    var prepareCount: Int { calls.filter { $0 == "prepare" }.count }
    var createCount: Int { calls.filter { $0 == "create" }.count }

    init(existingLineage: String? = nil) {
        self.existingLineage = existingLineage
    }

    func prepareBranch(_ operation: WorkspaceFrozenWorktreeOperation) async throws {
        calls.append("prepare")
    }

    func createWorktree(_ operation: WorkspaceFrozenWorktreeOperation) async throws -> String? {
        calls.append("create")
        return "lineage-a"
    }

    private(set) var existingLineageChecks = 0
    func existingCreatedWorktreeLineage(_ operation: WorkspaceFrozenWorktreeOperation) async throws -> String? {
        existingLineageChecks += 1
        calls.append("existing")
        return existingLineage
    }
}

private actor NonMissingCompletedGit: WorkspaceGitOperating {
    let nonMissingDestinations: Set<String>
    private(set) var createdDestinations: [String] = []
    private(set) var missingChecks: [String] = []

    init(nonMissingDestinations: Set<String>) {
        self.nonMissingDestinations = nonMissingDestinations
    }

    func prepareBranch(_ operation: WorkspaceFrozenWorktreeOperation) async throws {}

    func createWorktree(_ operation: WorkspaceFrozenWorktreeOperation) async throws -> String? {
        createdDestinations.append(operation.destinationPath)
        return "lineage-a"
    }

    func frozenWorktreeIsMissing(_ operation: WorkspaceFrozenWorktreeOperation) async throws -> Bool {
        missingChecks.append(operation.destinationPath)
        return nonMissingDestinations.contains(operation.destinationPath) == false
    }
}

private extension WorkspaceStoreLoadResult {
    func loadedCheckout(id: UUID) -> WorkspaceCheckout? {
        guard case .loaded(let state) = self else { return nil }
        return state.checkouts.first(where: { $0.id == id })
    }
}
