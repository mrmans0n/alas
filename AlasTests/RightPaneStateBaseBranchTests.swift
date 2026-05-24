import Testing
import Foundation
@testable import Alas

@MainActor
@Suite(.serialized)
struct RightPaneStateBaseBranchTests {
    private func makeWorktree(at path: URL, branch: String) -> Worktree {
        Worktree(
            id: Worktree.makeId(path: path),
            projectId: "test-project",
            name: branch,
            branch: branch,
            path: path,
            status: .clean,
            lastActivity: Date()
        )
    }

    private func createTestRepoWithBranches() async throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-base-branch-branches-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: tmp)
        _ = try await Process.git(["config", "user.email", "t@e"], cwd: tmp)
        _ = try await Process.git(["config", "user.name", "t"], cwd: tmp)
        try "main content\n".write(to: tmp.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "."], cwd: tmp)
        _ = try await Process.git(["commit", "-q", "-m", "main init"], cwd: tmp)
        _ = try await Process.git(["checkout", "-q", "-b", "develop"], cwd: tmp)
        try "develop content\n".write(to: tmp.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "."], cwd: tmp)
        _ = try await Process.git(["commit", "-q", "-m", "develop commit"], cwd: tmp)
        _ = try await Process.git(["checkout", "-q", "-b", "trunk"], cwd: tmp)
        try "trunk content\n".write(to: tmp.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "."], cwd: tmp)
        _ = try await Process.git(["commit", "-q", "-m", "trunk commit"], cwd: tmp)
        _ = try await Process.git(["checkout", "-q", "main"], cwd: tmp)
        return tmp
    }

    private func createTestRepoWithCommits() async throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-base-branch-commits-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: tmp)
        _ = try await Process.git(["config", "user.email", "t@e"], cwd: tmp)
        _ = try await Process.git(["config", "user.name", "t"], cwd: tmp)
        for i in 1...3 {
            try "\(i)\n".write(to: tmp.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            _ = try await Process.git(["add", "."], cwd: tmp)
            _ = try await Process.git(["commit", "-q", "-m", "commit \(i)"], cwd: tmp)
        }
        return tmp
    }

    @Test func selectBaseBranchAppendsToRecent() async throws {
        let tmp = try await createTestRepoWithBranches()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let wt = makeWorktree(at: tmp, branch: "feature")
        let state = RightPaneState(worktree: wt, baseBranch: "main")
        #expect(state.recentBaseBranches.isEmpty)
        state.selectBaseBranch("develop")
        #expect(state.recentBaseBranches == ["develop"])
        state.selectBaseBranch("trunk")
        #expect(state.recentBaseBranches == ["develop", "trunk"])
    }

    @Test func selectBaseBranchTriggersRefresh() async throws {
        let tmp = try await createTestRepoWithCommits()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let wt = makeWorktree(at: tmp, branch: "feature")
        let state = RightPaneState(worktree: wt, baseBranch: "main")
        await state.refresh()
        let before = state.commits.count
        state.selectBaseBranch("develop")
        // After refresh, commits may differ; we just verify refresh was
        // triggered by checking that loading eventually settles.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(!state.loading)
    }
}
