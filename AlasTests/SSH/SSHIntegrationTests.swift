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
}
