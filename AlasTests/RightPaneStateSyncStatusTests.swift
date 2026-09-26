import Testing
import Foundation
@testable import Alas

/// Real git fixtures built once per test process. Tests copy them into
/// unique directories (or, when they never touch git, share them read-only).
private enum SyncStatusFixtures {
    struct CloneAndRemote: Sendable {
        let clone: URL
        let remote: URL
    }

    /// Repository with one empty `root` commit on `main`, checked out on a
    /// new `feature` branch.
    static let repoOnFeature = Task { () async throws -> URL in
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-sync-tpl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try await checkedGit(["init", "-q", "-b", "main"], cwd: repo)
        try await checkedGit(["config", "user.email", "t@e"], cwd: repo)
        try await checkedGit(["config", "user.name", "t"], cwd: repo)
        try await checkedGit(["commit", "-q", "--allow-empty", "-m", "root"], cwd: repo)
        try await checkedGit(["checkout", "-q", "-b", "feature"], cwd: repo)
        return repo
    }

    /// Bare remote + clone on `main` tracking `origin/main`. After the clone
    /// was made, someone else pushed one more commit to the remote's `main`;
    /// the clone has not fetched it, so it is behind by exactly one once it
    /// does. The remote history is written with `git fast-import` straight
    /// into the bare repository instead of a publisher clone that pushes.
    static let remoteAhead = Task { () async throws -> CloneAndRemote in
        let tmp = FileManager.default.temporaryDirectory
        let remote = tmp.appendingPathComponent("alas-sync-tpl-rmt-\(UUID().uuidString)")
        let clone = tmp.appendingPathComponent("alas-sync-tpl-clone-\(UUID().uuidString)")
        let now = Int(Date().timeIntervalSince1970)
        try await checkedGit(["init", "--bare", "-q", "-b", "main", remote.path], cwd: nil)
        try await checkedGit(
            ["--git-dir", remote.path, "fast-import", "--quiet", "--done"],
            cwd: nil,
            stdin: "commit refs/heads/main\ncommitter p <p@e> \(now - 2) +0000\ndata 5\nroot\n\ndone\n"
        )
        try await checkedGit(["clone", "-q", remote.path, clone.path], cwd: nil)
        try await checkedGit(["config", "user.email", "c@e"], cwd: clone)
        try await checkedGit(["config", "user.name", "c"], cwd: clone)
        // Lands after the clone, so the clone has neither the ref nor the object.
        try await checkedGit(
            ["--git-dir", remote.path, "fast-import", "--quiet", "--done"],
            cwd: nil,
            stdin: "commit refs/heads/main\ncommitter p <p@e> \(now - 1) +0000\ndata 12\nnew on main\n\n"
                + "from refs/heads/main^0\ndone\n"
        )
        return CloneAndRemote(clone: clone, remote: remote)
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

    /// Private copy of the shared `main` + `feature` repo, for tests that
    /// mutate it. No tracked files, so the copy needs no index refresh.
    private func makeRepoOnFeature() async throws -> URL {
        let template = try await SyncStatusFixtures.repoOnFeature.value
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-sync-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: template, to: tmp)
        return tmp
    }

    /// The chip-predicate tests only need a real repository path to build a
    /// `RightPaneState`; they never refresh or touch git. They share the
    /// template read-only instead of building a repository apiece.
    private func sharedRepoOnFeature() async throws -> URL {
        try await SyncStatusFixtures.repoOnFeature.value
    }

    @Test func refreshClearsHeadSHAWhenHeadCannotResolve() async throws {
        let repo = try await makeRepoOnFeature()
        defer { try? FileManager.default.removeItem(at: repo) }
        let state = RightPaneState(
            worktree: makeWorktree(at: repo, branch: "feature"),
            baseBranch: "main"
        )
        await state.refresh()
        let originalHead = try #require(state.currentHeadSHA.isEmpty ? nil : state.currentHeadSHA)

        _ = try await Process.git(["checkout", "-q", "--orphan", "unborn"], cwd: repo)
        await state.refresh()

        #expect(state.currentBranch == "unborn")
        #expect(state.currentHeadSHA == "")
        #expect(state.currentHeadSHA != originalHead)
        #expect(state.reviewLoop.snapshot?.local.headSHA == "")
        #expect(state.reviewLoop.snapshot?.errorMessage == "No commits yet.")
    }

    // MARK: - showBehindBaseChip

    @Test func baseChipHiddenWhenStatusNil() async throws {
        let repo = try await sharedRepoOnFeature()
        let state = RightPaneState(
            worktree: makeWorktree(at: repo, branch: "feature"),
            baseBranch: "main"
        )
        #expect(state.showBehindBaseChip == false)
    }

    @Test func baseChipVisibleWhenBehindOnNonBaseBranch() async throws {
        let repo = try await sharedRepoOnFeature()
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
        let repo = try await sharedRepoOnFeature()
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
        let repo = try await sharedRepoOnFeature()
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
        let repo = try await sharedRepoOnFeature()
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
        let repo = try await sharedRepoOnFeature()
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
        let repo = try await sharedRepoOnFeature()
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
        let repo = try await sharedRepoOnFeature()
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

    /// Private copy of the shared remote-ahead fixture (see
    /// `SyncStatusFixtures.remoteAhead`), with `origin` repointed at the
    /// copied remote.
    private func makeCloneBehindRemoteMain(prefix: String) async throws -> (clone: URL, remote: URL) {
        let template = try await SyncStatusFixtures.remoteAhead.value
        let clone = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        let remote = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-rmt-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: template.clone, to: clone)
        try FileManager.default.copyItem(at: template.remote, to: remote)
        try await SyncStatusFixtures.checkedGit(["remote", "set-url", "origin", remote.path], cwd: clone)
        return (clone, remote)
    }

    /// Consumer clone switched to a fresh `feature` branch (no upstream)
    /// while the remote's `main` is one commit ahead of its `origin/main`.
    private func makeFeatureWithRemoteAhead() async throws -> (consumer: URL, remote: URL) {
        let (consumer, remote) = try await makeCloneBehindRemoteMain(prefix: "alas-sync-cons")
        try await SyncStatusFixtures.checkedGit(["checkout", "-q", "-b", "feature"], cwd: consumer)
        return (consumer, remote)
    }

    @Test func refreshSyncStatusPopulatesBehindBase() async throws {
        let (consumer, remote) = try await makeFeatureWithRemoteAhead()
        defer {
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
        // Clone B sits on `main` (so it has @{u} = origin/main) while
        // someone else has pushed one more commit to the remote's main;
        // B should detect "behind origin/main" via the upstream path.
        let (cloneB, remote) = try await makeCloneBehindRemoteMain(prefix: "alas-sync-up-b")
        defer {
            try? FileManager.default.removeItem(at: remote)
            try? FileManager.default.removeItem(at: cloneB)
        }

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

    /// `feature` (one local commit on top of the root) behind the remote's
    /// `main` by one commit that has not been fetched yet.
    private func makeFeatureBehindRemoteMain() async throws -> (repo: URL, remote: URL) {
        let (repo, remote) = try await makeCloneBehindRemoteMain(prefix: "alas-sync-reb")
        try await SyncStatusFixtures.checkedGit(["checkout", "-q", "-b", "feature"], cwd: repo)
        try await SyncStatusFixtures.checkedGit(["commit", "-q", "--allow-empty", "-m", "feat-1"], cwd: repo)
        return (repo, remote)
    }

    /// Polls `condition` on the main actor for up to ~5s, returning as soon
    /// as it holds, instead of sleeping a fixed interval.
    private func wait(until condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
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
        // HEAD went from unknown to resolved, so refresh() cleared the chips
        // and re-probes in a background task; wait for it to publish.
        try await wait { state.behindBase != nil }
        #expect(state.behindBase?.count == 1, "feature should be behind origin/main by 1 commit")

        // Rebase feature onto origin/main — now in sync.
        _ = try await Process.git(["rebase", "origin/main"], cwd: repo)

        // Second refresh — HEAD SHA changed (same branch), so refreshSyncStatus
        // should fire and update behindBase to 0.
        await state.refresh()
        // The new HEAD SHA makes refresh() clear behindBase to nil before
        // re-probing in the background, so non-nil means the new probe landed.
        try await wait { state.behindBase != nil }
        #expect(state.behindBase?.count == 0, "after rebase feature should be in sync with origin/main")
    }

    // MARK: - BehindChip rendering

    @Test func behindChipDisplayTextComposesArrowCount() {
        #expect(BehindChip.displayText(count: 3) == "↓3")
        #expect(BehindChip.displayText(count: 2) == "↓2")
    }

    @Test func behindChipDisplayTextHandlesLargeCounts() {
        #expect(BehindChip.displayText(count: 12) == "↓12")
    }

    @Test func behindChipBaseRoleUsesAccentToken() {
        #expect(BehindChip.Role.base.colorToken == "accent")
    }

    @Test func behindChipUpstreamRoleUsesCautionToken() {
        #expect(BehindChip.Role.upstream.colorToken == "caution")
    }
}
