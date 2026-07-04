import Testing
import Foundation
@testable import Alas

@MainActor
@Suite(.serialized)
struct RightPaneStoreBaseBranchTests {
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

    private func makeRepoOnMain() async throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-basebranch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: tmp)
        _ = try await Process.git(["config", "user.email", "t@e.com"], cwd: tmp)
        _ = try await Process.git(["config", "user.name", "t"], cwd: tmp)
        try "1\n".write(to: tmp.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "."], cwd: tmp)
        _ = try await Process.git(["commit", "-q", "-m", "feat: initial"], cwd: tmp)
        return tmp
    }

    @Test func effectiveBaseBranchSwitchesToOriginWhenOnBase() {
        let wt = makeWorktree(at: URL(fileURLWithPath: "/tmp/main"), branch: "main")
        #expect(RightPaneStore.effectiveBaseBranch(worktree: wt, baseBranch: "main") == "origin/main")
    }

    @Test func effectiveBaseBranchKeepsBaseWhenOnDifferentBranch() {
        let wt = makeWorktree(at: URL(fileURLWithPath: "/tmp/feature"), branch: "feature/x")
        #expect(RightPaneStore.effectiveBaseBranch(worktree: wt, baseBranch: "main") == "main")
    }

    @Test func effectiveBaseBranchIsNoOpForEmptyBaseBranch() {
        let wt = makeWorktree(at: URL(fileURLWithPath: "/tmp/empty"), branch: "main")
        #expect(RightPaneStore.effectiveBaseBranch(worktree: wt, baseBranch: "").isEmpty)
    }

    @Test func effectiveBaseBranchRespectsRemoteQualifiedBase() {
        let wt = makeWorktree(at: URL(fileURLWithPath: "/tmp/upstream"), branch: "upstream/main")
        #expect(RightPaneStore.effectiveBaseBranch(worktree: wt, baseBranch: "upstream/main") == "origin/upstream/main")
    }

    @Test func asyncProbeConfirmsOriginMainWhenRefExists() async throws {
        let repo = try await makeRepoOnMain()
        defer { try? FileManager.default.removeItem(at: repo) }

        let head = try await Process.git(["rev-parse", "HEAD"], cwd: repo).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await Process.git(["update-ref", "refs/remotes/origin/main", head], cwd: repo)

        let store = RightPaneStore(git: GitService())
        let state = store.state(for: makeWorktree(at: repo, branch: "main"), baseBranch: "main", trackUpstreamForCommits: false)
        #expect(state.baseBranch == "origin/main")

        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(state.baseBranch == "origin/main")
    }

    @Test func asyncProbeFallsBackWhenOriginMainMissing() async throws {
        let repo = try await makeRepoOnMain()
        defer { try? FileManager.default.removeItem(at: repo) }

        let store = RightPaneStore(git: GitService())
        let state = store.state(for: makeWorktree(at: repo, branch: "main"), baseBranch: "main", trackUpstreamForCommits: false)
        #expect(state.baseBranch == "origin/main")

        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(state.baseBranch == "main")
    }

    @Test func asyncProbeDoesNotOverrideUserSelection() async throws {
        let repo = try await makeRepoOnMain()
        defer { try? FileManager.default.removeItem(at: repo) }

        let head = try await Process.git(["rev-parse", "HEAD"], cwd: repo).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await Process.git(["update-ref", "refs/remotes/origin/main", head], cwd: repo)
        _ = try await Process.git(["branch", "develop"], cwd: repo)

        let store = RightPaneStore(git: GitService())
        let state = store.state(for: makeWorktree(at: repo, branch: "main"), baseBranch: "main", trackUpstreamForCommits: false)
        #expect(state.baseBranch == "origin/main")

        state.selectBaseBranch("develop")
        #expect(state.userOverrodeBaseBranch)

        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(state.baseBranch == "develop")
    }
}
