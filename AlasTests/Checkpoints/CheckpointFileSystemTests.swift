import Darwin
import Foundation
import Testing
@testable import Alas

@Suite("Checkpoint file system")
struct CheckpointFileSystemTests {
    @Test func filesystemReadsSymlinkWithoutFollowingIt() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("outside".utf8).write(to: root.appendingPathComponent("target"))
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("link").path,
            withDestinationPath: "target"
        )

        let state = try LiveCheckpointFileSystem().readLeaf(root: root, relativePath: "link")

        #expect(state == .symlink(Data("target".utf8)))
    }

    @Test func filesystemRejectsSymlinkedParentDuringContainmentValidation() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("escaped").path,
            withDestinationPath: outside.path
        )

        #expect(throws: CheckpointFileSystemError.self) {
            try LiveCheckpointFileSystem().validateRelativePath("escaped/file", under: root)
        }
    }

    @Test func durableWriteReplacesBytesAndAppliesRequestedMode() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("state")
        try Data("old".utf8).write(to: destination)

        try LiveCheckpointFileSystem().writeDurable(Data("new bytes".utf8), to: destination, mode: 0o755)
        var details = stat()
        #expect(lstat(destination.path, &details) == 0)

        #expect(try Data(contentsOf: destination) == Data("new bytes".utf8))
        #expect(details.st_mode & 0o777 == 0o755)
    }

    @Test func urlOperationsRejectIntermediateSymlinkAncestors() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outside) }
        let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: false)
        let source = sourceDirectory.appendingPathComponent("file")
        try Data("source".utf8).write(to: source)
        let outsideDirectory = outside.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: false)
        let escaped = root.appendingPathComponent("escaped", isDirectory: true)
        try FileManager.default.createSymbolicLink(atPath: escaped.path, withDestinationPath: outside.path)
        let destination = escaped.appendingPathComponent("nested/file")
        let fileSystem = LiveCheckpointFileSystem()

        #expect(throws: CheckpointFileSystemError.self) {
            try fileSystem.writeDurable(Data("replacement".utf8), to: destination, mode: 0o644)
        }
        #expect(throws: CheckpointFileSystemError.self) {
            try fileSystem.move(source, to: destination)
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(!FileManager.default.fileExists(atPath: outsideDirectory.appendingPathComponent("file").path))
    }

    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
}
