import Testing
import Foundation
@testable import Alas

private final class LoadOlderStackRunner: GGCommandRunning, @unchecked Sendable {
    func run(args: [String], cwd: URL?) async throws -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: GGStackModelsTests.fixture, stderr: "")
    }
}

private actor DelayedStackHydration {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func load(_ shas: [String]) async -> [String: CommitInfo] {
        started = true
        let waiters = startWaiters
        startWaiters = []
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { releaseContinuation = $0 }
        return Dictionary(uniqueKeysWithValues: shas.map { sha in
            let fullSHA = sha + String(repeating: "0", count: 40 - sha.count)
            return (fullSHA, CommitInfo(
                sha: fullSHA,
                shortSha: sha,
                author: "Test",
                authorInitials: "T",
                date: .now,
                subject: sha,
                conventionalTag: nil,
                filesChanged: 0,
                insertions: 0,
                deletions: 0
            ))
        })
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

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

    private struct FixtureCommit {
        let branch: String
        let message: String
        let path: String
        let contents: String
    }

    /// Builds the whole commit graph in ONE real `git fast-import` run
    /// instead of an add + commit process pair per commit (the paging
    /// fixtures need 20+ commits, which dominated these tests' runtime).
    /// The resulting history is the same shape the per-commit loop made:
    /// linear `main`, optional branch forked from main's tip, each commit
    /// rewriting one file, subjects as given. Commit timestamps increase
    /// one second per commit so `git log` ordering never depends on
    /// same-second ties. Finishes with a forced checkout of `checkout`, so
    /// HEAD, index, and working tree match a normal clean checkout.
    private func makeRepo(_ commits: [FixtureCommit], checkout: String) async throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-loadolder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: tmp)
        func data(_ text: String) -> String { "data \(text.utf8.count)\n\(text)" }
        let firstTimestamp = Int(Date().timeIntervalSince1970) - commits.count
        var stream = ""
        var tips: [String: Int] = [:]
        var lastMark: Int?
        for (index, commit) in commits.enumerated() {
            let mark = index + 1
            let timestamp = firstTimestamp + index
            stream += "commit refs/heads/\(commit.branch)\nmark :\(mark)\n"
            stream += "author t <t@e.com> \(timestamp) +0000\n"
            stream += "committer t <t@e.com> \(timestamp) +0000\n"
            stream += data("\(commit.message)\n") + "\n"
            // A branch's first commit forks from the previous commit (main's
            // tip), exactly like `git checkout -b` followed by a commit.
            if tips[commit.branch] == nil, let lastMark {
                stream += "from :\(lastMark)\n"
            }
            stream += "M 100644 inline \(commit.path)\n" + data(commit.contents) + "\n"
            tips[commit.branch] = mark
            lastMark = mark
        }
        stream += "done\n"
        let imported = try await Process.git(["fast-import", "--quiet", "--done"], cwd: tmp, stdin: stream)
        try #require(imported.exitCode == 0, "git fast-import failed: \(imported.stderr)")
        let checkedOut = try await Process.git(["checkout", "-q", "-f", checkout], cwd: tmp)
        try #require(checkedOut.exitCode == 0, "git checkout failed: \(checkedOut.stderr)")
        return tmp
    }

    private func mainCommits(_ n: Int) -> [FixtureCommit] {
        (1...n).map { FixtureCommit(branch: "main", message: "feat: c\($0)", path: "a.txt", contents: "\($0)\n") }
    }

    private func makeRepoOnMain(commits n: Int) async throws -> URL {
        try await makeRepo(mainCommits(n), checkout: "main")
    }

    private func makeBranchAhead(base: Int, ahead: Int) async throws -> URL {
        let feature = (1...ahead).map {
            FixtureCommit(branch: "feature", message: "feat: ahead\($0)", path: "a.txt", contents: "f\($0)\n")
        }
        return try await makeRepo(mainCommits(base) + feature, checkout: "feature")
    }

    private func makeRepoWithRemoteBranches() async throws -> (repo: URL, remote: URL) {
        let repo = try await makeRepo(
            mainCommits(1) + [
                FixtureCommit(branch: "worktree/task-branch", message: "feat: task", path: "task.txt", contents: "task\n"),
            ],
            checkout: "worktree/task-branch"
        )
        let remote = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-remote-\(UUID().uuidString).git")
        _ = try await Process.git(["init", "-q", "--bare", remote.path], cwd: repo)
        _ = try await Process.git(["remote", "add", "origin", remote.path], cwd: repo)
        // A push to a remote with the default fetch refspec also updates
        // refs/remotes/origin/*, so no separate fetch is needed for the
        // origin/... branches the test asserts on.
        _ = try await Process.git(["push", "-q", "origin", "main", "worktree/task-branch"], cwd: repo)
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

    @Test func loadingGGPresentationDisablesPaginationAndDropsRowsFromThePreviousSource() async throws {
        let repo = try await makeBranchAhead(base: 25, ahead: 3)
        defer { try? FileManager.default.removeItem(at: repo) }
        let state = RightPaneState(worktree: makeWorktree(at: repo, branch: "feature"), baseBranch: "main")
        await state.refresh()
        await state.loadOlder()
        #expect(state.olderCommits.count == 20)

        let hydration = DelayedStackHydration()
        state.ggService = GGService(runner: LoadOlderStackRunner())
        state.ggContextProvider = { _ in .active(stackName: "agent-inbox") }
        state.ggStackSourceCommits = state.commits
        state.ggStackCommitLoader = { _, shas in await hydration.load(shas) }

        let refresh = Task { @MainActor in await state.refreshGGStack() }
        await hydration.waitUntilStarted()
        #expect(state.ggStackLoadState == .loading)

        await state.loadOlder()

        #expect(state.olderCommits.isEmpty)
        #expect(state.hasMoreOlder)
        await hydration.release()
        await refresh.value
        #expect(state.ggStackLoadState == .loaded)
        #expect(state.olderCommits.isEmpty)
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
