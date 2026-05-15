import Testing
import Foundation
@testable import Alas

@Suite(.serialized)
struct GitServiceUpstreamTests {
    private func makeRepoWithRemote() async throws -> (URL, URL) {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-up-\(UUID().uuidString)")
        let remote = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-rmt-\(UUID().uuidString)")
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

    @Test func trueWhenHeadEqualsUpstream() async throws {
        let (repo, remote) = try await makeRepoWithRemote()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: remote)
        }
        let svc = GitService()
        #expect(try await svc.isHeadAtOrBehindUpstream(worktreePath: repo) == true)
    }

    @Test func falseWhenHeadAhead() async throws {
        let (repo, remote) = try await makeRepoWithRemote()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: remote)
        }
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "extra"], cwd: repo)
        let svc = GitService()
        #expect(try await svc.isHeadAtOrBehindUpstream(worktreePath: repo) == false)
    }

    @Test func falseWhenNoUpstream() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-noup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: dir)
        _ = try await Process.git(["config", "user.email", "t@e"], cwd: dir)
        _ = try await Process.git(["config", "user.name", "t"], cwd: dir)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "x"], cwd: dir)

        let svc = GitService()
        #expect(try await svc.isHeadAtOrBehindUpstream(worktreePath: dir) == false)
    }
}
