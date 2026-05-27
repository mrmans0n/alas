import Testing
import Foundation
@testable import Alas

@MainActor
@Suite(.serialized)
struct ProjectsManagerWorktreeOrderingTests {
    private func makeManager(repoPath: String = "/repo") -> (ProjectsManager, ProjectConfig) {
        let project = ProjectConfig(
            id: "p1",
            name: "p1",
            path: repoPath,
            color: "blue",
            addedAt: Date()
        )
        let mgr = ProjectsManager(persistedProjects: [project])
        return (mgr, project)
    }

    private func seed(_ mgr: ProjectsManager, projectId: String, _ wts: [Worktree]) {
        for wt in wts { mgr.insertOptimisticWorktree(wt) }
        for wt in wts { mgr.setOperationState(id: wt.id, state: nil) }
    }

    private func wt(path: String, branch: String, projectId: String = "p1") -> Worktree {
        let url = URL(fileURLWithPath: path)
        return Worktree(
            id: Worktree.makeId(path: url),
            projectId: projectId,
            name: branch,
            branch: branch,
            path: url,
            status: .clean,
            lastActivity: Date()
        )
    }

    // MARK: - main pinned first

    @Test func mainWorktreeIsFirstByDefault() {
        let (mgr, project) = makeManager()
        seed(mgr, projectId: project.id, [
            wt(path: "/repo/wts/feat", branch: "feat/foo"),
            wt(path: "/repo", branch: "main"),
            wt(path: "/repo/wts/fix", branch: "fix/bar"),
        ])

        let trees = mgr.worktrees(projectId: project.id)
        #expect(trees.first?.branch == "main")
    }

    @Test func mainWorktreeIsFirstEvenWithCustomOrder() {
        let main = wt(path: "/repo", branch: "main")
        let feat = wt(path: "/repo/wts/feat", branch: "feat")
        let fix = wt(path: "/repo/wts/fix", branch: "fix")
        let project = ProjectConfig(
            id: "p1",
            name: "p1",
            path: "/repo",
            color: "blue",
            addedAt: Date(),
            worktreeOrder: [feat.id, main.id, fix.id]
        )
        let mgr = ProjectsManager(persistedProjects: [project])
        seed(mgr, projectId: project.id, [feat, main, fix])

        let trees = mgr.worktrees(projectId: project.id)
        #expect(trees.first?.branch == "main")
        // After main, custom order should apply for the remaining worktrees.
        let afterMain = Array(trees.dropFirst())
        #expect(afterMain.map(\.branch) == ["feat", "fix"])
        #expect(mgr.projects[0].worktreeOrder == [feat.id, fix.id])
    }

    @Test func reorderNonMainWorktreesUpdatesOrder() {
        let main = wt(path: "/repo", branch: "main")
        let feat = wt(path: "/repo/wts/feat", branch: "feat")
        let fix = wt(path: "/repo/wts/fix", branch: "fix")
        let project = ProjectConfig(
            id: "p1",
            name: "p1",
            path: "/repo",
            color: "blue",
            addedAt: Date(),
            worktreeOrder: [feat.id, fix.id]
        )
        let mgr = ProjectsManager(persistedProjects: [project])
        seed(mgr, projectId: project.id, [feat, main, fix])

        mgr.reorderWorktree(projectId: project.id, fromIndex: 2, toIndex: 1)

        let trees = mgr.worktrees(projectId: project.id)
        #expect(trees.map(\.branch) == ["main", "fix", "feat"])
        #expect(mgr.projects[0].worktreeOrder == [fix.id, feat.id])
    }

    @Test func reorderRefusesToMoveMainBelowOthers() {
        let main = wt(path: "/repo", branch: "main")
        let feat = wt(path: "/repo/wts/feat", branch: "feat")
        let fix = wt(path: "/repo/wts/fix", branch: "fix")
        let project = ProjectConfig(
            id: "p1",
            name: "p1",
            path: "/repo",
            color: "blue",
            addedAt: Date(),
            worktreeOrder: [feat.id, fix.id]
        )
        let mgr = ProjectsManager(persistedProjects: [project])
        seed(mgr, projectId: project.id, [feat, main, fix])

        mgr.reorderWorktree(projectId: project.id, fromIndex: 0, toIndex: 2)

        let trees = mgr.worktrees(projectId: project.id)
        #expect(trees.map(\.branch) == ["main", "feat", "fix"])
        #expect(mgr.projects[0].worktreeOrder == [feat.id, fix.id])
    }

    @Test func reorderRefusesToMoveOthersAboveMain() {
        let main = wt(path: "/repo", branch: "main")
        let feat = wt(path: "/repo/wts/feat", branch: "feat")
        let fix = wt(path: "/repo/wts/fix", branch: "fix")
        let project = ProjectConfig(
            id: "p1",
            name: "p1",
            path: "/repo",
            color: "blue",
            addedAt: Date(),
            worktreeOrder: [feat.id, fix.id]
        )
        let mgr = ProjectsManager(persistedProjects: [project])
        seed(mgr, projectId: project.id, [feat, main, fix])

        mgr.reorderWorktree(projectId: project.id, fromIndex: 2, toIndex: 0)

        let trees = mgr.worktrees(projectId: project.id)
        #expect(trees.map(\.branch) == ["main", "fix", "feat"])
        #expect(mgr.projects[0].worktreeOrder == [fix.id, feat.id])
    }

    // MARK: - refresh reconciliation

    @Test func refreshReconciliationPreservesMainFirst() async throws {
        let (mgr, _) = makeManager()
        let svc = WorktreeService()

        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-wt-order-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: repo) }
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "init"], cwd: repo)

        let projectLive = try await mgr.addProject(path: repo, displayName: "order", color: "blue")
        try await mgr.refreshWorktrees(projectId: projectLive.id)

        let destA = repo.appendingPathComponent("wt-a")
        let destB = repo.appendingPathComponent("wt-b")
        _ = try await svc.add(repoPath: repo, base: "main", branch: "feat-a", destination: destA, projectId: projectLive.id)
        _ = try await svc.add(repoPath: repo, base: "main", branch: "feat-b", destination: destB, projectId: projectLive.id)

        try await mgr.refreshWorktrees(projectId: projectLive.id)
        let trees = mgr.worktrees(projectId: projectLive.id)
        #expect(trees.first?.branch == "main")
    }

    @Test func refreshAppliesPersistedOrderAfterMain() async throws {
        let svc = WorktreeService()
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-wt-order-refresh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: repo) }

        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "init"], cwd: repo)

        let destA = repo.appendingPathComponent("wt-a")
        let destB = repo.appendingPathComponent("wt-b")
        _ = try await svc.add(repoPath: repo, base: "main", branch: "feat-a", destination: destA, projectId: "p1")
        _ = try await svc.add(repoPath: repo, base: "main", branch: "feat-b", destination: destB, projectId: "p1")

        let project = ProjectConfig(
            id: "p1",
            name: "p1",
            path: repo.path,
            color: "blue",
            addedAt: Date(),
            worktreeOrder: [
                Worktree.makeId(path: destB),
                Worktree.makeId(path: repo),
                Worktree.makeId(path: destA),
            ]
        )
        let mgr = ProjectsManager(persistedProjects: [project])

        let changed = try await mgr.refreshWorktrees(projectId: project.id)
        let trees = mgr.worktrees(projectId: project.id)
        #expect(trees.map(\.branch) == ["main", "feat-b", "feat-a"])
        #expect(mgr.projects[0].worktreeOrder == [Worktree.makeId(path: destB), Worktree.makeId(path: destA)])
        #expect(changed)
    }

    @Test func applyHeadUpdatesPreservesMainFirst() {
        let (mgr, project) = makeManager()
        seed(mgr, projectId: project.id, [
            wt(path: "/repo/wts/feat", branch: "feat/foo"),
            wt(path: "/repo", branch: "main"),
        ])

        mgr.applyHeadUpdates(
            projectId: project.id,
            branchByWorktreePath: [URL(fileURLWithPath: "/repo/wts/feat"): "feat/bar"]
        )

        let trees = mgr.worktrees(projectId: project.id)
        #expect(trees.first?.branch == "main")
        #expect(trees.first { $0.path.path == "/repo/wts/feat" }?.branch == "feat/bar")
    }

    // MARK: - visible / archived

    @Test func visibleWorktreesAlsoHaveMainFirst() {
        let main = wt(path: "/repo", branch: "main")
        let feat = wt(path: "/repo/wts/feat", branch: "feat")
        let fix = wt(path: "/repo/wts/fix", branch: "fix")
        let project = ProjectConfig(
            id: "p1",
            name: "p1",
            path: "/repo",
            color: "blue",
            addedAt: Date(),
            worktreeOrder: [feat.id, fix.id]
        )
        let mgr = ProjectsManager(persistedProjects: [project])
        seed(mgr, projectId: project.id, [feat, main, fix])

        #expect(mgr.visibleWorktrees(projectId: project.id).map(\.branch) == ["main", "feat", "fix"])
    }

    @Test func visibleMainWorktreeReturnsUnarchivedMainOnly() {
        let main = wt(path: "/repo", branch: "main")
        let feat = wt(path: "/repo/wts/feat", branch: "feat")
        let project = ProjectConfig(
            id: "p1",
            name: "p1",
            path: "/repo",
            color: "blue",
            addedAt: Date()
        )
        let mgr = ProjectsManager(persistedProjects: [project])
        seed(mgr, projectId: project.id, [feat, main])

        #expect(mgr.visibleMainWorktree(projectId: project.id)?.id == main.id)

        mgr.setWorktreeHidden(projectId: project.id, path: main.path, hidden: true)

        #expect(mgr.visibleMainWorktree(projectId: project.id) == nil)
    }

    @Test func archivedWorktreesAlsoHaveMainFirst() {
        let main = wt(path: "/repo", branch: "main")
        let feat = wt(path: "/repo/wts/feat", branch: "feat")
        let fix = wt(path: "/repo/wts/fix", branch: "fix")
        let project = ProjectConfig(
            id: "p1",
            name: "p1",
            path: "/repo",
            color: "blue",
            addedAt: Date(),
            hiddenWorktreePaths: ["/repo"],
            worktreeOrder: [feat.id, fix.id]
        )
        let mgr = ProjectsManager(persistedProjects: [project])
        seed(mgr, projectId: project.id, [feat, main, fix])

        let archived = mgr.archivedWorktrees(projectId: project.id)
        #expect(archived.first?.branch == "main")
    }

    // MARK: - tolerant decode

    @Test func decodingOlderProjectConfigWithoutWorktreeOrderSuppliesEmptyArray() throws {
        let json = """
        {
          "version": 1,
          "projects": [{
            "id": "abc",
            "name": "alpha",
            "path": "/tmp/alpha",
            "color": "#5fb7c4",
            "addedAt": 0,
            "hiddenWorktreePaths": ["/tmp/alpha/wt"]
          }]
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let file = try decoder.decode(ProjectsFile.self, from: json)
        #expect(file.projects[0].worktreeOrder == [])
    }

    @Test func roundTripPreservesWorktreeOrder() throws {
        let project = ProjectConfig(
            id: "abc", name: "alpha", path: "/tmp/alpha",
            color: "#5fb7c4", addedAt: Date(timeIntervalSince1970: 0),
            worktreeOrder: ["/tmp/alpha/wt-feat", "/tmp/alpha/wt-fix"]
        )
        let file = ProjectsFile(projects: [project])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(file)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(ProjectsFile.self, from: data)
        #expect(decoded.projects[0].worktreeOrder == ["/tmp/alpha/wt-feat", "/tmp/alpha/wt-fix"])
    }
}
