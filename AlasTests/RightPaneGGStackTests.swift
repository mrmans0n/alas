import Foundation
import Testing
@testable import Alas

/// Counts `run(...)` calls so tests can assert `refreshGGStack()` skips the
/// gg CLI when gated closed / not stack-shaped, and dedupes when the commit
/// set is unchanged since the last query.
private final class CountingFakeGGRunner: GGCommandRunning, @unchecked Sendable {
    private(set) var callCount = 0
    let result: ProcessResult

    init(result: ProcessResult) {
        self.result = result
    }

    func run(args: [String], cwd: URL?) async throws -> ProcessResult {
        callCount += 1
        return result
    }
}

/// Always throws, simulating a transient gg/provider failure (e.g. a gh/glab
/// auth hiccup) rather than a real "not a stack" result.
private final class ThrowingFakeGGRunner: GGCommandRunning, @unchecked Sendable {
    private(set) var callCount = 0

    func run(args: [String], cwd: URL?) async throws -> ProcessResult {
        callCount += 1
        throw GGServiceError.commandFailed(stderr: "boom")
    }
}

@MainActor
struct RightPaneGGStackTests {
    private func makeWorktree() -> Worktree {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-gg-stack-\(UUID().uuidString)")
        return Worktree(
            id: Worktree.makeId(path: path),
            projectId: "test-project",
            name: "feature",
            branch: "feature",
            path: path,
            status: .clean,
            lastActivity: Date()
        )
    }

    private func commit(sha: String, stackShaped: Bool) -> CommitInfo {
        CommitInfo(
            sha: sha, shortSha: String(sha.prefix(7)),
            author: "Test", authorInitials: "T", date: Date(),
            subject: "subject",
            body: stackShaped ? "Some detail.\n\nGG-ID: abc123\nGG-Parent: def456" : "Just a plain commit body.",
            conventionalTag: nil,
            filesChanged: 1, insertions: 1, deletions: 0
        )
    }

    /// A real repo with `main` pushed to a bare remote, then a `nacho/stack`
    /// branch carrying one GG-ID-trailered commit — also fully pushed, so
    /// `@{u}` == HEAD and the branch has nothing left unpushed.
    private func createSyncedStackRepoWithUpstream() async throws -> (worktree: URL, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-gg-stack-upstream-\(UUID().uuidString)")
        let remote = root.appendingPathComponent("remote.git")
        let worktree = root.appendingPathComponent("clone")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "--bare", "-b", "main"], cwd: remote)
        _ = try await Process.git(["clone", "-q", remote.path, worktree.path], cwd: nil)
        _ = try await Process.git(["config", "user.email", "t@e"], cwd: worktree)
        _ = try await Process.git(["config", "user.name", "t"], cwd: worktree)
        try "base\n".write(to: worktree.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "."], cwd: worktree)
        _ = try await Process.git(["commit", "-q", "-m", "base"], cwd: worktree)
        _ = try await Process.git(["push", "-q", "-u", "origin", "main"], cwd: worktree)
        _ = try await Process.git(["checkout", "-q", "-b", "nacho/stack"], cwd: worktree)
        try "stack\n".write(to: worktree.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "."], cwd: worktree)
        _ = try await Process.git(
            ["commit", "-q", "-m", "feat: stack work", "-m", "GG-ID: abc123\nGG-Parent: def456"],
            cwd: worktree
        )
        _ = try await Process.git(["push", "-q", "-u", "origin", "nacho/stack"], cwd: worktree)
        return (worktree, root)
    }

    /// A gg stack that's already fully pushed (`gg sync` already ran) must
    /// still be detected under "Branch upstream" comparison mode. There the
    /// *display* `commits` list is `@{u}..HEAD` — empty once synced — but
    /// `ggStackSourceCommits` (fed by the review-loop base resolution,
    /// which never uses upstream) must still reflect the branch's GG-ID
    /// commit relative to `main`, or the stack-shape gate would incorrectly
    /// treat a synced stack as "not a stack" and clear the UI.
    @Test func performRefreshPopulatesGGStackSourceCommitsUnderBranchUpstreamMode() async throws {
        let (repo, root) = try await createSyncedStackRepoWithUpstream()
        defer { try? FileManager.default.removeItem(at: root) }
        let wt = Worktree(
            id: Worktree.makeId(path: repo),
            projectId: "test-project",
            name: "nacho/stack",
            branch: "nacho/stack",
            path: repo,
            status: .clean,
            lastActivity: Date()
        )
        let state = RightPaneState(worktree: wt, baseBranch: "main")
        state.comparisonMode = .branchUpstream

        await state.refresh()

        #expect(state.commits.isEmpty)
        #expect(!state.ggStackSourceCommits.isEmpty)
        #expect(GGStackGate.isStackShaped(commits: state.ggStackSourceCommits))
    }

    @Test func gateClosedSkipsCLIAndClearsStack() async throws {
        let wt = makeWorktree()
        let state = RightPaneState(worktree: wt, baseBranch: "main")
        let runner = CountingFakeGGRunner(
            result: ProcessResult(exitCode: 0, stdout: GGStackModelsTests.fixture, stderr: "")
        )
        state.ggService = GGService(runner: runner)
        state.ggGateProvider = { false }
        state.ggStackSourceCommits = [commit(sha: String(repeating: "a", count: 40), stackShaped: true)]

        await state.refreshGGStack()

        #expect(runner.callCount == 0)
        #expect(state.ggStack == nil)
        #expect(GGStackSummaryStore.shared.summaries[wt.path.path] == nil)
    }

    @Test func gateClosedClearsPausedOperation() async throws {
        let wt = makeWorktree()
        let state = RightPaneState(worktree: wt, baseBranch: "main")
        state.ggGateProvider = { false }
        state.ggStackSourceCommits = [commit(sha: String(repeating: "n", count: 40), stackShaped: true)]
        state.ggActionState.setPaused(GGPausedOperation(pausedBy: .sync))

        await state.refreshGGStack()

        #expect(state.ggActionState.pausedOperation == nil)
    }

    @Test func notStackShapedSkipsCLIAndClearsStack() async throws {
        let wt = makeWorktree()
        let state = RightPaneState(worktree: wt, baseBranch: "main")
        let runner = CountingFakeGGRunner(
            result: ProcessResult(exitCode: 0, stdout: GGStackModelsTests.fixture, stderr: "")
        )
        state.ggService = GGService(runner: runner)
        state.ggGateProvider = { true }
        state.ggStackSourceCommits = [commit(sha: String(repeating: "b", count: 40), stackShaped: false)]

        await state.refreshGGStack()

        #expect(runner.callCount == 0)
        #expect(state.ggStack == nil)
        #expect(GGStackSummaryStore.shared.summaries[wt.path.path] == nil)
    }

    @Test func unchangedCommitSetDoesNotReinvokeCLI() async throws {
        let wt = makeWorktree()
        let state = RightPaneState(worktree: wt, baseBranch: "main")
        let runner = CountingFakeGGRunner(
            result: ProcessResult(exitCode: 0, stdout: GGStackModelsTests.fixture, stderr: "")
        )
        state.ggService = GGService(runner: runner)
        state.ggGateProvider = { true }
        state.ggStackSourceCommits = [commit(sha: String(repeating: "c", count: 40), stackShaped: true)]

        await state.refreshGGStack()
        #expect(runner.callCount == 1)
        #expect(state.ggStack != nil)

        // Same commit set (same fingerprint) — must not hit the CLI again.
        await state.refreshGGStack()
        #expect(runner.callCount == 1)

        // Changing the commit set (new fingerprint) — must re-query.
        state.ggStackSourceCommits = [commit(sha: String(repeating: "d", count: 40), stackShaped: true)]
        await state.refreshGGStack()
        #expect(runner.callCount == 2)
    }

    /// `reevaluateGGGate()` must clear stale stack state immediately when the
    /// gate flips closed (e.g. the Settings master toggle goes off), rather
    /// than waiting for the next watcher-driven refresh. `reevaluateGGGate()`
    /// returns its underlying fire-and-forget task so the test can await it
    /// deterministically instead of racing the MainActor scheduler.
    @Test func reevaluateGGGateClearsStackWhenGateClosed() async throws {
        let wt = makeWorktree()
        let state = RightPaneState(worktree: wt, baseBranch: "main")
        let runner = CountingFakeGGRunner(
            result: ProcessResult(exitCode: 0, stdout: GGStackModelsTests.fixture, stderr: "")
        )
        state.ggService = GGService(runner: runner)
        state.ggGateProvider = { true }
        state.ggStackSourceCommits = [commit(sha: String(repeating: "e", count: 40), stackShaped: true)]

        await state.refreshGGStack()
        #expect(state.ggStack != nil)
        #expect(GGStackSummaryStore.shared.summaries[wt.path.path] != nil)

        // Simulate the master toggle going off in Settings.
        state.ggGateProvider = { false }
        await state.reevaluateGGGate().value

        #expect(state.ggStack == nil)
        #expect(GGStackSummaryStore.shared.summaries[wt.path.path] == nil)
    }

    /// A thrown gg failure must not cache the commits key — otherwise a
    /// transient error (auth hiccup, network blip) permanently skips retries
    /// for that commit set via the unchanged-key guard, even after the
    /// underlying problem clears up.
    @Test func transientFailureDoesNotPoisonCommitsKeyCache() async throws {
        let wt = makeWorktree()
        let state = RightPaneState(worktree: wt, baseBranch: "main")
        let runner = ThrowingFakeGGRunner()
        state.ggService = GGService(runner: runner)
        state.ggGateProvider = { true }
        state.ggStackSourceCommits = [commit(sha: String(repeating: "f", count: 40), stackShaped: true)]

        await state.refreshGGStack()
        #expect(runner.callCount == 1)
        #expect(state.ggStack == nil)
        #expect(state.ggStackCommitsKey == nil)

        // Same commit set again — since the key was never cached, this must
        // retry rather than being skipped by the unchanged-key guard.
        await state.refreshGGStack()
        #expect(runner.callCount == 2)
    }

    /// A stack loaded for one branch must not keep rendering after the user
    /// switches to a different stack-shaped branch and the reload for it
    /// fails transiently — the stale stack no longer matches `commits`.
    @Test func failedReloadClearsStaleStackFromDifferentBranch() async throws {
        let wt = makeWorktree()
        let state = RightPaneState(worktree: wt, baseBranch: "main")

        let okRunner = CountingFakeGGRunner(
            result: ProcessResult(exitCode: 0, stdout: GGStackModelsTests.fixture, stderr: "")
        )
        state.ggService = GGService(runner: okRunner)
        state.ggGateProvider = { true }
        state.currentBranch = "nacho/stack-a"
        state.ggStackSourceCommits = [commit(sha: String(repeating: "i", count: 40), stackShaped: true)]
        await state.refreshGGStack()
        #expect(state.ggStack != nil)
        #expect(GGStackSummaryStore.shared.summaries[wt.path.path] != nil)

        let throwingRunner = ThrowingFakeGGRunner()
        state.ggService = GGService(runner: throwingRunner)
        state.currentBranch = "nacho/stack-b"
        state.ggStackSourceCommits = [commit(sha: String(repeating: "j", count: 40), stackShaped: true)]
        await state.refreshGGStack()

        #expect(throwingRunner.callCount == 1)
        #expect(state.ggStack == nil)
        #expect(GGStackSummaryStore.shared.summaries[wt.path.path] == nil)

        // The cache key is reset (not left at branch A's stale key, and not
        // set to branch B's failed key) — retrying must re-invoke gg rather
        // than being skipped by the unchanged-key guard either way.
        #expect(state.ggStackCommitsKey == nil)
        await state.refreshGGStack()
        #expect(throwingRunner.callCount == 2)
    }

    /// The cache key must be reset (not left pointing at the last
    /// *successful* key) when a later reload fails and clears `ggStack` —
    /// otherwise returning to that prior branch/commit set would hit the
    /// unchanged-key guard and skip re-fetching the now-cleared stack,
    /// leaving the UI stuck showing plain commits.
    @Test func failedReloadAllowsRefetchOnReturnToPriorBranch() async throws {
        let wt = makeWorktree()
        let state = RightPaneState(worktree: wt, baseBranch: "main")
        let commitsA = [commit(sha: String(repeating: "k", count: 40), stackShaped: true)]

        let firstRunner = CountingFakeGGRunner(
            result: ProcessResult(exitCode: 0, stdout: GGStackModelsTests.fixture, stderr: "")
        )
        state.ggService = GGService(runner: firstRunner)
        state.ggGateProvider = { true }
        state.currentBranch = "nacho/stack-a"
        state.ggStackSourceCommits = commitsA
        await state.refreshGGStack()
        #expect(state.ggStack != nil)

        let throwingRunner = ThrowingFakeGGRunner()
        state.ggService = GGService(runner: throwingRunner)
        state.currentBranch = "nacho/stack-b"
        state.ggStackSourceCommits = [commit(sha: String(repeating: "l", count: 40), stackShaped: true)]
        await state.refreshGGStack()
        #expect(state.ggStack == nil)

        // Back to branch A with the exact same commits as the first,
        // successful load — must re-fetch, not be skipped as "unchanged".
        let secondRunner = CountingFakeGGRunner(
            result: ProcessResult(exitCode: 0, stdout: GGStackModelsTests.fixture, stderr: "")
        )
        state.ggService = GGService(runner: secondRunner)
        state.currentBranch = "nacho/stack-a"
        state.ggStackSourceCommits = commitsA
        await state.refreshGGStack()

        #expect(secondRunner.callCount == 1)
        #expect(state.ggStack != nil)
    }

    /// `gg ls --json` answers for the *current* branch, so a checkout to a
    /// different branch that happens to share the same commit SHAs (e.g.
    /// right after `git checkout -b` from the same HEAD) must not reuse the
    /// previous branch's cached stack via the unchanged-commits guard.
    @Test func branchChangeWithSameCommitsReinvokesCLI() async throws {
        let wt = makeWorktree()
        let state = RightPaneState(worktree: wt, baseBranch: "main")
        let runner = CountingFakeGGRunner(
            result: ProcessResult(exitCode: 0, stdout: GGStackModelsTests.fixture, stderr: "")
        )
        state.ggService = GGService(runner: runner)
        state.ggGateProvider = { true }
        state.currentBranch = "nacho/stack-a"
        state.ggStackSourceCommits = [commit(sha: String(repeating: "h", count: 40), stackShaped: true)]

        await state.refreshGGStack()
        #expect(runner.callCount == 1)

        state.currentBranch = "nacho/stack-b"
        await state.refreshGGStack()
        #expect(runner.callCount == 2)
    }

    /// `markSnapshotUnknown()` resets `commits` along with the rest of the
    /// snapshot; gg stack state derives from `commits`, so it must be reset
    /// in lockstep or a delayed/failed refresh after invalidation can leave
    /// a stale "Stack · …" header/sidebar badge rendered against an emptied
    /// commit list.
    @Test func markSnapshotUnknownClearsStackState() async throws {
        let wt = makeWorktree()
        let state = RightPaneState(worktree: wt, baseBranch: "main")
        let runner = CountingFakeGGRunner(
            result: ProcessResult(exitCode: 0, stdout: GGStackModelsTests.fixture, stderr: "")
        )
        state.ggService = GGService(runner: runner)
        state.ggGateProvider = { true }
        state.ggStackSourceCommits = [commit(sha: String(repeating: "g", count: 40), stackShaped: true)]

        await state.refreshGGStack()
        #expect(state.ggStack != nil)
        #expect(GGStackSummaryStore.shared.summaries[wt.path.path] != nil)

        state.markSnapshotUnknown()

        #expect(state.ggStack == nil)
        #expect(state.ggStackCommitsKey == nil)
        #expect(GGStackSummaryStore.shared.summaries[wt.path.path] == nil)
    }

    /// `gg ls --json` can't report a paused rebase, so `refreshGGStack()`
    /// reconciles `ggActionState.pausedOperation` from a git-level probe
    /// (`GGStackGate.operationInProgress`) independent of the gg query.
    @Test func refreshReconcilesPausedFromGitProbe() async throws {
        // Real temp repo with a rebase-merge dir → operationInProgress true.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-gg-paused-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".git/rebase-merge"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wt = Worktree(
            id: Worktree.makeId(path: dir), projectId: "p", name: "feature",
            branch: "feature", path: dir, status: .clean, lastActivity: Date()
        )
        let state = RightPaneState(worktree: wt, baseBranch: "main")
        state.ggService = GGService(runner: CountingFakeGGRunner(
            result: ProcessResult(exitCode: 0, stdout: GGStackModelsTests.fixture, stderr: "")
        ))
        state.ggGateProvider = { true }
        state.ggStackSourceCommits = [commit(sha: String(repeating: "a", count: 40), stackShaped: true)]

        await state.refreshGGStack()
        #expect(state.ggActionState.pausedOperation != nil)

        // Remove the marker → next refresh clears paused.
        try FileManager.default.removeItem(at: dir.appendingPathComponent(".git/rebase-merge"))
        state.ggStackCommitsKey = nil // force a re-query past the unchanged-key guard
        await state.refreshGGStack()
        #expect(state.ggActionState.pausedOperation == nil)
    }

    @Test func thrownRefreshKeepsPausedOperationWhenGitProbeIsPaused() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-gg-paused-throw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".git/rebase-merge"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wt = Worktree(
            id: Worktree.makeId(path: dir), projectId: "p", name: "feature",
            branch: "feature", path: dir, status: .clean, lastActivity: Date()
        )
        let state = RightPaneState(worktree: wt, baseBranch: "main")
        state.ggService = GGService(runner: ThrowingFakeGGRunner())
        state.ggGateProvider = { true }
        state.ggStackSourceCommits = [commit(sha: String(repeating: "m", count: 40), stackShaped: true)]

        await state.refreshGGStack()

        #expect(state.ggStack == nil)
        #expect(state.ggActionState.pausedOperation != nil)
    }
}
