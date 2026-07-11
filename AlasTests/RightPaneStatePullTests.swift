import Testing
import Foundation
@testable import Alas

@MainActor
@Suite(.serialized)
struct RightPaneStatePullTests {
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

    /// Bare remote + clone on `main` tracking `origin/main`, already one
    /// commit behind (a throwaway clone pushed `remote-1`).
    private func makeCloneBehindUpstream(conflicting: Bool) async throws -> (clone: URL, remote: URL) {
        let remote = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-rpspull-rmt-\(UUID().uuidString)")
        let seed = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-rpspull-seed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: seed) }
        _ = try await Process.git(["init", "--bare", "-q", remote.path], cwd: nil)
        _ = try await Process.git(["clone", "-q", remote.path, seed.path], cwd: nil)
        _ = try await Process.git(["config", "user.email", "s@e"], cwd: seed)
        _ = try await Process.git(["config", "user.name", "s"], cwd: seed)
        _ = try await Process.git(["config", "commit.gpgsign", "false"], cwd: seed)
        _ = try await Process.git(["checkout", "-q", "-b", "main"], cwd: seed)
        try "base\n".write(to: seed.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "a.txt"], cwd: seed)
        _ = try await Process.git(["commit", "-q", "-m", "base"], cwd: seed)
        _ = try await Process.git(["push", "-q", "-u", "origin", "main"], cwd: seed)
        _ = try await Process.git(["--git-dir", remote.path, "symbolic-ref", "HEAD", "refs/heads/main"], cwd: nil)

        let clone = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-rpspull-clone-\(UUID().uuidString)")
        _ = try await Process.git(["clone", "-q", remote.path, clone.path], cwd: nil)
        _ = try await Process.git(["config", "user.email", "c@e"], cwd: clone)
        _ = try await Process.git(["config", "user.name", "c"], cwd: clone)
        _ = try await Process.git(["config", "commit.gpgsign", "false"], cwd: clone)

        if conflicting {
            try "local change\n".write(to: clone.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            _ = try await Process.git(["commit", "-q", "-am", "local edit"], cwd: clone)
        }

        // Throwaway clone pushes a commit to origin/main.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-rpspull-push-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = try await Process.git(["clone", "-q", remote.path, tmp.path], cwd: nil)
        _ = try await Process.git(["config", "user.email", "x@e"], cwd: tmp)
        _ = try await Process.git(["config", "user.name", "x"], cwd: tmp)
        _ = try await Process.git(["config", "commit.gpgsign", "false"], cwd: tmp)
        let pushFile = conflicting ? "a.txt" : "b.txt"
        try "remote change\n".write(to: tmp.appendingPathComponent(pushFile), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", pushFile], cwd: tmp)
        _ = try await Process.git(["commit", "-q", "-m", "remote-1"], cwd: tmp)
        _ = try await Process.git(["push", "-q", "origin", "main"], cwd: tmp)

        return (clone, remote)
    }

    private func pushRemoteCommit(to remote: URL, fileName: String, message: String) async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-rpspull-push-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = try await Process.git(["clone", "-q", remote.path, tmp.path], cwd: nil)
        _ = try await Process.git(["config", "user.email", "x@e"], cwd: tmp)
        _ = try await Process.git(["config", "user.name", "x"], cwd: tmp)
        _ = try await Process.git(["config", "commit.gpgsign", "false"], cwd: tmp)
        try "remote change\n".write(to: tmp.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", fileName], cwd: tmp)
        _ = try await Process.git(["commit", "-q", "-m", message], cwd: tmp)
        _ = try await Process.git(["push", "-q", "origin", "main"], cwd: tmp)
    }

    /// Polls `condition` on the main actor up to ~5s, returning as soon as it
    /// holds. Avoids fixed sleeps that flake under load.
    private func wait(until condition: () -> Bool) async throws {
        for _ in 0..<50 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    @Test func pullNoOpsWhenNoUpstream() async throws {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-rpspull-nu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        _ = try await Process.git(["init", "-q", "-b", "feature"], cwd: repo)
        _ = try await Process.git(["config", "user.email", "t@e"], cwd: repo)
        _ = try await Process.git(["config", "user.name", "t"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "x"], cwd: repo)

        let state = RightPaneState(worktree: makeWorktree(at: repo, branch: "feature"), baseBranch: "main")
        // Probe sync status first so behindUpstream is nil *because the branch
        // has no upstream*, not merely because it was never fetched.
        await state.refreshSyncStatus()
        #expect(state.behindUpstream == nil)
        state.pull()
        #expect(state.pullInFlight == false)
    }

    @Test func pullFastForwardsAndClearsInFlight() async throws {
        let (clone, remote) = try await makeCloneBehindUpstream(conflicting: false)
        defer {
            try? FileManager.default.removeItem(at: clone)
            try? FileManager.default.removeItem(at: remote)
        }
        let state = RightPaneState(worktree: makeWorktree(at: clone, branch: "main"), baseBranch: "main")
        await state.refresh()
        try await wait { state.behindUpstream?.count == 1 }
        #expect(state.behindUpstream?.count == 1)

        state.pull()
        try await wait { !state.pullInFlight }

        let head = try await Process.git(["rev-parse", "HEAD"], cwd: clone).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let upstream = try await Process.git(["rev-parse", "origin/main"], cwd: clone).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(head == upstream)
        #expect(state.pullInFlight == false)
        #expect(state.mergeOp.current == nil)
    }

    @Test func pullRoutesConflictIntoMergeOp() async throws {
        let (clone, remote) = try await makeCloneBehindUpstream(conflicting: true)
        defer {
            try? FileManager.default.removeItem(at: clone)
            try? FileManager.default.removeItem(at: remote)
        }
        let state = RightPaneState(worktree: makeWorktree(at: clone, branch: "main"), baseBranch: "main")
        await state.refresh()
        try await wait { state.behindUpstream?.count == 1 }

        state.pull()
        try await wait { !state.pullInFlight }

        #expect(state.pullInFlight == false)
        guard case .rebase = state.mergeOp.current else {
            Issue.record("expected rebase-in-progress, got \(String(describing: state.mergeOp.current))")
            return
        }
    }

    @Test func forcedRefreshBypassesThrottleAndUpdatesBehindUpstream() async throws {
        let (clone, remote) = try await makeCloneBehindUpstream(conflicting: false)
        defer {
            try? FileManager.default.removeItem(at: clone)
            try? FileManager.default.removeItem(at: remote)
        }
        let state = RightPaneState(worktree: makeWorktree(at: clone, branch: "main"), baseBranch: "main")
        await state.refreshSyncStatus()
        #expect(state.behindUpstream?.count == 1)

        try await pushRemoteCommit(to: remote, fileName: "c.txt", message: "remote-2")

        // Non-forced: throttle skips the fetch, so the stale ref still reads 1.
        await state.refreshSyncStatus()
        #expect(state.behindUpstream?.count == 1)

        // Forced: fetches now, sees the upstream commit → behind by 2.
        await state.refreshSyncStatus(force: true)
        #expect(state.behindUpstream?.count == 2)
    }

    @Test func refreshThrottleSurvivesClearedBehindState() async throws {
        let (clone, remote) = try await makeCloneBehindUpstream(conflicting: false)
        defer {
            try? FileManager.default.removeItem(at: clone)
            try? FileManager.default.removeItem(at: remote)
        }
        let state = RightPaneState(worktree: makeWorktree(at: clone, branch: "main"), baseBranch: "main")

        await state.refreshSyncStatus()
        #expect(state.behindUpstream?.count == 1)

        state.behindBase = nil
        state.behindUpstream = nil
        try await pushRemoteCommit(to: remote, fileName: "d.txt", message: "remote-2")

        await state.refreshSyncStatus()
        #expect(state.behindUpstream?.count == 1)

        await state.refreshSyncStatus(force: true)
        #expect(state.behindUpstream?.count == 2)
    }
}
