import Testing
import Foundation
@testable import Alas

@Suite(.serialized)
struct GitServicePullTests {
    /// Bare remote + a clone checked out on `main` tracking `origin/main`.
    /// Returns the consumer clone and the remote (both must be cleaned up).
    fileprivate static func makeCloneOnMain() async throws -> (clone: URL, remote: URL) {
        let remote = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-pull-rmt-\(UUID().uuidString)")
        let seed = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-pull-seed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: seed) }
        _ = try await Process.git(["init", "--bare", "-q", remote.path], cwd: nil)
        _ = try await Process.git(["clone", "-q", remote.path, seed.path], cwd: nil)
        _ = try await Process.git(["config", "user.email", "s@e"], cwd: seed)
        _ = try await Process.git(["config", "user.name", "s"], cwd: seed)
        _ = try await Process.git(["config", "commit.gpgsign", "false"], cwd: seed)
        _ = try await Process.git(["checkout", "-q", "-b", "main"], cwd: seed)
        try "base\n".write(to: seed.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "a.txt"], cwd: seed)
        _ = try await Process.git(["commit", "-q", "-m", "base"], cwd: seed)
        _ = try await Process.git(["push", "-q", "-u", "origin", "main"], cwd: seed)
        _ = try await Process.git(["--git-dir", remote.path, "symbolic-ref", "HEAD", "refs/heads/main"], cwd: nil)

        let clone = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-pull-clone-\(UUID().uuidString)")
        _ = try await Process.git(["clone", "-q", remote.path, clone.path], cwd: nil)
        _ = try await Process.git(["config", "user.email", "c@e"], cwd: clone)
        _ = try await Process.git(["config", "user.name", "c"], cwd: clone)
        _ = try await Process.git(["config", "commit.gpgsign", "false"], cwd: clone)
        return (clone, remote)
    }

    /// Pushes one more commit to `origin/main` from a throwaway clone so the
    /// primary clone falls behind its upstream. `modify` controls the change.
    fileprivate static func pushToRemoteMain(_ remote: URL, file: String, contents: String, message: String) async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-pull-push-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = try await Process.git(["clone", "-q", remote.path, tmp.path], cwd: nil)
        _ = try await Process.git(["config", "user.email", "x@e"], cwd: tmp)
        _ = try await Process.git(["config", "user.name", "x"], cwd: tmp)
        _ = try await Process.git(["config", "commit.gpgsign", "false"], cwd: tmp)
        try contents.write(to: tmp.appendingPathComponent(file), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", file], cwd: tmp)
        _ = try await Process.git(["commit", "-q", "-m", message], cwd: tmp)
        _ = try await Process.git(["push", "-q", "origin", "main"], cwd: tmp)
    }

    private static func headSHA(_ repo: URL, _ ref: String) async throws -> String {
        try await Process.git(["rev-parse", ref], cwd: repo).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test func pullFastForwardsWhenNoLocalCommits() async throws {
        let (clone, remote) = try await Self.makeCloneOnMain()
        defer {
            try? FileManager.default.removeItem(at: clone)
            try? FileManager.default.removeItem(at: remote)
        }
        try await Self.pushToRemoteMain(remote, file: "b.txt", contents: "new\n", message: "remote-1")

        let svc = GitService()
        let result = try await svc.pull(worktreePath: clone)
        #expect(result == .clean)
        let head = try await Self.headSHA(clone, "HEAD")
        let upstream = try await Self.headSHA(clone, "origin/main")
        #expect(head == upstream)
    }

    @Test func pullRebasesLocalCommitsWhenDivergedCleanly() async throws {
        let (clone, remote) = try await Self.makeCloneOnMain()
        defer {
            try? FileManager.default.removeItem(at: clone)
            try? FileManager.default.removeItem(at: remote)
        }
        // Local commit touching a different file than the remote one.
        try "local\n".write(to: clone.appendingPathComponent("local.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "local.txt"], cwd: clone)
        _ = try await Process.git(["commit", "-q", "-m", "local-1"], cwd: clone)
        try await Self.pushToRemoteMain(remote, file: "b.txt", contents: "new\n", message: "remote-1")

        let svc = GitService()
        let result = try await svc.pull(worktreePath: clone)
        #expect(result == .clean)
        // Both the remote file and the replayed local file exist.
        #expect(FileManager.default.fileExists(atPath: clone.appendingPathComponent("b.txt").path))
        #expect(FileManager.default.fileExists(atPath: clone.appendingPathComponent("local.txt").path))
    }

    @Test func pullReturnsConflictWhenDivergedConflicting() async throws {
        let (clone, remote) = try await Self.makeCloneOnMain()
        defer {
            try? FileManager.default.removeItem(at: clone)
            try? FileManager.default.removeItem(at: remote)
        }
        // Local commit and remote commit modify the SAME line of a.txt.
        try "local change\n".write(to: clone.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["commit", "-q", "-am", "local edit"], cwd: clone)
        try await Self.pushToRemoteMain(remote, file: "a.txt", contents: "remote change\n", message: "remote edit")

        let svc = GitService()
        let result = try await svc.pull(worktreePath: clone)
        guard case .conflict(let files) = result else {
            Issue.record("expected .conflict, got \(result)")
            return
        }
        #expect(files.contains(where: { $0.path == "a.txt" }))
    }

    @Test func pullThrowsWhenNoUpstream() async throws {
        let (clone, remote) = try await Self.makeCloneOnMain()
        defer {
            try? FileManager.default.removeItem(at: clone)
            try? FileManager.default.removeItem(at: remote)
        }
        // A fresh local branch with no upstream tracking ref.
        _ = try await Process.git(["checkout", "-q", "-b", "no-upstream"], cwd: clone)

        let svc = GitService()
        await #expect(throws: PullError.noUpstream) {
            _ = try await svc.pull(worktreePath: clone)
        }
    }
}
