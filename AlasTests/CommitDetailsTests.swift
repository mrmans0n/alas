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
        try "first\nsecond\nthird\n".write(to: repo.appendingPathComponent("old.txt"), atomically: true, encoding: .utf8)
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
        // The old path should NOT appear as a separate D entry once rename detection fires.
        #expect(!details.files.contains { $0.path == "old.txt" })
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
