import Foundation
import Testing
@testable import Alas

@MainActor
struct WorkspaceEditRemoteTests {
    @Test func boundedRemoteSnapshotsPreserveBytesAndRefuseOversizeAndNonfiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-edit-remote-cap-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("quoted ' file")
        let bytes = Data([0, 255, 10, 65])
        try bytes.write(to: file)
        let command = RemoteFileAccess.boundedReadScript(path: file.path, maxBytes: 4)
        let result = try await Process.runData("/bin/sh", args: ["-c", command])
        guard case .file(let content, _) = try RemoteFileAccess.boundedReadResult(result, maxBytes: 4) else {
            Issue.record("Expected the complete boundary-sized file")
            return
        }
        #expect(content == bytes)
        try Data(repeating: 65, count: 5).write(to: file)
        let oversized = try await Process.runData("/bin/sh", args: ["-c", command])
        #expect(oversized.stdout.isEmpty)
        #expect(throws: RemoteFileAccessError.fileTooLarge) { try RemoteFileAccess.boundedReadResult(oversized, maxBytes: 4) }
        try FileManager.default.removeItem(at: file)
        let missing = try await Process.runData("/bin/sh", args: ["-c", command])
        #expect(try RemoteFileAccess.boundedReadResult(missing, maxBytes: 4) == .missing)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        let directory = try await Process.runData("/bin/sh", args: ["-c", command])
        #expect(try RemoteFileAccess.boundedReadResult(directory, maxBytes: 4) == .directory)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: root)
        let symlink = try await Process.runData("/bin/sh", args: ["-c", command])
        #expect(try RemoteFileAccess.boundedReadResult(symlink, maxBytes: 4) == .symlink)
    }

    @Test func remoteFileGrowthAfterStatIsBoundedAndNeverReturnsTruncatedSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-edit-remote-growth-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("growing")
        try Data("abcd".utf8).write(to: file)
        // A shell function grows the file after the real size probe completed.
        // The subsequent mtime probe and read therefore observe the larger file.
        let probe = "stat() { /usr/bin/stat \"$@\"; status=$?; case \"$*\" in *'%z'*) printf 'more bytes' >> \(SSHCommand.shellQuote(file.path));; esac; return $status; }; "
        let result = try await Process.runData("/bin/sh", args: ["-c", probe + RemoteFileAccess.boundedReadScript(path: file.path, maxBytes: 4)])
        #expect(result.exitCode == 0)
        #expect(RemoteFileAccess.parseReadPayload(result.stdout)?.contents.count == 5)
        #expect(throws: RemoteFileAccessError.fileTooLarge) { try RemoteFileAccess.boundedReadResult(result, maxBytes: 4) }
        #expect(try Data(contentsOf: file).count > 5)
    }

    @Test func ambiguousHelperWriteErrorsNeverAllowFallback() {
        #expect(!RemoteFileAccess.canFallbackAfterWriteError(.unavailable("lost response")))
        #expect(!RemoteFileAccess.canFallbackAfterWriteError(.notRunning))
        #expect(!RemoteFileAccess.canFallbackAfterWriteError(.decoding("invalid response")))
    }

    @Test func guardedRemoteMoveRejectsChangedDestinationAndDirectories() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-edit-shell-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("a ' source")
        let destination = root.appendingPathComponent("b destination")
        try Data("source\n".utf8).write(to: source)
        try Data("later destination".utf8).write(to: destination)
        let command = RemoteFileOps.guardedMoveCommand(from: source.path, to: destination.path, expectedSource: Data("source\n".utf8), expectedDestination: nil)
        let conflict = try await Process.run("/bin/sh", args: ["-c", command])
        #expect(conflict.exitCode == 42)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "later destination")
        #expect(try String(contentsOf: source, encoding: .utf8) == "source\n")
        try FileManager.default.removeItem(at: destination)
        let moved = try await Process.run("/bin/sh", args: ["-c", command])
        #expect(moved.exitCode == 0)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try String(contentsOf: destination, encoding: .utf8) == "source\n")
        let directoryDelete = RemoteFileOps.guardedReplaceCommand(path: root.path, expected: nil, replacement: nil)
        #expect(try await Process.run("/bin/sh", args: ["-c", directoryDelete]).exitCode == 42)
        #expect(FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func guardedRemoteRestorePreservesPermissionsAndLaterContent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-edit-shell-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("restored file")
        let command = RemoteFileOps.guardedReplaceCommand(path: file.path, expected: nil, replacement: Data("saved\n".utf8), permissions: 0o640)
        #expect(try await Process.run("/bin/sh", args: ["-c", command], stdin: "saved\n").exitCode == 0)
        #expect(try String(contentsOf: file, encoding: .utf8) == "saved\n")
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o640)
        let conflict = RemoteFileOps.guardedReplaceCommand(path: file.path, expected: Data("older".utf8), replacement: Data("replacement".utf8))
        #expect(try await Process.run("/bin/sh", args: ["-c", conflict], stdin: "replacement").exitCode == 42)
        #expect(try String(contentsOf: file, encoding: .utf8) == "saved\n")
    }

    @Test func remoteTwoFileRenameKeepsHostAndDirtyState() async throws {
        let fixture = try WorkspaceEditFixture(host: "build-host")
        defer { fixture.remove() }
        guard case .applied = await fixture.executor.apply(fixture.plan) else { Issue.record("Expected applied")
        return }
        #expect(fixture.access.files[fixture.a]?.document.host == "build-host")
        #expect(fixture.access.files[fixture.a]?.content == Data("new dirty".utf8))
        #expect(fixture.access.files[fixture.a]?.diskContent == Data("old saved".utf8))
        #expect(fixture.access.files[fixture.b]?.content == Data("new disk".utf8))
        #expect(fixture.access.calls.filter { $0.hasPrefix("write:") } == ["write:a", "write:b"])
    }

    @Test func writeThenDisconnectRetainsUnknownStepWithoutRetrying() async throws {
        let fixture = try WorkspaceEditFixture(host: "build-host")
        defer { fixture.remove() }
        fixture.access.disconnectAfterWrite = fixture.b
        let outcome = await fixture.executor.apply(fixture.plan)
        guard case .recoveryRequired = outcome else { Issue.record("Expected retained recovery")
        return }
        #expect(fixture.access.calls.filter { $0.hasPrefix("write:") } == ["write:a", "write:b"])
        #expect(fixture.access.files[fixture.b]?.content == Data("new disk".utf8))
        let record = try #require(fixture.journal.records().first)
        #expect(record.entries.last?.state == .unknown)
        fixture.access.disconnected = false
        fixture.access.disconnectAfterWrite = nil
        guard case .recovered = await fixture.executor.recover(record.id) else { Issue.record("Expected recovery after reconnect")
        return }
        #expect(fixture.access.files[fixture.a]?.content == Data("old dirty".utf8))
        #expect(fixture.access.files[fixture.b]?.content == Data("old disk".utf8))
        #expect(fixture.access.calls.filter { $0.hasPrefix("write:") } == ["write:a", "write:b", "write:b", "write:a"])
    }
}
