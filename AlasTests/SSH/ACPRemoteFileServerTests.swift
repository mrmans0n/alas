import Foundation
import Testing
@testable import Alas

struct ACPRemoteFileServerTests {
    private let server = ACPRemoteFileServer(host: "devbox", worktreeRoot: "/srv/repo")

    @Test func containsPathsInsideRoot() throws {
        #expect(try server.lexicallyResolveInsideWorktree(path: "src/main.swift") == "/srv/repo/src/main.swift")
        #expect(try server.lexicallyResolveInsideWorktree(path: "/srv/repo/a.txt") == "/srv/repo/a.txt")
    }

    @Test func normalizesDotSegments() throws {
        #expect(try server.lexicallyResolveInsideWorktree(path: "src/../src/./m.swift") == "/srv/repo/src/m.swift")
    }

    @Test func rejectsEscapes() {
        #expect(throws: (any Error).self) { try server.lexicallyResolveInsideWorktree(path: "../outside") }
        #expect(throws: (any Error).self) { try server.lexicallyResolveInsideWorktree(path: "/srv/repo-other/x") }
    }

    @Test func containmentProbeUsesPhysicalParentCheck() {
        let command = server.containmentProbeCommand(path: "/srv/repo/link/passwd")

        #expect(command.contains("root='/srv/repo'"))
        #expect(command.contains("target='/srv/repo/link/passwd'"))
        #expect(command.contains("pwd -P"))
        #expect(command.contains("existing_phys"))
        #expect(command.contains("exit 6"))
    }

    @Test func sharedContainmentHelperUsesSameProbe() {
        let command = RemotePathContainment.containmentProbeCommand(
            path: "/srv/repo/link/passwd",
            worktreeRoot: "/srv/repo"
        )

        #expect(command == server.containmentProbeCommand(path: "/srv/repo/link/passwd"))
    }

    @Test func containmentExcludingGitProbeCommandShapeChecksFullyResolvedRelativePath() {
        let command = RemotePathContainment.containmentExcludingGitProbeCommand(
            path: "/srv/repo/alias/config",
            worktreeRoot: "/srv/repo"
        )

        #expect(command.contains("root='/srv/repo'"))
        #expect(command.contains("target='/srv/repo/alias/config'"))
        #expect(command.contains("pwd -P"))
        #expect(command.contains(".[Gg][Ii][Tt]"))
        #expect(command.contains("exit 7"))
    }

    /// Verifies the shell script's actual behavior directly, without an SSH
    /// connection: `RemoteExec.run` would run this exact string as a POSIX
    /// shell command on the remote host, and since the script only uses
    /// `cd`/`pwd -P`/`dirname`/`basename`/`case` its behavior is identical
    /// run locally via `/bin/sh -c`. This proves the shell logic itself is
    /// correct; it does not exercise `RemoteExec.run` or a real SSH host.
    @Test func containmentExcludingGitProbeCommandRejectsADirectorySymlinkAliasToGit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-containment-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let gitDir = root.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try "fake git config".write(to: gitDir.appendingPathComponent("config"), atomically: true, encoding: .utf8)

        let srcDir = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try "print(1)".write(to: srcDir.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)

        let alias = root.appendingPathComponent("alias")
        // Use the String-based API so the symlink target is written as the
        // literal relative string ".git" (resolved relative to `alias`'s own
        // directory when followed) — the URL-based overload would instead
        // resolve `URL(fileURLWithPath: ".git")` against the PROCESS's
        // current directory before writing the link, producing a broken
        // symlink here.
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: ".git")

        // The alias resolves (through the symlink) to inside `.git` — must be rejected.
        #expect(try await exitCode(forTarget: alias.appendingPathComponent("config").path, root: root.path) == 7)
        // Requesting the alias itself (a directory symlink to `.git`) must also be rejected.
        #expect(try await exitCode(forTarget: alias.path, root: root.path) == 7)
        // The real `.git` directory, addressed directly, must also be rejected.
        #expect(try await exitCode(forTarget: gitDir.appendingPathComponent("config").path, root: root.path) == 7)
        // A legitimate existing file must pass.
        #expect(try await exitCode(forTarget: srcDir.appendingPathComponent("main.swift").path, root: root.path) == 0)
        // A legitimate not-yet-existing file (about to be created) must pass.
        #expect(try await exitCode(forTarget: srcDir.appendingPathComponent("new.swift").path, root: root.path) == 0)
    }

    private func exitCode(forTarget target: String, root: String) async throws -> Int32 {
        let command = RemotePathContainment.containmentExcludingGitProbeCommand(path: target, worktreeRoot: root)
        let result = try await Process.run("/bin/sh", args: ["-c", command])
        return result.exitCode
    }
}
