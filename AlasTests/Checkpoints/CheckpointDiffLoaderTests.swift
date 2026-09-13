import AppKit
import Testing
@testable import Alas

struct CheckpointDiffLoaderTests {
    @Test func textDiffUsesCheckpointBeforeCurrentAfterWithoutMutation() async throws {
        let repo = try await CheckpointTestRepository.make()
        defer { repo.remove() }
        try repo.write("checkpoint text\n", to: "file.txt")
        let service = WorktreeCheckpointService(store: .init(root: repo.root.appendingPathComponent(".git/checkpoints")))
        let checkpoint = try await service.createManual(target: repo.target, label: "Saved")
        try repo.write("current text\n", to: "file.txt")
        let before = try await repo.status()
        guard case .text(let diff) = await service.diffContent(target: repo.target, id: checkpoint.id, path: "file.txt") else {
            Issue.record("Expected text diff")
            return
        }
        let lines = diff.hunks.flatMap(\.lines)
        #expect(lines.filter { $0.kind == .delete }.map(\.text) == ["checkpoint text"])
        #expect(lines.filter { $0.kind == .add }.map(\.text) == ["current text"])
        #expect(try await repo.status() == before)
        _ = try await service.delete(target: repo.target, id: checkpoint.id)
        guard case .unavailable = await service.diffContent(target: repo.target, id: checkpoint.id, path: "file.txt") else {
            Issue.record("Deleted checkpoint must be unavailable")
            return
        }
    }

    @Test func binarySizesAndMissingBlobAreExplicit() async throws {
        let repo = try await CheckpointTestRepository.make()
        defer { repo.remove() }
        let saved = Data([0, 255, 1])
        try repo.write(saved, to: "file.dat")
        let root = repo.root.appendingPathComponent(".git/checkpoints")
        let service = WorktreeCheckpointService(store: .init(root: root))
        let checkpoint = try await service.createManual(target: repo.target, label: "Saved")
        try repo.write(Data([0, 254, 2, 3, 4]), to: "file.dat")
        guard case .binary(let before, let after) = await service.diffContent(target: repo.target, id: checkpoint.id, path: "file.dat") else {
            Issue.record("Expected binary diff")
            return
        }
        #expect(before == 3)
        #expect(after == 5)
        let blob = root.appendingPathComponent(repo.target.lineageID).appendingPathComponent("blobs").appendingPathComponent(CheckpointBlobReference.make(for: saved).sha256)
        try FileManager.default.removeItem(at: blob)
        guard case .unavailable = await service.diffContent(target: repo.target, id: checkpoint.id, path: "file.dat") else {
            Issue.record("Missing blob must be unavailable")
            return
        }
    }

    @Test func emptyFileAdditionAndDeletionRemainVisible() async throws {
        let repo = try await CheckpointTestRepository.make()
        defer { repo.remove() }
        let service = WorktreeCheckpointService(store: .init(root: repo.root.appendingPathComponent(".git/checkpoints")))
        let additionBaseline = try await service.createManual(target: repo.target, label: "Before empty add")
        try repo.write(Data(), to: "empty.txt")

        guard case .text(let addition) = await service.diffContent(target: repo.target, id: additionBaseline.id, path: "empty.txt") else {
            Issue.record("Expected empty addition text diff")
            return
        }
        #expect(addition.metadataSummary == "Empty file added.")

        try await repo.commitAll("empty")
        let deletionBaseline = try await service.createManual(target: repo.target, label: "Before empty delete")
        try FileManager.default.removeItem(at: repo.root.appendingPathComponent("empty.txt"))

        guard case .text(let deletion) = await service.diffContent(target: repo.target, id: deletionBaseline.id, path: "empty.txt") else {
            Issue.record("Expected empty deletion text diff")
            return
        }
        #expect(deletion.metadataSummary == "Empty file deleted.")
    }

    @Test func absentOnBothSidesDoesNotReportEmptyFileChange() async throws {
        let repo = try await CheckpointTestRepository.make()
        defer { repo.remove() }
        let pathState = CheckpointPathState(
            relativePath: "deleted.txt",
            head: .absent,
            index: .absent,
            worktree: .absent
        )
        let manifest = try WorktreeCheckpointManifest(
            kind: .manual,
            label: "Saved",
            createdAt: Date(timeIntervalSince1970: 1),
            byteCount: 0,
            lineageID: repo.target.lineageID,
            capturedPath: repo.root.path,
            repositoryName: "test",
            branch: "main",
            headOID: String(repeating: "f", count: 40),
            exclusions: [],
            groups: [],
            paths: [pathState]
        )
        let store = WorktreeCheckpointStore(root: repo.root.appendingPathComponent(".git/checkpoints"))
        _ = try await store.publish(.init(manifest: manifest, blobs: [:]))
        let service = WorktreeCheckpointService(store: store)

        guard case .text(let diff) = await service.diffContent(target: repo.target, id: manifest.id, path: "deleted.txt") else {
            Issue.record("Expected absent/absent path to render as an unchanged text diff")
            return
        }

        #expect(diff.hunks.isEmpty)
        #expect(diff.metadataSummary == nil)
    }

    @Test func currentOnlyDiffSnapshotsOnlyRequestedPath() async throws {
        let repo = try await CheckpointTestRepository.make()
        defer { repo.remove() }
        try repo.write("baseline\n", to: "unrelated.txt")
        try await repo.commitAll("baseline")
        let store = WorktreeCheckpointStore(root: repo.root.appendingPathComponent(".git/checkpoints"))
        let captureService = WorktreeCheckpointService(store: store)
        let checkpoint = try await captureService.createManual(target: repo.target, label: "Before new file")
        try repo.write("dirty but unrelated\n", to: "unrelated.txt")
        try repo.write("new\n", to: "new.txt")
        let diffService = WorktreeCheckpointService(
            store: store,
            snapshotter: .init(fileSystem: PathReadFailingFileSystem(failingRelativePath: "unrelated.txt"))
        )

        guard case .text(let diff) = await diffService.diffContent(target: repo.target, id: checkpoint.id, path: "new.txt") else {
            Issue.record("Expected current-only text diff")
            return
        }

        let lines = diff.hunks.flatMap(\.lines)
        let additions = lines.filter { $0.kind == .add }.map(\.text)
        #expect(additions == ["new"])
    }

    @Test func modeOnlyDiffRemainsVisible() async throws {
        let repo = try await CheckpointTestRepository.make()
        defer { repo.remove() }
        try repo.write("same\n", to: "script.sh")
        let fileURL = repo.root.appendingPathComponent("script.sh")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
        let service = WorktreeCheckpointService(store: .init(root: repo.root.appendingPathComponent(".git/checkpoints")))
        let checkpoint = try await service.createManual(target: repo.target, label: "Saved")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fileURL.path)

        guard case .text(let diff) = await service.diffContent(target: repo.target, id: checkpoint.id, path: "script.sh") else {
            Issue.record("Expected text diff")
            return
        }

        #expect(diff.hunks.isEmpty)
        #expect(diff.metadataSummary == "File mode changed from 100644 to 100755 — no content changes.")
    }

    @Test func fileKindOnlyDiffRemainsVisible() async throws {
        let repo = try await CheckpointTestRepository.make()
        defer { repo.remove() }
        try repo.write("target", to: "linkish")
        try repo.write("target\n", to: "target")
        let fileURL = repo.root.appendingPathComponent("linkish")
        let service = WorktreeCheckpointService(store: .init(root: repo.root.appendingPathComponent(".git/checkpoints")))
        let checkpoint = try await service.createManual(target: repo.target, label: "Saved")
        try FileManager.default.removeItem(at: fileURL)
        try FileManager.default.createSymbolicLink(atPath: fileURL.path, withDestinationPath: "target")

        let content = await service.diffContent(target: repo.target, id: checkpoint.id, path: "linkish")
        guard case .text(let diff) = content else {
            Issue.record("Expected text diff, got \(describe(content))")
            return
        }

        #expect(diff.isBinary == false)
        #expect(diff.hunks.isEmpty)
        #expect(diff.metadataSummary == "File mode changed from 100644 to 120000 — no content changes.")
    }

    @Test func imageNamedSymlinkUsesTextDiffInsteadOfImageDecode() async throws {
        let repo = try await CheckpointTestRepository.make()
        defer { repo.remove() }
        try repo.symlink("assets/old.png", at: "logo.png")
        let service = WorktreeCheckpointService(store: .init(root: repo.root.appendingPathComponent(".git/checkpoints")))
        let checkpoint = try await service.createManual(target: repo.target, label: "Saved")
        try FileManager.default.removeItem(at: repo.root.appendingPathComponent("logo.png"))
        try repo.symlink("assets/new.png", at: "logo.png")

        let content = await service.diffContent(target: repo.target, id: checkpoint.id, path: "logo.png")
        guard case .text(let diff) = content else {
            Issue.record("Expected symlink target diff, got \(describe(content))")
            return
        }
        let lines = diff.hunks.flatMap(\.lines)
        let deletions = lines.filter { $0.kind == .delete }.map(\.text)
        let additions = lines.filter { $0.kind == .add }.map(\.text)

        #expect(deletions == ["assets/old.png"])
        #expect(additions == ["assets/new.png"])
    }

    @Test func oversizedCurrentSideReturnsSizePreviewWithoutReadingFile() async throws {
        let repo = try await CheckpointTestRepository.make()
        defer { repo.remove() }
        let bytes = Data("small\n".utf8)
        let blob = CheckpointBlobReference.make(for: bytes)
        let fileState = CheckpointFileState.regular(blob: blob, executable: false)
        let pathState = CheckpointPathState(
            relativePath: "huge.txt",
            head: fileState,
            index: fileState,
            worktree: fileState
        )
        let oversizedByteCount = Int64(10 * 1024 * 1024 + 1)
        let manifest = try WorktreeCheckpointManifest(
            kind: .manual,
            label: "Saved",
            createdAt: Date(timeIntervalSince1970: 1),
            byteCount: Int64(bytes.count),
            lineageID: repo.target.lineageID,
            capturedPath: repo.root.path,
            repositoryName: "test",
            branch: "main",
            headOID: String(repeating: "f", count: 40),
            exclusions: [],
            groups: [],
            paths: [pathState]
        )
        let store = WorktreeCheckpointStore(root: repo.root.appendingPathComponent(".git/checkpoints"))
        _ = try await store.publish(.init(manifest: manifest, blobs: [blob: bytes]))
        let service = WorktreeCheckpointService(
            store: store,
            snapshotter: .init(fileSystem: OversizedReadFailingFileSystem(
                oversizedRelativePath: "huge.txt",
                byteCount: oversizedByteCount
            ))
        )

        guard case .binary(let before, let after) = await service.diffContent(target: repo.target, id: manifest.id, path: "huge.txt") else {
            Issue.record("Expected oversized diff to return a size preview")
            return
        }

        #expect(before == Int64(bytes.count))
        #expect(after == oversizedByteCount)
    }

    @Test func currentDirectoryAtCheckpointFilePathIsTreatedAsAbsentLeaf() async throws {
        let repo = try await CheckpointTestRepository.make()
        defer { repo.remove() }
        try repo.write("saved\n", to: "config")
        let service = WorktreeCheckpointService(store: .init(root: repo.root.appendingPathComponent(".git/checkpoints")))
        let checkpoint = try await service.createManual(target: repo.target, label: "Saved")
        try FileManager.default.removeItem(at: repo.root.appendingPathComponent("config"))
        try repo.write("child\n", to: "config/local.json")

        guard case .text(let diff) = await service.diffContent(target: repo.target, id: checkpoint.id, path: "config") else {
            Issue.record("Expected directory replacement to render as a file deletion")
            return
        }

        let lines = diff.hunks.flatMap(\.lines)
        let deletedTexts = lines.filter { $0.kind == .delete }.map(\.text)
        #expect(deletedTexts == ["saved"])
    }

    @Test func oversizedEqualCurrentFileDoesNotReportChangedBinaryPreview() async throws {
        let repo = try await CheckpointTestRepository.make()
        defer { repo.remove() }
        let bytes = Data(repeating: 42, count: 10 * 1024 * 1024 + 1)
        let blob = CheckpointBlobReference.make(for: bytes)
        let fileState = CheckpointFileState.regular(blob: blob, executable: false)
        let pathState = CheckpointPathState(
            relativePath: "huge.txt",
            head: fileState,
            index: fileState,
            worktree: fileState
        )
        let manifest = try WorktreeCheckpointManifest(
            kind: .manual,
            label: "Saved",
            createdAt: Date(timeIntervalSince1970: 1),
            byteCount: Int64(bytes.count),
            lineageID: repo.target.lineageID,
            capturedPath: repo.root.path,
            repositoryName: "test",
            branch: "main",
            headOID: String(repeating: "f", count: 40),
            exclusions: [],
            groups: [],
            paths: [pathState]
        )
        try repo.write(bytes, to: "huge.txt")
        let store = WorktreeCheckpointStore(root: repo.root.appendingPathComponent(".git/checkpoints"))
        _ = try await store.publish(.init(manifest: manifest, blobs: [blob: bytes]))
        let service = WorktreeCheckpointService(store: store)

        guard case .text(let diff) = await service.diffContent(target: repo.target, id: manifest.id, path: "huge.txt") else {
            Issue.record("Expected equal oversized file to render as no text changes")
            return
        }

        let hunksAreEmpty = diff.hunks.isEmpty
        let metadataSummary = diff.metadataSummary
        #expect(hunksAreEmpty)
        #expect(metadataSummary == nil)
    }

    @Test func oversizedEqualCurrentFilePreservesModeOnlySummary() async throws {
        let repo = try await CheckpointTestRepository.make()
        defer { repo.remove() }
        let bytes = Data(repeating: 42, count: 10 * 1024 * 1024 + 1)
        let blob = CheckpointBlobReference.make(for: bytes)
        let fileState = CheckpointFileState.regular(blob: blob, executable: false)
        let pathState = CheckpointPathState(
            relativePath: "huge.sh",
            head: fileState,
            index: fileState,
            worktree: fileState
        )
        let manifest = try WorktreeCheckpointManifest(
            kind: .manual,
            label: "Saved",
            createdAt: Date(timeIntervalSince1970: 1),
            byteCount: Int64(bytes.count),
            lineageID: repo.target.lineageID,
            capturedPath: repo.root.path,
            repositoryName: "test",
            branch: "main",
            headOID: String(repeating: "f", count: 40),
            exclusions: [],
            groups: [],
            paths: [pathState]
        )
        try repo.write(bytes, to: "huge.sh")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: repo.root.appendingPathComponent("huge.sh").path)
        let store = WorktreeCheckpointStore(root: repo.root.appendingPathComponent(".git/checkpoints"))
        _ = try await store.publish(.init(manifest: manifest, blobs: [blob: bytes]))
        let service = WorktreeCheckpointService(store: store)

        guard case .text(let diff) = await service.diffContent(target: repo.target, id: manifest.id, path: "huge.sh") else {
            Issue.record("Expected equal oversized file with mode change to render as a text metadata summary")
            return
        }

        #expect(diff.hunks.isEmpty)
        #expect(diff.metadataSummary == "File mode changed from 100644 to 100755 — no content changes.")
    }

    private func describe(_ content: CheckpointDiffContent) -> String {
        switch content {
        case .text:
            return "text"
        case .image:
            return "image"
        case .binary(let beforeByteCount, let afterByteCount):
            return "binary(\(String(describing: beforeByteCount)), \(String(describing: afterByteCount)))"
        case .unavailable(let message):
            return "unavailable(\(message))"
        }
    }

    @Test @MainActor func imagesKeepBothSidesAndFrameCounts() async throws {
        let repo = try await CheckpointTestRepository.make()
        defer { repo.remove() }
        let first = try png(width: 2)
        let second = try png(width: 3)
        try repo.write(first, to: "image.png")
        let service = WorktreeCheckpointService(store: .init(root: repo.root.appendingPathComponent(".git/checkpoints")))
        let checkpoint = try await service.createManual(target: repo.target, label: "Saved")
        try repo.write(second, to: "image.png")
        guard case .image(let pair) = await service.diffContent(target: repo.target, id: checkpoint.id, path: "image.png") else {
            Issue.record("Expected image diff")
            return
        }
        #expect(pair.beforeImage?.size.width == 2)
        #expect(pair.afterImage?.size.width == 3)
        #expect(pair.beforeFrameCount == 1)
        #expect(pair.afterFrameCount == 1)
    }

    @MainActor private func png(width: Int) throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for x in 0..<width { bitmap.setColor(.red, atX: x, y: 0) }
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
}

private struct PathReadFailingFileSystem: CheckpointFileSystem {
    enum Failure: Error { case unexpectedRead(String) }

    let failingRelativePath: String
    private let live = LiveCheckpointFileSystem()

    func readLeaf(root: URL, relativePath: String) throws -> CheckpointLeafRead {
        if relativePath == failingRelativePath { throw Failure.unexpectedRead(relativePath) }
        return try live.readLeaf(root: root, relativePath: relativePath)
    }

    func metadata(root: URL, relativePath: String) throws -> CheckpointLeafMetadata? {
        if relativePath == failingRelativePath { throw Failure.unexpectedRead(relativePath) }
        return try live.metadata(root: root, relativePath: relativePath)
    }

    func validateRelativePath(_ relativePath: String, under root: URL) throws -> URL {
        try live.validateRelativePath(relativePath, under: root)
    }

    func createDirectoryExclusively(_ url: URL, mode: mode_t) throws {
        try live.createDirectoryExclusively(url, mode: mode)
    }

    func writeDurable(_ data: Data, to url: URL, mode: mode_t) throws {
        try live.writeDurable(data, to: url, mode: mode)
    }

    func createSymlink(target: Data, at url: URL) throws {
        try live.createSymlink(target: target, at: url)
    }

    func move(_ source: URL, to destination: URL) throws {
        try live.move(source, to: destination)
    }

    func moveExclusively(_ source: URL, to destination: URL) throws {
        try live.moveExclusively(source, to: destination)
    }

    func removeIfPresent(_ url: URL) throws {
        try live.removeIfPresent(url)
    }

    func list(_ url: URL) throws -> [URL] {
        try live.list(url)
    }

    func fileData(_ url: URL) throws -> Data {
        try live.fileData(url)
    }

    func synchronizeDirectory(_ url: URL) throws {
        try live.synchronizeDirectory(url)
    }
}

private struct OversizedReadFailingFileSystem: CheckpointFileSystem {
    enum Failure: Error { case unexpectedRead(String) }

    let oversizedRelativePath: String
    let byteCount: Int64
    private let live = LiveCheckpointFileSystem()

    func readLeaf(root: URL, relativePath: String) throws -> CheckpointLeafRead {
        if relativePath == oversizedRelativePath { throw Failure.unexpectedRead(relativePath) }
        return try live.readLeaf(root: root, relativePath: relativePath)
    }

    func metadata(root: URL, relativePath: String) throws -> CheckpointLeafMetadata? {
        if relativePath == oversizedRelativePath {
            return .init(kind: .regular, executable: false, byteCount: byteCount)
        }
        return try live.metadata(root: root, relativePath: relativePath)
    }

    func validateRelativePath(_ relativePath: String, under root: URL) throws -> URL {
        try live.validateRelativePath(relativePath, under: root)
    }

    func createDirectoryExclusively(_ url: URL, mode: mode_t) throws {
        try live.createDirectoryExclusively(url, mode: mode)
    }

    func writeDurable(_ data: Data, to url: URL, mode: mode_t) throws {
        try live.writeDurable(data, to: url, mode: mode)
    }

    func createSymlink(target: Data, at url: URL) throws {
        try live.createSymlink(target: target, at: url)
    }

    func move(_ source: URL, to destination: URL) throws {
        try live.move(source, to: destination)
    }

    func moveExclusively(_ source: URL, to destination: URL) throws {
        try live.moveExclusively(source, to: destination)
    }

    func removeIfPresent(_ url: URL) throws {
        try live.removeIfPresent(url)
    }

    func list(_ url: URL) throws -> [URL] {
        try live.list(url)
    }

    func fileData(_ url: URL) throws -> Data {
        try live.fileData(url)
    }

    func synchronizeDirectory(_ url: URL) throws {
        try live.synchronizeDirectory(url)
    }
}
