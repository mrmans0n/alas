import Foundation
import Testing
@testable import Alas

@Suite("Workspace checkout local integration")
struct WorkspaceCheckoutLocalIntegrationTests {
    @Test func createsTwoRepositoryMembersWithOneSharedBranchUnderOneRoot() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-local-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let first = try await makeRepository(at: temporary.appendingPathComponent("first"))
        let second = try await makeRepository(at: temporary.appendingPathComponent("second"))
        let root = temporary.appendingPathComponent("checkouts").path
        let members = [
            WorkspaceMember(projectID: "first", fallbackProjectName: "First", fallbackRepositoryRoot: first.path),
            WorkspaceMember(projectID: "second", fallbackProjectName: "Second", fallbackRepositoryRoot: second.path)
        ]
        let workspace = Workspace(name: "Release", executionLocation: .local, members: members)
        let projects = [project(id: "first", path: first.path), project(id: "second", path: second.path)]
        let preflight = WorkspaceCheckoutPreflight(projects: projects)

        let result = await preflight.prepare(.init(workspace: workspace, branch: "release/1091", rootPath: root, baseReference: "main"))
        let plan: FrozenWorkspaceCheckoutPlan
        switch result {
        case .success(let frozen): plan = frozen
        case .failure(let diagnostics):
            Issue.record("Expected local plan: \(diagnostics.map(\.message))")
            return
        }
        let store = WorkspaceStore(url: temporary.appendingPathComponent("workspaces.json"))
        let coordinator = WorkspaceCheckoutCoordinator(store: store, scripts: EmptyWorkspaceSetup())
        let checkout = try await coordinator.create(workspace: workspace, plan: plan)
        await coordinator.awaitCreationCompletion(checkoutID: checkout.id)
        guard let completedCheckout = await store.checkout(id: checkout.id) else {
            Issue.record("Expected persisted checkout after creation")
            return
        }

        #expect(completedCheckout.members.allSatisfy { $0.availability == .available })
        #expect(completedCheckout.members.map(\.worktreePath) == ["\(root)/first", "\(root)/second"])
        let manifestURL = URL(fileURLWithPath: root).appendingPathComponent(WorkspaceCheckoutManifest.fileName)
        let manifest = try JSONDecoder().decode(WorkspaceCheckoutManifest.self, from: Data(contentsOf: manifestURL))
        #expect(manifest.checkoutID == checkout.id)
        #expect(manifest.branch == "release/1091")
        #expect(manifest.members.map(\.path) == completedCheckout.members.map(\.worktreePath))
        for member in completedCheckout.members {
            let branch = try await Process.git(["branch", "--show-current"], cwd: URL(fileURLWithPath: member.worktreePath))
            #expect(branch.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "release/1091")
        }
    }

    private func makeRepository(at url: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: url)
        _ = try await Process.git(["config", "user.email", "workspace@example.com"], cwd: url)
        _ = try await Process.git(["config", "user.name", "Workspace"], cwd: url)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "initial"], cwd: url)
        return url
    }

    private func project(id: String, path: String) -> ProjectConfig {
        .init(id: id, name: id, path: path, color: "blue", addedAt: .distantPast)
    }
}

private struct EmptyWorkspaceSetup: WorkspaceScriptRunning {
    func runSetup(for operation: WorkspaceCheckoutSetupOperation) async throws {}
}
