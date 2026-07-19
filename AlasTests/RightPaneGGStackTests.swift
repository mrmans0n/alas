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

    @Test func gateClosedSkipsCLIAndClearsStack() async throws {
        let wt = makeWorktree()
        let state = RightPaneState(worktree: wt, baseBranch: "main")
        let runner = CountingFakeGGRunner(
            result: ProcessResult(exitCode: 0, stdout: GGStackModelsTests.fixture, stderr: "")
        )
        state.ggService = GGService(runner: runner)
        state.ggGateProvider = { false }
        state.commits = [commit(sha: String(repeating: "a", count: 40), stackShaped: true)]

        await state.refreshGGStack()

        #expect(runner.callCount == 0)
        #expect(state.ggStack == nil)
        #expect(GGStackSummaryStore.shared.summaries[wt.path.path] == nil)
    }

    @Test func notStackShapedSkipsCLIAndClearsStack() async throws {
        let wt = makeWorktree()
        let state = RightPaneState(worktree: wt, baseBranch: "main")
        let runner = CountingFakeGGRunner(
            result: ProcessResult(exitCode: 0, stdout: GGStackModelsTests.fixture, stderr: "")
        )
        state.ggService = GGService(runner: runner)
        state.ggGateProvider = { true }
        state.commits = [commit(sha: String(repeating: "b", count: 40), stackShaped: false)]

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
        state.commits = [commit(sha: String(repeating: "c", count: 40), stackShaped: true)]

        await state.refreshGGStack()
        #expect(runner.callCount == 1)
        #expect(state.ggStack != nil)

        // Same commit set (same fingerprint) — must not hit the CLI again.
        await state.refreshGGStack()
        #expect(runner.callCount == 1)

        // Changing the commit set (new fingerprint) — must re-query.
        state.commits = [commit(sha: String(repeating: "d", count: 40), stackShaped: true)]
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
        state.commits = [commit(sha: String(repeating: "e", count: 40), stackShaped: true)]

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
        state.commits = [commit(sha: String(repeating: "f", count: 40), stackShaped: true)]

        await state.refreshGGStack()
        #expect(runner.callCount == 1)
        #expect(state.ggStack == nil)
        #expect(state.ggStackCommitsKey == nil)

        // Same commit set again — since the key was never cached, this must
        // retry rather than being skipped by the unchanged-key guard.
        await state.refreshGGStack()
        #expect(runner.callCount == 2)
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
        state.commits = [commit(sha: String(repeating: "h", count: 40), stackShaped: true)]

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
        state.commits = [commit(sha: String(repeating: "g", count: 40), stackShaped: true)]

        await state.refreshGGStack()
        #expect(state.ggStack != nil)
        #expect(GGStackSummaryStore.shared.summaries[wt.path.path] != nil)

        state.markSnapshotUnknown()

        #expect(state.ggStack == nil)
        #expect(state.ggStackCommitsKey == nil)
        #expect(GGStackSummaryStore.shared.summaries[wt.path.path] == nil)
    }
}
