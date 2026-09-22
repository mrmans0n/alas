import Foundation
import Testing
@testable import Alas

/// The plain worktree-delete path (CLI and, by extension, the sidebar's
/// single-item delete) must never remove a worktree an active Workspace
/// checkout still owns — that is exactly the state that left the user with
/// a broken checkout row and no clue where to fix it. Deletion belongs to
/// the checkout lifecycle instead. An archived or Former Workspace checkout
/// no longer manages the worktree's lifecycle, so it must not be refused.
///
/// These tests also cover the archived-checkout corner of the checkout
/// deletion/forget flow itself: the coordinator refuses to mutate an
/// archived checkout at all, so every entry point a user can reach for
/// "delete" or "forget" must unarchive first rather than dead-end.
@MainActor
@Suite(.serialized)
struct WorkspaceOwnedWorktreeDeletionGuardTests {
    @Test func cliDeleteRefusesAWorktreeOwnedByAnActiveWorkspaceCheckout() async throws {
        let fixture = try await Fixture.make(suffix: "cli-guard")
        defer { fixture.removeFiles() }

        let response = await fixture.state.cliDeleteWorktree(fixture.worktree, force: true, keepBranch: true)

        guard case .error(let message) = response else {
            Issue.record("Expected a refusal, got \(response)")
            return
        }
        #expect(message.localizedCaseInsensitiveContains("workspace"))
        #expect(fixture.state.projectsManager.worktrees(projectId: fixture.project.id).contains { $0.id == fixture.worktree.id })
    }

    @Test func cliDeleteAllowsAWorktreeNoCheckoutClaimsOwnershipOf() async throws {
        let fixture = try await Fixture.make(suffix: "cli-guard-unowned", includesCheckout: false)
        defer { fixture.removeFiles() }

        let response = await fixture.state.cliDeleteWorktree(fixture.worktree, force: true, keepBranch: true)

        #expect(response == .ok)
    }

    @Test func cliDeleteAllowsAWorktreeOwnedOnlyByAnArchivedWorkspaceCheckout() async throws {
        let fixture = try await Fixture.make(suffix: "cli-guard-archived", checkoutArchived: true)
        defer { fixture.removeFiles() }

        let response = await fixture.state.cliDeleteWorktree(fixture.worktree, force: true, keepBranch: true)

        #expect(response == .ok)
    }

    @Test func deleteAndForgetUnarchivesAnArchivedCheckoutInsteadOfRefusingIt() async throws {
        let fixture = try await Fixture.make(suffix: "delete-archived", checkoutArchived: true)
        defer { fixture.removeFiles() }
        let checkoutID = try #require(fixture.checkoutID)

        let outcome = try await fixture.state.deleteAndForgetWorkspaceCheckout(id: checkoutID)

        #expect(outcome == .forgotten)
        #expect(fixture.state.workspacesManager.checkout(id: checkoutID) == nil)
    }

    @Test func workspaceCheckoutDeletionConfirmationUnarchivesBeforeComputingRisks() async throws {
        let fixture = try await Fixture.make(suffix: "confirm-archived", checkoutArchived: true)
        defer { fixture.removeFiles() }
        let checkoutID = try #require(fixture.checkoutID)

        let confirmation = try await fixture.state.workspaceCheckoutDeletionConfirmation(checkoutID: checkoutID)

        #expect(confirmation.requiresConfirmation == false)
        #expect(fixture.state.workspacesManager.checkout(id: checkoutID)?.archivedAt == nil)
    }

    @Test func forgetUnarchivesAFullyDeletedArchivedCheckoutInsteadOfRefusingIt() async throws {
        // A checkout with no members left behaves like one whose deletion
        // already fully completed while it was still active; it was then
        // archived, which the coordinator otherwise refuses to mutate
        // further without an explicit unarchive.
        let fixture = try await Fixture.make(suffix: "forget-archived", includesCheckout: false)
        defer { fixture.removeFiles() }
        let checkoutID = UUID()
        let checkout = WorkspaceCheckout(
            id: checkoutID,
            workspaceID: nil,
            fallbackWorkspaceName: "Release",
            executionLocation: .local,
            branch: "feature/forget-archived",
            rootPath: fixture.checkoutRoot.path,
            archivedAt: .now,
            members: []
        )
        try await fixture.workspaceStore.checkpoint(.init(checkouts: [checkout]))
        await fixture.state.workspacesManager.refreshCheckoutSnapshots()

        try await fixture.state.forgetWorkspaceCheckout(id: checkoutID)

        #expect(fixture.state.workspacesManager.checkout(id: checkoutID) == nil)
    }

    @MainActor
    private struct Fixture {
        let state: AppState
        let workspaceStore: WorkspaceStore
        let project: ProjectConfig
        let worktree: Worktree
        let repo: URL
        let linked: URL
        let checkoutRoot: URL
        let workspaceURL: URL
        let checkoutID: UUID?

        func removeFiles() {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: checkoutRoot)
            try? FileManager.default.removeItem(at: workspaceURL)
        }

        static func make(
            suffix: String,
            includesCheckout: Bool = true,
            checkoutArchived: Bool = false
        ) async throws -> Fixture {
            let repo = FileManager.default.temporaryDirectory.appendingPathComponent("alas-\(suffix)-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            _ = try await Process.git(["init", "-q", "-b", "main"], cwd: repo)
            _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "init"], cwd: repo)
            let head = try await Process.git(["rev-parse", "HEAD"], cwd: repo)
                .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            // A dedicated root, not the shared temp directory: root cleanup
            // inspects every entry under `rootPath` that isn't a managed
            // member, and the shared temp directory is full of unrelated
            // files from concurrent tests.
            let checkoutRoot = FileManager.default.temporaryDirectory.appendingPathComponent("alas-\(suffix)-root-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: checkoutRoot, withIntermediateDirectories: true)
            let linked = checkoutRoot.appendingPathComponent("member")
            let workspaceURL = FileManager.default.temporaryDirectory.appendingPathComponent("alas-\(suffix)-workspace-\(UUID().uuidString).json")

            let workspaceStore = WorkspaceStore(url: workspaceURL)
            let state = AppState(workspaceStore: workspaceStore)
            state.config.workspacesEnabled = true
            _ = await state.workspacesManager.setEnabled(true, spacesFile: SpacesFile(activeSpaceId: "space", spaces: [
                SpaceConfig(id: "space", name: "Default", emoji: "folder", projectIds: [], lastSelectedWorktreeId: nil, createdAt: .distantPast),
            ]))
            let project = try await state.projectsManager.addProject(path: repo, displayName: suffix, color: "#5fb7c4")
            let worktree = try await WorktreeService().add(
                repoPath: repo, base: "main", branch: "feature/\(suffix)", destination: linked, projectId: project.id
            )
            try await state.projectsManager.refreshWorktrees(projectId: project.id)

            var checkoutID: UUID?
            if includesCheckout {
                let memberID = UUID()
                let checkout = WorkspaceCheckout(
                    workspaceID: UUID(),
                    fallbackWorkspaceName: "Release",
                    executionLocation: .local,
                    branch: worktree.branch,
                    rootPath: linked.deletingLastPathComponent().path,
                    archivedAt: checkoutArchived ? .now : nil,
                    members: [
                        WorkspaceCheckoutMember(
                            id: memberID,
                            workspaceMemberID: UUID(),
                            projectID: project.id,
                            fallbackProjectName: "Release",
                            fallbackRepositoryRoot: repo.path,
                            worktreePath: linked.path,
                            gitLineageID: WorktreeService.existingLocalLineageID(forWorktreeAt: linked),
                            availability: .available,
                            checkpoint: .setupComplete,
                            cleanupOwnership: .init(worktreeCreated: true, branchOwnership: .reused),
                            plan: .init(
                                checkoutMemberID: memberID,
                                projectID: project.id,
                                sourceRepositoryPath: repo.path,
                                destinationPath: linked.path,
                                baseReference: "main",
                                baseCommit: head,
                                branchIntent: .reuse
                            )
                        ),
                    ]
                )
                try await workspaceStore.checkpoint(.init(checkouts: [checkout]))
                await state.workspacesManager.refreshCheckoutSnapshots()
                checkoutID = checkout.id
            }

            return Fixture(state: state, workspaceStore: workspaceStore, project: project, worktree: worktree, repo: repo, linked: linked, checkoutRoot: checkoutRoot, workspaceURL: workspaceURL, checkoutID: checkoutID)
        }
    }
}
