import Testing
import Foundation
@testable import Alas

struct WorktreeServiceTests {
    private func makeRepo() async throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-wt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: dir)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "init"], cwd: dir)
        return dir
    }

    @Test func listFindsMain() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let svc = WorktreeService()
        let trees = try await svc.list(repoPath: repo, projectId: "p")
        #expect(trees.count == 1)
        #expect(trees.first?.branch == "main")
    }

    @Test func addCreatesWorktree() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let dest = repo.deletingLastPathComponent().appendingPathComponent("\(repo.lastPathComponent)-feat")
        defer { try? FileManager.default.removeItem(at: dest) }
        let svc = WorktreeService()
        let wt = try await svc.add(
            repoPath: repo, base: "main", branch: "feat/x",
            destination: dest, projectId: "p"
        )
        #expect(wt.branch == "feat/x")
        #expect(FileManager.default.fileExists(atPath: dest.path))

        let listed = try await svc.list(repoPath: repo, projectId: "p")
        #expect(listed.count == 2)
    }

    @Test func removeDeletesWorktree() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let dest = repo.deletingLastPathComponent().appendingPathComponent("\(repo.lastPathComponent)-rm")
        let svc = WorktreeService()
        _ = try await svc.add(
            repoPath: repo, base: "main", branch: "feat/rm",
            destination: dest, projectId: "p"
        )
        try await svc.remove(repoPath: repo, worktreePath: dest, deleteBranchIfMerged: false)
        let listed = try await svc.list(repoPath: repo, projectId: "p")
        #expect(listed.count == 1)
    }
}
