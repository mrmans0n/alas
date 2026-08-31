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

    @Test func retrySetupUsesTheFrozenWorktreeAndNeverRepeatsASuccess() async throws {
        let fixture = try await persistedFixture(checkpoint: .worktreeCreated)
        let scripts = RepairScriptRunner()
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: RepairGit(), scripts: scripts, projectMutationGate: ProjectMutationGate())

        _ = try await coordinator.retrySetup(checkoutID: fixture.checkout.id, memberID: fixture.checkout.members[0].id)
        _ = try await coordinator.retrySetup(checkoutID: fixture.checkout.id, memberID: fixture.checkout.members[0].id)

        #expect(await scripts.paths == ["/checkouts/a"])
        #expect(await fixture.store.load().loadedCheckout(id: fixture.checkout.id)?.members[0].checkpoint == .setupComplete)
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
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: git, scripts: scripts, projectMutationGate: ProjectMutationGate())

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

    @Test func concurrentResumeCreationClaimsTheFrozenMemberOnce() async throws {
        let fixture = try await persistedFixture(checkpoint: .planPersisted)
        let git = ResumeGit()
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: git, scripts: RepairScriptRunner(), projectMutationGate: ProjectMutationGate())

        async let first = coordinator.resumeCreation(checkoutID: fixture.checkout.id)
        async let second = coordinator.resumeCreation(checkoutID: fixture.checkout.id)
        _ = try await (first, second)

        #expect(await git.operations.count == 2)
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

private struct RepairGit: WorkspaceGitOperating {
    func prepareBranch(_ operation: WorkspaceFrozenWorktreeOperation) async throws {}
    func createWorktree(_ operation: WorkspaceFrozenWorktreeOperation) async throws -> String? { nil }
}

private actor RepairScriptRunner: WorkspaceScriptRunning {
    private(set) var paths: [String] = []
    func runSetup(for operation: WorkspaceCheckoutSetupOperation) async throws { paths.append(operation.worktreePath) }
}

private actor ResumeGit: WorkspaceGitOperating {
    private(set) var operations: [WorkspaceFrozenWorktreeOperation] = []
    func prepareBranch(_ operation: WorkspaceFrozenWorktreeOperation) async throws { operations.append(operation) }
    func createWorktree(_ operation: WorkspaceFrozenWorktreeOperation) async throws -> String? { operations.append(operation)
    return "lineage-a" }
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

private extension WorkspaceStoreLoadResult {
    func loadedCheckout(id: UUID) -> WorkspaceCheckout? {
        guard case .loaded(let state) = self else { return nil }
        return state.checkouts.first(where: { $0.id == id })
    }
}
