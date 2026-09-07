import Foundation
import Testing
import Darwin
@testable import Alas

/// Races `operation` against a timeout so a regression that reintroduces a
/// blocking read (e.g. `head` against a writerless FIFO) fails the test
/// loudly and promptly instead of hanging the whole suite.
private func withTimeout<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable () async -> T) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil
        }
        let result = await group.next() ?? nil
        group.cancelAll()
        return result
    }
}

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

    // MARK: - containedReadScript / containedRead

    /// Same local-`/bin/sh` verification strategy as
    /// `containmentExcludingGitProbeCommandRejectsADirectorySymlinkAliasToGit`:
    /// `containedReadScript` only uses POSIX shell builtins plus
    /// `stat`/`head`, so its behavior locally is identical to what
    /// `RemoteExec.run` would produce against a real remote host.
    private func runContainedRead(target: String, root: String, maxBytes: Int = 1_000_000) async throws -> ProcessResultData {
        let command = RemotePathContainment.containedReadScript(path: target, worktreeRoot: root, maxBytes: maxBytes)
        return try await Process.runData("/bin/sh", args: ["-c", command])
    }

    private func makeContainedReadRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-contained-read-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func containedReadScriptReadsAnOrdinaryFileInOneShellInvocation() async throws {
        let root = try makeContainedReadRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.txt")
        try "hello\n".write(to: file, atomically: true, encoding: .utf8)

        let result = try await runContainedRead(target: file.path, root: root.path)

        #expect(result.exitCode == 0)
        let text = String(data: result.stdout, encoding: .utf8)
        #expect(text == "6\nhello\n")
    }

    @Test func containedReadScriptRejectsASymlink() async throws {
        let root = try makeContainedReadRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("real.txt")
        try "secret\n".write(to: target, atomically: true, encoding: .utf8)
        let alias = root.appendingPathComponent("alias.txt")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)

        let result = try await runContainedRead(target: alias.path, root: root.path)

        #expect(result.exitCode == 8)
    }

    @Test func containedReadScriptRejectsADirectory() async throws {
        let root = try makeContainedReadRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let result = try await runContainedRead(target: dir.path, root: root.path)

        #expect(result.exitCode == 9)
    }

    /// A FIFO passes the symlink/directory/existence checks above it, so
    /// without an explicit regular-file check `head` would block
    /// indefinitely waiting for a writer that never arrives. `mkfifo`
    /// creates a real named pipe; nothing ever opens it for writing, so a
    /// regression that drops the `[ -f ]` check would hang this test until
    /// the timeout — asserted against explicitly so it fails loudly rather
    /// than hanging the whole suite.
    @Test func containedReadScriptRejectsAFIFOWithoutBlockingOnHead() async throws {
        let root = try makeContainedReadRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fifo = root.appendingPathComponent("pipe")
        #expect(fifo.path.withCString { mkfifo($0, 0o600) } == 0)

        let outcome = await withTimeout(seconds: 5) {
            try? await runContainedRead(target: fifo.path, root: root.path)
        }
        let result = try #require(
            outcome.flatMap { $0 },
            "containedReadScript hung on a writerless FIFO instead of returning promptly")

        #expect(result.exitCode == 12)
    }

    @Test func containedReadScriptReportsMissingFile() async throws {
        let root = try makeContainedReadRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try await runContainedRead(target: root.appendingPathComponent("nope.txt").path, root: root.path)

        #expect(result.exitCode == 10)
    }

    @Test func containedReadScriptRejectsPathsOutsideTheWorktree() async throws {
        let root = try makeContainedReadRoot()
        let outside = try makeContainedReadRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let file = outside.appendingPathComponent("secret.txt")
        try "nope\n".write(to: file, atomically: true, encoding: .utf8)

        let result = try await runContainedRead(target: file.path, root: root.path)

        #expect(result.exitCode == 6)
    }

    /// The script itself reads `maxBytes + 1` bytes (not exactly `maxBytes`)
    /// — see `containedReadScript`'s doc comment: that extra byte is how
    /// `parseContainedReadResult` detects a file that grew past `maxBytes`
    /// between the earlier `stat` and this `head` call.
    @Test func containedReadScriptCapsTheTransferredBodyWithoutMisreportingSize() async throws {
        let root = try makeContainedReadRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("big.txt")
        let content = String(repeating: "x", count: 1000)
        try content.write(to: file, atomically: true, encoding: .utf8)

        let result = try await runContainedRead(target: file.path, root: root.path, maxBytes: 10)

        #expect(result.exitCode == 0)
        guard let newline = result.stdout.firstIndex(of: UInt8(ascii: "\n")) else {
            Issue.record("expected a size header line")
            return
        }
        let header = String(data: result.stdout[..<newline], encoding: .utf8)
        #expect(header == "1000")
        let body = result.stdout[result.stdout.index(after: newline)...]
        #expect(body.count == 11)
    }

    // MARK: - parseContainedReadResult

    @Test func parseContainedReadResultReportsSizeAndPrefixForAnOrdinaryFile() {
        let stdout = "6\nhello\n".data(using: .utf8)!
        let outcome = RemotePathContainment.parseContainedReadResult(exitCode: 0, stdout: stdout, maxBytes: 1_000_000)
        #expect(outcome == .ok(byteSize: 6, prefix: "hello\n".data(using: .utf8)!))
    }

    /// The exact race the finding described: `stat` observed the file at
    /// 50 bytes (comfortably under `maxBytes`), but by the time `head -c
    /// maxBytes + 1` ran, a concurrent write had grown it — so the actual
    /// transferred body is `maxBytes + 1` bytes despite the stale "50"
    /// header. The parsed outcome must report the file as over the cap
    /// (`byteSize > maxBytes`) rather than trusting the header and handing
    /// back a truncated prefix as if it were the complete file.
    @Test func parseContainedReadResultOverridesAStaleSmallHeaderWhenTheActualBodyExceedsMaxBytes() {
        let maxBytes = 10
        let header = "50\n".data(using: .utf8)!
        let body = Data(repeating: UInt8(ascii: "x"), count: maxBytes + 1)
        let outcome = RemotePathContainment.parseContainedReadResult(exitCode: 0, stdout: header + body, maxBytes: maxBytes)
        guard case let .ok(byteSize, prefix) = outcome else {
            Issue.record("expected .ok, got \(outcome)")
            return
        }
        #expect(byteSize > maxBytes)
        #expect(prefix.count == maxBytes)
    }

    @Test func parseContainedReadResultMapsNonZeroExitCodes() {
        #expect(RemotePathContainment.parseContainedReadResult(exitCode: 6, stdout: Data(), maxBytes: 10) == .outsideWorktree)
        #expect(RemotePathContainment.parseContainedReadResult(exitCode: 7, stdout: Data(), maxBytes: 10) == .outsideWorktree)
        #expect(RemotePathContainment.parseContainedReadResult(exitCode: 8, stdout: Data(), maxBytes: 10) == .symlink)
        #expect(RemotePathContainment.parseContainedReadResult(exitCode: 9, stdout: Data(), maxBytes: 10) == .directory)
        #expect(RemotePathContainment.parseContainedReadResult(exitCode: 10, stdout: Data(), maxBytes: 10) == .missing)
        #expect(RemotePathContainment.parseContainedReadResult(exitCode: 11, stdout: Data(), maxBytes: 10) == .unreadable)
    }

    // MARK: - containedListScript / containedList

    /// Same local-`/bin/sh` verification strategy as the read-script tests
    /// above: `containedListScript` only uses POSIX shell builtins plus
    /// `ls`, so its behavior locally is identical to what `RemoteExec.run`
    /// would produce against a real remote host.
    private func runContainedList(target: String, root: String) async throws -> ProcessResultData {
        let command = RemotePathContainment.containedListScript(path: target, worktreeRoot: root)
        return try await Process.runData("/bin/sh", args: ["-c", command])
    }

    @Test func containedListScriptListsADirectoryInOneShellInvocation() async throws {
        let root = try makeContainedReadRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try "print(1)".write(to: root.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)

        let result = try await runContainedList(target: root.path, root: root.path)

        #expect(result.exitCode == 0)
        let entries = RemoteFileStats.parseLsEntries(String(data: result.stdout, encoding: .utf8) ?? "")
            .sorted { $0.name < $1.name }
        #expect(entries.map(\.name) == ["main.swift", "src"])
        #expect(entries.first { $0.name == "src" }?.isDirectory == true)
        #expect(entries.first { $0.name == "main.swift" }?.isDirectory == false)
    }

    @Test func containedListScriptRejectsAFile() async throws {
        let root = try makeContainedReadRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.txt")
        try "hello\n".write(to: file, atomically: true, encoding: .utf8)

        let result = try await runContainedList(target: file.path, root: root.path)

        #expect(result.exitCode == 9)
    }

    @Test func containedListScriptRejectsPathsOutsideTheWorktree() async throws {
        let root = try makeContainedReadRoot()
        let outside = try makeContainedReadRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        let result = try await runContainedList(target: outside.path, root: root.path)

        #expect(result.exitCode == 6)
    }

    /// The exact scenario the finding described: containment and the
    /// listing must resolve the SAME physical path, so a directory symlink
    /// alias to `.git` is rejected here just as it is for reads.
    @Test func containedListScriptRejectsADirectorySymlinkAliasToGit() async throws {
        let root = try makeContainedReadRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let gitDir = root.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: ".git")

        let result = try await runContainedList(target: alias.path, root: root.path)

        #expect(result.exitCode == 7)
    }
}
