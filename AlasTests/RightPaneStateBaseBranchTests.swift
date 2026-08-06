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
        _ = try await Process.git(["checkout", "-q", "-b", "staging"], cwd: tmp)
        try "staging content\n".write(to: tmp.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "."], cwd: tmp)
        _ = try await Process.git(["commit", "-q", "-m", "staging commit"], cwd: tmp)
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

    private func createTestRepoWithUpstream() async throws -> (worktree: URL, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-base-branch-upstream-\(UUID().uuidString)")
        let remote = root.appendingPathComponent("remote.git")
        let worktree = root.appendingPathComponent("clone")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "--bare", "-b", "master"], cwd: remote)
        _ = try await Process.git(["clone", "-q", remote.path, worktree.path], cwd: nil)
        _ = try await Process.git(["config", "user.email", "t@e"], cwd: worktree)
        _ = try await Process.git(["config", "user.name", "t"], cwd: worktree)
        try "base\n".write(to: worktree.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "."], cwd: worktree)
        _ = try await Process.git(["commit", "-q", "-m", "base"], cwd: worktree)
        _ = try await Process.git(["push", "-q", "-u", "origin", "master"], cwd: worktree)
        _ = try await Process.git(["checkout", "-q", "-b", "feature"], cwd: worktree)
        try "feature\n".write(to: worktree.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["commit", "-q", "-am", "feature work"], cwd: worktree)
        _ = try await Process.git(["push", "-q", "-u", "origin", "feature"], cwd: worktree)
        return (worktree, root)
    }

    private func createTestRepoWithForkAndUpstream() async throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-base-branch-fork-upstream-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: tmp)
        _ = try await Process.git(["config", "user.email", "t@e"], cwd: tmp)
        _ = try await Process.git(["config", "user.name", "t"], cwd: tmp)
        try "base\n".write(to: tmp.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "."], cwd: tmp)
        _ = try await Process.git(["commit", "-q", "-m", "base"], cwd: tmp)
        _ = try await Process.git(["remote", "add", "origin", "https://github.com/nacho/alas.git"], cwd: tmp)
        _ = try await Process.git(["remote", "add", "upstream", "https://github.com/mrmans0n/alas.git"], cwd: tmp)
        let baseSha = try await Process.git(["rev-parse", "HEAD"], cwd: tmp)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await Process.git(["update-ref", "refs/remotes/origin/main", baseSha], cwd: tmp)
        _ = try await Process.git(["update-ref", "refs/remotes/upstream/main", baseSha], cwd: tmp)
        _ = try await Process.git(["checkout", "-q", "-b", "feature"], cwd: tmp)
        _ = try await Process.git(["branch", "--set-upstream-to=upstream/main", "feature"], cwd: tmp)
        try "feature\n".write(to: tmp.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["commit", "-q", "-am", "feature work"], cwd: tmp)
        return tmp
    }

    private func createTestRepoWithUnsupportedTrackedRemote() async throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-base-branch-unsupported-upstream-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: tmp)
        _ = try await Process.git(["config", "user.email", "t@e"], cwd: tmp)
        _ = try await Process.git(["config", "user.name", "t"], cwd: tmp)
        try "base\n".write(to: tmp.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "."], cwd: tmp)
        _ = try await Process.git(["commit", "-q", "-m", "base"], cwd: tmp)
        _ = try await Process.git(["remote", "add", "origin", "https://github.com/nacho/alas.git"], cwd: tmp)
        _ = try await Process.git(["remote", "add", "internal", "../internal.git"], cwd: tmp)
        let baseSha = try await Process.git(["rev-parse", "HEAD"], cwd: tmp)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await Process.git(["update-ref", "refs/remotes/origin/main", baseSha], cwd: tmp)
        _ = try await Process.git(["checkout", "-q", "-b", "feature"], cwd: tmp)
        try "feature\n".write(to: tmp.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["commit", "-q", "-am", "feature work"], cwd: tmp)
        let featureSha = try await Process.git(["rev-parse", "HEAD"], cwd: tmp)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await Process.git(["update-ref", "refs/remotes/internal/feature", featureSha], cwd: tmp)
        _ = try await Process.git(["branch", "--set-upstream-to=internal/feature", "feature"], cwd: tmp)
        return tmp
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
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

    @Test func selectBaseBranchClearsBehindBase() async throws {
        let tmp = try await createTestRepoWithBranches()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let wt = makeWorktree(at: tmp, branch: "feature")
        let state = RightPaneState(worktree: wt, baseBranch: "main")
        state.behindBase = GitService.BehindStatus(ref: "origin/main", sha: "abc", count: 2, probedAt: Date())

        state.selectBaseBranch("develop")

        #expect(state.behindBase == nil)
    }

    @Test func selectBaseBranchTriggersRefresh() async throws {
        let tmp = try await createTestRepoWithBranches()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let wt = makeWorktree(at: tmp, branch: "feature")
        let state = RightPaneState(worktree: wt, baseBranch: "main")
        await state.refresh()
        state.selectBaseBranch("trunk")
        try await waitUntil { !state.loading }
        #expect(!state.loading)
    }

    @Test func selectBaseBranchCapsRecentAtThree() async throws {
        let tmp = try await createTestRepoWithBranches()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let wt = makeWorktree(at: tmp, branch: "feature")
        let state = RightPaneState(worktree: wt, baseBranch: "main")
        state.selectBaseBranch("develop")
        state.selectBaseBranch("trunk")
        state.selectBaseBranch("staging")
        #expect(state.recentBaseBranches == ["develop", "trunk", "staging"])
        state.selectBaseBranch("main")
        #expect(state.recentBaseBranches == ["trunk", "staging", "main"])
    }

    @Test func selectBaseBranchRefreshesExistingRecentRecency() async throws {
        let tmp = try await createTestRepoWithBranches()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let wt = makeWorktree(at: tmp, branch: "feature")
        let state = RightPaneState(worktree: wt, baseBranch: "main")
        state.selectBaseBranch("develop")
        state.selectBaseBranch("trunk")
        state.selectBaseBranch("develop")
        state.selectBaseBranch("staging")
        state.selectBaseBranch("main")
        #expect(state.recentBaseBranches == ["develop", "staging", "main"])
    }

    @Test func refreshUsesUpstreamWhenConfiguredBaseIsMissingAndNotOverridden() async throws {
        let (repo, root) = try await createTestRepoWithUpstream()
        defer { try? FileManager.default.removeItem(at: root) }
        let wt = makeWorktree(at: repo, branch: "feature")
        let state = RightPaneState(worktree: wt, baseBranch: "main")
        state.comparisonMode = .branchUpstream

        await state.refresh()

        #expect(state.comparisonRef == "origin/feature")
    }

    @Test func refreshUsesComparisonRefRemoteForCommitLinks() async throws {
        let repo = try await createTestRepoWithForkAndUpstream()
        defer { try? FileManager.default.removeItem(at: repo) }
        let wt = makeWorktree(at: repo, branch: "feature")
        let state = RightPaneState(worktree: wt, baseBranch: "main")
        state.comparisonMode = .branchUpstream

        await state.refresh()

        #expect(state.comparisonRef == "upstream/main")
        #expect(state.commitRemote?.remoteName == "upstream")
        #expect(state.commitRemote?.repositorySlug == "mrmans0n/alas")
    }

    @Test func refreshDoesNotFallbackPrimaryCommitRemoteFromUnsupportedUpstream() async throws {
        let repo = try await createTestRepoWithUnsupportedTrackedRemote()
        defer { try? FileManager.default.removeItem(at: repo) }
        let wt = makeWorktree(at: repo, branch: "feature")
        let state = RightPaneState(worktree: wt, baseBranch: "main")

        await state.refresh()

        #expect(state.upstreamRef == "internal/feature")
        #expect(!state.commitsNeedPush)
        #expect(state.commitRemote?.remoteName == "origin")
        #expect(state.primaryCommitRemote == nil)
    }

    @Test func storeRefreshesWhenConfigMatchesClearedOverride() async throws {
        let (repo, root) = try await createTestRepoWithUpstream()
        defer { try? FileManager.default.removeItem(at: root) }
        let wt = makeWorktree(at: repo, branch: "feature")
        let store = RightPaneStore()
        let state = store.state(for: wt, baseBranch: "main", comparisonMode: .branchUpstream)

        state.selectBaseBranch("develop")
        try await Task.sleep(for: .milliseconds(200))
        #expect(state.baseBranch == "develop")
        #expect(state.userOverrodeBaseBranch)

        _ = store.state(for: wt, baseBranch: "develop", comparisonMode: .branchUpstream)
        try await Task.sleep(for: .milliseconds(600))

        #expect(!state.userOverrodeBaseBranch)
        #expect(state.comparisonRef == "origin/feature")
    }

    @Test func storeRefreshesWhenComparisonModeToggles() async throws {
        let (repo, root) = try await createTestRepoWithUpstream()
        defer { try? FileManager.default.removeItem(at: root) }
        let wt = makeWorktree(at: repo, branch: "feature")
        let store = RightPaneStore()
        let state = store.state(for: wt, baseBranch: "master", comparisonMode: .branchUpstream)
        try await waitUntil { state.comparisonRef == "origin/feature" }
        #expect(state.comparisonRef == "origin/feature")

        _ = store.state(for: wt, baseBranch: "master", comparisonMode: .manual)
        try await waitUntil { state.comparisonRef == "master" }
        #expect(state.comparisonRef == "master")
        #expect(state.comparisonMode == .manual)
    }

    @Test func commitEditorComparisonRefReturnsOnlyResolvedRef() async throws {
        let tmp = try await createTestRepoWithBranches()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let wt = makeWorktree(at: tmp, branch: "feature")
        let store = RightPaneStore()
        let state = store.state(for: wt, baseBranch: "main", comparisonMode: .manual)

        #expect(store.commitEditorComparisonRef(worktreeId: wt.id) == nil)

        state.comparisonRef = "origin/main"

        #expect(store.commitEditorComparisonRef(worktreeId: wt.id) == "origin/main")
    }

    @Test func invalidatingCachedSnapshotHidesStaleChangesUntilRefreshPublishes() async throws {
        let tmp = try await createTestRepoWithBranches()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try "dirty\n".write(to: tmp.appendingPathComponent("stale.txt"), atomically: true, encoding: .utf8)
        let wt = makeWorktree(at: tmp, branch: "main")
        let store = RightPaneStore()
        let state = store.state(for: wt, baseBranch: "main", comparisonMode: .manual)
        try await waitUntil { state.hasLoadedSnapshot && !state.displayChanges.isEmpty }

        store.invalidateSnapshot(worktreeId: wt.id)

        #expect(!state.hasLoadedSnapshot)
        #expect(state.displayChanges.isEmpty)
        #expect(state.changes.isEmpty)
        #expect(store.commitEditorComparisonRef(worktreeId: wt.id) == nil)
    }

    @Test func refreshFailurePublishesLoadedErrorSnapshot() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-missing-worktree-\(UUID().uuidString)")
        let wt = makeWorktree(at: tmp, branch: "main")
        let state = RightPaneState(worktree: wt, baseBranch: "main")

        await state.refresh()

        #expect(state.hasLoadedSnapshot)
        #expect(state.sidebarError != nil)
        #expect(state.displayChanges.isEmpty)
    }

    @Test func refreshReportsFailureWhenSnapshotDoesNotPublish() async {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-missing-worktree-\(UUID().uuidString)")
        let state = RightPaneState(worktree: makeWorktree(at: tmp, branch: "main"), baseBranch: "main")

        let refreshed = await state.refresh()

        #expect(!refreshed)
    }
}
