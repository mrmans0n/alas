import Testing
import Foundation
import Darwin
@testable import Alas

/// Races `operation` against a timeout so a regression that reintroduces a
/// blocking read (e.g. `Data(contentsOf:)` against a writerless FIFO) fails
/// the test loudly and promptly instead of hanging the whole suite.
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

    /// Unlike the nil-ref case above, a NON-nil ref that fails its numstat
    /// diff (an invalid ref, here) is not "no base to compare against" —
    /// falling back to `status()` would silently report only current
    /// index/worktree changes as the complete change list, hiding every
    /// committed change relative to the (bad) ref instead of surfacing the
    /// failure.
    @Test func changedFilesAgainstRef_throwsRatherThanFallingBackToStatusForAResolvedButInvalidRef() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "one\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "a.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "base"], cwd: repo)

        await #expect(throws: (any Error).self) {
            _ = try await GitService().changedFilesAgainstRef(worktreePath: repo, ref: "not-a-real-ref")
        }
    }

    /// `changedFileBadges` reports the same paths/statuses as
    /// `changedFilesAgainstRef` — just without ever populating add/del
    /// (proving the numstat call and per-untracked-file line counting were
    /// actually skipped, not merely unused by this particular fixture).
    @Test func changedFileBadges_includesCommittedAndUncommittedAndUntrackedWithoutMetrics() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "one\n".write(to: repo.appendingPathComponent("base.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "base.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "base"], cwd: repo)
        _ = try await Process.git(["branch", "start"], cwd: repo)

        try "one\ntwo\n".write(to: repo.appendingPathComponent("base.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "base.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "committed change"], cwd: repo)

        try "new\n".write(to: repo.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)

        let files = try await GitService().changedFileBadges(worktreePath: repo, ref: "start")
        #expect(files.map(\.path).sorted() == ["base.txt", "untracked.txt"])
        let base = try #require(files.first { $0.path == "base.txt" })
        #expect(base.status == "M")
        #expect(base.add == 0 && base.del == 0)
        let untracked = try #require(files.first { $0.path == "untracked.txt" })
        #expect(untracked.status == "A")
        #expect(untracked.add == 0 && untracked.del == 0)
    }

    @Test func changedFileBadges_fallsBackToStatusWhenRefIsNil() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        _ = try await Process.git(["commit", "--allow-empty", "-m", "init"], cwd: repo)
        try "hello\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let files = try await GitService().changedFileBadges(worktreePath: repo, ref: nil)
        #expect(files.map(\.path) == ["a.txt"])
    }

    /// Same "must propagate, not silently fall back" contract as
    /// `changedFilesAgainstRef_throwsRatherThanFallingBackToStatusForAResolvedButInvalidRef`.
    @Test func changedFileBadges_throwsRatherThanFallingBackToStatusForAResolvedButInvalidRef() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "one\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "a.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "base"], cwd: repo)

        await #expect(throws: (any Error).self) {
            _ = try await GitService().changedFileBadges(worktreePath: repo, ref: "not-a-real-ref")
        }
    }

    @Test func changedFileBadges_handlesRename() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "content\n".write(to: repo.appendingPathComponent("old.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "old.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "add file"], cwd: repo)
        _ = try await Process.git(["branch", "start"], cwd: repo)

        _ = try await Process.git(["mv", "old.txt", "new.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "rename"], cwd: repo)

        let files = try await GitService().changedFileBadges(worktreePath: repo, ref: "start")
        #expect(files.map(\.path) == ["new.txt"])
        let renamed = try #require(files.first { $0.path == "new.txt" })
        #expect(renamed.status == "R")
        #expect(renamed.renameFrom == "old.txt")
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
    /// The rename-diff branch of `diff(worktreePath:againstRef:file:)` used
    /// to omit `-c core.quotePath=false` from the actual diff-producing
    /// `Process.git` call (unlike `renameSource`'s own internal
    /// `--name-status` lookup, which already had it). Under the default
    /// quoting, a non-ASCII rename DESTINATION name comes back escaped in
    /// the `diff --git a/<old> b/<new>` header (e.g. `b/cr\303\250me.txt`),
    /// so `sliceDiffForFile`'s raw, unquoted `b/<file>` suffix match fails
    /// to find the section and the file opens with an empty diff.
    @Test func diffAgainstRef_showsChangesForARenamedFileWithANonASCIIDestinationName() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "line1\nline2\nline3\nline4\nline5\n".write(
            to: repo.appendingPathComponent("café.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "café.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "base"], cwd: repo)
        _ = try await Process.git(["branch", "start"], cwd: repo)

        _ = try await Process.git(["mv", "café.txt", "crème.txt"], cwd: repo)
        try "line1\nline2\nline3-changed\nline4\nline5\n".write(
            to: repo.appendingPathComponent("crème.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "-A"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "rename and edit"], cwd: repo)

        let diff = try await GitService().diff(worktreePath: repo, againstRef: "start", file: "crème.txt")
        let addedLines = diff.hunks.flatMap(\.lines).filter { $0.kind == .add }.map(\.text)
        let deletedLines = diff.hunks.flatMap(\.lines).filter { $0.kind == .delete }.map(\.text)
        #expect(addedLines == ["line3-changed"])
        #expect(deletedLines == ["line3"])
    }

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

    /// A bare `--` pathspec argument is interpreted as a glob pattern by
    /// default, and `[...]` is pathspec-magic for a character class — so
    /// `report[1].txt` as a pathspec actually matches the UNRELATED tracked
    /// file `report1.txt` (verified empirically: `git diff -- 'report[1].txt'`
    /// without `--literal-pathspecs` returns both files' diffs). Without
    /// `--literal-pathspecs`, requesting the diff for `report[1].txt` would
    /// leak `report1.txt`'s changes into the result.
    @Test func diffAgainstRef_treatsAFileNameContainingPathspecMagicAsLiteral() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "one\n".write(to: repo.appendingPathComponent("report1.txt"), atomically: true, encoding: .utf8)
        try "one\n".write(to: repo.appendingPathComponent("report[1].txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "-A"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "base"], cwd: repo)
        _ = try await Process.git(["branch", "start"], cwd: repo)

        try "one\ntwo\n".write(to: repo.appendingPathComponent("report1.txt"), atomically: true, encoding: .utf8)
        try "one\nthree\n".write(to: repo.appendingPathComponent("report[1].txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "-A"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "edit both"], cwd: repo)

        let diff = try await GitService().diff(worktreePath: repo, againstRef: "start", file: "report[1].txt")
        let added = diff.hunks.flatMap(\.lines).filter { $0.kind == .add }.map(\.text)
        #expect(added == ["three"])
        #expect(!added.contains("two"))
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

    /// The exact shape the finding described: `file` ("zzz.txt") is a copy
    /// of "aaa.txt", which sorts BEFORE it — so git emits aaa.txt's own
    /// section of the two-path diff FIRST. When that section alone exceeds
    /// the byte cap, the capped subprocess terminates before zzz.txt's
    /// section ever appears, and `sliceDiffForFile` finds nothing to return
    /// for it — indistinguishable from a genuinely empty diff unless this is
    /// treated as a failure instead.
    @Test func diffAgainstRef_throwsWhenACopySourceSectionAloneExceedsTheOutputCap() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let original = (1 ... 100).map { "line\($0)\n" }.joined()
        try original.write(to: repo.appendingPathComponent("aaa.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "aaa.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "base"], cwd: repo)
        _ = try await Process.git(["branch", "start"], cwd: repo)

        // Append enough new content to aaa.txt that its OWN diff section
        // (measured at ~611 bytes for this exact fixture) exceeds the
        // test's small cap below, while staying similar enough to its prior
        // version for git's default (no --find-copies-harder) copy
        // detection to still recognize zzz.txt as a copy of it — appending
        // materially more than 10 lines here drops the similarity score
        // below git's 50% threshold and the fixture stops producing a copy
        // at all, defeating the point of the test.
        let appended = original + (1 ... 10).map { "appended-line-\($0)-with-enough-padding-to-add-up\n" }.joined()
        try appended.write(to: repo.appendingPathComponent("aaa.txt"), atomically: true, encoding: .utf8)
        // zzz.txt: a copy of the now-appended aaa.txt, sorting AFTER it, with
        // one more line so it's a distinct file highly similar to its source.
        try (appended + "zzz-marker\n").write(to: repo.appendingPathComponent("zzz.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "-A"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "copy with modification"], cwd: repo)

        // Confirm the fixture actually produces the copy relationship this
        // test depends on before asserting anything about the cap.
        let files = try await GitService().changedFilesAgainstRef(worktreePath: repo, ref: "start")
        let copy = try #require(files.first { $0.path == "zzz.txt" })
        #expect(copy.status == "C")
        #expect(copy.renameFrom == "aaa.txt")

        await #expect(throws: (any Error).self) {
            _ = try await GitService().diff(
                worktreePath: repo, againstRef: "start", file: "zzz.txt", maxOutputBytes: 300)
        }
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

    /// A file tracked at `comparisonRef` but since deleted is no longer in
    /// the current index, so plain `check-ignore` (no `--no-index`) falls
    /// back to matching purely by name — reporting it "ignored" whenever a
    /// LATER-added `.gitignore` pattern happens to match its name, even
    /// though its legitimate deletion diff should still be servable.
    /// `comparisonRef` must exempt it the same way the force-added-tracked
    /// exemption above exempts a currently-indexed path.
    @Test func isPathIgnored_reportsFalseForAFileTrackedAtTheComparisonRefButSinceDeleted() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "keep me\n".write(to: repo.appendingPathComponent("was-tracked.log"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "was-tracked.log"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "add tracked file"], cwd: repo)
        _ = try await Process.git(["branch", "start"], cwd: repo)

        // Gitignore does not untrack an already-tracked file, so adding this
        // pattern now still leaves `was-tracked.log` tracked at HEAD.
        try "*.log\n".write(to: repo.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", ".gitignore"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "add gitignore pattern"], cwd: repo)

        _ = try await Process.git(["rm", "was-tracked.log"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "delete tracked file"], cwd: repo)

        // Without the ref exemption, this reports true (ignored-by-name):
        let ignoredWithoutRef = try await GitService().isPathIgnored(worktreePath: repo, path: "was-tracked.log")
        #expect(ignoredWithoutRef)

        let ignoredWithRef = try await GitService().isPathIgnored(
            worktreePath: repo, path: "was-tracked.log", comparisonRef: "start")
        #expect(!ignoredWithRef)
    }

    /// End-to-end confirmation via the actual diff entry point: requesting
    /// the diff for a deleted, ignore-pattern-matching file must show the
    /// deletion rather than throwing/being blocked.
    @Test func diffAgainstRef_showsADeletedFileEvenWhenItsNameMatchesALaterAddedGitignorePattern() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "keep me\n".write(to: repo.appendingPathComponent("was-tracked.log"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "was-tracked.log"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "add tracked file"], cwd: repo)
        _ = try await Process.git(["branch", "start"], cwd: repo)

        try "*.log\n".write(to: repo.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", ".gitignore"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "add gitignore pattern"], cwd: repo)
        _ = try await Process.git(["rm", "was-tracked.log"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "delete tracked file"], cwd: repo)

        let diff = try await GitService().diff(worktreePath: repo, againstRef: "start", file: "was-tracked.log")
        let deleted = diff.hunks.flatMap(\.lines).filter { $0.kind == .delete }
        #expect(deleted.map(\.text).contains("keep me"))
    }

    /// `cat-file -e` exits with the SAME code for a genuinely missing object
    /// AND for an invalid ref name — the exit code alone can't distinguish
    /// them (verified empirically: both are 128 on git 2.50). `diff` must
    /// not silently treat the invalid-ref case as "new/untracked file"; it
    /// must propagate the failure.
    @Test func diffAgainstRef_throwsRatherThanTreatingAnInvalidRefAsANewFile() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "one\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "a.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "base"], cwd: repo)

        await #expect(throws: (any Error).self) {
            _ = try await GitService().diff(worktreePath: repo, againstRef: "not-a-real-ref", file: "a.txt")
        }
    }

    /// The genuinely-missing-object case (a real ref, a path that doesn't
    /// exist there) must still take the untracked/new-file branch rather
    /// than throwing — this is the behavior `diffAgainstRef_showsUntrackedFileAsAllAdd`
    /// already covers for a NEVER-committed file; this covers the "valid
    /// ref, path absent at that ref" shape explicitly to guard the
    /// cat-file-exit-code fix above from over-rejecting the legitimate case.
    @Test func diffAgainstRef_stillShowsANewFileAsAllAddWhenItGenuinelyDidNotExistAtAValidRef() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        _ = try await Process.git(["commit", "--allow-empty", "-m", "init"], cwd: repo)
        _ = try await Process.git(["branch", "start"], cwd: repo)
        try "fresh\n".write(to: repo.appendingPathComponent("brand-new.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "brand-new.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "add new file"], cwd: repo)

        let diff = try await GitService().diff(worktreePath: repo, againstRef: "start", file: "brand-new.txt")
        let added = diff.hunks.flatMap(\.lines).filter { $0.kind == .add }
        #expect(added.map(\.text) == ["fresh"])
    }

    /// A file declared binary purely via `.gitattributes` (content that
    /// still looks like valid UTF-8 at the byte level) produces a
    /// hunk-less diff with `Binary files ... differ` instead of `@@` hunks
    /// — `ParsedDiff.isBinary` must pick that up so callers don't mistake
    /// it for a legitimately empty diff.
    @Test func diffAgainstRef_flagsAGitattributesDeclaredBinaryFileWithUTF8Content() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "*.dat binary\n".write(to: repo.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
        try "hello world this is text\n".write(to: repo.appendingPathComponent("f.dat"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", ".gitattributes", "f.dat"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "base"], cwd: repo)
        _ = try await Process.git(["branch", "start"], cwd: repo)
        try "hello world this is text CHANGED\n".write(to: repo.appendingPathComponent("f.dat"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "f.dat"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "change binary-declared file"], cwd: repo)

        let diff = try await GitService().diff(worktreePath: repo, againstRef: "start", file: "f.dat")
        #expect(diff.hunks.isEmpty)
        #expect(diff.isBinary)
    }

    /// An untracked file ending in exactly one trailing newline must report
    /// the same add-count whether or not a comparison ref happens to
    /// resolve — `status(worktreePath:)`'s own line counting used to
    /// disagree with `addedLineCount`'s (used by the ref-resolved path) by
    /// exactly one for this shape.
    @Test func changedFilesAgainstRef_reportsTheSameAddCountForAnUntrackedFileRegardlessOfRefResolution() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        _ = try await Process.git(["commit", "--allow-empty", "-m", "init"], cwd: repo)
        try "one\n".write(to: repo.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)

        let withNilRef = try await GitService().changedFilesAgainstRef(worktreePath: repo, ref: nil)
        let untrackedNilRef = try #require(withNilRef.first { $0.path == "untracked.txt" })
        #expect(untrackedNilRef.add == 1)

        _ = try await Process.git(["branch", "start"], cwd: repo)
        let withResolvedRef = try await GitService().changedFilesAgainstRef(worktreePath: repo, ref: "start")
        let untrackedResolvedRef = try #require(withResolvedRef.first { $0.path == "untracked.txt" })
        #expect(untrackedResolvedRef.add == 1)
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

    /// `status`'s no-HEAD numstat used to diff `--cached` (index vs empty
    /// tree), which only sees the STAGED snapshot. Staging a one-line file
    /// and then appending a second, unstaged line must still report both
    /// lines as added — matching `diffAgainstHEAD`'s own all-add diff
    /// (working tree vs `/dev/null`) above, which always shows the current
    /// on-disk content regardless of what's staged.
    @Test func changedFilesAgainstRef_countsPostStageEditsOnAnUnbornBranch() async throws {
        let repo = try await makeUnbornRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "line1\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "a.txt"], cwd: repo)
        try "line1\nline2\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let files = try await GitService().changedFilesAgainstRef(worktreePath: repo, ref: nil)
        // Exactly one row for "a.txt" — an "AM" file (staged, then further
        // edited) must not appear twice just because `status()` itself
        // tracks stage separately.
        #expect(files.filter { $0.path == "a.txt" }.count == 1)
        let entry = try #require(files.first { $0.path == "a.txt" })
        #expect(entry.add == 2)
        #expect(entry.status == "A")
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

    /// `changedFilesAgainstRef`'s nil-ref case (no resolvable base, e.g. an
    /// unborn branch) falls back to `status(worktreePath:)`. `status` used
    /// to swallow ANY nonzero `git status` exit into `[]` — a dropped SSH
    /// connection would then look identical to "nothing has changed"
    /// instead of surfacing as a failure. Registering a real, but
    /// unreachable, remote host forces every `git` subprocess for this
    /// worktree through a failing SSH invocation (`ssh` itself fails fast on
    /// the invalid TLD, no real network wait), which is exactly the shape of
    /// failure `status` must now propagate.
    @Test func changedFilesAgainstRef_propagatesAStatusFailureOnTheNilRefFallback() async throws {
        let repo = try await makeUnbornRepo()
        defer {
            RemoteHostRegistry.shared.unregister(root: repo.path)
            try? FileManager.default.removeItem(at: repo)
        }
        try "fresh\n".write(to: repo.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        RemoteHostRegistry.shared.register(root: repo.path, host: "nonexistent-host.invalid")

        await #expect(throws: (any Error).self) {
            _ = try await GitService().changedFilesAgainstRef(worktreePath: repo, ref: nil)
        }
    }

    /// A transport failure (disconnected helper, unreachable host) on the
    /// root Files-tree request used to parse as "zero files" — an empty,
    /// misleadingly "successful" repository — because `gitVisibleFilePaths`
    /// didn't check `ls-files`'s exit code. Registering a real, but
    /// unreachable, remote host forces exactly that shape of failure (`ssh`
    /// itself fails fast on the invalid TLD, no real network wait) and
    /// `fileTree` must now propagate it as a thrown error instead of
    /// returning an empty node list.
    @Test func fileTreePropagatesAGitVisibleFilePathsFailureInsteadOfReportingAnEmptyTree() async throws {
        let repo = try await makeRepo()
        defer {
            RemoteHostRegistry.shared.unregister(root: repo.path)
            try? FileManager.default.removeItem(at: repo)
        }
        try "one\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "a.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "base"], cwd: repo)
        RemoteHostRegistry.shared.register(root: repo.path, host: "nonexistent-host.invalid")

        await #expect(throws: (any Error).self) {
            _ = try await GitService().fileTree(worktreePath: repo, statusEntries: [])
        }
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

    // MARK: - collapsingStagedAndUnstagedEntries

    /// The merged row takes its IDENTITY (status/renameFrom/conflict) from
    /// the staged side — the unstaged sibling would misleadingly read "M"
    /// as if a base version existed (there is no HEAD on the unborn branch
    /// this collapsing exists for) — but its METRICS from the unstaged
    /// side, which `status()` now computes against the WHOLE working tree,
    /// matching what `remoteFileDiff` actually renders for the path. The
    /// staged side's own metrics are index-only (`status()`'s per-stage
    /// fix) and would undercount here if used for the merged row instead.
    @Test func collapsingStagedAndUnstagedEntries_mergesAStagedAndUnstagedPairKeepingStagedIdentityAndUnstagedMetrics() {
        let staged = ChangedFile(path: "a.txt", status: "A", stage: .staged, add: 1, del: 0, renameFrom: nil)
        let unstaged = ChangedFile(path: "a.txt", status: "M", stage: .unstaged, add: 2, del: 0, renameFrom: nil)
        let expected = ChangedFile(path: "a.txt", status: "A", stage: .staged, add: 2, del: 0, renameFrom: nil)
        #expect(GitService.collapsingStagedAndUnstagedEntries([staged, unstaged]) == [expected])
        // Order of the pair shouldn't matter.
        #expect(GitService.collapsingStagedAndUnstagedEntries([unstaged, staged]) == [expected])
    }

    @Test func collapsingStagedAndUnstagedEntries_leavesUnrelatedPathsAndSingleEntriesAlone() {
        let a = ChangedFile(path: "a.txt", status: "A", stage: .staged, add: 1, del: 0, renameFrom: nil)
        let b = ChangedFile(path: "b.txt", status: "M", stage: .unstaged, add: 1, del: 0, renameFrom: nil)
        #expect(GitService.collapsingStagedAndUnstagedEntries([a, b]) == [a, b])
    }

    // MARK: - addedLineCount

    /// `addedLineCount` runs synchronously on whatever actor called it —
    /// ultimately `changedFilesAgainstRef`, reachable from the `@MainActor`
    /// `remoteChangeList` (this test struct is itself `@MainActor`, matching
    /// that). A FIFO passes every check `Data(contentsOf:)` doesn't itself
    /// perform, so without an explicit regular-file guard, opening Changes
    /// on a worktree containing an untracked FIFO would block the READ
    /// indefinitely waiting for a writer that never arrives — freezing the
    /// whole app, not just this one request. `mkfifo` creates a real named
    /// pipe; nothing ever opens it for writing, so a regression would hang
    /// this test until the timeout — asserted against explicitly so it
    /// fails loudly rather than hanging the whole suite.
    @Test func addedLineCount_returnsPromptlyForAFIFOWithNoWriter() async throws {
        let root = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let fifo = root.appendingPathComponent("pipe")
        #expect(fifo.path.withCString { mkfifo($0, 0o600) } == 0)

        let outcome = await withTimeout(seconds: 5) {
            GitService.addedLineCount(worktreePath: root, path: "pipe")
        }
        let result = try #require(outcome, "addedLineCount hung on a writerless FIFO instead of returning promptly")
        #expect(result == 0)
    }

    /// Git's blob for a symlink IS the target path string, never the
    /// target's own file content. An untracked symlink to a real,
    /// multi-line file must therefore report a line count that matches the
    /// TARGET PATH STRING (always 1 for a normal path with no embedded
    /// newline) — not 0 (the old behavior once the target stopped looking
    /// like a "regular file" through the follow) and not the target
    /// file's own line count (a symlink to a huge file wrongly inflating
    /// this).
    @Test func addedLineCount_countsAnUntrackedSymlinkAsItsTargetPathStringNotTheTargetsContent() async throws {
        let root = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        try "one\ntwo\nthree\n".write(to: root.appendingPathComponent("target.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link.txt"),
            withDestinationURL: root.appendingPathComponent("target.txt"))

        let result = GitService.addedLineCount(worktreePath: root, path: "link.txt")
        #expect(result == 1)
    }

    /// A broken symlink (target doesn't exist) still has a real blob in
    /// git's object model — the link's target path string — so it must
    /// still report 1, not 0.
    @Test func addedLineCount_countsABrokenUntrackedSymlinkAsItsTargetPathString() async throws {
        let root = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("broken-link.txt"),
            withDestinationURL: root.appendingPathComponent("does-not-exist.txt"))

        let result = GitService.addedLineCount(worktreePath: root, path: "broken-link.txt")
        #expect(result == 1)
    }
}
