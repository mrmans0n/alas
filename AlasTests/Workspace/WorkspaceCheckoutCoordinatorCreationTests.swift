import Foundation
import Testing
@testable import Alas

@Suite("Workspace checkout coordinator creation")
struct WorkspaceCheckoutCoordinatorCreationTests {
    @Test func persistsEveryFrozenMemberPlanBeforeTheFirstGitMutation() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-coordinator-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WorkspaceStore(url: url)
        let member = WorkspaceMember(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            projectID: "project-a",
            fallbackProjectName: "Project A",
            fallbackRepositoryRoot: "/repos/a"
        )
        let workspace = Workspace(name: "Release", executionLocation: .local, members: [member])
        let checkoutID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let plan = FrozenWorkspaceCheckoutPlan(
            checkoutID: checkoutID,
            workspaceID: workspace.id,
            executionLocation: .local,
            branch: "release/1091",
            rootPath: "/checkouts/release",
            members: [.init(
                checkoutMemberID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                workspaceMemberID: member.id,
                projectID: "project-a",
                sourceRepositoryPath: "/repos/a",
                destinationPath: "/checkouts/release/a",
                baseReference: "main",
                baseCommit: "abc123",
                branchIntent: .create(atCommit: "abc123")
            )]
        )
        let git = PersistedPlanInspectingGit(store: store, checkoutID: checkoutID)
        let coordinator = WorkspaceCheckoutCoordinator(store: store, git: git, scripts: NoopWorkspaceScriptRunner())

        _ = try await coordinator.create(workspace: workspace, plan: plan)
        await coordinator.awaitCreationCompletion(checkoutID: checkoutID)

        #expect(await git.sawCompletePersistedPlan)
    }

    @Test func capsMembersAtFourAndContinuesSiblingsAfterOneFailure() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-coordinator-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WorkspaceStore(url: url)
        let fixture = makeFixture(count: 5)
        let git = ConcurrentWorkspaceGit(failingProjectID: "project-0")
        let coordinator = WorkspaceCheckoutCoordinator(store: store, git: git, scripts: NoopWorkspaceScriptRunner(), projectMutationGate: ProjectMutationGate())

        let checkout = try await coordinator.create(workspace: fixture.workspace, plan: fixture.plan)
        await coordinator.awaitCreationCompletion(checkoutID: checkout.id)

        #expect(await git.maximumConcurrentPreparations <= 4)
        #expect(await git.createdProjectIDs.count == 4)
        let completed = await store.checkout(id: checkout.id)
        #expect(completed?.members.first?.checkpoint == .failed)
        #expect(completed?.members.dropFirst().allSatisfy { $0.checkpoint == .setupComplete } == true)
        #expect(completed?.members.dropFirst().allSatisfy { $0.gitLineageID == "lineage-\($0.projectID)" } == true)
    }

    @Test func serializesSameProjectAndPassesTheExactFrozenIntent() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-coordinator-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = WorkspaceMember(projectID: "shared", fallbackProjectName: "One", fallbackRepositoryRoot: "/repos/one")
        let second = WorkspaceMember(projectID: "shared", fallbackProjectName: "Two", fallbackRepositoryRoot: "/repos/two")
        let workspace = Workspace(name: "Release", executionLocation: .local, members: [first, second])
        let plan = FrozenWorkspaceCheckoutPlan(checkoutID: UUID(), workspaceID: workspace.id, executionLocation: .local, branch: "release/1091", rootPath: "/checkouts/release", members: [
            .init(checkoutMemberID: UUID(), workspaceMemberID: first.id, projectID: "shared", sourceRepositoryPath: "/repos/one", destinationPath: "/checkouts/release/one", baseReference: "main", baseCommit: "one", branchIntent: .create(atCommit: "one")),
            .init(checkoutMemberID: UUID(), workspaceMemberID: second.id, projectID: "shared", sourceRepositoryPath: "/repos/two", destinationPath: "/checkouts/release/two", baseReference: "main", baseCommit: "two", branchIntent: .reuse)
        ])
        let git = SerialIntentWorkspaceGit()
        let coordinator = WorkspaceCheckoutCoordinator(store: WorkspaceStore(url: url), git: git, scripts: NoopWorkspaceScriptRunner(), projectMutationGate: ProjectMutationGate())

        _ = try await coordinator.create(workspace: workspace, plan: plan)
        await coordinator.awaitCreationCompletion(checkoutID: plan.checkoutID)

        #expect(await git.maximumConcurrentPreparations == 1)
        #expect(await git.intents == [.create(atCommit: "one"), .reuse(atCommit: "two")])
    }

    @Test func stopAfterCurrentOperationsLeavesPendingMembersResumable() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-coordinator-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WorkspaceStore(url: url)
        let fixture = makeFixture(count: 5)
        let git = ConcurrentWorkspaceGit(failingProjectID: "never")
        let coordinator = WorkspaceCheckoutCoordinator(store: store, git: git, scripts: NoopWorkspaceScriptRunner(), projectMutationGate: ProjectMutationGate())

        let checkout = try await coordinator.createPersisted(workspace: fixture.workspace, plan: fixture.plan)
        await coordinator.beginCreation(checkoutID: checkout.id)
        try await coordinator.stopAfterCurrentOperations(checkoutID: checkout.id)
        await coordinator.awaitCreationCompletion(checkoutID: checkout.id)

        let persisted = await store.checkout(id: checkout.id)
        #expect(persisted?.operation == .idle)
        #expect(persisted?.stopAfterCurrentOperations == false)
        #expect(persisted?.members.contains(where: { $0.checkpoint == WorkspaceCheckoutCheckpoint.planPersisted }) == true)
    }

    @Test func resumeCreationIsRejectedWhileBackgroundCreationOwnsTheCheckout() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-coordinator-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WorkspaceStore(url: url)
        let fixture = makeFixture(count: 1)
        let git = BlockingWorkspaceGit()
        let coordinator = WorkspaceCheckoutCoordinator(store: store, git: git, scripts: NoopWorkspaceScriptRunner(), projectMutationGate: ProjectMutationGate())

        let checkout = try await coordinator.createPersisted(workspace: fixture.workspace, plan: fixture.plan)
        await coordinator.beginCreation(checkoutID: checkout.id)
        await git.waitUntilPrepareStarted()

        await #expect(throws: WorkspaceCheckoutCoordinatorError.operationInProgress) {
            try await coordinator.resumeCreation(checkoutID: checkout.id)
        }

        await git.release()
        await coordinator.awaitCreationCompletion(checkoutID: checkout.id)
    }

    @Test func resumeCreationTreatsPreparedBranchAtFrozenBaseAsDurable() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-coordinator-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WorkspaceStore(url: url)
        let fixture = makeFixture(count: 1)
        let checkout = WorkspaceCheckout(
            workspaceID: fixture.workspace.id,
            fallbackWorkspaceName: fixture.workspace.name,
            executionLocation: fixture.workspace.executionLocation,
            branch: fixture.plan.branch,
            rootPath: fixture.plan.rootPath,
            operation: .creating,
            members: [
                WorkspaceCheckoutMember(
                    id: fixture.plan.members[0].checkoutMemberID,
                    workspaceMemberID: fixture.plan.members[0].workspaceMemberID,
                    projectID: fixture.plan.members[0].projectID,
                    fallbackProjectName: "Project 0",
                    fallbackRepositoryRoot: "/repos/0",
                    worktreePath: fixture.plan.members[0].destinationPath,
                    checkpoint: .branchPreparing,
                    plan: fixture.plan.members[0].memberPlan
                )
            ]
        )
        try await store.checkpoint(.init(checkouts: [checkout]))
        let git = PreparedBranchWorkspaceGit()
        let coordinator = WorkspaceCheckoutCoordinator(store: store, git: git, scripts: NoopWorkspaceScriptRunner(), projectMutationGate: ProjectMutationGate())

        _ = try await coordinator.resumeCreation(checkoutID: checkout.id)

        #expect(await git.prepareCount == 0)
        #expect(await git.createCount == 1)
        #expect(await store.checkout(id: checkout.id)?.members[0].cleanupOwnership.branchOwnership == .created)
    }

    @Test func overlappingMemberDeletionRejectsTheSecondLiveCall() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-coordinator-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WorkspaceStore(url: url)
        let fixture = makeFixture(count: 1)
        let memberPlan = fixture.plan.members[0]
        let memberID = memberPlan.checkoutMemberID
        let member = WorkspaceCheckoutMember(
            id: memberID,
            workspaceMemberID: memberPlan.workspaceMemberID,
            projectID: memberPlan.projectID,
            fallbackProjectName: "Project 0",
            fallbackRepositoryRoot: "/repos/0",
            worktreePath: memberPlan.destinationPath,
            gitLineageID: "lineage-project-0",
            availability: .available,
            checkpoint: .setupComplete,
            cleanupOwnership: .init(worktreeCreated: true, branchOwnership: .created),
            plan: memberPlan.memberPlan
        )
        let checkout = WorkspaceCheckout(
            workspaceID: fixture.workspace.id,
            fallbackWorkspaceName: fixture.workspace.name,
            executionLocation: .local,
            branch: fixture.plan.branch,
            rootPath: fixture.plan.rootPath,
            members: [member]
        )
        try await store.checkpoint(.init(checkouts: [checkout]))
        let lifecycle = BlockingCleanupLifecycle()
        let coordinator = WorkspaceCheckoutCoordinator(
            store: store,
            git: CountingWorkspaceGit(),
            scripts: NoopWorkspaceScriptRunner(),
            projectMutationGate: ProjectMutationGate(),
            lifecycle: lifecycle
        )

        let first = Task {
            try await coordinator.deleteMember(checkoutID: checkout.id, memberID: memberID)
        }
        await lifecycle.waitUntilPreflightStarted()

        await #expect(throws: WorkspaceCheckoutCoordinatorError.operationInProgress) {
            try await coordinator.deleteMember(checkoutID: checkout.id, memberID: memberID)
        }

        await lifecycle.release()
        _ = try await first.value
    }

    @Test func rejectsInconsistentFrozenPlanBeforePersistingOrCallingGit() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-coordinator-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let fixture = makeFixture(count: 1)
        var invalidPlan = fixture.plan
        invalidPlan.branch = "bad branch"
        invalidPlan.members[0].branchIntent = .create(atCommit: "different-commit")
        let git = CountingWorkspaceGit()
        let store = WorkspaceStore(url: url)
        let coordinator = WorkspaceCheckoutCoordinator(store: store, git: git, scripts: NoopWorkspaceScriptRunner(), projectMutationGate: ProjectMutationGate())

        await #expect(throws: WorkspaceCheckoutCoordinatorError.incompletePlan) {
            try await coordinator.create(workspace: fixture.workspace, plan: invalidPlan)
        }

        #expect(await git.callCount == 0)
        #expect(await store.load() == .missing)
    }

    @Test func persistsFrozenPreflightWarningsWithTheCheckoutSnapshot() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-coordinator-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let fixture = makeFixture(count: 1)
        var plan = fixture.plan
        plan.warnings = [.init(severity: .warning, message: "Workspace member 1 is using cached ref 'main' for 'origin/main'.")]
        let store = WorkspaceStore(url: url)
        let coordinator = WorkspaceCheckoutCoordinator(store: store, git: CountingWorkspaceGit(), scripts: NoopWorkspaceScriptRunner(), projectMutationGate: ProjectMutationGate())

        let checkout = try await coordinator.create(workspace: fixture.workspace, plan: plan)
        #expect(checkout.diagnostics.map(\.message) == plan.warnings.map(\.message))
        guard case .loaded(let persisted) = await store.load() else {
            Issue.record("Expected persisted Workspace state")
            return
        }
        #expect(persisted.checkouts.first?.diagnostics.map(\.message) == plan.warnings.map(\.message))
    }

    @Test func setupCombinesSharedWorkspaceAndMemberSpecificScriptWithoutRepeatingGlobalPrefix() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-coordinator-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let fixture = makeFixture(count: 1)
        let scripts = CapturingWorkspaceScriptRunner()
        let snapshot = WorkspaceCheckoutConfigurationSnapshot(
            capturedAt: Date(timeIntervalSince1970: 0),
            shared: .init(
                sessionOpenScript: "",
                worktreeCreateScript: "echo global\necho workspace",
                creationLaunchPreference: .inherit
            ),
            members: [
                fixture.workspace.members[0].id: .init(
                    setupScript: "echo global\necho project",
                    ggMode: .off,
                    mcpServers: []
                )
            ]
        )
        let coordinator = WorkspaceCheckoutCoordinator(
            store: WorkspaceStore(url: url),
            git: CountingWorkspaceGit(),
            scripts: scripts,
            projectMutationGate: ProjectMutationGate()
        )

        let checkout = try await coordinator.create(
            workspace: fixture.workspace,
            plan: fixture.plan,
            configurationSnapshot: snapshot
        )
        await coordinator.awaitCreationCompletion(checkoutID: checkout.id)

        #expect(await scripts.recordedScripts == ["echo global\necho workspace\necho project"])
    }

    @Test func resumeCreationRecreatesManifestBeforeMemberMutation() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-coordinator-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WorkspaceStore(url: url)
        let fixture = makeFixture(count: 1)
        let checkout = WorkspaceCheckout(
            workspaceID: fixture.workspace.id,
            fallbackWorkspaceName: fixture.workspace.name,
            executionLocation: fixture.workspace.executionLocation,
            branch: fixture.plan.branch,
            rootPath: fixture.plan.rootPath,
            operation: .creating,
            members: [
                WorkspaceCheckoutMember(
                    id: fixture.plan.members[0].checkoutMemberID,
                    workspaceMemberID: fixture.plan.members[0].workspaceMemberID,
                    projectID: fixture.plan.members[0].projectID,
                    fallbackProjectName: "Project 0",
                    fallbackRepositoryRoot: "/repos/0",
                    worktreePath: fixture.plan.members[0].destinationPath,
                    checkpoint: .planPersisted,
                    plan: fixture.plan.members[0].memberPlan
                )
            ]
        )
        try await store.checkpoint(.init(checkouts: [checkout]))
        let manifests = RecordingManifestWriter()
        let git = ManifestOrderingGit(manifests: manifests)
        let coordinator = WorkspaceCheckoutCoordinator(
            store: store,
            git: git,
            scripts: NoopWorkspaceScriptRunner(),
            projectMutationGate: ProjectMutationGate(),
            manifests: manifests
        )

        _ = try await coordinator.resumeCreation(checkoutID: checkout.id)

        #expect(await manifests.writeCount == 1)
        #expect(await git.sawManifestBeforeGit)
    }

    @Test func resumeCreationDoesNotRunGitWhenManifestCannotBeRecreated() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-coordinator-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WorkspaceStore(url: url)
        let fixture = makeFixture(count: 1)
        let checkout = WorkspaceCheckout(
            workspaceID: fixture.workspace.id,
            fallbackWorkspaceName: fixture.workspace.name,
            executionLocation: fixture.workspace.executionLocation,
            branch: fixture.plan.branch,
            rootPath: fixture.plan.rootPath,
            operation: .creating,
            members: [
                WorkspaceCheckoutMember(
                    id: fixture.plan.members[0].checkoutMemberID,
                    workspaceMemberID: fixture.plan.members[0].workspaceMemberID,
                    projectID: fixture.plan.members[0].projectID,
                    fallbackProjectName: "Project 0",
                    fallbackRepositoryRoot: "/repos/0",
                    worktreePath: fixture.plan.members[0].destinationPath,
                    checkpoint: .planPersisted,
                    plan: fixture.plan.members[0].memberPlan
                )
            ]
        )
        try await store.checkpoint(.init(checkouts: [checkout]))
        let git = CountingWorkspaceGit()
        let coordinator = WorkspaceCheckoutCoordinator(
            store: store,
            git: git,
            scripts: NoopWorkspaceScriptRunner(),
            projectMutationGate: ProjectMutationGate(),
            manifests: FailingManifestWriter()
        )

        await #expect(throws: TestError.failed) {
            try await coordinator.resumeCreation(checkoutID: checkout.id)
        }

        #expect(await git.callCount == 0)
        let persisted = await store.checkout(id: checkout.id)
        #expect(persisted?.operation == .idle)
        #expect(persisted?.diagnostics.contains(where: { $0.message == "Could not write the Workspace checkout manifest." }) == true)
    }

    @Test func failedLineageCheckpointKeepsOwnedWorktreeRecoverableWithoutAddingAgain() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-coordinator-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WorkspaceStore(url: url)
        let fixture = makeFixture(count: 1)
        let git = LineageFailureThenRecoveryGit(store: store, checkoutID: fixture.plan.checkoutID)
        let coordinator = WorkspaceCheckoutCoordinator(store: store, git: git, scripts: NoopWorkspaceScriptRunner(), projectMutationGate: ProjectMutationGate())

        let checkout = try await coordinator.create(workspace: fixture.workspace, plan: fixture.plan)
        await coordinator.awaitCreationCompletion(checkoutID: checkout.id)

        let failed = try #require(await store.checkout(id: checkout.id))
        #expect(failed.members[0].checkpoint == .failed)
        #expect(failed.members[0].cleanupOwnership.worktreeCreated)
        let expectedLineage = "workspace-\(checkout.id.uuidString.lowercased())-\(failed.members[0].id.uuidString.lowercased())"
        #expect(failed.members[0].gitLineageID == expectedLineage)
        #expect(await git.sawOwnedWorktreeBeforeCreate)

        _ = try await coordinator.resumeCreation(checkoutID: checkout.id)

        let repaired = try #require(await store.checkout(id: checkout.id))
        #expect(repaired.members[0].checkpoint == .setupComplete)
        #expect(repaired.members[0].gitLineageID == expectedLineage)
        #expect(await git.createCount == 1)
        #expect(await git.existingLineageAllowedRecording)
    }

    @Test func manifestRefreshesWithMemberAvailabilityAfterCreationCompletes() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-coordinator-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WorkspaceStore(url: url)
        let fixture = makeFixture(count: 1)
        let manifests = RecordingManifestWriter()
        let coordinator = WorkspaceCheckoutCoordinator(
            store: store,
            git: ConcurrentWorkspaceGit(failingProjectID: "never"),
            scripts: NoopWorkspaceScriptRunner(),
            projectMutationGate: ProjectMutationGate(),
            manifests: manifests
        )

        let checkout = try await coordinator.create(workspace: fixture.workspace, plan: fixture.plan)
        await coordinator.awaitCreationCompletion(checkoutID: checkout.id)

        #expect(await manifests.memberAvailabilities.contains([.available]))
    }

    private func makeFixture(count: Int) -> (workspace: Workspace, plan: FrozenWorkspaceCheckoutPlan) {
        let members = (0 ..< count).map { index in
            WorkspaceMember(projectID: "project-\(index)", fallbackProjectName: "Project \(index)", fallbackRepositoryRoot: "/repos/\(index)")
        }
        let workspace = Workspace(name: "Release", executionLocation: .local, members: members)
        let plan = FrozenWorkspaceCheckoutPlan(
            checkoutID: UUID(), workspaceID: workspace.id, executionLocation: .local, branch: "release/1091", rootPath: "/checkouts/release",
            members: members.enumerated().map { index, member in
                .init(checkoutMemberID: UUID(), workspaceMemberID: member.id, projectID: member.projectID, sourceRepositoryPath: "/repos/\(index)", destinationPath: "/checkouts/release/\(index)", baseReference: "main", baseCommit: "commit-\(index)", branchIntent: .create(atCommit: "commit-\(index)"))
            }
        )
        return (workspace, plan)
    }
}

private extension FrozenWorkspaceCheckoutPlan.Member {
    var memberPlan: WorkspaceCheckoutMemberPlan {
        .init(
            checkoutMemberID: checkoutMemberID,
            projectID: projectID,
            sourceRepositoryPath: sourceRepositoryPath,
            destinationPath: destinationPath,
            baseReference: baseReference,
            baseCommit: baseCommit,
            branchIntent: branchIntent
        )
    }
}

private actor PersistedPlanInspectingGit: WorkspaceGitOperating {
    let store: WorkspaceStore
    let checkoutID: UUID
    private(set) var sawCompletePersistedPlan = false

    init(store: WorkspaceStore, checkoutID: UUID) {
        self.store = store
        self.checkoutID = checkoutID
    }

    func prepareBranch(_ operation: WorkspaceFrozenWorktreeOperation) async throws {
        await inspectPersistedPlan()
    }

    func createWorktree(_ operation: WorkspaceFrozenWorktreeOperation) async throws -> String? {
        await inspectPersistedPlan()
        return nil
    }

    private func inspectPersistedPlan() async {
        guard case .loaded(let state) = await store.load(),
              let checkout = state.checkouts.first(where: { $0.id == checkoutID }),
              checkout.operation == .creating,
              checkout.members.count == 1,
              let member = checkout.members.first,
              member.plan?.sourceRepositoryPath == "/repos/a",
              member.plan?.baseCommit == "abc123",
              member.plan?.branchIntent == .create(atCommit: "abc123"),
              member.checkpoint == .branchPreparing
        else { return }
        sawCompletePersistedPlan = true
    }
}

private struct NoopWorkspaceScriptRunner: WorkspaceScriptRunning {
    func runSetup(for operation: WorkspaceCheckoutSetupOperation) async throws {}
}

private actor CapturingWorkspaceScriptRunner: WorkspaceScriptRunning {
    private(set) var recordedScripts: [String] = []

    func runSetup(for operation: WorkspaceCheckoutSetupOperation) async throws {
        recordedScripts.append(operation.script)
    }
}

private actor ConcurrentWorkspaceGit: WorkspaceGitOperating {
    let failingProjectID: String
    private var activePreparations = 0
    private(set) var maximumConcurrentPreparations = 0
    private(set) var createdProjectIDs: [String] = []

    init(failingProjectID: String) { self.failingProjectID = failingProjectID }

    func prepareBranch(_ operation: WorkspaceFrozenWorktreeOperation) async throws {
        activePreparations += 1
        maximumConcurrentPreparations = max(maximumConcurrentPreparations, activePreparations)
        try await Task.sleep(for: .milliseconds(50))
        activePreparations -= 1
        if operation.projectID == failingProjectID { throw TestError.failed }
    }

    func createWorktree(_ operation: WorkspaceFrozenWorktreeOperation) async throws -> String? {
        createdProjectIDs.append(operation.projectID)
        return "lineage-\(operation.projectID)"
    }
}

private enum TestError: Error { case failed }

private actor RecordingManifestWriter: WorkspaceCheckoutManifestWriting {
    private(set) var writeCount = 0
    private var snapshots: [WorkspaceCheckout] = []

    var memberAvailabilities: [[WorkspaceCheckoutMemberAvailability]] {
        snapshots.map { $0.members.map(\.availability) }
    }

    func writeManifest(for checkout: WorkspaceCheckout) async throws {
        writeCount += 1
        snapshots.append(checkout)
    }
}

private struct FailingManifestWriter: WorkspaceCheckoutManifestWriting {
    func writeManifest(for checkout: WorkspaceCheckout) async throws {
        throw TestError.failed
    }
}

private actor ManifestOrderingGit: WorkspaceGitOperating {
    let manifests: RecordingManifestWriter
    private(set) var sawManifestBeforeGit = false

    init(manifests: RecordingManifestWriter) {
        self.manifests = manifests
    }

    func prepareBranch(_ operation: WorkspaceFrozenWorktreeOperation) async throws {
        if await manifests.writeCount > 0 {
            sawManifestBeforeGit = true
        }
    }

    func createWorktree(_ operation: WorkspaceFrozenWorktreeOperation) async throws -> String? {
        if await manifests.writeCount > 0 {
            sawManifestBeforeGit = true
        }
        return "lineage-\(operation.projectID)"
    }
}

private actor PreparedBranchWorkspaceGit: WorkspaceGitOperating {
    private(set) var prepareCount = 0
    private(set) var createCount = 0

    func preparedBranchMatchesFrozenBase(_ operation: WorkspaceFrozenWorktreeOperation) async throws -> Bool { true }

    func prepareBranch(_ operation: WorkspaceFrozenWorktreeOperation) async throws {
        prepareCount += 1
    }

    func createWorktree(_ operation: WorkspaceFrozenWorktreeOperation) async throws -> String? {
        createCount += 1
        return "lineage-\(operation.projectID)"
    }
}

private actor BlockingCleanupLifecycle: WorkspaceCheckoutLifecycleOperating {
    private var started = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func deletePreflight(_ plan: WorkspaceCheckoutCleanupPlan) async throws -> WorktreeDeletePreflight {
        started = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
        if !released {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        return .init(reasons: [], submoduleLocalState: .none)
    }

    func inspectRoot(_ plan: WorkspaceCheckoutCleanupPlan) async -> WorkspaceCheckoutCleanupRootObservation {
        .init(isContained: true, leftovers: [])
    }

    func verifyCleanup(_ plan: WorkspaceCheckoutCleanupPlan) async -> WorkspaceCheckoutMemberObservation {
        .exactLineage(plan.expectedLineageID)
    }

    func removeWorktree(_ plan: WorkspaceCheckoutCleanupPlan, force: Bool) async throws {}
    func deleteMergedBranch(_ plan: WorkspaceCheckoutCleanupPlan) async throws -> Bool { true }

    func waitUntilPreflightStarted() async {
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

private actor SerialIntentWorkspaceGit: WorkspaceGitOperating {
    private var active = 0
    private(set) var maximumConcurrentPreparations = 0
    private(set) var intents: [FrozenBranchIntent] = []

    func prepareBranch(_ operation: WorkspaceFrozenWorktreeOperation) async throws {
        active += 1
        maximumConcurrentPreparations = max(maximumConcurrentPreparations, active)
        intents.append(operation.branchIntent)
        try await Task.sleep(for: .milliseconds(25))
        active -= 1
    }

    func createWorktree(_ operation: WorkspaceFrozenWorktreeOperation) async throws -> String? { nil }
}

private actor CountingWorkspaceGit: WorkspaceGitOperating {
    private(set) var callCount = 0

    func prepareBranch(_ operation: WorkspaceFrozenWorktreeOperation) async throws { callCount += 1 }
    func createWorktree(_ operation: WorkspaceFrozenWorktreeOperation) async throws -> String? { callCount += 1
    return nil }
}

private actor LineageFailureThenRecoveryGit: WorkspaceGitOperating {
    let store: WorkspaceStore
    let checkoutID: UUID
    private(set) var createCount = 0
    private(set) var sawOwnedWorktreeBeforeCreate = false
    private(set) var existingLineageAllowedRecording = false

    init(store: WorkspaceStore, checkoutID: UUID) {
        self.store = store
        self.checkoutID = checkoutID
    }

    func prepareBranch(_ operation: WorkspaceFrozenWorktreeOperation) async throws {}

    func createWorktree(_ operation: WorkspaceFrozenWorktreeOperation) async throws -> String? {
        createCount += 1
        if let checkout = await store.checkout(id: checkoutID),
           let member = checkout.members.first(where: { $0.id == operation.checkoutMemberID }) {
            sawOwnedWorktreeBeforeCreate = member.checkpoint == .worktreeCreating
                && member.cleanupOwnership.worktreeCreated
        }
        throw TestError.failed
    }

    func existingCreatedWorktreeLineage(_ operation: WorkspaceFrozenWorktreeOperation) async throws -> String? {
        existingLineageAllowedRecording = operation.canRecordMissingLineage
        return operation.canRecordMissingLineage ? operation.expectedLineageID : nil
    }
}

private actor BlockingWorkspaceGit: WorkspaceGitOperating {
    private var prepareStarted = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func prepareBranch(_ operation: WorkspaceFrozenWorktreeOperation) async throws {
        prepareStarted = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
        if !released {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
    }

    func createWorktree(_ operation: WorkspaceFrozenWorktreeOperation) async throws -> String? {
        "lineage-\(operation.projectID)"
    }

    func waitUntilPrepareStarted() async {
        if prepareStarted { return }
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
