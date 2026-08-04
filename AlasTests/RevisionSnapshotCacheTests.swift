import CryptoKit
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

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Writes an LFS pointer file at `fileName`, and, unless `withObject` is
    /// false, the real object bytes it resolves to under the repo's default
    /// `.git/lfs/objects` store — mirroring what `git lfs` itself would leave
    /// on disk after a real fetch, without needing `git-lfs` installed to
    /// produce it.
    private func writeLFSPointer(
        for data: Data,
        named fileName: String,
        in repo: URL,
        withObject: Bool = true
    ) throws {
        let oid = sha256Hex(data)
        let pointer = """
        version https://git-lfs.github.com/spec/v1
        oid sha256:\(oid)
        size \(data.count)

        """
        try pointer.write(
            to: repo.appendingPathComponent(fileName),
            atomically: true,
            encoding: .utf8
        )
        guard withObject else { return }
        let objectDir = repo.appendingPathComponent(".git/lfs/objects")
            .appendingPathComponent(String(oid.prefix(2)))
            .appendingPathComponent(String(oid.dropFirst(2).prefix(2)))
        try FileManager.default.createDirectory(at: objectDir, withIntermediateDirectories: true)
        try data.write(to: objectDir.appendingPathComponent(oid))
    }

    @Test func refComponentReplacesUnsafeCharacters() {
        #expect(RevisionSnapshotCache.refComponent("stash@{0}^3") == "stash%40%7B0%7D%5E3")
    }

    @Test func refComponentKeepsShasIntact() {
        #expect(RevisionSnapshotCache.refComponent("a1b2c3d") == "a1b2c3d")
    }

    @Test func refComponentDistinguishesStashFromItsUntrackedParent() {
        let tracked = RevisionSnapshotCache.refComponent("stash@{0}")
        let untracked = RevisionSnapshotCache.refComponent("stash@{0}^3")
        #expect(tracked != untracked)
    }

    @Test func refComponentIsInjectiveForCollidingRefs() {
        #expect(RevisionSnapshotCache.refComponent("feature/foo") != RevisionSnapshotCache.refComponent("feature-foo"))
    }

    @Test func snapshotURLPreservesRelativePath() {
        let cache = RevisionSnapshotCache(sessionID: "fixed-session")
        let worktree = URL(fileURLWithPath: "/tmp/some-repo")
        let url = cache.snapshotURL(worktreePath: worktree, ref: "a1b2c3d", path: "Sources/Right/ChangedRow.swift")
        #expect(Array(url.pathComponents.suffix(4)) == ["a1b2c3d", "Sources", "Right", "ChangedRow.swift"])
        #expect(url.path.hasPrefix(cache.sessionDirectory.path))
    }

    @Test func snapshotURLDiffersByWorktreeForTheSameRefAndPath() {
        let cache = RevisionSnapshotCache(sessionID: "fixed-session")
        let worktreeA = URL(fileURLWithPath: "/tmp/repo-a")
        let worktreeB = URL(fileURLWithPath: "/tmp/repo-b")
        let urlA = cache.snapshotURL(worktreePath: worktreeA, ref: "HEAD", path: "README.md")
        let urlB = cache.snapshotURL(worktreePath: worktreeB, ref: "HEAD", path: "README.md")
        #expect(urlA != urlB)
        // Deterministic within a session: the same worktree must keep
        // producing the same destination across calls, or a cache hit for
        // one call would miss the file a later call actually wrote.
        #expect(cache.snapshotURL(worktreePath: worktreeA, ref: "HEAD", path: "README.md") == urlA)
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

    /// The app receiving a drag can save over the snapshot file. Reusing it
    /// would then hand out bytes that no longer match the revision.
    @Test func snapshotIsRewrittenAfterTheReceivingAppEditsIt() async throws {
        let repo = try await makeRepo(name: "clobbered")
        defer { try? FileManager.default.removeItem(at: repo) }
        let file = repo.appendingPathComponent("hello.txt")
        try "committed".write(to: file, atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "hello.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "add hello"], cwd: repo)

        let cache = RevisionSnapshotCache(sessionID: UUID().uuidString)
        let first = try #require(await cache.snapshot(worktreePath: repo, ref: "HEAD", path: "hello.txt"))
        #expect(try String(contentsOf: first, encoding: .utf8) == "committed")

        // Stand in for an editor saving the dropped file back to disk.
        try "edited by the receiving app".write(to: first, atomically: true, encoding: .utf8)

        let second = try #require(await cache.snapshot(worktreePath: repo, ref: "HEAD", path: "hello.txt"))
        #expect(try String(contentsOf: second, encoding: .utf8) == "committed")
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

    @Test func snapshotMemoizesAMissingBlobAndDoesNotReRunGitShow() async throws {
        let repo = try await makeRepo(name: "missing-memo")
        defer { try? FileManager.default.removeItem(at: repo) }
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "init"], cwd: repo)

        let cache = RevisionSnapshotCache(sessionID: UUID().uuidString)
        let first = await cache.snapshot(worktreePath: repo, ref: "HEAD", path: "nope.txt")
        #expect(first == nil)

        // The blob now genuinely exists at the (new) HEAD. If the second
        // lookup re-ran `git show` it would succeed; a repeat nil here can
        // only come from the negative-memoization cache keyed on the ref
        // string "HEAD", not from re-inspecting the repository.
        let file = repo.appendingPathComponent("nope.txt")
        try "now it exists".write(to: file, atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "nope.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "add nope.txt"], cwd: repo)

        let second = await cache.snapshot(worktreePath: repo, ref: "HEAD", path: "nope.txt")
        #expect(second == nil)

        await cache.removeSessionDirectory()
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

    @Test func sweepDoesNotDeleteFreshSiblingSessionDirectories() async throws {
        let repo = try await makeRepo(name: "sweep")
        defer { try? FileManager.default.removeItem(at: repo) }
        let file = repo.appendingPathComponent("a.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "a.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "a"], cwd: repo)

        let sibling = RevisionSnapshotCache(sessionID: "sibling-\(UUID().uuidString)")
        _ = await sibling.snapshot(worktreePath: repo, ref: "HEAD", path: "a.txt")
        #expect(FileManager.default.fileExists(atPath: sibling.sessionDirectory.path))

        let cache = RevisionSnapshotCache(sessionID: UUID().uuidString)
        _ = await cache.snapshot(worktreePath: repo, ref: "HEAD", path: "a.txt")

        #expect(FileManager.default.fileExists(atPath: sibling.sessionDirectory.path))

        await sibling.removeSessionDirectory()
        await cache.removeSessionDirectory()
    }

    @Test func differentWorktreesDoNotShareCacheEntries() async throws {
        let repoA = try await makeRepo(name: "worktree-a")
        defer { try? FileManager.default.removeItem(at: repoA) }
        let repoB = try await makeRepo(name: "worktree-b")
        defer { try? FileManager.default.removeItem(at: repoB) }

        // Same relative path, same ref name, different repos. Before the
        // worktree was folded into the cache key, this collided on a single
        // dictionary entry: the second repo's lookup would hit the first
        // repo's cached URL and hand back the wrong file's bytes.
        let fileA = repoA.appendingPathComponent("shared.txt")
        try "content from repo A".write(to: fileA, atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "shared.txt"], cwd: repoA)
        _ = try await Process.git(["commit", "-q", "-m", "a"], cwd: repoA)

        let fileB = repoB.appendingPathComponent("shared.txt")
        try "content from repo B".write(to: fileB, atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "shared.txt"], cwd: repoB)
        _ = try await Process.git(["commit", "-q", "-m", "b"], cwd: repoB)

        let cache = RevisionSnapshotCache(sessionID: UUID().uuidString)

        let snapshotA = await cache.snapshot(worktreePath: repoA, ref: "HEAD", path: "shared.txt")
        let unwrappedA = try #require(snapshotA)
        #expect(try String(contentsOf: unwrappedA, encoding: .utf8) == "content from repo A")

        let snapshotB = await cache.snapshot(worktreePath: repoB, ref: "HEAD", path: "shared.txt")
        let unwrappedB = try #require(snapshotB)
        #expect(try String(contentsOf: unwrappedB, encoding: .utf8) == "content from repo B")

        await cache.removeSessionDirectory()
    }

    @Test func cancelledSnapshotIsNotMemoizedAsMissing() async throws {
        let repo = try await makeRepo(name: "cancel")
        defer { try? FileManager.default.removeItem(at: repo) }

        // A sizeable blob gives `git show` real decompress/pipe/write work
        // to do, so cancelling right after kicking off the task has a
        // realistic chance of landing while the process is still running
        // rather than after it has already exited on its own. 5MB is
        // enough margin over Swift's task-scheduling overhead without
        // making this test a heavy I/O cost in CI. If the process happens
        // to finish first, the assertions below still hold (nothing was
        // ever memoized as missing), so this test cannot go spuriously red
        // — it just wouldn't have exercised the interesting path on that
        // particular run.
        let file = repo.appendingPathComponent("big.bin")
        let bytes = Data(count: 5 * 1024 * 1024)
        try bytes.write(to: file)
        _ = try await Process.git(["add", "big.bin"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "add big blob"], cwd: repo)

        let cache = RevisionSnapshotCache(sessionID: UUID().uuidString)

        let task = Task {
            await cache.snapshot(worktreePath: repo, ref: "HEAD", path: "big.bin")
        }
        task.cancel()
        _ = await task.value

        // A fresh, uncancelled lookup for the same key must still succeed:
        // the earlier cancellation must not have poisoned the cache with a
        // "this blob does not exist" entry.
        let retried = await cache.snapshot(worktreePath: repo, ref: "HEAD", path: "big.bin")
        let unwrapped = try #require(retried)
        #expect(try Data(contentsOf: unwrapped) == bytes)

        await cache.removeSessionDirectory()
    }

    /// `git show` on an LFS-tracked path returns the pointer stub, not the
    /// asset. A snapshot of such a path must resolve to the real bytes from
    /// the local LFS store, or a "broken image" is what lands in Finder.
    @Test func snapshotResolvesAnLFSPointerToTheRealObjectData() async throws {
        let repo = try await makeRepo(name: "lfs")
        defer { try? FileManager.default.removeItem(at: repo) }
        let payload = Data("this stands in for real image bytes".utf8)
        try writeLFSPointer(for: payload, named: "logo.png", in: repo)
        _ = try await Process.git(["add", "logo.png"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "lfs image"], cwd: repo)

        let cache = RevisionSnapshotCache(sessionID: UUID().uuidString)
        let snapshot = await cache.snapshot(worktreePath: repo, ref: "HEAD", path: "logo.png")

        let unwrapped = try #require(snapshot)
        #expect(try Data(contentsOf: unwrapped) == payload)
        await cache.removeSessionDirectory()
    }

    /// LFS objects can be un-fetched locally. In that case there is no real
    /// asset to substitute, so the honest outcome is writing the pointer
    /// unchanged rather than failing the drag.
    @Test func snapshotWritesThePointerVerbatimWhenTheLFSObjectIsNotFetchedLocally() async throws {
        let repo = try await makeRepo(name: "lfs-missing")
        defer { try? FileManager.default.removeItem(at: repo) }
        let payload = Data("bytes that were never fetched locally".utf8)
        try writeLFSPointer(for: payload, named: "logo.png", in: repo, withObject: false)
        _ = try await Process.git(["add", "logo.png"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "lfs image, object absent"], cwd: repo)

        let cache = RevisionSnapshotCache(sessionID: UUID().uuidString)
        let snapshot = await cache.snapshot(worktreePath: repo, ref: "HEAD", path: "logo.png")

        let unwrapped = try #require(snapshot)
        let written = try String(contentsOf: unwrapped, encoding: .utf8)
        #expect(written.hasPrefix("version https://git-lfs.github.com/spec/v1"))
        await cache.removeSessionDirectory()
    }

    /// A snapshot write happens deep inside `<session>/<worktree>/<ref>/...`,
    /// which does not by itself touch the session root's own mtime once that
    /// subtree already exists — only creating a *direct* child of the root
    /// does. Without an explicit touch, a long-running instance's session
    /// root looks abandoned to another instance's stale sweep even while it
    /// is actively writing snapshots.
    @Test func snapshotOfADeepNestedFileRefreshesTheSessionRootModificationDate() async throws {
        let repo = try await makeRepo(name: "touch-root")
        defer { try? FileManager.default.removeItem(at: repo) }
        let fileA = repo.appendingPathComponent("a.txt")
        try "a".write(to: fileA, atomically: true, encoding: .utf8)
        let fileB = repo.appendingPathComponent("b.txt")
        try "b".write(to: fileB, atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "a.txt", "b.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "a and b"], cwd: repo)

        let cache = RevisionSnapshotCache(sessionID: UUID().uuidString)
        // Establish the <session>/<worktree>/<ref>/ subtree first, so the
        // second snapshot below writes a new file into an already-existing
        // directory rather than creating a fresh direct child of the session
        // root — the exact "deep nested write" scenario the fix targets.
        _ = try #require(await cache.snapshot(worktreePath: repo, ref: "HEAD", path: "a.txt"))

        let backDated = Date().addingTimeInterval(-2 * RevisionSnapshotCache.staleSessionAge)
        try FileManager.default.setAttributes(
            [.modificationDate: backDated],
            ofItemAtPath: cache.sessionDirectory.path
        )
        let attributesBeforeSecondWrite = try FileManager.default.attributesOfItem(atPath: cache.sessionDirectory.path)
        let mtimeBeforeSecondWrite = try #require(attributesBeforeSecondWrite[.modificationDate] as? Date)

        _ = try #require(await cache.snapshot(worktreePath: repo, ref: "HEAD", path: "b.txt"))

        let attributesAfterSecondWrite = try FileManager.default.attributesOfItem(atPath: cache.sessionDirectory.path)
        let mtimeAfterSecondWrite = try #require(attributesAfterSecondWrite[.modificationDate] as? Date)
        #expect(mtimeAfterSecondWrite > mtimeBeforeSecondWrite)

        await cache.removeSessionDirectory()
    }
}
