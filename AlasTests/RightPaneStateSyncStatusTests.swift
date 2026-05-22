import Testing
import Foundation
@testable import Alas

@MainActor
@Suite(.serialized)
struct RightPaneStateSyncStatusTests {
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

    private func makeRepoOnFeature() async throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: tmp)
        _ = try await Process.git(["config", "user.email", "t@e"], cwd: tmp)
        _ = try await Process.git(["config", "user.name", "t"], cwd: tmp)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "root"], cwd: tmp)
        _ = try await Process.git(["checkout", "-q", "-b", "feature"], cwd: tmp)
        return tmp
    }

    // MARK: - showBehindBaseChip

    @Test func baseChipHiddenWhenStatusNil() async throws {
        let repo = try await makeRepoOnFeature()
        defer { try? FileManager.default.removeItem(at: repo) }
        let state = RightPaneState(
            worktree: makeWorktree(at: repo, branch: "feature"),
            baseBranch: "main"
        )
        #expect(state.showBehindBaseChip == false)
    }

    @Test func baseChipVisibleWhenBehindOnNonBaseBranch() async throws {
        let repo = try await makeRepoOnFeature()
        defer { try? FileManager.default.removeItem(at: repo) }
        let state = RightPaneState(
            worktree: makeWorktree(at: repo, branch: "feature"),
            baseBranch: "main"
        )
        state.behindBase = GitService.BehindStatus(
            ref: "origin/main",
            sha: "deadbeef",
            count: 3,
            probedAt: Date()
        )
        #expect(state.showBehindBaseChip == true)
    }

    @Test func baseChipHiddenWhenCountZero() async throws {
        let repo = try await makeRepoOnFeature()
        defer { try? FileManager.default.removeItem(at: repo) }
        let state = RightPaneState(
            worktree: makeWorktree(at: repo, branch: "feature"),
            baseBranch: "main"
        )
        state.behindBase = GitService.BehindStatus(
            ref: "origin/main",
            sha: "deadbeef",
            count: 0,
            probedAt: Date()
        )
        #expect(state.showBehindBaseChip == false)
    }

    @Test func baseChipHiddenOnBaseBranchItself() async throws {
        let repo = try await makeRepoOnFeature()
        defer { try? FileManager.default.removeItem(at: repo) }
        let state = RightPaneState(
            worktree: makeWorktree(at: repo, branch: "main"),
            baseBranch: "main"
        )
        state.behindBase = GitService.BehindStatus(
            ref: "origin/main",
            sha: "deadbeef",
            count: 5,
            probedAt: Date()
        )
        #expect(state.showBehindBaseChip == false)
    }

    @Test func baseChipHiddenOnDetachedHead() async throws {
        let repo = try await makeRepoOnFeature()
        defer { try? FileManager.default.removeItem(at: repo) }
        let state = RightPaneState(
            worktree: makeWorktree(at: repo, branch: ""),
            baseBranch: "main"
        )
        state.behindBase = GitService.BehindStatus(
            ref: "origin/main",
            sha: "deadbeef",
            count: 3,
            probedAt: Date()
        )
        #expect(state.showBehindBaseChip == false)
    }

    // MARK: - showBehindUpstreamChip

    @Test func upstreamChipHiddenWhenStatusNil() async throws {
        let repo = try await makeRepoOnFeature()
        defer { try? FileManager.default.removeItem(at: repo) }
        let state = RightPaneState(
            worktree: makeWorktree(at: repo, branch: "feature"),
            baseBranch: "main"
        )
        #expect(state.showBehindUpstreamChip == false)
    }

    @Test func upstreamChipVisibleEvenOnBaseBranch() async throws {
        // Unlike base chip, the upstream chip CAN show when current branch
        // equals baseBranch — local main could be behind origin/main and we
        // want to nudge that.
        let repo = try await makeRepoOnFeature()
        defer { try? FileManager.default.removeItem(at: repo) }
        let state = RightPaneState(
            worktree: makeWorktree(at: repo, branch: "main"),
            baseBranch: "main"
        )
        state.behindUpstream = GitService.BehindStatus(
            ref: "origin/main",
            sha: "deadbeef",
            count: 1,
            probedAt: Date()
        )
        #expect(state.showBehindUpstreamChip == true)
    }

    @Test func upstreamChipHiddenOnDetachedHead() async throws {
        let repo = try await makeRepoOnFeature()
        defer { try? FileManager.default.removeItem(at: repo) }
        let state = RightPaneState(
            worktree: makeWorktree(at: repo, branch: ""),
            baseBranch: "main"
        )
        state.behindUpstream = GitService.BehindStatus(
            ref: "origin/feature",
            sha: "deadbeef",
            count: 2,
            probedAt: Date()
        )
        #expect(state.showBehindUpstreamChip == false)
    }

    // MARK: - refreshSyncStatus integration

    private func makeFeatureWithRemoteAhead() async throws -> (publisher: URL, consumer: URL, remote: URL) {
        let publisher = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-sync-pub-\(UUID().uuidString)")
        let remote = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-sync-rmt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: publisher, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: publisher)
        _ = try await Process.git(["config", "user.email", "p@e"], cwd: publisher)
        _ = try await Process.git(["config", "user.name", "p"], cwd: publisher)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "root"], cwd: publisher)
        _ = try await Process.git(["init", "--bare", "-q", remote.path], cwd: nil)
        _ = try await Process.git(["remote", "add", "origin", remote.path], cwd: publisher)
        _ = try await Process.git(["push", "-q", "-u", "origin", "main"], cwd: publisher)

        let consumer = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-sync-cons-\(UUID().uuidString)")
        _ = try await Process.git(["clone", "-q", remote.path, consumer.path], cwd: nil)
        _ = try await Process.git(["config", "user.email", "c@e"], cwd: consumer)
        _ = try await Process.git(["config", "user.name", "c"], cwd: consumer)
        _ = try await Process.git(["checkout", "-q", "-b", "feature"], cwd: consumer)

        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "new on main"], cwd: publisher)
        _ = try await Process.git(["push", "-q", "origin", "main"], cwd: publisher)

        return (publisher, consumer, remote)
    }

    @Test func refreshSyncStatusPopulatesBehindBase() async throws {
        let (publisher, consumer, remote) = try await makeFeatureWithRemoteAhead()
        defer {
            try? FileManager.default.removeItem(at: publisher)
            try? FileManager.default.removeItem(at: consumer)
            try? FileManager.default.removeItem(at: remote)
        }
        let state = RightPaneState(
            worktree: makeWorktree(at: consumer, branch: "feature"),
            baseBranch: "main"
        )
        await state.refreshSyncStatus()
        #expect(state.behindBase?.ref == "origin/main")
        #expect(state.behindBase?.count == 1)
        #expect(state.behindUpstream == nil) // no upstream set on feature
    }

    @Test func refreshSyncStatusClearsBehindBaseWhenNoBaseRef() async throws {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-sync-nb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        _ = try await Process.git(["init", "-q", "-b", "feature"], cwd: repo)
        _ = try await Process.git(["config", "user.email", "t@e"], cwd: repo)
        _ = try await Process.git(["config", "user.name", "t"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "x"], cwd: repo)

        let state = RightPaneState(
            worktree: makeWorktree(at: repo, branch: "feature"),
            baseBranch: "main"
        )
        state.behindBase = GitService.BehindStatus(
            ref: "origin/main",
            sha: "deadbeef",
            count: 3,
            probedAt: Date()
        )
        await state.refreshSyncStatus()
        #expect(state.behindBase == nil)
    }

    @Test func refreshSyncStatusPopulatesBehindUpstreamWhenSomeoneElsePushed() async throws {
        // Two clones of the same bare remote — clone A pushes a new commit
        // to main; clone B should detect "behind origin/main" via the
        // upstream path (since B is ON main, so it has @{u} = origin/main).
        let remote = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-sync-up-rmt-\(UUID().uuidString)")
        let cloneA = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-sync-up-a-\(UUID().uuidString)")
        let cloneB = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-sync-up-b-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: remote)
            try? FileManager.default.removeItem(at: cloneA)
            try? FileManager.default.removeItem(at: cloneB)
        }
        _ = try await Process.git(["init", "--bare", "-q", remote.path], cwd: nil)
        // Seed with one commit by cloneA.
        _ = try await Process.git(["clone", "-q", remote.path, cloneA.path], cwd: nil)
        _ = try await Process.git(["config", "user.email", "a@e"], cwd: cloneA)
        _ = try await Process.git(["config", "user.name", "a"], cwd: cloneA)
        _ = try await Process.git(["checkout", "-q", "-b", "main"], cwd: cloneA)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "seed"], cwd: cloneA)
        _ = try await Process.git(["push", "-q", "-u", "origin", "main"], cwd: cloneA)
        // cloneB clones at the same SHA.
        _ = try await Process.git(["clone", "-q", remote.path, cloneB.path], cwd: nil)
        _ = try await Process.git(["config", "user.email", "b@e"], cwd: cloneB)
        _ = try await Process.git(["config", "user.name", "b"], cwd: cloneB)
        // cloneA pushes a new commit.
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "from A"], cwd: cloneA)
        _ = try await Process.git(["push", "-q", "origin", "main"], cwd: cloneA)

        let state = RightPaneState(
            worktree: makeWorktree(at: cloneB, branch: "main"),
            baseBranch: "main"
        )
        await state.refreshSyncStatus()
        // cloneB is on main; behindBase is suppressed by the predicate
        // (currentBranch == baseBranch) but the field is populated.
        // The interesting nudge here is behindUpstream.
        #expect(state.behindUpstream?.ref == "origin/main")
        #expect(state.behindUpstream?.count == 1)
        #expect(state.showBehindUpstreamChip == true)
    }

    // MARK: - rebase-triggered refresh

    private func makeFeatureBehindRemoteMain() async throws -> (repo: URL, remote: URL) {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-sync-reb-\(UUID().uuidString)")
        let remote = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-sync-reb-rmt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: repo)
        _ = try await Process.git(["config", "user.email", "t@e"], cwd: repo)
        _ = try await Process.git(["config", "user.name", "t"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "root"], cwd: repo)
        _ = try await Process.git(["init", "--bare", "-q", remote.path], cwd: nil)
        _ = try await Process.git(["remote", "add", "origin", remote.path], cwd: repo)
        _ = try await Process.git(["push", "-q", "-u", "origin", "main"], cwd: repo)

        // Create feature behind origin/main by one commit.
        _ = try await Process.git(["checkout", "-q", "-b", "feature"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "feat-1"], cwd: repo)

        // Push one commit to origin/main from a separate clone so feature is behind.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-sync-reb-tmp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = try await Process.git(["clone", "-q", remote.path, tmp.path], cwd: nil)
        _ = try await Process.git(["config", "user.email", "x@e"], cwd: tmp)
        _ = try await Process.git(["config", "user.name", "x"], cwd: tmp)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "main-1"], cwd: tmp)
        _ = try await Process.git(["push", "-q", "origin", "main"], cwd: tmp)

        return (repo, remote)
    }

    @Test func refreshSyncStatusFiresOnRebase() async throws {
        let (repo, remote) = try await makeFeatureBehindRemoteMain()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: remote)
        }
        let state = RightPaneState(
            worktree: makeWorktree(at: repo, branch: "feature"),
            baseBranch: "main"
        )

        // First refresh — feature is behind origin/main.
        await state.refresh()
        // The background refreshSyncStatus task needs a moment to finish on MainActor.
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(state.behindBase?.count == 1, "feature should be behind origin/main by 1 commit")

        // Rebase feature onto origin/main — now in sync.
        _ = try await Process.git(["rebase", "origin/main"], cwd: repo)

        // Second refresh — HEAD SHA changed (same branch), so refreshSyncStatus
        // should fire and update behindBase to 0.
        await state.refresh()
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(state.behindBase?.count == 0, "after rebase feature should be in sync with origin/main")
    }
}
