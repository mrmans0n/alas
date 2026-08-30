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

        #expect(await git.maximumConcurrentPreparations <= 4)
        #expect(await git.createdProjectIDs.count == 4)
        #expect(checkout.members.first?.checkpoint == .failed)
        #expect(checkout.members.dropFirst().allSatisfy { $0.checkpoint == .setupComplete })
        #expect(checkout.members.dropFirst().allSatisfy { $0.gitLineageID == "lineage-\($0.projectID)" })
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

        #expect(await git.maximumConcurrentPreparations == 1)
        #expect(await git.intents == [.create(atCommit: "one"), .reuse(atCommit: "two")])
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
    func createWorktree(_ operation: WorkspaceFrozenWorktreeOperation) async throws -> String? { callCount += 1; return nil }
}
