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
}
