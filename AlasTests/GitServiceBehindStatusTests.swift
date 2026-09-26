import Testing
import Foundation
@testable import Alas

@Suite(.serialized)
struct GitServiceBehindStatusTests {
    @Test func branchCommitCountIncludesPushedCommitsAndExcludesBaseHistory() async throws {
        let (repo, remote) = try await makeRepoWithRemote()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: remote)
        }
        _ = try await Process.git(["checkout", "-q", "-b", "feature"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "one"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "two"], cwd: repo)
        _ = try await Process.git(["push", "-q", "-u", "origin", "feature"], cwd: repo)
        let git = GitService()
        let summary = try #require(try await git.branchCommitCount(worktreePath: repo, baseBranch: "main"))
        #expect(summary.count == 2)
        #expect(summary.baseRef == "origin/main")
        #expect(try await git.branchCommitCount(worktreePath: repo, baseBranch: "missing") == nil)
        _ = try await Process.git(["branch", "stack-base"], cwd: repo)
        #expect(try await git.branchCommitCount(worktreePath: repo, baseBranch: "stack-base")?.count == 0)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "three"], cwd: repo)
        #expect(try await git.branchCommitCount(worktreePath: repo, baseBranch: "stack-base")?.count == 1)
    }

    private struct RepoWithRemote: Sendable {
        let repo: URL
        let remote: URL
    }

    /// Real repositories built once per test process and copied per test, so
    /// each test starts from the same state as the old per-test
    /// init/config/commit(/push) sequence without re-spawning those git
    /// processes every time.
    private static let localRepoTemplate = Task { try await makeLocalRepoTemplate() }
    private static let repoWithRemoteTemplate = Task { try await makeRepoWithRemoteTemplate() }

    @discardableResult
    private static func checkedGit(_ args: [String], cwd: URL?) async throws -> String {
        let result = try await Process.git(args, cwd: cwd)
        guard result.exitCode == 0 else { throw ProcessError.nonZeroExit(result.exitCode, result.stderr) }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `main` with a single empty `init` commit and no remotes.
    private static func makeLocalRepoTemplate() async throws -> URL {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-behind-template-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try await checkedGit(["init", "-q", "-b", "main"], cwd: repo)
        try await checkedGit(["config", "user.email", "t@e"], cwd: repo)
        try await checkedGit(["config", "user.name", "t"], cwd: repo)
        try await checkedGit(["commit", "-q", "--allow-empty", "-m", "init"], cwd: repo)
        return repo
    }

    /// The local template's `main` pushed with `-u` to a bare `origin` whose
    /// HEAD points at `main`.
    private static func makeRepoWithRemoteTemplate() async throws -> RepoWithRemote {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-behind-rmt-template-\(UUID().uuidString)")
        let repo = root.appendingPathComponent("repo")
        let remote = root.appendingPathComponent("remote.git")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: try await localRepoTemplate.value, to: repo)
        try await checkedGit(["init", "--bare", "-q", remote.path], cwd: nil)
        try await checkedGit(["remote", "add", "origin", remote.path], cwd: repo)
        try await checkedGit(["push", "-q", "-u", "origin", "main"], cwd: repo)
        try await checkedGit(["--git-dir", remote.path, "symbolic-ref", "HEAD", "refs/heads/main"], cwd: nil)
        return RepoWithRemote(repo: repo, remote: remote)
    }

    private func makeLocalRepo(_ prefix: String) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: try await Self.localRepoTemplate.value, to: dir)
        return dir
    }

    private func makeRepoWithRemote() async throws -> (URL, URL) {
        let template = try await Self.repoWithRemoteTemplate.value
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-behind-\(UUID().uuidString)")
        let remote = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-behind-rmt-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: template.repo, to: repo)
        try FileManager.default.copyItem(at: template.remote, to: remote)
        // `refs/remotes/origin/main` and the upstream config survive the copy;
        // only the URL must be repointed at this test's own remote.
        try await Self.checkedGit(["remote", "set-url", "origin", remote.path], cwd: repo)
        return (repo, remote)
    }

    @Test func resolveBaseRefPrefersOrigin() async throws {
        let (repo, remote) = try await makeRepoWithRemote()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: remote)
        }
        let svc = GitService()
        let resolved = try await svc.resolveBaseRef(worktreePath: repo, baseBranch: "main")
        #expect(resolved?.remote == "origin")
        #expect(resolved?.baseRef == "origin/main")
        #expect(resolved?.fetchBranch == "main")
    }

    @Test func resolveBaseRefCanPreferLocalSimpleBranch() async throws {
        let (repo, remote) = try await makeRepoWithRemote()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: remote)
        }
        let svc = GitService()
        let resolved = try await svc.resolveBaseRef(worktreePath: repo, baseBranch: "main", preferLocal: true)
        #expect(resolved?.remote == nil)
        #expect(resolved?.baseRef == "main")
        #expect(resolved?.fetchBranch == nil)
    }

    @Test func resolveBaseRefSplitsRemoteQualifiedBranchForFetch() async throws {
        let (repo, remote) = try await makeRepoWithRemote()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: remote)
        }
        let svc = GitService()
        let resolved = try await svc.resolveBaseRef(worktreePath: repo, baseBranch: "origin/main")
        #expect(resolved?.remote == "origin")
        #expect(resolved?.baseRef == "origin/main")
        #expect(resolved?.fetchBranch == "main")
    }

    @Test func resolveBaseRefPrefersLocalSlashBranchOverRemoteTrackingRef() async throws {
        let (repo, remote) = try await makeRepoWithRemote()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: remote)
        }
        let otherRemote = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-behind-team-rmt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: otherRemote) }
        _ = try await Process.git(["init", "--bare", "-q", otherRemote.path], cwd: nil)
        _ = try await Process.git(["remote", "add", "team", otherRemote.path], cwd: repo)
        _ = try await Process.git(["checkout", "-q", "-b", "team/main"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "local slash branch"], cwd: repo)
        _ = try await Process.git(["checkout", "-q", "main"], cwd: repo)
        _ = try await Process.git(["push", "-q", "team", "main"], cwd: repo)

        let svc = GitService()
        let resolved = try await svc.resolveBaseRef(worktreePath: repo, baseBranch: "team/main")
        #expect(resolved?.remote == nil)
        #expect(resolved?.baseRef == "team/main")
        #expect(resolved?.fetchBranch == nil)
    }

    @Test func resolveBaseRefFallsBackToLocalBase() async throws {
        let dir = try await makeLocalRepo("alas-behind-loc")
        defer { try? FileManager.default.removeItem(at: dir) }

        let svc = GitService()
        let resolved = try await svc.resolveBaseRef(worktreePath: dir, baseBranch: "main")
        #expect(resolved?.remote == nil)
        #expect(resolved?.baseRef == "main")
        #expect(resolved?.fetchBranch == nil)
    }

    @Test func resolveBaseRefReturnsNilWhenNoBaseExists() async throws {
        let dir = try await makeLocalRepo("alas-behind-nil")
        defer { try? FileManager.default.removeItem(at: dir) }
        // The only branch is `feature`: no local or remote `main` exists.
        try await Self.checkedGit(["branch", "-m", "main", "feature"], cwd: dir)

        let svc = GitService()
        let resolved = try await svc.resolveBaseRef(worktreePath: dir, baseBranch: "main")
        #expect(resolved == nil)
    }

    @Test func resolveUpstreamRefReturnsTrackedRef() async throws {
        let (repo, remote) = try await makeRepoWithRemote()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: remote)
        }
        let svc = GitService()
        let resolved = try await svc.resolveUpstreamRef(worktreePath: repo)
        #expect(resolved?.remote == "origin")
        #expect(resolved?.ref == "origin/main")
    }

    @Test func resolveUpstreamRefHandlesRemoteNameWithSlash() async throws {
        // Configure a remote whose name contains a slash. Without robust
        // parsing the splitter would pick "foo" as the remote and silently
        // fail to fetch.
        let repo = try await makeLocalRepo("alas-behind-slash")
        let remote = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-behind-slash-rmt-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: remote)
        }
        _ = try await Process.git(["init", "--bare", "-q", remote.path], cwd: nil)
        _ = try await Process.git(["remote", "add", "foo/bar", remote.path], cwd: repo)
        _ = try await Process.git(["push", "-q", "-u", "foo/bar", "main"], cwd: repo)

        let svc = GitService()
        let resolved = try await svc.resolveUpstreamRef(worktreePath: repo)
        #expect(resolved?.remote == "foo/bar")
        #expect(resolved?.ref == "foo/bar/main")
    }

    @Test func resolveUpstreamRefReturnsNilForUnpushedBranch() async throws {
        let (repo, remote) = try await makeRepoWithRemote()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: remote)
        }
        _ = try await Process.git(["checkout", "-q", "-b", "feature"], cwd: repo)

        let svc = GitService()
        let resolved = try await svc.resolveUpstreamRef(worktreePath: repo)
        #expect(resolved == nil)
    }

    @Test func upstreamDivergenceCountsAheadAndBehindAgainstTrackingRef() async throws {
        let (repo, remote) = try await makeRepoWithRemote()
        let peer = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-divergence-peer-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: remote)
            try? FileManager.default.removeItem(at: peer)
        }

        _ = try await Process.git(["clone", "-q", remote.path, peer.path], cwd: nil)
        _ = try await Process.git(
            ["-c", "user.email=peer@example.com", "-c", "user.name=Peer", "commit", "-q", "--allow-empty", "-m", "remote"],
            cwd: peer
        )
        _ = try await Process.git(["push", "-q", "origin", "main"], cwd: peer)
        _ = try await Process.git(["fetch", "-q", "origin", "main"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "local"], cwd: repo)

        let status = try await GitService().upstreamDivergence(worktreePath: repo)
        #expect(status?.upstreamRef == "origin/main")
        #expect(status?.ahead == 1)
        #expect(status?.behind == 1)
    }

    @Test func behindStatusReturnsCount() async throws {
        let (repo, remote) = try await makeRepoWithRemote()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: remote)
        }
        // `feature` stays at the pushed base while `main` moves ahead.
        _ = try await Process.git(["branch", "feature"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "m1"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "m2"], cwd: repo)
        _ = try await Process.git(["push", "-q", "origin", "main"], cwd: repo)
        _ = try await Process.git(["checkout", "-q", "feature"], cwd: repo)

        let svc = GitService()
        let status = try await svc.behindStatus(worktreePath: repo, ref: "origin/main")
        #expect(status.ref == "origin/main")
        #expect(status.count == 2)
        #expect(status.sha.count == 40)
    }

    @Test func behindStatusBehindZeroWhenInSync() async throws {
        let (repo, remote) = try await makeRepoWithRemote()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: remote)
        }
        let svc = GitService()
        let status = try await svc.behindStatus(worktreePath: repo, ref: "origin/main")
        #expect(status.ref == "origin/main")
        #expect(status.count == 0)
    }

    @Test func behindStatusThrowsWhenRefMissing() async throws {
        let dir = try await makeLocalRepo("alas-behind-miss")
        defer { try? FileManager.default.removeItem(at: dir) }

        let svc = GitService()
        await #expect(throws: GitService.BehindStatusError.self) {
            _ = try await svc.behindStatus(worktreePath: dir, ref: "origin/nope")
        }
    }

    @Test func fetchRefUpdatesRemoteTrackingRef() async throws {
        let (repo, remote) = try await makeRepoWithRemote()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: remote)
        }
        let consumer = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-behind-cons-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: consumer) }
        // The consumer only fetches, so it needs no commit identity.
        _ = try await Process.git(["clone", "-q", remote.path, consumer.path], cwd: nil)

        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "new"], cwd: repo)
        _ = try await Process.git(["push", "-q", "origin", "main"], cwd: repo)

        let svc = GitService()
        let before = try await svc.behindStatus(worktreePath: consumer, ref: "origin/main")
        #expect(before.count == 0)

        try await svc.fetchRef(worktreePath: consumer, remote: "origin", branch: "main")

        let after = try await svc.behindStatus(worktreePath: consumer, ref: "origin/main")
        #expect(after.count == 1)
    }
}
