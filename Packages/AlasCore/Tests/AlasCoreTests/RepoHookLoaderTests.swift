import Foundation
import Testing
import AlasCore

struct RepoHookLoaderTests {
    @Test func loadsExactUTF8HookBytes() async throws {
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("echo from repo\n".utf8)
        try write(bytes, event: .sessionOpen, root: root)

        let result = await RepoHookLoader().load(event: .sessionOpen, worktreeRoot: root, host: nil)

        guard case let .loaded(hook) = result else {
            Issue.record("expected loaded hook, got \(result)")
            return
        }
        #expect(hook.bytes == bytes)
        #expect(hook.text == "echo from repo\n")
        #expect(hook.source == .local)
        #expect(hook.hash == RepoHookTrust.hash(event: .sessionOpen, bytes: bytes))
    }

    @Test func reportsMissingAndWhitespaceOnlyHooksSeparately() async throws {
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(await RepoHookLoader().load(event: .sessionOpen, worktreeRoot: root, host: nil) == .missing(source: .local))

        try write(Data(" \n\t".utf8), event: .sessionOpen, root: root)
        #expect(await RepoHookLoader().load(event: .sessionOpen, worktreeRoot: root, host: nil) == .empty(source: .local))
    }

    @Test func rejectsInvalidUTF8AndOversizedHooks() async throws {
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }

        try write(Data([0xFF]), event: .sessionOpen, root: root)
        let invalidUTF8 = await RepoHookLoader().load(event: .sessionOpen, worktreeRoot: root, host: nil)
        #expect(invalidUTF8 == .failed(source: .local, message: "Hook is not valid UTF-8"))

        try write(Data(repeating: UInt8(ascii: "x"), count: RepoHookLoader.maximumBytes + 1), event: .sessionOpen, root: root)
        let oversized = await RepoHookLoader().load(event: .sessionOpen, worktreeRoot: root, host: nil)
        #expect(oversized == .failed(source: .local, message: "Hook exceeds the 256 KiB limit"))
    }

    @Test func acceptsFinalSymlinkThatResolvesInsideWorktree() async throws {
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("scripts/hook.sh")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "echo linked".write(to: target, atomically: true, encoding: .utf8)
        let hook = hookURL(event: .sessionOpen, root: root)
        try FileManager.default.createSymbolicLink(atPath: hook.path, withDestinationPath: "../../scripts/hook.sh")

        let result = await RepoHookLoader().load(event: .sessionOpen, worktreeRoot: root, host: nil)

        guard case let .loaded(loaded) = result else {
            Issue.record("expected loaded hook, got \(result)")
            return
        }
        #expect(loaded.text == "echo linked")
    }

    @Test func reportsDanglingIntermediateSymlinkAsReadFailure() async throws {
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let hooksDirectory = root.appendingPathComponent(".alas/hooks")
        try FileManager.default.removeItem(at: hooksDirectory)
        let missingDirectory = root.appendingPathComponent("missing-hooks")
        try FileManager.default.createSymbolicLink(
            atPath: hooksDirectory.path,
            withDestinationPath: missingDirectory.path
        )

        let result = await RepoHookLoader().load(event: .sessionOpen, worktreeRoot: root, host: nil)

        #expect(result == .failed(source: .local, message: "Hook symlink could not be resolved safely"))
    }

    @Test func rejectsSymlinkThatEscapesWorktree() async throws {
        let root = try makeRepository()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try "echo escaped".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: hookURL(event: .sessionOpen, root: root), withDestinationURL: outside)

        let result = await RepoHookLoader().load(event: .sessionOpen, worktreeRoot: root, host: nil)

        #expect(result == .failed(source: .local, message: "Hook resolves outside the worktree"))
    }

    @Test func injectedRemoteReaderPreservesRemoteSourceAndFailures() async throws {
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let loader = RepoHookLoader { _, _, host in
            host == "devbox" ? .data(Data("echo remote".utf8)) : .failed("connection failed")
        }

        let loaded = await loader.load(event: .worktreeCreate, worktreeRoot: root, host: "devbox")
        let failed = await loader.load(event: .worktreeCreate, worktreeRoot: root, host: "offline")

        guard case let .loaded(hook) = loaded else {
            Issue.record("expected loaded hook, got \(loaded)")
            return
        }
        #expect(hook.source == .remote(host: "devbox"))
        #expect(hook.text == "echo remote")
        #expect(failed == .failed(source: .remote(host: "offline"), message: "connection failed"))
    }

    @Test func reportsInaccessibleHooksAsReadFailures() async throws {
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let hooksDirectory = root.appendingPathComponent(".alas/hooks")
        try write(Data("echo protected".utf8), event: .sessionOpen, root: root)
        let originalPermissions = try #require(
            FileManager.default.attributesOfItem(atPath: hooksDirectory.path)[.posixPermissions]
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: originalPermissions],
                ofItemAtPath: hooksDirectory.path
            )
        }
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: hooksDirectory.path)

        let result = await RepoHookLoader().load(event: .sessionOpen, worktreeRoot: root, host: nil)

        guard case let .failed(source, _) = result else {
            Issue.record("expected an inaccessible hook to fail, got \(result)")
            return
        }
        #expect(source == .local)
    }

    // `loadCommitted` must approve the bytes a checkout of `ref` will run,
    // judged by the same rules as the disk loader.

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

    private func makeRepository() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alas-repo-hook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".alas/hooks"), withIntermediateDirectories: true)
        return root
    }

    private func hookURL(event: RepoHookEvent, root: URL) -> URL {
        root.appendingPathComponent(event.relativePath)
    }

    private func write(_ bytes: Data, event: RepoHookEvent, root: URL) throws {
        try bytes.write(to: hookURL(event: event, root: root))
    }

    /// A repository at `<tmp>/repo` whose `main` commits whatever `write`
    /// puts at the worktree-create hook's path.
    private func commitHook(_ write: (URL) throws -> Void) async throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alas-committed-hook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = root.appendingPathComponent("repo")
        try await GitTemplate.repository(at: repo)
        let hook = repo.appendingPathComponent(RepoHookEvent.worktreeCreate.relativePath)
        try FileManager.default.createDirectory(at: hook.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write(hook)
        _ = try await Process.git(["add", "-A"], cwd: repo)
        _ = try await Process.git(
            ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-q", "-m", "Add hook"], cwd: repo)
        return repo
    }
}
