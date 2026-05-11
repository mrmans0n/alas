import Testing
import Foundation
@testable import Alas

@Suite(.serialized)
struct CommitsAheadTests {
    private func makeRepoWithUpstream() async throws -> (worktree: URL, remote: URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-ca-\(UUID().uuidString)")
        let remote = tmp.appendingPathComponent("remote.git")
        let worktree = tmp.appendingPathComponent("clone")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "--bare", "-b", "main"], cwd: remote)

        // Local repo with one commit, push to remote, set upstream.
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: worktree)
        try "hi".write(to: worktree.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "."], cwd: worktree)
        _ = try await Process.git(["commit", "-q", "-m", "base"], cwd: worktree)
        _ = try await Process.git(["remote", "add", "origin", remote.path], cwd: worktree)
        _ = try await Process.git(["push", "-q", "-u", "origin", "main"], cwd: worktree)
        return (worktree, remote)
    }

    @Test func returnsEmptyWhenUpToDateWithUpstream() async throws {
        let (worktree, remote) = try await makeRepoWithUpstream()
        defer {
            try? FileManager.default.removeItem(at: worktree.deletingLastPathComponent())
            _ = remote
        }
        let svc = GitService()
        let (commits, upstream) = try await svc.commitsAhead(at: worktree)
        #expect(commits.isEmpty)
        #expect(upstream == "origin/main")
    }

    @Test func returnsAheadCommitsNewestFirst() async throws {
        let (worktree, _) = try await makeRepoWithUpstream()
        defer { try? FileManager.default.removeItem(at: worktree.deletingLastPathComponent()) }
        try "1\n".write(to: worktree.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["commit", "-q", "-am", "feat: first ahead"], cwd: worktree)
        try "2\n".write(to: worktree.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["commit", "-q", "-am", "fix: second ahead"], cwd: worktree)

        let svc = GitService()
        let (commits, upstream) = try await svc.commitsAhead(at: worktree)
        #expect(upstream == "origin/main")
        #expect(commits.count == 2)
        // Newest first.
        #expect(commits[0].subject == "second ahead")
        #expect(commits[0].conventionalTag == "fix")
        #expect(commits[1].subject == "first ahead")
        #expect(commits[1].conventionalTag == "feat")
        // shortSha is the first 7 chars of sha.
        #expect(commits[0].shortSha == String(commits[0].sha.prefix(7)))
        // Numstat picked up the edit.
        #expect(commits[0].filesChanged >= 1)
    }

    @Test func returnsEmptyWhenNoUpstream() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-ca-noup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: tmp)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "solo"], cwd: tmp)

        let svc = GitService()
        let (commits, upstream) = try await svc.commitsAhead(at: tmp)
        #expect(commits.isEmpty)
        #expect(upstream == nil)
    }

    @Test func parsesMultiCommitOutputWithoutDropping() async throws {
        let (worktree, _) = try await makeRepoWithUpstream()
        defer { try? FileManager.default.removeItem(at: worktree.deletingLastPathComponent()) }
        for i in 1...5 {
            try "\(i)\n".write(to: worktree.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            _ = try await Process.git(["commit", "-q", "-am", "step \(i)"], cwd: worktree)
        }
        let svc = GitService()
        let (commits, _) = try await svc.commitsAhead(at: worktree)
        #expect(commits.count == 5)
        let subjects = commits.map(\.subject)
        #expect(subjects == ["step 5", "step 4", "step 3", "step 2", "step 1"])
    }
}
