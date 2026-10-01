import Darwin
import Foundation
import Testing
@testable import Alas

struct AppStateRemoteWorktreePathTests {
    @Test(arguments: ["feature", "missing/repo/feature", "quote's dir/feature"])
    func remoteDestinationResolvesSymlinkBeforeAssigningWorktreeIdentity(suffix: String) async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let physical = root.appendingPathComponent("physical")
        let alias = root.appendingPathComponent("workspace")
        try fm.createDirectory(at: physical, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: alias, withDestinationURL: physical)
        defer { try? fm.removeItem(at: root) }
        // Foundation normalizes /private/var back to /var on this Mac.
        // Use the filesystem's physical spelling, as remote Git does.
        let physicalPath = try #require(realpath(physical.path, nil))
        defer { free(physicalPath) }

        let destination = try await RemotePath.resolvedWorktreeDestination(
            alias.appendingPathComponent(suffix).path,
            anchor: "/.alas-remote/mini/repo",
            runCommand: { command in
                let process = Process()
                let output = Pipe()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", command]
                process.standardOutput = output
                try process.run()
                process.waitUntilExit()
                return ProcessResult(
                    exitCode: process.terminationStatus,
                    stdout: String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                    stderr: ""
                )
            }
        )

        #expect(destination.path == "/.alas-remote/mini\(String(cString: physicalPath))/\(suffix)")
        #expect(!fm.fileExists(atPath: physical.appendingPathComponent(suffix).path))
    }

    @Test func remoteDestinationRejectsFailedResolution() async {
        await #expect(throws: (any Error).self) {
            try await RemotePath.resolvedWorktreeDestination(
                "/workspace/feature",
                anchor: "/.alas-remote/mini/repo",
                runCommand: { _ in ProcessResult(exitCode: 1, stdout: "", stderr: "unreadable parent") }
            )
        }
    }

    @Test func remoteWorktreeDestinationReplacesLocalHomePrefix() {
        let path = AppState.destinationPathReplacingLocalHome(
            "/Users/local/.alas/worktrees/repo-feature",
            localHome: "/Users/local",
            remoteHome: "/home/remote"
        )

        #expect(path == "/home/remote/.alas/worktrees/repo-feature")
    }

    @Test func remoteWorktreeDestinationKeepsNonHomeAbsolutePath() {
        let path = AppState.destinationPathReplacingLocalHome(
            "/srv/worktrees/repo-feature",
            localHome: "/Users/local",
            remoteHome: "/home/remote"
        )

        #expect(path == "/srv/worktrees/repo-feature")
    }

    /// Startup recovery matches an interrupted delegation by this path, so it
    /// must have the created worktree's form: virtual for a remote project.
    @Test(arguments: [
        ("/srv/repo", "/srv/worktrees/repo-feature"),
        ("/.alas-remote/mini/srv/repo", "/.alas-remote/mini/srv/worktrees/repo-feature"),
    ])
    func delegatedDestinationHasTheCreatedWorktreesForm(projectPath: String, expected: String) {
        let destination = AppState.delegatedWorktreeDestination(
            rendered: URL(fileURLWithPath: "/srv/worktrees/repo-feature"),
            projectPath: projectPath
        )

        #expect(destination.path == expected)
    }

    /// Local worktree destinations may not land in the reserved namespace,
    /// including its bare root.
    @Test(arguments: [RemotePath.root, RemotePath.root + "/x/wt"])
    func localDestinationRefusesTheReservedNamespace(destination: String) async {
        await #expect(throws: (any Error).self) {
            try await AppState.preparedCreateWorktreeDestination(
                repoPath: URL(fileURLWithPath: "/srv/repo"),
                destination: URL(fileURLWithPath: destination)
            )
        }
    }

    @Test func remoteSaveAsNormalizesRelativePath() throws {
        let path = try AppState.normalizedRemoteRelativePath(" nested\\file.txt ")

        #expect(path == "nested/file.txt")
    }

    @Test func remoteSaveAsRejectsAbsoluteOrEscapingPaths() {
        #expect(throws: (any Error).self) {
            try AppState.normalizedRemoteRelativePath("/tmp/file.txt")
        }
        #expect(throws: (any Error).self) {
            try AppState.normalizedRemoteRelativePath("../file.txt")
        }
    }
}
