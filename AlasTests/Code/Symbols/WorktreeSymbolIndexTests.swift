import Foundation
import Testing
@testable import Alas

@Suite("WorktreeSymbolIndex")
struct WorktreeSymbolIndexTests {
    private func lastSnapshot(_ stream: AsyncStream<WorktreeSymbolIndex.Snapshot>) async -> WorktreeSymbolIndex.Snapshot? {
        var last: WorktreeSymbolIndex.Snapshot?
        for await snapshot in stream { last = snapshot }
        return last
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-symbols-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Starts a refresh whose file listing suspends until the returned
    /// continuation is resumed; returns once the listing is suspended.
    private func gatedUpdates(
        _ index: WorktreeSymbolIndex, root: URL
    ) async -> (AsyncStream<WorktreeSymbolIndex.Snapshot>, CheckedContinuation<[String]?, Never>) {
        let (gates, parked) = AsyncStream.makeStream(of: CheckedContinuation<[String]?, Never>.self)
        let stream = await index.updates(root: root) {
            await withCheckedContinuation { parked.yield($0) }
        }
        var waiting = gates.makeAsyncIterator()
        return (stream, await waiting.next()!)
    }

    @Test("a refresh picks up changed, added, and deleted files and skips unsupported ones")
    func incrementalRefresh() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-symbols-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ path: String, _ text: String) throws {
            try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        try write("A.swift", "struct Alpha {}")
        try write("B.swift", "struct Beta {}")
        try write("notes.md", "# Gamma")
        let index = WorktreeSymbolIndex()

        let first = try #require(await lastSnapshot(index.updates(root: root) { ["A.swift", "B.swift", "notes.md"] }))
        #expect(first.isComplete)
        #expect(first.totalFiles == 2)
        #expect(Set(first.symbols.map(\.name)) == ["Alpha", "Beta"])
        #expect(await index.isLoaded(root: root))

        // Force a different size so the stamp changes even within one mtime tick.
        try write("A.swift", "struct AlphaRenamed {}")
        try write("C.swift", "struct Gamma {}")
        try FileManager.default.removeItem(at: root.appendingPathComponent("B.swift"))
        let second = try #require(await lastSnapshot(index.updates(root: root) { ["A.swift", "C.swift"] }))
        #expect(Set(second.symbols.map(\.name)) == ["AlphaRenamed", "Gamma"])

        // A failed `git ls-files` must not wipe what is already indexed.
        let failed = try #require(await lastSnapshot(index.updates(root: root) { nil }))
        #expect(failed.isComplete)
        #expect(Set(failed.symbols.map(\.name)) == ["AlphaRenamed", "Gamma"])
    }

    @Test("a refresh superseded while listing files commits nothing; its consumer ends with the newer result at once")
    func newerRefreshWins() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try "struct Alpha {}".write(to: root.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
        try "struct Beta {}".write(to: root.appendingPathComponent("B.swift"), atomically: true, encoding: .utf8)
        let index = WorktreeSymbolIndex()

        let (older, gate) = await gatedUpdates(index, root: root)
        let olderReader = Task { await lastSnapshot(older) }
        let newer = try #require(await lastSnapshot(index.updates(root: root) { ["A.swift", "B.swift"] }))
        #expect(Set(newer.symbols.map(\.name)) == ["Alpha", "Beta"])

        // The older listing has not returned, yet its stream already ended
        // with the newer result: stopping the reader keeps what it was sent.
        olderReader.cancel()
        let olderResult = await olderReader.value
        // Released last, the older listing, taken before B.swift existed,
        // commits nothing.
        gate.resume(returning: ["A.swift"])
        let olderLast = try #require(olderResult)
        #expect(olderLast.isComplete)
        #expect(Set(olderLast.symbols.map(\.name)) == ["Alpha", "Beta"])
        let cached = try #require(await lastSnapshot(index.updates(root: root) { nil }))
        #expect(Set(cached.symbols.map(\.name)) == ["Alpha", "Beta"])
    }

    @Test("removing a worktree drops its index, ends its refresh, and leaves other worktrees alone")
    func removesOneRoot() async throws {
        let removed = try makeRoot()
        let kept = try makeRoot()
        defer {
            try? FileManager.default.removeItem(at: removed)
            try? FileManager.default.removeItem(at: kept)
        }
        try "struct Gone {}".write(to: removed.appendingPathComponent("Gone.swift"), atomically: true, encoding: .utf8)
        try "struct Kept {}".write(to: kept.appendingPathComponent("Kept.swift"), atomically: true, encoding: .utf8)
        let index = WorktreeSymbolIndex()
        _ = await lastSnapshot(index.updates(root: removed) { ["Gone.swift"] })
        _ = await lastSnapshot(index.updates(root: kept) { ["Kept.swift"] })

        let (inFlight, gate) = await gatedUpdates(index, root: removed)
        await index.remove(root: removed)
        #expect(await lastSnapshot(inFlight) == nil)
        gate.resume(returning: ["Gone.swift"])
        #expect(await !index.isLoaded(root: removed))
        // A worktree-change refresh must not rebuild a removed index.
        await index.refreshIfLoaded(root: removed) { ["Gone.swift"] }
        #expect(await !index.isLoaded(root: removed))

        #expect(await index.isLoaded(root: kept))
        let cached = try #require(await lastSnapshot(index.updates(root: kept) { nil }))
        #expect(cached.symbols.map(\.name) == ["Kept"])
    }

    @Test("a file that could not be read is retried once readable, even with an unchanged stamp")
    func retriesUnreadableFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-symbols-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Locked.swift")
        try "struct Locked {}".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        let index = WorktreeSymbolIndex()

        let locked = try #require(await lastSnapshot(index.updates(root: root) { ["Locked.swift"] }))
        #expect(locked.symbols.isEmpty)

        // chmod changes neither size nor modification date.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        let readable = try #require(await lastSnapshot(index.updates(root: root) { ["Locked.swift"] }))
        #expect(readable.symbols.map(\.name) == ["Locked"])
    }

    @Test("only regular files are read: directories and FIFOs return nil without blocking", .timeLimit(.minutes(1)))
    func readsRegularFilesOnly() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-symbols-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(SymbolSource.readBounded(directory, within: directory.deletingLastPathComponent()) == nil)

        // A blocking open on a FIFO with no writer would hang forever.
        let fifo = directory.appendingPathComponent("Pipe.swift")
        #expect(mkfifo(fifo.path, 0o644) == 0)
        #expect(SymbolSource.readBounded(fifo, within: directory) == nil)
    }

    @Test("containment is checked on the opened file, not only on the path checked earlier")
    func readBoundedChecksOpenedFile() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-symbols-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let outside = base.appendingPathComponent("Secret.swift")
        try "struct Secret {}".write(to: outside, atomically: true, encoding: .utf8)
        let inside = root.appendingPathComponent("A.swift")
        try "struct A {}".write(to: inside, atomically: true, encoding: .utf8)
        #expect(SymbolSource.readBounded(inside, within: root) == "struct A {}")

        // Simulates a swap after `containedLocalURL` approved the path: the
        // same path now opens a file outside the worktree.
        try FileManager.default.removeItem(at: inside)
        try FileManager.default.createSymbolicLink(at: inside, withDestinationURL: outside)
        #expect(SymbolSource.readBounded(inside, within: root) == nil)
    }

    @Test("files over the size cap are skipped")
    func skipsLargeFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-symbols-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let big = "struct Big {}\n" + String(repeating: "// pad\n", count: WorktreeSymbolIndex.maxFileBytes / 7 + 1)
        try big.write(to: root.appendingPathComponent("Big.swift"), atomically: true, encoding: .utf8)

        let snapshot = try #require(await lastSnapshot(WorktreeSymbolIndex().updates(root: root) { ["Big.swift"] }))
        #expect(snapshot.symbols.isEmpty)
        #expect(snapshot.isComplete)
    }

    @Test("symlinks that resolve outside the worktree are neither indexed nor read")
    func ignoresEscapingSymlinks() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-symbols-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("worktree", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try "struct Secret {}".write(to: outside.appendingPathComponent("Secret.swift"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Escape.swift"),
                                                   withDestinationURL: outside.appendingPathComponent("Secret.swift"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: outside)

        let snapshot = try #require(await lastSnapshot(WorktreeSymbolIndex().updates(root: root) {
            ["Escape.swift", "linked/Secret.swift"]
        }))
        #expect(snapshot.symbols.isEmpty)
        #expect(await SymbolSource.read(root: root, relativePath: "Escape.swift") == nil)
        #expect(await SymbolSource.read(root: root, relativePath: "linked/Secret.swift") == nil)

        // Git metadata is never read, by path or through an in-tree symlink.
        let hooks = root.appendingPathComponent(".git/hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        try "struct Hook {}".write(to: hooks.appendingPathComponent("hook.swift"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Hook.swift"),
                                                   withDestinationURL: hooks.appendingPathComponent("hook.swift"))
        #expect(await SymbolSource.read(root: root, relativePath: ".git/hooks/hook.swift") == nil)
        #expect(await SymbolSource.read(root: root, relativePath: "Hook.swift") == nil)
    }
}
