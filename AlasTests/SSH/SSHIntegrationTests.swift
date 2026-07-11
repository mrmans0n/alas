import Foundation
import Testing
@testable import Alas

/// Enable with ALAS_SSH_INTEGRATION=1 and key-authenticated ssh localhost.
struct SSHIntegrationTests {
    private var enabled: Bool {
        ProcessInfo.processInfo.environment["ALAS_SSH_INTEGRATION"] == "1"
    }

    @Test func remoteGitStatusOverSSHLocalhost() async throws {
        try #require(enabled, "set ALAS_SSH_INTEGRATION=1 to run")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-ssh-itest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            RemoteHostRegistry.shared.unregister(root: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }

        _ = try await Process.run("/usr/bin/env", args: ["git", "init"], cwd: directory)
        RemoteHostRegistry.shared.register(root: directory.path, host: "localhost")
        let status = try await Process.git(["status", "--porcelain=v2"], cwd: directory)
        #expect(status.exitCode == 0)
        let repository = try await Process.git(["rev-parse", "--is-inside-work-tree"], cwd: directory)
        #expect(repository.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true")
    }

    @Test func remoteValidatorAcceptsAndRejects() async throws {
        try #require(enabled, "set ALAS_SSH_INTEGRATION=1 to run")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-ssh-itest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await Process.run("/usr/bin/env", args: ["git", "init"], cwd: directory)

        try await RemoteRepoValidator.validate(host: "localhost", path: directory.path)
        await #expect(throws: RemoteRepoValidationError.self) {
            try await RemoteRepoValidator.validate(host: "localhost", path: "/nonexistent-alas")
        }
    }

    @Test func remoteExecAndCapabilitiesAgainstLocalhost() async throws {
        try #require(enabled, "set ALAS_SSH_INTEGRATION=1 to run")
        let echo = try await RemoteExec.run(host: "localhost", cwd: nil, command: "echo alas-ok")
        #expect(echo.exitCode == 0)
        #expect(echo.stdout.contains("alas-ok"))
        let capabilities = await RemoteHostCapabilityStore.shared.capabilities(for: "localhost")
        #expect(capabilities?.os == .macos)
        #expect(capabilities?.gitVersion != nil)
    }

    @Test func remoteFileAccessRoundTripAndConflictGate() async throws {
        try #require(enabled, "set ALAS_SSH_INTEGRATION=1 to run")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-ssh-file-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("run.sh")
        try Data("one\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)

        let initial = try await RemoteFileAccess.read(host: "localhost", path: file.path)
        guard case let .file(data, mtime) = initial else { Issue.record("expected readable file"); return }
        #expect(String(data: data, encoding: .utf8) == "one\n")
        #expect(RemoteSaveGate.decision(originalMtime: mtime, remoteMtime: mtime) == .proceed)
        _ = try await RemoteFileAccess.write(host: "localhost", path: file.path, content: "two\n")
        let updated = try await RemoteFileAccess.read(host: "localhost", path: file.path)
        guard case let .file(updatedData, updatedMtime) = updated else { Issue.record("expected updated file"); return }
        #expect(String(data: updatedData, encoding: .utf8) == "two\n")
        #expect(RemoteSaveGate.decision(originalMtime: mtime, remoteMtime: updatedMtime) == .conflict)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o755)
    }

    @Test func remoteZmxBatchLadderDegradesGracefully() async throws {
        try #require(enabled, "set ALAS_SSH_INTEGRATION=1 to run")
        let result = try await RemoteExec.run(
            host: "localhost",
            cwd: nil,
            command: RemoteTerminalScript.zmxBatchCommand(["ls", "--short"]),
            timeout: 10
        )
        #expect(result.exitCode == 0)
    }

    @Test func attachScriptRunsPlainShellOverSSH() async throws {
        try #require(enabled, "set ALAS_SSH_INTEGRATION=1 to run")
        let script = RemoteTerminalScript.attachScript(
            worktreePath: "/tmp",
            sessionName: "alas-itest",
            useZmx: false,
            startupSuffix: "pwd; exit 0"
        )
        let result = try await RemoteExec.run(
            host: "localhost",
            cwd: nil,
            command: script,
            timeout: 20
        )
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("/tmp"))
    }
}
