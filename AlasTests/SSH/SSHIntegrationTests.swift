import Foundation
import Testing
@testable import Alas

/// Enable with ALAS_SSH_INTEGRATION=1 and key-authenticated ssh localhost.
@Suite(.disabled(if: ProcessInfo.processInfo.environment["ALAS_SSH_INTEGRATION"] != "1"))
struct SSHIntegrationTests {
    private struct ProjectMemoryStore: PersistenceStoreProtocol {
        let projectsFile: ProjectsFile

        func write<T: Encodable>(_: T, to _: URL) throws {}

        func readIfExists<T: Decodable>(_ type: T.Type, from _: URL) throws -> T? {
            if type == ProjectsFile.self {
                return projectsFile as? T
            }
            if type == AppConfig.self {
                return AppConfig.defaults as? T
            }
            return nil
        }
    }

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

    @Test @MainActor func remoteBranchesDiscoverOverSSHLocalhost() async throws {
        try #require(enabled, "set ALAS_SSH_INTEGRATION=1 to run")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-ssh-branches-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            RemoteHostRegistry.shared.unregister(root: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }

        _ = try await Process.run("/usr/bin/env", args: ["git", "init", "-q", "-b", "main"], cwd: directory)
        _ = try await Process.run("/usr/bin/env", args: ["git", "config", "user.email", "test@example.com"], cwd: directory)
        _ = try await Process.run("/usr/bin/env", args: ["git", "config", "user.name", "Test User"], cwd: directory)
        _ = try await Process.run("/usr/bin/env", args: ["git", "commit", "-q", "--allow-empty", "-m", "initial"], cwd: directory)
        _ = try await Process.run("/usr/bin/env", args: ["git", "branch", "feature/remote"], cwd: directory)
        let project = ProjectConfig(
            id: "ssh-branches",
            name: "SSH Branches",
            path: directory.path,
            color: "blue",
            addedAt: Date(),
            host: "localhost"
        )
        let state = AppState(store: ProjectMemoryStore(
            projectsFile: ProjectsFile(projects: [project])
        ))

        let result = await state.remoteBranches(projectId: project.id)

        guard case let .success(branches, preferredBase) = result else {
            Issue.record("expected branch list success, got \(result)")
            return
        }
        #expect(branches.contains("main"))
        #expect(branches.contains("feature/remote"))
        #expect(preferredBase == "main")
    }

    @Test @MainActor func remoteWorktreeSessionCreationOverSSHLocalhost() async throws {
        try #require(enabled, "set ALAS_SSH_INTEGRATION=1 to run")

        let repository = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-ssh-worktree-session-\(UUID().uuidString)")
        let worktreeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-ssh-worktree-root-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer {
            RemoteHostRegistry.shared.unregister(root: repository.path)
            try? FileManager.default.removeItem(at: worktreeRoot)
            try? FileManager.default.removeItem(at: repository)
        }

        _ = try await Process.run("/usr/bin/env", args: ["git", "init", "-q", "-b", "main"], cwd: repository)
        _ = try await Process.run("/usr/bin/env", args: ["git", "config", "user.email", "test@example.com"], cwd: repository)
        _ = try await Process.run("/usr/bin/env", args: ["git", "config", "user.name", "Test User"], cwd: repository)
        _ = try await Process.run("/usr/bin/env", args: ["git", "commit", "-q", "--allow-empty", "-m", "initial"], cwd: repository)
        let project = ProjectConfig(
            id: "ssh-worktree-session",
            name: "SSH Worktree Session",
            path: repository.path,
            color: "blue",
            addedAt: Date(),
            host: "localhost"
        )
        let state = AppState(store: ProjectMemoryStore(
            projectsFile: ProjectsFile(projects: [project])
        ))
        state.config.worktrees.rootPath = worktreeRoot.path
        state.config.worktrees.pathTemplate = "{worktreeRoot}/{repo}-{branch}"
        state.agentRegistry = AgentRegistry(
            builtinState: [
                "claude": BuiltinAgentState(isEnabled: true, binaryOverride: nil, extraTerminalArgs: nil),
            ],
            customs: [],
            installedIds: ["claude"]
        )
        state.remoteSessionAttachScheduler = { _, _ in }

        let result = await state.createRemoteWorktreeSession(
            projectId: project.id,
            base: "main",
            branch: "feature/ssh",
            agentId: "claude"
        )

        guard case let .success(summary) = result else {
            Issue.record("expected remote worktree session creation, got \(result)")
            return
        }
        let worktree = try #require(summary.worktree)
        let worktreeId = Worktree.makeId(path: URL(fileURLWithPath: worktree.path))
        defer {
            RemoteHostRegistry.shared.unregister(root: worktree.path)
            try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId))
            let database = Paths.acpSessionsDB(forWorktreeId: worktreeId)
            try? FileManager.default.removeItem(at: database)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: database.path + "-wal"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: database.path + "-shm"))
        }
        #expect(FileManager.default.fileExists(atPath: worktree.path))
        #expect(state.selectedWorktreeId == worktreeId)
        #expect(state.tabs.tabs(forWorktree: worktreeId).contains { tab in
            if case let .acpSession(session) = tab { return session.sessionId == summary.id }
            return false
        })
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
        guard case let .file(data, mtime) = initial else {
            Issue.record("expected readable file")
            return
        }
        #expect(String(data: data, encoding: .utf8) == "one\n")
        #expect(RemoteSaveGate.decision(originalMtime: mtime, remoteMtime: mtime) == .proceed)
        _ = try await RemoteFileAccess.write(host: "localhost", path: file.path, content: "two\n")
        let updated = try await RemoteFileAccess.read(host: "localhost", path: file.path)
        guard case let .file(updatedData, updatedMtime) = updated else {
            Issue.record("expected updated file")
            return
        }
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

    @Test func remoteMoveAndTTYCleanupAgainstLocalhost() async throws {
        try #require(enabled, "set ALAS_SSH_INTEGRATION=1 to run")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-ssh-p6-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let from = directory.appendingPathComponent("a.txt").path
        _ = try await RemoteFileAccess.write(host: "localhost", path: from, content: "x\n")
        let to = directory.appendingPathComponent("nested/dir/b.txt").path
        let move = try await RemoteExec.run(
            host: "localhost",
            cwd: nil,
            command: RemoteFileOps.moveCommand(from: from, to: to),
            timeout: 15
        )
        #expect(move.exitCode == 0)
        #expect(FileManager.default.fileExists(atPath: to))
        #expect(!FileManager.default.fileExists(atPath: from))

        let marker = "alas-hup-probe-\(UUID().uuidString.prefix(8))"
        let ssh = SSHCommand(host: "localhost", mode: .batch)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: SSHCommand.executable)
        process.arguments = ["-tt"] + ssh.argv(remoteScript: SSHCommand.remoteScript(
            command: "sleep 300; : \(marker)"
        ))
        try process.run()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        process.terminate()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let survivors = try await Process.run(
            "/usr/bin/env", args: ["pgrep", "-f", marker], timeout: 10
        )
        #expect(survivors.exitCode != 0)
    }

    @Test func remoteDiscardRemovesUntrackedFilesAgainstLocalhost() async throws {
        try #require(enabled, "set ALAS_SSH_INTEGRATION=1 to run")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-ssh-discard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            RemoteHostRegistry.shared.unregister(root: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }

        _ = try await Process.run("/usr/bin/env", args: ["git", "init", "-q", "-b", "main"], cwd: directory)
        _ = try await Process.run("/usr/bin/env", args: ["git", "config", "user.email", "t@e"], cwd: directory)
        _ = try await Process.run("/usr/bin/env", args: ["git", "config", "user.name", "t"], cwd: directory)
        try Data("seed\n".utf8).write(to: directory.appendingPathComponent("seed.txt"))
        _ = try await Process.run("/usr/bin/env", args: ["git", "add", "seed.txt"], cwd: directory)
        _ = try await Process.run("/usr/bin/env", args: ["git", "commit", "-q", "-m", "seed"], cwd: directory)
        try Data("remote\n".utf8).write(to: directory.appendingPathComponent("untracked.txt"))
        RemoteHostRegistry.shared.register(root: directory.path, host: "localhost")

        try await GitService().discardPaths(worktreePath: directory, files: ["untracked.txt"])

        let exists = try await RemoteExec.run(
            host: "localhost",
            cwd: nil,
            command: "[ -e \(SSHCommand.shellQuote(directory.appendingPathComponent("untracked.txt").path)) ]",
            timeout: 10
        )
        #expect(exists.exitCode != 0)
    }

    /// Finding 1 (2nd Codex pass on PR #1124): a directory symlink alias to
    /// `.git` used to pass `RemotePathContainment.verifyRemoteContainment`
    /// because only the physical PARENT's location was checked — the
    /// resolved path landed inside `.git`, which is still under the
    /// worktree root. Requires a real SSH connection (the containment probe
    /// runs remote `cd`/`pwd -P`), so this is gated behind
    /// `ALAS_SSH_INTEGRATION=1` like the rest of this suite.
    @Test func containmentRejectsADirectorySymlinkAliasToGitOverSSHLocalhost() async throws {
        try #require(enabled, "set ALAS_SSH_INTEGRATION=1 to run")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-ssh-git-alias-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gitDir = directory.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try Data("[remote \"origin\"]\n\turl = https://user:secret@example.com/repo.git\n".utf8)
            .write(to: gitDir.appendingPathComponent("config"))
        try FileManager.default.createSymbolicLink(
            atPath: directory.appendingPathComponent("alias").path, withDestinationPath: ".git")

        await #expect(throws: RemotePathContainment.ContainmentError.self) {
            try await RemotePathContainment.verifyRemoteContainment(
                host: "localhost",
                path: directory.appendingPathComponent("alias/config").path,
                worktreeRoot: directory.path
            )
        }
        // A legitimate file must still pass.
        try Data("print(1)".utf8).write(to: directory.appendingPathComponent("main.swift"))
        try await RemotePathContainment.verifyRemoteContainment(
            host: "localhost",
            path: directory.appendingPathComponent("main.swift").path,
            worktreeRoot: directory.path
        )
    }

    /// Finding 2: `RemoteFileAccess.size` must report the real remote byte
    /// count via a cheap `stat`, without transferring the file's contents.
    @Test func remoteFileAccessSizeReportsByteCountOverSSHLocalhost() async throws {
        try #require(enabled, "set ALAS_SSH_INTEGRATION=1 to run")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-ssh-size-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("big.txt")
        try String(repeating: "x", count: 10_000).write(to: file, atomically: true, encoding: .utf8)

        let size = try await RemoteFileAccess.size(host: "localhost", path: file.path)
        #expect(size == 10_000)

        let missing = try await RemoteFileAccess.size(
            host: "localhost", path: directory.appendingPathComponent("missing.txt").path)
        #expect(missing == nil)
    }

    /// Finding 2 end-to-end: `AppState.readRemoteWorktreeFileRaw` must
    /// report `.tooLarge` with the real byte count for an oversized remote
    /// file WITHOUT ever downloading it.
    @Test @MainActor func readRemoteWorktreeFileRawReportsTooLargeWithoutDownloadingOverSSHLocalhost() async throws {
        try #require(enabled, "set ALAS_SSH_INTEGRATION=1 to run")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-ssh-toolarge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("huge.txt")
        let byteCount = RemoteWorktreeFileAccess.maxFileBytes + 1
        try String(repeating: "x", count: byteCount).write(to: file, atomically: true, encoding: .utf8)

        let state = AppState(store: ProjectMemoryStore(projectsFile: ProjectsFile(projects: [])))
        let outcome = await state.readRemoteWorktreeFileRaw(
            host: "localhost", worktreeRoot: directory.path, relativePath: "huge.txt")

        guard case let .tooLarge(byteSize) = outcome else {
            Issue.record("expected .tooLarge, got \(outcome)")
            return
        }
        #expect(byteSize == byteCount)
    }

    /// Finding 3: the remote branch of `fileTreeChildren` must classify
    /// gitignored entries as `.ignored` (not `.tracked`, which would leak
    /// their names past `AppState.remoteFileNodes`' visibility filter).
    @Test func fileTreeChildrenFiltersIgnoredEntriesOverSSHLocalhost() async throws {
        try #require(enabled, "set ALAS_SSH_INTEGRATION=1 to run")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-ssh-ignored-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            RemoteHostRegistry.shared.unregister(root: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        _ = try await Process.run("/usr/bin/env", args: ["git", "init", "-q", "-b", "main"], cwd: directory)
        _ = try await Process.run("/usr/bin/env", args: ["git", "config", "user.email", "t@e"], cwd: directory)
        _ = try await Process.run("/usr/bin/env", args: ["git", "config", "user.name", "t"], cwd: directory)
        try Data("node_modules/\n".utf8).write(to: directory.appendingPathComponent(".gitignore"))
        _ = try await Process.run("/usr/bin/env", args: ["git", "add", ".gitignore"], cwd: directory)
        _ = try await Process.run("/usr/bin/env", args: ["git", "commit", "-q", "-m", "init"], cwd: directory)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: directory.appendingPathComponent("node_modules/pkg.js"))
        try Data("keep".utf8).write(to: directory.appendingPathComponent("keep.txt"))
        _ = try await Process.run("/usr/bin/env", args: ["git", "add", "keep.txt"], cwd: directory)
        _ = try await Process.run("/usr/bin/env", args: ["git", "commit", "-q", "-m", "add keep"], cwd: directory)
        RemoteHostRegistry.shared.register(root: directory.path, host: "localhost")

        let children = try await GitService().fileTreeChildren(worktreePath: directory, path: "")

        let ignoredNode = try #require(children.first { $0.path == "node_modules" })
        #expect(ignoredNode.visibility == .ignored)
        #expect(children.first { $0.path == "keep.txt" }?.visibility == .tracked)
    }

    /// Finding 5: untracked-file line counts in the remote base-relative
    /// changes view must use the real remote byte content, not a local
    /// `Data(contentsOf:)` read against a path with no local file behind it
    /// (which silently reports 0 lines).
    @Test func changedFilesAgainstRefUsesRemoteLineCountsForUntrackedFilesOverSSHLocalhost() async throws {
        try #require(enabled, "set ALAS_SSH_INTEGRATION=1 to run")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-ssh-linecounts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            RemoteHostRegistry.shared.unregister(root: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        _ = try await Process.run("/usr/bin/env", args: ["git", "init", "-q", "-b", "main"], cwd: directory)
        _ = try await Process.run("/usr/bin/env", args: ["git", "config", "user.email", "t@e"], cwd: directory)
        _ = try await Process.run("/usr/bin/env", args: ["git", "config", "user.name", "t"], cwd: directory)
        _ = try await Process.run("/usr/bin/env", args: ["git", "commit", "-q", "--allow-empty", "-m", "init"], cwd: directory)
        _ = try await Process.run("/usr/bin/env", args: ["git", "branch", "start"], cwd: directory)
        try Data("one\ntwo\nthree\n".utf8).write(to: directory.appendingPathComponent("untracked.txt"))
        RemoteHostRegistry.shared.register(root: directory.path, host: "localhost")

        let files = try await GitService().changedFilesAgainstRef(worktreePath: directory, ref: "start")

        let untracked = try #require(files.first { $0.path == "untracked.txt" })
        #expect(untracked.add == 3)
    }
}
