import Testing
import Foundation
@testable import Alas

private struct PullFixture: Sendable {
    let clone: URL
    let remote: URL
    /// `remote-2`: a commit stored in `remote` (child of `remote-1`, adds
    /// `c.txt`) that no ref points at yet. See `pushRemoteCommit(to:)`.
    let pendingRemoteCommit: String

    func remove() {
        try? FileManager.default.removeItem(at: clone)
        try? FileManager.default.removeItem(at: remote)
    }
}

/// Real bare remote + real clone on `main` tracking `origin/main`, already one
/// commit behind: after the clone was made, `remote-1` landed on the remote's
/// `main` (touching `a.txt` when `conflicting`, which the clone also edited in
/// a local commit; `b.txt` otherwise). The clone has not fetched it, so its
/// `origin/main` still points at `base` exactly as after a throwaway clone's
/// push. Histories are written with `git fast-import` straight into the bare
/// remote instead of a seed clone and a pusher clone.
private enum PullFixtures {
    /// Built once per test process; tests copy it (`makeCloneBehindUpstream`).
    static let fastForwardTemplate = Task { try await build(conflicting: false, prefix: "alas-rpspull-tpl") }

    static func build(conflicting: Bool, prefix: String) async throws -> PullFixture {
        let tmp = FileManager.default.temporaryDirectory
        let remote = tmp.appendingPathComponent("\(prefix)-rmt-\(UUID().uuidString)")
        let clone = tmp.appendingPathComponent("\(prefix)-clone-\(UUID().uuidString)")
        func data(_ text: String) -> String { "data \(text.utf8.count)\n\(text)\n" }
        let now = Int(Date().timeIntervalSince1970)

        try await checkedGit(["init", "--bare", "-q", "-b", "main", remote.path], cwd: nil)
        try await checkedGit(
            ["--git-dir", remote.path, "fast-import", "--quiet", "--done"],
            cwd: nil,
            stdin: "commit refs/heads/main\ncommitter s <s@e> \(now - 3) +0000\n" + data("base\n")
                + "M 100644 inline a.txt\n" + data("base\n") + "done\n"
        )

        try await checkedGit(["clone", "-q", remote.path, clone.path], cwd: nil)
        try await checkedGit(["config", "user.email", "c@e"], cwd: clone)
        try await checkedGit(["config", "user.name", "c"], cwd: clone)
        try await checkedGit(["config", "commit.gpgsign", "false"], cwd: clone)
        if conflicting {
            try "local change\n".write(to: clone.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            try await checkedGit(["commit", "-q", "-am", "local edit"], cwd: clone)
        }

        // Written after the clone, so the clone never sees these objects
        // until it fetches. `remote-2` goes to a scratch ref that is deleted
        // right away; its objects stay in the remote for `pushRemoteCommit`.
        let pushFile = conflicting ? "a.txt" : "b.txt"
        try await checkedGit(
            ["--git-dir", remote.path, "fast-import", "--quiet", "--done"],
            cwd: nil,
            stdin: "commit refs/heads/main\nmark :1\ncommitter x <x@e> \(now - 2) +0000\n" + data("remote-1\n")
                + "from refs/heads/main^0\nM 100644 inline \(pushFile)\n" + data("remote change\n")
                + "commit refs/alas-test/remote-2\ncommitter x <x@e> \(now - 1) +0000\n" + data("remote-2\n")
                + "from :1\nM 100644 inline c.txt\n" + data("remote change\n") + "done\n"
        )
        let pending = try await checkedGit(["--git-dir", remote.path, "rev-parse", "refs/alas-test/remote-2"], cwd: nil)
        try await checkedGit(["--git-dir", remote.path, "update-ref", "-d", "refs/alas-test/remote-2"], cwd: nil)
        return PullFixture(clone: clone, remote: remote, pendingRemoteCommit: pending)
    }

    @discardableResult
    static func checkedGit(_ args: [String], cwd: URL?, stdin: String? = nil) async throws -> String {
        let result = try await Process.git(args, cwd: cwd, stdin: stdin)
        guard result.exitCode == 0 else { throw ProcessError.nonZeroExit(result.exitCode, result.stderr) }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

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
            lastActivity: Date(),
            lineageID: WorktreeService.localLineageID(forWorktreeAt: path)
        )
    }

    /// Fresh copy of the shared non-conflicting fixture (see
    /// `PullFixtures`): two directory copies plus two git calls instead of
    /// rebuilding the three-clone push history for every test.
    private func makeCloneBehindUpstream() async throws -> PullFixture {
        let template = try await PullFixtures.fastForwardTemplate.value
        let copy = PullFixture(
            clone: FileManager.default.temporaryDirectory
                .appendingPathComponent("alas-rpspull-clone-\(UUID().uuidString)"),
            remote: FileManager.default.temporaryDirectory
                .appendingPathComponent("alas-rpspull-rmt-\(UUID().uuidString)"),
            pendingRemoteCommit: template.pendingRemoteCommit
        )
        try FileManager.default.copyItem(at: template.clone, to: copy.clone)
        try FileManager.default.copyItem(at: template.remote, to: copy.remote)
        _ = try await PullFixtures.checkedGit(["remote", "set-url", "origin", copy.remote.path], cwd: copy.clone)
        // Copying rewrites every stat field the index cached for `a.txt`.
        _ = try await PullFixtures.checkedGit(["update-index", "-q", "--refresh"], cwd: copy.clone)
        return copy
    }

    /// Someone else pushes `remote-2`: the remote's `main` advances by one
    /// commit the clone has not fetched. The commit object was written into
    /// the remote when the fixture was built, so this is the same ref update
    /// a push performs on the receiving side, without a throwaway clone.
    private func pushRemoteCommit(to fixture: PullFixture) async throws {
        _ = try await PullFixtures.checkedGit(
            ["--git-dir", fixture.remote.path, "update-ref", "refs/heads/main", fixture.pendingRemoteCommit],
            cwd: nil
        )
    }

    /// Polls `condition` on the main actor up to ~5s, returning as soon as it
    /// holds. Avoids fixed sleeps that flake under load; the fine 10ms step
    /// keeps the detection latency negligible.
    private func wait(until condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
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
        let fixture = try await makeCloneBehindUpstream()
        defer { fixture.remove() }
        let clone = fixture.clone
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
        // Single use, so built directly rather than from a shared template.
        let fixture = try await PullFixtures.build(conflicting: true, prefix: "alas-rpspull-conflict")
        defer { fixture.remove() }
        let state = RightPaneState(worktree: makeWorktree(at: fixture.clone, branch: "main"), baseBranch: "main")
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
        let fixture = try await makeCloneBehindUpstream()
        defer { fixture.remove() }
        let state = RightPaneState(worktree: makeWorktree(at: fixture.clone, branch: "main"), baseBranch: "main")
        await state.refreshSyncStatus()
        #expect(state.behindUpstream?.count == 1)

        try await pushRemoteCommit(to: fixture)

        // Non-forced: throttle skips the fetch, so the stale ref still reads 1.
        await state.refreshSyncStatus()
        #expect(state.behindUpstream?.count == 1)

        // Forced: fetches now, sees the upstream commit → behind by 2.
        await state.refreshSyncStatus(force: true)
        #expect(state.behindUpstream?.count == 2)
    }

    @Test func refreshThrottleSurvivesClearedBehindState() async throws {
        let fixture = try await makeCloneBehindUpstream()
        defer { fixture.remove() }
        let state = RightPaneState(worktree: makeWorktree(at: fixture.clone, branch: "main"), baseBranch: "main")

        await state.refreshSyncStatus()
        #expect(state.behindUpstream?.count == 1)

        state.behindBase = nil
        state.behindUpstream = nil
        try await pushRemoteCommit(to: fixture)

        await state.refreshSyncStatus()
        #expect(state.behindUpstream?.count == 1)

        await state.refreshSyncStatus(force: true)
        #expect(state.behindUpstream?.count == 2)
    }
}
