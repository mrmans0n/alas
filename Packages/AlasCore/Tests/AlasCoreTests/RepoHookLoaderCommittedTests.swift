import Foundation
import Testing
import AlasCore

/// `loadCommitted` must approve the bytes a checkout of `ref` will run,
/// judged by the same rules as the disk loader.
struct RepoHookLoaderCommittedTests {
    /// A committed symlink, both inside the tree and escaping it, loads as the
    /// disk loader loads the same checkout.
    @Test(arguments: ["../../scripts/hook.sh", "../../../outside.sh"])
    func aSymlinkedHookLoadsAsOnDisk(target: String) async throws {
        let repo = try await commitHook { hook in
            let script = hook.deletingLastPathComponent().appendingPathComponent(target).standardizedFileURL
            try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "echo linked\n".write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.createSymbolicLink(atPath: hook.path, withDestinationPath: target)
        }
        defer { try? FileManager.default.removeItem(at: repo.deletingLastPathComponent()) }

        let committed = await RepoHookLoader.loadCommitted(event: .worktreeCreate, ref: "main", repoPath: repo, host: nil)
        let onDisk = await RepoHookLoader().load(event: .worktreeCreate, worktreeRoot: repo, host: nil)

        #expect(committed == onDisk)
        if case let .loaded(hook) = committed { #expect(hook.text == "echo linked\n") }
    }

    /// A link target is a path, not a pathspec: `../../:/scripts/hook.sh` names
    /// a directory called `:` at the root, not the root's `scripts/hook.sh`.
    @Test func aSymlinkTargetIsNotReadAsAPathspec() async throws {
        let repo = try await commitHook { hook in
            let script = hook.deletingLastPathComponent().appendingPathComponent("../../scripts/hook.sh").standardizedFileURL
            try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "echo linked\n".write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.createSymbolicLink(atPath: hook.path, withDestinationPath: "../../:/scripts/hook.sh")
        }
        defer { try? FileManager.default.removeItem(at: repo.deletingLastPathComponent()) }

        #expect(await RepoHookLoader.loadCommitted(event: .worktreeCreate, ref: "main", repoPath: repo, host: nil)
            == .failed(source: .local, message: "Hook symlink could not be resolved safely"))
    }

    @Test func anOversizedCommittedHookIsRejected() async throws {
        let repo = try await commitHook { hook in
            try Data(repeating: UInt8(ascii: "x"), count: RepoHookLoader.maximumBytes + 1).write(to: hook)
        }
        defer { try? FileManager.default.removeItem(at: repo.deletingLastPathComponent()) }

        #expect(await RepoHookLoader.loadCommitted(event: .worktreeCreate, ref: "main", repoPath: repo, host: nil)
            == .failed(source: .local, message: "Hook exceeds the 256 KiB limit"))
    }

    /// A repository at `<tmp>/repo` whose `main` commits whatever `write`
    /// puts at the worktree-create hook's path.
    private func commitHook(_ write: (URL) throws -> Void) async throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alas-committed-hook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = root.appendingPathComponent("repo")
        try GitTemplate.repository(at: repo)
        let hook = repo.appendingPathComponent(RepoHookEvent.worktreeCreate.relativePath)
        try FileManager.default.createDirectory(at: hook.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write(hook)
        _ = try await Process.git(["add", "-A"], cwd: repo)
        _ = try await Process.git(
            ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-q", "-m", "Add hook"], cwd: repo)
        return repo
    }
}
