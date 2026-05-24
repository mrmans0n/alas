import Testing
import Foundation
@testable import Alas

@Suite(.serialized)
struct GitServiceBehindStatusTests {
    private func makeRepoWithRemote() async throws -> (URL, URL) {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-behind-\(UUID().uuidString)")
        let remote = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-behind-rmt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: repo)
        _ = try await Process.git(["config", "user.email", "t@e"], cwd: repo)
        _ = try await Process.git(["config", "user.name", "t"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "init"], cwd: repo)
        _ = try await Process.git(["init", "--bare", "-q", remote.path], cwd: nil)
        _ = try await Process.git(["remote", "add", "origin", remote.path], cwd: repo)
        _ = try await Process.git(["push", "-q", "-u", "origin", "main"], cwd: repo)
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
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-behind-loc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: dir)
        _ = try await Process.git(["config", "user.email", "t@e"], cwd: dir)
        _ = try await Process.git(["config", "user.name", "t"], cwd: dir)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "init"], cwd: dir)

        let svc = GitService()
        let resolved = try await svc.resolveBaseRef(worktreePath: dir, baseBranch: "main")
        #expect(resolved?.remote == nil)
        #expect(resolved?.baseRef == "main")
        #expect(resolved?.fetchBranch == nil)
    }

    @Test func resolveBaseRefReturnsNilWhenNoBaseExists() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-behind-nil-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await Process.git(["init", "-q", "-b", "feature"], cwd: dir)
        _ = try await Process.git(["config", "user.email", "t@e"], cwd: dir)
        _ = try await Process.git(["config", "user.name", "t"], cwd: dir)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "x"], cwd: dir)

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
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-behind-slash-\(UUID().uuidString)")
        let remote = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-behind-slash-rmt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: remote)
        }
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: repo)
        _ = try await Process.git(["config", "user.email", "t@e"], cwd: repo)
        _ = try await Process.git(["config", "user.name", "t"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "root"], cwd: repo)
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

    @Test func behindStatusReturnsCount() async throws {
        let (repo, remote) = try await makeRepoWithRemote()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: remote)
        }
        _ = try await Process.git(["checkout", "-q", "-b", "feature"], cwd: repo)
        _ = try await Process.git(["checkout", "-q", "main"], cwd: repo)
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
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-behind-miss-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: dir)
        _ = try await Process.git(["config", "user.email", "t@e"], cwd: dir)
        _ = try await Process.git(["config", "user.name", "t"], cwd: dir)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "init"], cwd: dir)

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
        _ = try await Process.git(["clone", "-q", remote.path, consumer.path], cwd: nil)
        _ = try await Process.git(["config", "user.email", "c@e"], cwd: consumer)
        _ = try await Process.git(["config", "user.name", "c"], cwd: consumer)

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
