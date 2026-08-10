import Testing
import Foundation
@testable import Alas

@MainActor
@Suite(.serialized)
struct RightPaneStateLoadOlderTests {
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

    private func makeRepoOnMain(commits n: Int) async throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-loadolder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: tmp)
        _ = try await Process.git(["config", "user.email", "t@e.com"], cwd: tmp)
        _ = try await Process.git(["config", "user.name", "t"], cwd: tmp)
        for i in 1...n {
            try "\(i)\n".write(to: tmp.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            _ = try await Process.git(["add", "."], cwd: tmp)
            _ = try await Process.git(["commit", "-q", "-m", "feat: c\(i)"], cwd: tmp)
        }
        return tmp
    }

    private func makeBranchAhead(base: Int, ahead: Int) async throws -> URL {
        let repo = try await makeRepoOnMain(commits: base)
        _ = try await Process.git(["checkout", "-q", "-b", "feature"], cwd: repo)
        for i in 1...ahead {
            try "f\(i)\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            _ = try await Process.git(["add", "."], cwd: repo)
            _ = try await Process.git(["commit", "-q", "-m", "feat: ahead\(i)"], cwd: repo)
        }
        return repo
    }

    private func makeRepoWithRemoteBranches() async throws -> (repo: URL, remote: URL) {
        let repo = try await makeRepoOnMain(commits: 1)
        let remote = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-remote-\(UUID().uuidString).git")
        _ = try await Process.git(["init", "-q", "--bare", remote.path], cwd: repo)
        _ = try await Process.git(["remote", "add", "origin", remote.path], cwd: repo)
        _ = try await Process.git(["checkout", "-q", "-b", "worktree/task-branch"], cwd: repo)
        try "task\n".write(to: repo.appendingPathComponent("task.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "."], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "feat: task"], cwd: repo)
        _ = try await Process.git(["push", "-q", "origin", "main", "worktree/task-branch"], cwd: repo)
        _ = try await Process.git(["fetch", "-q", "origin"], cwd: repo)
        return (repo, remote)
    }

    @Test func firstPageUsesParentOfLastAheadCommit() async throws {
        let repo = try await makeBranchAhead(base: 25, ahead: 3)
        defer { try? FileManager.default.removeItem(at: repo) }
        let state = RightPaneState(worktree: makeWorktree(at: repo, branch: "feature"), baseBranch: "main")
        await state.refresh()
        #expect(state.commits.count == 3)
        #expect(state.olderCommits.isEmpty)
        #expect(state.hasMoreOlder)

        await state.loadOlder()
        #expect(state.olderCommits.count == 20)
        #expect(state.hasMoreOlder)
        // First older entry is the parent of the oldest ahead commit
        // ("ahead1"), which is the latest base commit "c25".
        #expect(state.olderCommits[0].subject == "c25")
    }

    @Test func hydratedGGDisplayRowsProvideTheFirstOlderHistoryCursor() async throws {
        let repo = try await makeBranchAhead(base: 25, ahead: 3)
        defer { try? FileManager.default.removeItem(at: repo) }
        let state = RightPaneState(worktree: makeWorktree(at: repo, branch: "feature"), baseBranch: "main")
        await state.refresh()
        let displayedStack = state.commits
        state.ggStackDisplayCommits = displayedStack
        state.ggStackLoadState = .loaded
        state.commits = []

        await state.loadOlder()

        let displayedSHAs = Set(state.commitsForDisplay.map(\.sha))
        let olderSHAs = Set(state.olderCommits.map(\.sha))
        #expect(state.olderCommits.count == 20)
        #expect(state.olderCommits.first?.subject == "c25")
        #expect(displayedSHAs.intersection(olderSHAs).isEmpty)
        #expect(displayedSHAs.union(olderSHAs).count == 23)
    }

    @Test func branchFetchMarksLoadingAndPublishesCompleteInitialList() async throws {
        let fixture = try await makeRepoWithRemoteBranches()
        defer {
            try? FileManager.default.removeItem(at: fixture.repo)
            try? FileManager.default.removeItem(at: fixture.remote)
        }
        let state = RightPaneState(
            worktree: makeWorktree(at: fixture.repo, branch: "worktree/task-branch"),
            baseBranch: "main"
        )

        #expect(state.availableBranches.isEmpty)
        #expect(state.isFetchingBranches == false)
        #expect(state.hasFetchedBranches == false)
        #expect(BaseBranchSelector.shouldShowLoading(
            isLoading: state.isFetchingBranches,
            hasLoaded: state.hasFetchedBranches
        ))

        await state.fetchBranches()

        #expect(state.isFetchingBranches == false)
        #expect(state.hasFetchedBranches)
        #expect(!BaseBranchSelector.shouldShowLoading(
            isLoading: state.isFetchingBranches,
            hasLoaded: state.hasFetchedBranches
        ))
        #expect(state.availableBranches.contains("main"))
        #expect(state.availableBranches.contains("worktree/task-branch"))
        #expect(state.availableBranches.contains("origin/main"))
        #expect(state.availableBranches.contains("origin/worktree/task-branch"))
    }

    @Test func subsequentPageContinuesFromOlderCursor() async throws {
        let repo = try await makeBranchAhead(base: 50, ahead: 2)
        defer { try? FileManager.default.removeItem(at: repo) }
        let state = RightPaneState(worktree: makeWorktree(at: repo, branch: "feature"), baseBranch: "main")
        await state.refresh()
        await state.loadOlder()
        let firstPageTail = state.olderCommits.last!.subject
        await state.loadOlder()
        #expect(state.olderCommits.count == 40)
        let pageTwoStartIndex = 20
        #expect(state.olderCommits[pageTwoStartIndex].subject != firstPageTail)
    }

    @Test func endOfHistoryFlipsHasMoreOlder() async throws {
        let repo = try await makeBranchAhead(base: 5, ahead: 1)
        defer { try? FileManager.default.removeItem(at: repo) }
        let state = RightPaneState(worktree: makeWorktree(at: repo, branch: "feature"), baseBranch: "main")
        await state.refresh()
        await state.loadOlder()
        // 5 base commits, ahead1's parent is c5, so older = c1..c5 → 5 entries.
        #expect(state.olderCommits.count == 5)
        #expect(state.hasMoreOlder == false)
    }

    @Test func atBaseUsesHeadAsCursor() async throws {
        let repo = try await makeRepoOnMain(commits: 6)
        defer { try? FileManager.default.removeItem(at: repo) }
        let state = RightPaneState(worktree: makeWorktree(at: repo, branch: "main"), baseBranch: "main")
        await state.refresh()
        #expect(state.commits.isEmpty)
        await state.loadOlder()
        // HEAD^ + ancestors = c1..c5
        #expect(state.olderCommits.map(\.subject) == ["c5", "c4", "c3", "c2", "c1"])
        #expect(state.hasMoreOlder == false)
    }

    @Test func refreshClearsOlderState() async throws {
        let repo = try await makeBranchAhead(base: 25, ahead: 2)
        defer { try? FileManager.default.removeItem(at: repo) }
        let state = RightPaneState(worktree: makeWorktree(at: repo, branch: "feature"), baseBranch: "main")
        await state.refresh()
        await state.loadOlder()
        #expect(state.olderCommits.count == 20)
        await state.refresh()
        #expect(state.olderCommits.isEmpty)
        #expect(state.hasMoreOlder)
        #expect(state.isLoadingOlder == false)
    }

    @Test func errorPathDisablesFurtherLoads() async throws {
        // Unborn-HEAD repo. We DO NOT call refresh() (it would also error).
        // loadOlder() uses cursor = "HEAD" which doesn't resolve → git errors
        // → hasMoreOlder = false.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-loadolder-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let state = RightPaneState(worktree: makeWorktree(at: tmp, branch: "main"), baseBranch: "main")
        await state.loadOlder()
        #expect(state.hasMoreOlder == false)
        #expect(state.olderCommits.isEmpty)
        #expect(state.isLoadingOlder == false)
    }

    @Test func loadOlderWithNoComparisonRef() async throws {
        // No remote (no upstream), and we set baseBranch to a name that
        // doesn't resolve locally → commitsAhead returns ([], nil).
        let repo = try await makeRepoOnMain(commits: 6)
        defer { try? FileManager.default.removeItem(at: repo) }
        let state = RightPaneState(
            worktree: makeWorktree(at: repo, branch: "main"),
            baseBranch: "nonexistent-branch"
        )
        await state.refresh()
        #expect(state.commits.isEmpty)
        #expect(state.comparisonRef == nil)

        await state.loadOlder()
        // Cursor falls back to "HEAD", so we get HEAD^ and older = c5..c1.
        #expect(state.olderCommits.map(\.subject) == ["c5", "c4", "c3", "c2", "c1"])
        #expect(state.hasMoreOlder == false)
    }
}
