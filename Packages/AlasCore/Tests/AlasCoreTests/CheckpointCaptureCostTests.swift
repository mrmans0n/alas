import Foundation
import Testing
import AlasCore

/// Pins what an automatic capture reads and hashes, and that the cheaper
/// verification still catches an edit made during the capture.
struct CheckpointCaptureCostTests {
    @Test func eachDirtyFileIsReadOncePerCapture() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        // Changed long enough ago that the verify pass may trust its stat.
        let fileSystem = RecordingFileSystem(shiftingTimesBy: -3600)
        let service = WorktreeCheckpointService(store: .init(root: fixture.storeRoot),
                                                snapshotter: WorktreeStateSnapshotter(fileSystem: fileSystem))

        _ = try await service.createAutomatic(target: fixture.target, label: "Before")

        #expect(fileSystem.reads() == [Fixture.tracked: 1, Fixture.untracked: 1])
    }

    @Test func publishingOverKnownBlobsDoesNotRehashThem() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let store = WorktreeCheckpointStore(root: fixture.storeRoot)
        let service = WorktreeCheckpointService(store: store)
        _ = try await service.createAutomatic(target: fixture.target, label: "First")
        let before = await store.blobHashValidationCountForTesting()

        try fixture.write("another\n", to: "second.txt")
        _ = try await service.createAutomatic(target: fixture.target, label: "Second")

        #expect(await store.blobHashValidationCountForTesting() == before)
    }

    @Test func sameSizeEditWithUnchangedStatInRacyWindowIsCaptured() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        // Stat never changes, so only the racy-window re-read can see the edit.
        let fileSystem = RecordingFileSystem(freezingIdentities: true)
        let edited = Data("EDITED\n".utf8)
        let attempts = AttemptLog()
        let service = WorktreeCheckpointService(
            store: .init(root: fixture.storeRoot), snapshotter: WorktreeStateSnapshotter(fileSystem: fileSystem),
            hooks: .init(afterPayloadStaging: { attempt in
                attempts.append(attempt)
                if attempt == 1 { try fixture.write(edited, to: Fixture.untracked) }
            })
        )

        let summary = try await service.createAutomatic(target: fixture.target, label: "Before")

        let manifest = try await service.manifest(target: fixture.target, id: summary.id)
        let saved = try #require(manifest.paths.first { $0.relativePath == Fixture.untracked })
        #expect(attempts.values == [1, 2])
        #expect(saved.worktree.blob == CheckpointBlobReference.make(for: edited))
    }

    private struct Fixture {
        static let tracked = ".alas/scripts/hello.sh"
        static let untracked = "notes.txt"
        let root: URL
        let storeRoot: URL
        let target: CheckpointWorktreeTarget

        static func make() async throws -> Self {
            let base = URL(fileURLWithPath: "/private/tmp/checkpoint-cost-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            let root = base.appendingPathComponent("repo")
            try await GitTemplate.repository(at: root)
            let lineage = try #require(WorktreeService.localLineageID(forWorktreeAt: root))
            let fixture = Self(root: root, storeRoot: base.appendingPathComponent("store"),
                               target: .init(worktreeID: "w", projectID: "p", path: root, lineageID: lineage, branch: "main",
                                             repositoryName: "test", workspaceName: nil))
            try fixture.write("#!/bin/sh\necho changed\n", to: tracked)
            try fixture.write("ORIGIN\n", to: untracked)
            return fixture
        }

        func write(_ text: String, to path: String) throws { try write(Data(text.utf8), to: path) }
        func write(_ data: Data, to path: String) throws { try data.write(to: root.appendingPathComponent(path)) }
        func remove() { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    }
}

private final class AttemptLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Int] = []
    var values: [Int] { lock.withLock { recorded } }
    func append(_ value: Int) { lock.withLock { recorded.append(value) } }
}

/// The live file system, counting each content read by path and optionally
/// rewriting what `metadata` reports about a regular file's stat.
private final class RecordingFileSystem: CheckpointFileSystem, @unchecked Sendable {
    private let live = LiveCheckpointFileSystem()
    private let shift: Int64
    private let freezing: Bool
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var frozen: [String: CheckpointStatIdentity] = [:]

    init(shiftingTimesBy seconds: Int64 = 0, freezingIdentities: Bool = false) {
        shift = seconds * 1_000_000_000
        freezing = freezingIdentities
    }

    func reads() -> [String: Int] { lock.withLock { counts } }
    private func count(_ path: String) { lock.withLock { counts[path, default: 0] += 1 } }

    func readLeaf(root: URL, relativePath: String) throws -> CheckpointLeafRead {
        count(relativePath)
        return try live.readLeaf(root: root, relativePath: relativePath)
    }

    func regularFileReference(root: URL, relativePath: String) throws -> CheckpointBlobReference {
        count(relativePath)
        return try live.regularFileReference(root: root, relativePath: relativePath)
    }

    func metadata(root: URL, relativePath: String) throws -> CheckpointLeafMetadata? {
        guard let metadata = try live.metadata(root: root, relativePath: relativePath) else { return nil }
        guard let real = metadata.identity else { return metadata }
        var identity = CheckpointStatIdentity(device: real.device, inode: real.inode, byteCount: real.byteCount,
                                              modified: real.modified + shift, changed: real.changed + shift)
        if freezing {
            identity = lock.withLock {
                if let first = frozen[relativePath] { return first }
                frozen[relativePath] = identity
                return identity
            }
        }
        return .init(kind: metadata.kind, executable: metadata.executable, byteCount: metadata.byteCount, identity: identity)
    }

    func validateRelativePath(_ relativePath: String, under root: URL) throws -> URL {
        try live.validateRelativePath(relativePath, under: root)
    }
    func createDirectoryExclusively(_ url: URL, mode: mode_t) throws { try live.createDirectoryExclusively(url, mode: mode) }
    func writeDurable(_ data: Data, to url: URL, mode: mode_t) throws { try live.writeDurable(data, to: url, mode: mode) }
    func createSymlink(target: Data, at url: URL) throws { try live.createSymlink(target: target, at: url) }
    func move(_ source: URL, to destination: URL) throws { try live.move(source, to: destination) }
    func moveExclusively(_ source: URL, to destination: URL) throws { try live.moveExclusively(source, to: destination) }
    func removeIfPresent(_ url: URL) throws { try live.removeIfPresent(url) }
    func list(_ url: URL) throws -> [URL] { try live.list(url) }
    func fileData(_ url: URL) throws -> Data { try live.fileData(url) }
    func synchronizeDirectory(_ url: URL) throws { try live.synchronizeDirectory(url) }
}
