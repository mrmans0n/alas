import Foundation
import Testing
@testable import Alas

struct RevisionSnapshotCacheTests {
    private func makeRepo(name: String) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-dragout-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: dir)
        _ = try await Process.git(["config", "user.email", "test@example.com"], cwd: dir)
        _ = try await Process.git(["config", "user.name", "Test"], cwd: dir)
        return dir
    }

    @Test func refComponentReplacesUnsafeCharacters() {
        #expect(RevisionSnapshotCache.refComponent("stash@{0}^3") == "stash--0--3")
    }

    @Test func refComponentKeepsShasIntact() {
        #expect(RevisionSnapshotCache.refComponent("a1b2c3d") == "a1b2c3d")
    }

    @Test func refComponentDistinguishesStashFromItsUntrackedParent() {
        let tracked = RevisionSnapshotCache.refComponent("stash@{0}")
        let untracked = RevisionSnapshotCache.refComponent("stash@{0}^3")
        #expect(tracked != untracked)
    }

    @Test func snapshotURLPreservesRelativePath() {
        let cache = RevisionSnapshotCache(sessionID: "fixed-session")
        let url = cache.snapshotURL(ref: "a1b2c3d", path: "Sources/Right/ChangedRow.swift")
        #expect(Array(url.pathComponents.suffix(4)) == ["a1b2c3d", "Sources", "Right", "ChangedRow.swift"])
        #expect(url.path.hasPrefix(cache.sessionDirectory.path))
    }

    @Test func snapshotWritesTheBlobAtThatRevisionNotTheWorkingTree() async throws {
        let repo = try await makeRepo(name: "snapshot")
        defer { try? FileManager.default.removeItem(at: repo) }
        let file = repo.appendingPathComponent("hello.txt")
        try "committed".write(to: file, atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "hello.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "add hello"], cwd: repo)
        try "working tree".write(to: file, atomically: true, encoding: .utf8)

        let cache = RevisionSnapshotCache(sessionID: UUID().uuidString)
        let snapshot = await cache.snapshot(worktreePath: repo, ref: "HEAD", path: "hello.txt")

        let unwrapped = try #require(snapshot)
        #expect(try String(contentsOf: unwrapped, encoding: .utf8) == "committed")
        #expect(unwrapped.lastPathComponent == "hello.txt")
        await cache.removeSessionDirectory()
    }

    @Test func snapshotReturnsNilWhenTheBlobDoesNotExistAtThatRevision() async throws {
        let repo = try await makeRepo(name: "missing")
        defer { try? FileManager.default.removeItem(at: repo) }
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "init"], cwd: repo)

        let cache = RevisionSnapshotCache(sessionID: UUID().uuidString)
        let snapshot = await cache.snapshot(worktreePath: repo, ref: "HEAD", path: "nope.txt")

        #expect(snapshot == nil)
    }

    @Test func removeSessionDirectoryDeletesWrittenSnapshots() async throws {
        let repo = try await makeRepo(name: "cleanup")
        defer { try? FileManager.default.removeItem(at: repo) }
        let file = repo.appendingPathComponent("a.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "a.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "a"], cwd: repo)

        let cache = RevisionSnapshotCache(sessionID: UUID().uuidString)
        _ = await cache.snapshot(worktreePath: repo, ref: "HEAD", path: "a.txt")
        #expect(FileManager.default.fileExists(atPath: cache.sessionDirectory.path))

        await cache.removeSessionDirectory()
        #expect(!FileManager.default.fileExists(atPath: cache.sessionDirectory.path))
    }
}
