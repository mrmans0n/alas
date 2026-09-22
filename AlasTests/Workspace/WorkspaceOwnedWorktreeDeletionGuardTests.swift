import Foundation
import Testing
@testable import Alas

/// The plain worktree-delete path (CLI and, by extension, the sidebar's
/// single-item delete) must never remove a worktree a Workspace checkout
/// still owns — that is exactly the state that left the user with a broken
/// checkout row and no clue where to fix it. Deletion belongs to the
/// checkout lifecycle instead.
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

    @MainActor
    private struct Fixture {
        let state: AppState
        let project: ProjectConfig
        let worktree: Worktree
        let repo: URL
        let linked: URL
        let workspaceURL: URL

        func removeFiles() {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: linked)
            try? FileManager.default.removeItem(at: workspaceURL)
        }

        static func make(
            suffix: String,
            includesCheckout: Bool = true
        ) async throws -> Fixture {
            let repo = FileManager.default.temporaryDirectory.appendingPathComponent("alas-\(suffix)-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            _ = try await Process.git(["init", "-q", "-b", "main"], cwd: repo)
            _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "init"], cwd: repo)
            let linked = repo.deletingLastPathComponent().appendingPathComponent("\(suffix)-linked-\(UUID().uuidString)")
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

            if includesCheckout {
                let memberID = UUID()
                let checkout = WorkspaceCheckout(
                    workspaceID: UUID(),
                    fallbackWorkspaceName: "Release",
                    executionLocation: .local,
                    branch: worktree.branch,
                    rootPath: linked.deletingLastPathComponent().path,
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
                            checkpoint: .setupComplete
                        ),
                    ]
                )
                try await workspaceStore.checkpoint(.init(checkouts: [checkout]))
                await state.workspacesManager.refreshCheckoutSnapshots()
            }

            return Fixture(state: state, project: project, worktree: worktree, repo: repo, linked: linked, workspaceURL: workspaceURL)
        }
    }
}
