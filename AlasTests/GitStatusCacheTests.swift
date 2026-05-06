import Testing
import Foundation
@testable import Alas

@Suite(.serialized)
struct GitStatusCacheTests {
    private func makeRepoWithCommit() async throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-gs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: dir)
        _ = try await Process.git(["config", "user.email", "test@example.com"], cwd: dir)
        _ = try await Process.git(["config", "user.name", "Test"], cwd: dir)
        try "hello\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "a.txt"], cwd: dir)
        _ = try await Process.git(["commit", "-q", "-m", "init"], cwd: dir)
        return dir
    }

    @Test func modifiedFileSurfacesAsM() async throws {
        let repo = try await makeRepoWithCommit()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "changed\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let cache = GitStatusCache()
        let map = try await cache.statuses(forWorktreePath: repo)
        #expect(map["a.txt"] == .modified)
    }

    @Test func untrackedNotSurfacedAsBadge() async throws {
        let repo = try await makeRepoWithCommit()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "x".write(to: repo.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        let cache = GitStatusCache()
        let map = try await cache.statuses(forWorktreePath: repo)
        // Untracked files are not in the M/A/D/R badge set; they have no entry.
        #expect(map["new.txt"] == nil)
    }

    @Test func stagedAddSurfacesAsA() async throws {
        let repo = try await makeRepoWithCommit()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "x".write(to: repo.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "new.txt"], cwd: repo)
        let cache = GitStatusCache()
        let map = try await cache.statuses(forWorktreePath: repo)
        #expect(map["new.txt"] == .added)
    }

    @Test func deletedSurfacesAsD() async throws {
        let repo = try await makeRepoWithCommit()
        defer { try? FileManager.default.removeItem(at: repo) }
        try FileManager.default.removeItem(at: repo.appendingPathComponent("a.txt"))
        let cache = GitStatusCache()
        let map = try await cache.statuses(forWorktreePath: repo)
        #expect(map["a.txt"] == .deleted)
    }

    @Test func nonAsciiPathSurfacesCorrectly() async throws {
        let repo = try await makeRepoWithCommit()
        defer { try? FileManager.default.removeItem(at: repo) }
        let nonAscii = "src/résumé.txt"
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent("src"),
            withIntermediateDirectories: true
        )
        try "x".write(to: repo.appendingPathComponent(nonAscii), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", nonAscii], cwd: repo)
        let cache = GitStatusCache()
        let map = try await cache.statuses(forWorktreePath: repo)
        #expect(map[nonAscii] == .added)
    }
}
