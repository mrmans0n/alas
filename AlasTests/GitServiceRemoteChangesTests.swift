import Testing
import Foundation
@testable import Alas

@Suite(.serialized)
@MainActor
struct GitServiceRemoteChangesTests {
    private func makeRepo() async throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-remote-changes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: tmp)
        _ = try await Process.git(["config", "user.email", "test@example.com"], cwd: tmp)
        _ = try await Process.git(["config", "user.name", "test user"], cwd: tmp)
        return tmp
    }

    @Test func changedFilesAgainstRef_includesCommittedAndUncommittedAndUntracked() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "one\n".write(to: repo.appendingPathComponent("base.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "base.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "base"], cwd: repo)
        _ = try await Process.git(["branch", "start"], cwd: repo)

        try "one\ntwo\n".write(to: repo.appendingPathComponent("base.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "base.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "committed change"], cwd: repo)

        try "dirty\n".write(to: repo.appendingPathComponent("dirty.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "dirty.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "add dirty"], cwd: repo)
        try "dirty\nedited\n".write(to: repo.appendingPathComponent("dirty.txt"), atomically: true, encoding: .utf8)

        try "new\n".write(to: repo.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)

        let files = try await GitService().changedFilesAgainstRef(worktreePath: repo, ref: "start")
        #expect(files.map(\.path).sorted() == ["base.txt", "dirty.txt", "untracked.txt"])
        let base = try #require(files.first { $0.path == "base.txt" })
        #expect(base.status == "M")
        #expect(base.add == 1)
        let untracked = try #require(files.first { $0.path == "untracked.txt" })
        #expect(untracked.status == "A")
        #expect(untracked.add == 1)
    }

    @Test func changedFilesAgainstRef_fallsBackToStatusWhenRefIsNil() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        _ = try await Process.git(["commit", "--allow-empty", "-m", "init"], cwd: repo)
        try "hello\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let files = try await GitService().changedFilesAgainstRef(worktreePath: repo, ref: nil)
        #expect(files.map(\.path) == ["a.txt"])
    }

    @Test func diffAgainstRef_returnsHunksForACommittedChange() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "one\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "a.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "base"], cwd: repo)
        _ = try await Process.git(["branch", "start"], cwd: repo)
        try "one\ntwo\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "a.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "second line"], cwd: repo)

        let diff = try await GitService().diff(worktreePath: repo, againstRef: "start", file: "a.txt")
        let added = diff.hunks.flatMap(\.lines).filter { $0.kind == .add }
        #expect(added.map(\.text) == ["two"])
    }

    @Test func diffAgainstRef_showsUntrackedFileAsAllAdd() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        _ = try await Process.git(["commit", "--allow-empty", "-m", "init"], cwd: repo)
        _ = try await Process.git(["branch", "start"], cwd: repo)
        try "fresh\n".write(to: repo.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)

        let diff = try await GitService().diff(worktreePath: repo, againstRef: "start", file: "new.txt")
        let added = diff.hunks.flatMap(\.lines).filter { $0.kind == .add }
        #expect(added.map(\.text) == ["fresh"])
    }

    /// `diff(worktreePath:againstRef:file:)` used to check `git cat-file -e
    /// <ref>:<file>` using the file's CURRENT (post-rename) path, which does
    /// not exist at `ref` (it existed under its OLD name) — so a renamed
    /// file rendered as an entirely new file (every line an addition)
    /// instead of a rename-aware diff of just the actual edit.
    @Test func diffAgainstRef_showsOnlyTheChangedLineForARenamedAndEditedFile() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "line1\nline2\nline3\nline4\nline5\n".write(
            to: repo.appendingPathComponent("old.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "old.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "base"], cwd: repo)
        _ = try await Process.git(["branch", "start"], cwd: repo)

        _ = try await Process.git(["mv", "old.txt", "new.txt"], cwd: repo)
        try "line1\nline2\nline3-changed\nline4\nline5\n".write(
            to: repo.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "-A"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "rename and edit"], cwd: repo)

        let diff = try await GitService().diff(worktreePath: repo, againstRef: "start", file: "new.txt")
        let addedLines = diff.hunks.flatMap(\.lines).filter { $0.kind == .add }.map(\.text)
        let deletedLines = diff.hunks.flatMap(\.lines).filter { $0.kind == .delete }.map(\.text)
        #expect(addedLines == ["line3-changed"])
        #expect(deletedLines == ["line3"])
    }

    /// `renameSource` used to only recognize an `"R"` name-status prefix, so
    /// a file git classifies as a COPY (`"C<score>"`, distinct from a rename
    /// because the source path still exists) fell through to being diffed
    /// as brand new — every line shown as an addition instead of a diff
    /// against the copy source. With `-C` (not `-C -C`), git only considers
    /// a path a copy SOURCE when that source is itself modified in the same
    /// diff — verified empirically before writing this test — so the
    /// original file is edited alongside the copy to reliably reproduce a
    /// `"C"` status rather than `"R"`.
    @Test func diffAgainstRef_showsOnlyTheChangedLineForACopiedAndEditedFile() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "line1\nline2\nline3\nline4\nline5\n".write(
            to: repo.appendingPathComponent("old.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "old.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "base"], cwd: repo)
        _ = try await Process.git(["branch", "start"], cwd: repo)

        try FileManager.default.copyItem(
            at: repo.appendingPathComponent("old.txt"), to: repo.appendingPathComponent("new.txt"))
        try "line1\nline2\nline3-changed\nline4\nline5\n".write(
            to: repo.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        // The original must also change in the SAME diff, or git's `-C`
        // (without a second `-C`) won't consider it eligible as a copy
        // source at all and `new.txt` would show up as a plain add instead.
        try "line1\nline2\nline3\nline4\nline5\nline6\n".write(
            to: repo.appendingPathComponent("old.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "old.txt", "new.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "copy and edit"], cwd: repo)

        // Confirm the premise: git reports this as a copy (`C`), not a
        // rename (`R`), before asserting on the diff that depends on it.
        let nameStatus = try await Process.git(
            ["-c", "core.quotePath=false", "diff", "--name-status", "-z", "-M", "-C", "start"], cwd: repo)
        let parsed = GitService.parseNameStatusZOutput(nameStatus.stdout)
        #expect(parsed.status["new.txt"] == "C")
        #expect(parsed.original["new.txt"] == "old.txt")

        let diff = try await GitService().diff(worktreePath: repo, againstRef: "start", file: "new.txt")
        let addedLines = diff.hunks.flatMap(\.lines).filter { $0.kind == .add }.map(\.text)
        let deletedLines = diff.hunks.flatMap(\.lines).filter { $0.kind == .delete }.map(\.text)
        #expect(addedLines == ["line3-changed"])
        #expect(deletedLines == ["line3"])
    }

    /// Under git's default `core.quotePath=true`, a non-ASCII filename is
    /// emitted quoted and octal-escaped (e.g. `café.txt` →
    /// `"caf\303\251.txt"`). Without `-c core.quotePath=false` (and `-z` to
    /// make the escaping avoidable in the first place), the client would be
    /// handed that literal escaped string as the path, which doesn't name
    /// any real file.
    @Test func changedFilesAgainstRef_reportsTheExactNonASCIIFilename() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let filename = "café.txt"
        try "one\n".write(to: repo.appendingPathComponent(filename), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", filename], cwd: repo)
        _ = try await Process.git(["commit", "-m", "add"], cwd: repo)
        _ = try await Process.git(["branch", "start"], cwd: repo)

        try "one\ntwo\n".write(to: repo.appendingPathComponent(filename), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", filename], cwd: repo)
        _ = try await Process.git(["commit", "-m", "edit"], cwd: repo)

        let files = try await GitService().changedFilesAgainstRef(worktreePath: repo, ref: "start")
        #expect(files.map(\.path) == [filename])

        let diff = try await GitService().diff(worktreePath: repo, againstRef: "start", file: filename)
        let added = diff.hunks.flatMap(\.lines).filter { $0.kind == .add }
        #expect(added.map(\.text) == ["two"])
    }

    @Test func changedFilesAgainstRef_handlesRename() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "content\n".write(to: repo.appendingPathComponent("old.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "old.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "add file"], cwd: repo)
        _ = try await Process.git(["branch", "start"], cwd: repo)

        _ = try await Process.git(["mv", "old.txt", "new.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "rename"], cwd: repo)

        let files = try await GitService().changedFilesAgainstRef(worktreePath: repo, ref: "start")
        #expect(files.map(\.path) == ["new.txt"])
        let renamed = try #require(files.first { $0.path == "new.txt" })
        #expect(renamed.status == "R")
        #expect(renamed.renameFrom == "old.txt")
    }

    @Test func diffAgainstRef_fallsBackToWorkingTreeWhenRefIsNil() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "one\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "a.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "base"], cwd: repo)

        try "one\ntwo\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let diff = try await GitService().diff(worktreePath: repo, againstRef: nil, file: "a.txt")
        let added = diff.hunks.flatMap(\.lines).filter { $0.kind == .add }
        #expect(added.map(\.text) == ["two"])
    }

    /// `diff(worktreePath:againstRef: nil, file:)` used to fall back to
    /// `diff(worktreePath:file:)`'s default (unstaged, working-tree-vs-INDEX)
    /// view, which by definition shows nothing for a change that IS staged
    /// (the index already matches the working tree). Meanwhile
    /// `changedFilesAgainstRef`'s own nil-ref fallback (`status`) DOES
    /// surface staged files, so the file appeared in the change list but
    /// opened to an empty diff. `diffAgainstHEAD` compares the working tree
    /// against HEAD, which reflects the staged content as changed.
    @Test func diffAgainstRef_showsAStagedOnlyChangeWhenRefIsNil() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "one\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "a.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "base"], cwd: repo)

        try "one\ntwo\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "a.txt"], cwd: repo)

        let diff = try await GitService().diff(worktreePath: repo, againstRef: nil, file: "a.txt")
        let added = diff.hunks.flatMap(\.lines).filter { $0.kind == .add }
        #expect(added.map(\.text) == ["two"])
    }

    @Test func diffAgainstRef_handlesDeletedFile() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "content\nline two\n".write(to: repo.appendingPathComponent("deleted.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "deleted.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "add file"], cwd: repo)
        _ = try await Process.git(["branch", "start"], cwd: repo)

        _ = try await Process.git(["rm", "deleted.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "delete"], cwd: repo)

        let diff = try await GitService().diff(worktreePath: repo, againstRef: "start", file: "deleted.txt")
        let deleted = diff.hunks.flatMap(\.lines).filter { $0.kind == .delete }
        #expect(!deleted.isEmpty)
        #expect(deleted.map(\.text).contains("content"))
        #expect(deleted.map(\.text).contains("line two"))
    }

    @Test func isPathIgnored_reportsTrueForAGitignoredPath() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "secret.env\n".write(to: repo.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try "TOKEN=abc\n".write(to: repo.appendingPathComponent("secret.env"), atomically: true, encoding: .utf8)

        let ignored = try await GitService().isPathIgnored(worktreePath: repo, path: "secret.env")
        #expect(ignored)
    }

    @Test func isPathIgnored_reportsFalseForATrackedPath() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "one\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "a.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "base"], cwd: repo)

        let ignored = try await GitService().isPathIgnored(worktreePath: repo, path: "a.txt")
        #expect(!ignored)
    }

    @Test func looksBinaryAtRef_sniffsTheBlobWhenTheWorkingTreeFileIsGone() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try Data([0x42, 0x00, 0x43]).write(to: repo.appendingPathComponent("image.bin"))
        _ = try await Process.git(["add", "image.bin"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "add binary"], cwd: repo)
        _ = try await Process.git(["branch", "start"], cwd: repo)

        _ = try await Process.git(["rm", "image.bin"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "remove binary"], cwd: repo)

        let result = try await GitService().looksBinaryAtRef(worktreePath: repo, ref: "start", file: "image.bin")
        #expect(result == true)
    }

    @Test func looksBinaryAtRef_returnsFalseForATextBlob() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "plain text\n".write(to: repo.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "notes.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "add notes"], cwd: repo)
        _ = try await Process.git(["branch", "start"], cwd: repo)

        _ = try await Process.git(["rm", "notes.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "remove notes"], cwd: repo)

        let result = try await GitService().looksBinaryAtRef(worktreePath: repo, ref: "start", file: "notes.txt")
        #expect(result == false)
    }

    @Test func looksBinaryAtRef_returnsNilWhenTheFileDoesNotExistAtTheRef() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        _ = try await Process.git(["commit", "--allow-empty", "-m", "init"], cwd: repo)
        _ = try await Process.git(["branch", "start"], cwd: repo)

        let result = try await GitService().looksBinaryAtRef(worktreePath: repo, ref: "start", file: "missing.bin")
        #expect(result == nil)
    }

    /// Regression coverage for bounding `looksBinaryAtRef`'s blob read: a
    /// several-hundred-KB deleted binary file must still be correctly
    /// detected as binary from just its first 8 KB, not by buffering the
    /// entire historical blob.
    @Test func looksBinaryAtRef_sniffsALargeBlobWithoutReadingItWhole() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        // A NUL byte up front plus a few hundred KB of filler — large enough
        // that reading the whole blob (rather than an 8 KB prefix) would be
        // wasteful, per the finding this test guards against.
        var bytes = Data([0x00])
        bytes.append(Data(repeating: 0x41, count: 400 * 1024))
        try bytes.write(to: repo.appendingPathComponent("large.bin"))
        _ = try await Process.git(["add", "large.bin"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "add large binary"], cwd: repo)
        _ = try await Process.git(["branch", "start"], cwd: repo)

        _ = try await Process.git(["rm", "large.bin"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "remove large binary"], cwd: repo)

        let result = try await GitService().looksBinaryAtRef(worktreePath: repo, ref: "start", file: "large.bin")
        #expect(result == true)
    }

    @Test func isPathIgnored_reportsFalseForAForceAddedTrackedFileMatchingAGitignorePattern() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "forced.log\n".write(to: repo.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try "keep me\n".write(to: repo.appendingPathComponent("forced.log"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "-f", "forced.log"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "force add ignored file"], cwd: repo)

        let ignored = try await GitService().isPathIgnored(worktreePath: repo, path: "forced.log")
        #expect(!ignored)
    }

    // MARK: - fileTreeChildren (remote branch) ignored-directory-with-tracked-descendant

    /// `fileTreeChildren`'s remote branch discovers directory entries by
    /// listing the actual remote filesystem (not just `git ls-files`), so it
    /// can encounter a directory like `.vscode` that matches `.gitignore`
    /// but contains a force-added, tracked file such as
    /// `.vscode/settings.json`. Classifying `.vscode` itself as `.ignored`
    /// would make `AppState.remoteFileNodes` drop it from its parent's flat
    /// listing entirely — since the wire protocol's `RemoteFileNode` has no
    /// `children` and fetches each directory lazily, the client would never
    /// be able to expand into `.vscode` to reach `settings.json`, even
    /// though that file is genuinely tracked and reachable via
    /// `remoteFileContents`/`remoteFileDiff` if the client already knew its
    /// path. This exercises the extracted decision helper directly, since
    /// driving the remote branch of `fileTreeChildren` end-to-end requires a
    /// real SSH-reachable host (`RemoteFileStats.directoryEntries`), which
    /// isn't available in this test environment — see
    /// `RemoteAppStateAccessTests.readRemoteWorktreeFileRawDoesNotFallBackToLocalDiskWhenTheHostIsUnreachable`
    /// for the same constraint acknowledged elsewhere.
    @Test func shouldClassifyRemotelyDiscoveredEntry_skipsADirectoryWithATrackedDescendant() {
        let gitVisiblePaths: Set<String> = [".vscode/settings.json"]

        let result = GitService().shouldClassifyRemotelyDiscoveredEntry(
            fullPath: ".vscode",
            isDirectory: true,
            gitVisiblePaths: gitVisiblePaths
        )

        #expect(!result)
    }

    @Test func shouldClassifyRemotelyDiscoveredEntry_classifiesADirectoryWithNoTrackedDescendant() {
        let gitVisiblePaths: Set<String> = ["src/main.swift"]

        let result = GitService().shouldClassifyRemotelyDiscoveredEntry(
            fullPath: "node_modules",
            isDirectory: true,
            gitVisiblePaths: gitVisiblePaths
        )

        #expect(result)
    }

    @Test func shouldClassifyRemotelyDiscoveredEntry_alwaysClassifiesFiles() {
        let gitVisiblePaths: Set<String> = []

        let result = GitService().shouldClassifyRemotelyDiscoveredEntry(
            fullPath: ".env",
            isDirectory: false,
            gitVisiblePaths: gitVisiblePaths
        )

        #expect(result)
    }

    @Test func shouldClassifyRemotelyDiscoveredEntry_skipsOnlyForADirectDescendantNotAPrefixCollision() {
        // ".vscode-extra/tracked.txt" is NOT a descendant of ".vscode" (no
        // "/" boundary), so this must not false-positive via a naive
        // `hasPrefix(root)` check on the un-slashed root.
        let gitVisiblePaths: Set<String> = [".vscode-extra/tracked.txt"]

        let result = GitService().shouldClassifyRemotelyDiscoveredEntry(
            fullPath: ".vscode",
            isDirectory: true,
            gitVisiblePaths: gitVisiblePaths
        )

        #expect(result)
    }

    // MARK: - diffAgainstHEAD on an unborn branch

    private func makeUnbornRepo() async throws -> URL {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-unborn-diff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: repo)
        _ = try await Process.git(["config", "user.email", "test@example.com"], cwd: repo)
        _ = try await Process.git(["config", "user.name", "Test User"], cwd: repo)
        return repo
    }

    /// Baseline/regression coverage for the LOCAL branch of `diffAgainstHEAD`'s
    /// unborn-HEAD existence check — must be unaffected by making the check
    /// remote-aware.
    @Test func diffAgainstHEADOnAnUnbornLocalBranchShowsAnExistingFileAsAllAdd() async throws {
        let repo = try await makeUnbornRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "fresh\n".write(to: repo.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)

        let diff = try await GitService().diffAgainstHEAD(worktreePath: repo, file: "new.txt")
        let added = diff.hunks.flatMap(\.lines).filter { $0.kind == .add }
        #expect(added.map(\.text) == ["fresh"])
    }

    @Test func diffAgainstHEADOnAnUnbornLocalBranchReturnsEmptyHunksForAMissingFile() async throws {
        let repo = try await makeUnbornRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        let diff = try await GitService().diffAgainstHEAD(worktreePath: repo, file: "missing.txt")
        #expect(diff.hunks.isEmpty)
    }

    /// `diffAgainstHEAD`'s unborn-HEAD existence check used to be
    /// `FileManager.default.fileExists`, a purely LOCAL filesystem check
    /// that is meaningless for an SSH-backed worktree — nothing exists
    /// locally at that path, so it always reported the file as missing and
    /// silently returned an empty diff for every staged/untracked file on a
    /// remote unborn branch. There is no reachable SSH host in this
    /// environment, so this can't drive a real end-to-end remote diff:
    /// `Process.git` itself also routes every git invocation for a
    /// `RemoteHostRegistry`-registered worktree over the same (unreachable)
    /// host, so the final diff still comes back empty here regardless —
    /// but for a different reason (a failed SSH connection), not because
    /// the existence check took a local-disk shortcut. What this test
    /// proves empirically is the structural negative that matters: handing
    /// `diffAgainstHEAD` a worktree registered as remote does not crash or
    /// hang (the `nonexistent-host.invalid` TLD fails DNS resolution fast
    /// rather than hanging on a connection timeout). That the existence
    /// check itself now calls `RemoteFileAccess.existence(host:path:)`
    /// instead of `FileManager.default.fileExists` when
    /// `worktreePath.isRemoteAlasPath` is true is verified by reading
    /// `diffAgainstHEAD`'s source, not by this test.
    @Test func diffAgainstHEADOnAnUnbornRemoteBranchDoesNotCrashOrHangOnAnUnreachableHost() async throws {
        let repo = try await makeUnbornRepo()
        defer {
            RemoteHostRegistry.shared.unregister(root: repo.path)
            try? FileManager.default.removeItem(at: repo)
        }
        try "fresh\n".write(to: repo.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        RemoteHostRegistry.shared.register(root: repo.path, host: "nonexistent-host.invalid")

        let diff = try await GitService().diffAgainstHEAD(worktreePath: repo, file: "new.txt")
        #expect(diff.hunks.isEmpty)
    }

    // MARK: - parseNumstatZOutput / parseNameStatusZOutput

    @Test func parseNumstatZOutput_parsesOrdinaryRecords() {
        let stream = "3\t1\tfile1.txt\00\t5\tcafé.txt\0"
        let (add, del) = GitService.parseNumstatZOutput(stream)
        #expect(add == ["file1.txt": 3, "café.txt": 0])
        #expect(del == ["file1.txt": 1, "café.txt": 5])
    }

    @Test func parseNumstatZOutput_parsesRenameRecords() {
        // "<add>\t<del>\t\0<oldPath>\0<newPath>\0"
        let stream = "2\t0\t\0old.txt\0new.txt\0"
        let (add, del) = GitService.parseNumstatZOutput(stream)
        #expect(add == ["new.txt": 2])
        #expect(del == ["new.txt": 0])
    }

    @Test func parseNameStatusZOutput_parsesOrdinaryRecords() {
        let stream = "M\0file1.txt\0A\0café.txt\0"
        let parsed = GitService.parseNameStatusZOutput(stream)
        #expect(parsed.ordered == ["file1.txt", "café.txt"])
        #expect(parsed.status == ["file1.txt": "M", "café.txt": "A"])
        #expect(parsed.original.isEmpty)
    }

    @Test func parseNameStatusZOutput_parsesRenameAndCopyRecords() {
        let stream = "R100\0old.txt\0new.txt\0C75\0base.txt\0copy.txt\0"
        let parsed = GitService.parseNameStatusZOutput(stream)
        #expect(parsed.ordered == ["new.txt", "copy.txt"])
        #expect(parsed.status == ["new.txt": "R", "copy.txt": "C"])
        #expect(parsed.original == ["new.txt": "old.txt", "copy.txt": "base.txt"])
    }
}
