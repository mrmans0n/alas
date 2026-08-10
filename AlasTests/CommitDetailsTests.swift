import Testing
import Foundation
@testable import Alas

@Suite(.serialized)
struct CommitDetailsTests {
    private func makeRepo() async throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-cd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: tmp)
        _ = try await Process.git(["config", "user.email", "test@example.com"], cwd: tmp)
        _ = try await Process.git(["config", "user.name", "test user"], cwd: tmp)
        return tmp
    }

    private func currentSha(in repo: URL) async throws -> String {
        let r = try await Process.git(["rev-parse", "HEAD"], cwd: repo)
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test func parsesNormalCommitWithBody() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "hello\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "."], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "feat: greet", "-m", "Adds a greeting file."], cwd: repo)
        let sha = try await currentSha(in: repo)

        let details = try await GitService().commitDetails(at: repo, sha: sha)
        #expect(details.info.sha == sha)
        #expect(details.info.subject == "greet")
        #expect(details.info.conventionalTag == "feat")
        #expect(details.body == "Adds a greeting file.")
        #expect(details.authorEmail == "test@example.com")
        #expect(details.parents.isEmpty)        // initial commit
        #expect(details.files.count == 1)
        #expect(details.files[0].path == "a.txt")
        #expect(details.files[0].status == "A")
        #expect(details.files[0].add == 1)
        #expect(details.files[0].del == 0)
    }

    @Test func parsesCommitWithMultipleFilesAndDeletion() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "x\n".write(to: repo.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
        try "y\n".write(to: repo.appendingPathComponent("gone.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "."], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "seed"], cwd: repo)

        try "xx\nxx\n".write(to: repo.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: repo.appendingPathComponent("gone.txt"))
        try "n\n".write(to: repo.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "-A"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "change"], cwd: repo)
        let sha = try await currentSha(in: repo)

        let details = try await GitService().commitDetails(at: repo, sha: sha)
        #expect(details.parents.count == 1)
        #expect(details.body == "")
        let byPath = Dictionary(uniqueKeysWithValues: details.files.map { ($0.path, $0) })
        #expect(byPath["keep.txt"]?.status == "M")
        #expect(byPath["gone.txt"]?.status == "D")
        #expect(byPath["new.txt"]?.status == "A")
        #expect(byPath["new.txt"]?.add == 1)
        #expect(byPath["new.txt"]?.del == 0)
    }

    @Test func diffOfCommitReturnsHunks() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "one\ntwo\nthree\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "."], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "seed"], cwd: repo)
        try "one\nTWO\nthree\nfour\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["commit", "-q", "-am", "edit"], cwd: repo)
        let sha = try await currentSha(in: repo)

        let diff = try await GitService().diff(worktreePath: repo, sha: sha, file: "a.txt")
        #expect(!diff.hunks.isEmpty)
        let kinds = diff.hunks.flatMap { $0.lines.map(\.kind) }
        #expect(kinds.contains(.add))
        #expect(kinds.contains(.delete))
    }

    @Test func diffOfInitialCommitReturnsAllAdditions() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "first\nsecond\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "."], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "init"], cwd: repo)
        let sha = try await currentSha(in: repo)

        let diff = try await GitService().diff(worktreePath: repo, sha: sha, file: "a.txt")
        #expect(!diff.hunks.isEmpty)
        let kinds = diff.hunks.flatMap { $0.lines.map(\.kind) }
        #expect(kinds.allSatisfy { $0 == .add })
    }

    @Test func parsesMergeCommitWithTwoParents() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "base\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "."], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "base"], cwd: repo)

        _ = try await Process.git(["checkout", "-q", "-b", "side"], cwd: repo)
        try "side\n".write(to: repo.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "."], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "side change"], cwd: repo)

        _ = try await Process.git(["checkout", "-q", "main"], cwd: repo)
        try "main\n".write(to: repo.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "."], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "main change"], cwd: repo)

        _ = try await Process.git(["merge", "--no-ff", "-q", "-m", "merge: side into main", "side"], cwd: repo)
        let sha = try await currentSha(in: repo)

        let details = try await GitService().commitDetails(at: repo, sha: sha)
        #expect(details.parents.count == 2)
        #expect(details.parents.allSatisfy { $0.count == 40 })
        // First-parent diff: merging `side` into `main` brings b.txt from side.
        let paths = details.files.map(\.path).sorted()
        #expect(paths == ["b.txt"])
        let b = details.files.first { $0.path == "b.txt" }
        #expect(b?.status == "A")
        #expect(b?.add == 1)
    }

    @Test func parsesCommitWithRenameAndBinary() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        // Seed with a text file and a binary file.
        // Use enough lines so that changing just one still meets git's rename
        // similarity threshold (default 50%; 9/10 lines unchanged = 90%).
        let seedContent = (1 ... 10).map { "line\($0)" }.joined(separator: "\n") + "\n"
        try seedContent.write(to: repo.appendingPathComponent("old.txt"), atomically: true, encoding: .utf8)
        // 16 bytes of binary data — first byte 0 makes git classify it as binary.
        let binaryData = Data([0x00, 0xFF, 0x10, 0x80, 0x42, 0xAA, 0x33, 0x77,
                               0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
        try binaryData.write(to: repo.appendingPathComponent("blob.bin"))
        _ = try await Process.git(["add", "."], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "seed"], cwd: repo)

        // Rename the text file (git only treats it as a rename in `diff -M`
        // / `log --follow`; for diff-tree with no rename detection, it shows
        // as add+delete. Pass `-M` to diff-tree by using a single
        // configured rename detection — git defaults to detecting renames
        // when running `git mv`.) Use `git mv` to make the rename explicit.
        _ = try await Process.git(["mv", "old.txt", "new.txt"], cwd: repo)
        // Modify one line so numstat reports non-zero adds/dels while keeping
        // similarity high enough for rename detection (9/10 lines unchanged).
        let modifiedContent = (1 ... 9).map { "line\($0)" }.joined(separator: "\n") + "\nMODIFIED\n"
        try modifiedContent.write(to: repo.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        // Modify the binary file slightly so it shows up as a change.
        let binaryData2 = Data([0x00, 0xFF, 0x10, 0x80, 0x99, 0xAA, 0x33, 0x77,
                                0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
        try binaryData2.write(to: repo.appendingPathComponent("blob.bin"))
        _ = try await Process.git(["add", "-A"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "rename + binary"], cwd: repo)
        let sha = try await currentSha(in: repo)

        let details = try await GitService().commitDetails(at: repo, sha: sha)

        // Binary file: numstat emits "-" for both add and del → both 0 in
        // the stored CommitChangedFile.
        let binary = details.files.first { $0.path == "blob.bin" }
        #expect(binary != nil)
        #expect(binary?.status == "M")
        #expect(binary?.add == 0)
        #expect(binary?.del == 0)

        // Rename: -M enables rename detection so git diff-tree reports a single
        // R entry for new.txt. The old path must NOT appear as a separate D entry.
        let renamed = details.files.first { $0.path == "new.txt" }
        #expect(renamed?.status == "R")
        #expect(renamed?.originalPath == "old.txt")
        #expect((renamed?.add ?? 0) > 0)
        #expect((renamed?.del ?? 0) > 0)
        // The old path should NOT appear as a separate D entry once rename detection fires.
        #expect(!details.files.contains { $0.path == "old.txt" })
    }

    @Test func diffOfRenamedFileShowsRenameNotFullRewrite() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        // Use enough lines so that changing one still meets git's rename similarity threshold.
        let seedContent = (1 ... 10).map { "line\($0)" }.joined(separator: "\n") + "\n"
        try seedContent.write(to: repo.appendingPathComponent("old.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "."], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "seed"], cwd: repo)
        _ = try await Process.git(["mv", "old.txt", "new.txt"], cwd: repo)
        // Tweak one line so the rename has a small content change.
        let modifiedContent = (1 ... 9).map { "line\($0)" }.joined(separator: "\n") + "\nMODIFIED\n"
        try modifiedContent.write(to: repo.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "-A"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "rename + edit"], cwd: repo)
        let sha = try await currentSha(in: repo)

        let svc = GitService()
        // Passing originalPath = "old.txt" lets git produce a proper rename diff.
        let diff = try await svc.diff(worktreePath: repo, sha: sha, file: "new.txt", originalPath: "old.txt")
        let kinds = diff.hunks.flatMap { $0.lines.map(\.kind) }
        // A proper rename diff has at MOST one add and one delete (the modified
        // line) plus context lines. A naive new-file-addition would have 3 adds
        // and 0 deletes — assert we're in the rename regime.
        let addCount = kinds.filter { $0 == .add }.count
        let delCount = kinds.filter { $0 == .delete }.count
        #expect(addCount < 3)   // would be 3 if rendered as full new-file
        #expect(addCount >= 1)
        #expect(delCount >= 1)
    }

    @Test func diffOfCopiedFileExcludesSourceHunks() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        // Seed with a 10-line file so git's copy detection has enough
        // similarity to consider the duplicate a copy.
        try (1...10).map { "line \($0)\n" }.joined()
            .write(to: repo.appendingPathComponent("old.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "."], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "seed"], cwd: repo)
        // Copy old.txt to new.txt AND modify old.txt — exactly the
        // scenario where passing both paths without slicing would pull
        // in old.txt's M hunks under new.txt's header.
        try (1...10).map { "line \($0)\n" }.joined()
            .write(to: repo.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        try (1...10).map { i in i == 5 ? "MODIFIED\n" : "line \(i)\n" }.joined()
            .write(to: repo.appendingPathComponent("old.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "-A"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "copy + edit"], cwd: repo)
        let sha = try await currentSha(in: repo)

        let svc = GitService()
        // Diff for new.txt with originalPath = old.txt. The slice should
        // strip old.txt's M hunks. A pure copy with no further edits has
        // zero hunks; if our slice kept old.txt's section, we'd see the
        // MODIFIED <- line 5 swap.
        let diff = try await svc.diff(worktreePath: repo, sha: sha, file: "new.txt", originalPath: "old.txt")
        let texts = diff.hunks.flatMap { $0.lines }.map(\.text)
        #expect(!texts.contains("MODIFIED"))
        #expect(!texts.contains("line 5"))
    }

    @Test func sliceDiffForFileKeepsOnlyMatchingSection() {
        let raw = """
        diff --git a/old.txt b/new.txt
        similarity index 100%
        copy from old.txt
        copy to new.txt
        diff --git a/old.txt b/old.txt
        index abc..def 100644
        --- a/old.txt
        +++ b/old.txt
        @@ -1,3 +1,3 @@
         line 1
        -line 2
        +MODIFIED
         line 3
        """
        let kept = GitService.sliceDiffForFile(raw, file: "new.txt")
        #expect(kept.contains("copy from old.txt"))
        #expect(!kept.contains("MODIFIED"))
        #expect(!kept.contains("@@ -1,3 +1,3 @@"))
    }

    @Test func diffOfMergeCommitFollowsFirstParent() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "base\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "."], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "base"], cwd: repo)

        _ = try await Process.git(["checkout", "-q", "-b", "side"], cwd: repo)
        try "side\n".write(to: repo.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "."], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "side"], cwd: repo)

        _ = try await Process.git(["checkout", "-q", "main"], cwd: repo)
        try "main\n".write(to: repo.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "."], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "main"], cwd: repo)

        _ = try await Process.git(["merge", "--no-ff", "-q", "-m", "merge", "side"], cwd: repo)
        let sha = try await currentSha(in: repo)

        // First-parent diff brings b.txt in from `side` (the second parent).
        // c.txt was the last commit on main (the first parent) and is NOT in this diff.
        let diff = try await GitService().diff(worktreePath: repo, sha: sha, file: "b.txt")
        let kinds = diff.hunks.flatMap { $0.lines.map(\.kind) }
        #expect(!diff.hunks.isEmpty)
        #expect(kinds.allSatisfy { $0 == .add })   // b.txt is new from this side, all additions

        // Sanity: c.txt is unchanged in the merge (it's already in the first parent),
        // so the diff for it should be empty.
        let cDiff = try await GitService().diff(worktreePath: repo, sha: sha, file: "c.txt")
        #expect(cDiff.hunks.isEmpty)
    }
}
