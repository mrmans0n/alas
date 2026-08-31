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

    @Test func deletingAMemberPersistsTheFrozenCleanupPlanBeforeRemovingTheWorktree() async throws {
        let fixture = try await Fixture.make()
        let lifecycle = PersistedCleanupLifecycle(store: fixture.store, checkoutID: fixture.checkout.id)
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: FixtureGit(), scripts: FixtureScripts(), sessions: LifecycleSessions(), lifecycle: lifecycle)

        let checkout = try await coordinator.deleteMember(checkoutID: fixture.checkout.id, memberID: fixture.member.id)

        #expect(await lifecycle.sawPersistedCleanupPlan)
        #expect(checkout.members[0].availability == .explicitlyDeleted)
        #expect(checkout.members[0].cleanup?.worktreeRemoved == true)
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
        let lifecycle = FixtureLifecycle(preflight: .init(reasons: [.dirty], submoduleLocalState: .none))
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: FixtureGit(), scripts: FixtureScripts(), sessions: LifecycleSessions(), lifecycle: lifecycle)

        await #expect(throws: WorkspaceCheckoutCoordinatorError.cleanupConfirmationRequired) {
            try await coordinator.deleteMember(checkoutID: fixture.checkout.id, memberID: fixture.member.id)
        }
        #expect(await lifecycle.removedMembers.isEmpty)
    }

    @Test func confirmedRiskPassesForceToWorktreeRemoval() async throws {
        let fixture = try await Fixture.make()
        let lifecycle = FixtureLifecycle(preflight: .init(reasons: [.dirty], submoduleLocalState: .none))
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: FixtureGit(), scripts: FixtureScripts(), sessions: LifecycleSessions(), lifecycle: lifecycle)

        _ = try await coordinator.deleteMember(checkoutID: fixture.checkout.id, memberID: fixture.member.id, confirmingRisks: true)

        #expect(await lifecycle.removeForces == [true])
    }

    @Test func wholeDeletionContinuesAfterOneMemberFails() async throws {
        let fixture = try await Fixture.make(memberCount: 2)
        let lifecycle = FixtureLifecycle(failingMember: fixture.checkout.members[0].id)
        let coordinator = WorkspaceCheckoutCoordinator(store: fixture.store, git: FixtureGit(), scripts: FixtureScripts(), sessions: LifecycleSessions(), lifecycle: lifecycle)

        let result = try await coordinator.deleteCheckout(checkoutID: fixture.checkout.id)

        #expect(result.members[0].availability == .available)
        #expect(result.members[1].availability == .explicitlyDeleted)
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
            .init(exitCode: 0, stdout: "", stderr: ""),
            .init(exitCode: 1, stdout: "", stderr: "not merged"),
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

        let preflight = try await lifecycle.deletePreflight(plan)
        try await lifecycle.removeWorktree(plan, force: true)
        let branchRemoved = try await lifecycle.deleteMergedBranch(plan)

        #expect(preflight.reasons == [.dirty])
        #expect(branchRemoved == false)
        let commands = await runner.commands.joined(separator: "\n")
        #expect(commands.contains("worktree remove -f --"))
        #expect(commands.contains("branch -d"))
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

private struct FixtureGit: WorkspaceGitOperating {
    func prepareBranch(_ operation: WorkspaceFrozenWorktreeOperation) async throws {}
    func createWorktree(_ operation: WorkspaceFrozenWorktreeOperation) async throws -> String? { nil }
}
private struct FixtureScripts: WorkspaceScriptRunning { func runSetup(for operation: WorkspaceCheckoutSetupOperation) async throws {} }
private actor LifecycleSessions: WorkspaceCheckoutSessionStopping {
    private(set) var stopped: [UUID] = []
    func stopSessions(for checkoutID: UUID) async { stopped.append(checkoutID) }
}
private actor FixtureLifecycle: WorkspaceCheckoutLifecycleOperating {
    let verification: WorkspaceCheckoutMemberObservation
    private(set) var removedMembers: [UUID] = []
    private(set) var deletedBranches: [UUID] = []
    private(set) var removeForces: [Bool] = []
    let preflight: WorktreeDeletePreflight
    let leftovers: [String]
    let failingMember: UUID?
    let branchRemoved: Bool
    init(verification: WorkspaceCheckoutMemberObservation = .exactLineage("lineage-a"), preflight: WorktreeDeletePreflight = .init(reasons: [], submoduleLocalState: .none), leftovers: [String] = [], failingMember: UUID? = nil, branchRemoved: Bool = true) { self.verification = verification
    self.preflight = preflight
    self.leftovers = leftovers
    self.failingMember = failingMember
    self.branchRemoved = branchRemoved }
    func deletePreflight(_ plan: WorkspaceCheckoutCleanupPlan) async throws -> WorktreeDeletePreflight { preflight }
    func inspectRoot(_ plan: WorkspaceCheckoutCleanupPlan) async -> WorkspaceCheckoutCleanupRootObservation { .init(isContained: true, leftovers: leftovers) }
    func verifyCleanup(_ plan: WorkspaceCheckoutCleanupPlan) async -> WorkspaceCheckoutMemberObservation {
        if verification == .exactLineage("lineage-a") { return .exactLineage(plan.expectedLineageID) }
        return verification
    }
    func removeWorktree(_ plan: WorkspaceCheckoutCleanupPlan, force: Bool) async throws { if failingMember == plan.memberID { throw TestLifecycleError.failed }
    removeForces.append(force)
    removedMembers.append(plan.memberID) }
    func deleteMergedBranch(_ plan: WorkspaceCheckoutCleanupPlan) async throws -> Bool { deletedBranches.append(plan.memberID)
    return branchRemoved }
}
private actor PersistedCleanupLifecycle: WorkspaceCheckoutLifecycleOperating {
    let store: WorkspaceStore
    let checkoutID: UUID
    private(set) var sawPersistedCleanupPlan = false
    init(store: WorkspaceStore, checkoutID: UUID) { self.store = store
    self.checkoutID = checkoutID }
    func deletePreflight(_ plan: WorkspaceCheckoutCleanupPlan) async throws -> WorktreeDeletePreflight { .init(reasons: [], submoduleLocalState: .none) }
    func inspectRoot(_ plan: WorkspaceCheckoutCleanupPlan) async -> WorkspaceCheckoutCleanupRootObservation { .init(isContained: true, leftovers: []) }
    func verifyCleanup(_ plan: WorkspaceCheckoutCleanupPlan) async -> WorkspaceCheckoutMemberObservation { .exactLineage("lineage-a") }
    func removeWorktree(_ plan: WorkspaceCheckoutCleanupPlan, force: Bool) async throws {
        guard case .loaded(let state) = await store.load(),
              state.checkouts.first(where: { $0.id == checkoutID })?.members.first?.cleanup?.plan == plan else { return }
        sawPersistedCleanupPlan = true
    }
    func deleteMergedBranch(_ plan: WorkspaceCheckoutCleanupPlan) async throws -> Bool { true }
}
private enum TestLifecycleError: Error { case failed }

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
