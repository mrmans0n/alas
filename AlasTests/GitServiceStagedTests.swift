import Testing
import Foundation
@testable import Alas

@Suite(.serialized)
@MainActor
struct GitServiceStagedTests {
    private func makeRepo() async throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-staged-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: tmp)
        _ = try await Process.git(["config", "user.email", "test@example.com"], cwd: tmp)
        _ = try await Process.git(["config", "user.name", "test user"], cwd: tmp)
        return tmp
    }

    @Test func stagedChangedFiles_listsAddedAndModifiedFiles() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        _ = try await Process.git(["commit", "--allow-empty", "-m", "init"], cwd: repo)
        try "hello\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "world\n".write(to: repo.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "a.txt", "b.txt"], cwd: repo)

        let files = try await GitService().stagedChangedFiles(at: repo)
        #expect(files.map(\.path).sorted() == ["a.txt", "b.txt"])
        #expect(files.allSatisfy { $0.status == "A" })
    }

    @Test func stagedChangedFiles_emptyWhenNothingStaged() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        _ = try await Process.git(["commit", "--allow-empty", "-m", "init"], cwd: repo)

        let files = try await GitService().stagedChangedFiles(at: repo)
        #expect(files.isEmpty)
    }

    @Test func stagedChangedFiles_supportsUnbornHEAD() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "hi\n".write(to: repo.appendingPathComponent("first.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "first.txt"], cwd: repo)

        let files = try await GitService().stagedChangedFiles(at: repo)
        #expect(files.map(\.path) == ["first.txt"])
        #expect(files.first?.status == "A")
    }

    @Test func stagedChangedFiles_detectsModifiedAndDeleted() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "original\n".write(to: repo.appendingPathComponent("mod.txt"), atomically: true, encoding: .utf8)
        try "keep\n".write(to: repo.appendingPathComponent("del.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "."], cwd: repo)
        _ = try await Process.git(["commit", "-m", "seed"], cwd: repo)

        try "modified\n".write(to: repo.appendingPathComponent("mod.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: repo.appendingPathComponent("del.txt"))
        _ = try await Process.git(["add", "mod.txt", "del.txt"], cwd: repo)

        let files = try await GitService().stagedChangedFiles(at: repo)
        let byPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
        #expect(byPath["mod.txt"]?.status == "M")
        #expect(byPath["del.txt"]?.status == "D")
    }

    @Test func unstageHunk_removesOneHunkFromIndex() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        // Establish a baseline commit with a 10-line file so changes at top
        // and bottom produce two separate hunks.
        let baseline = """
            line1
            line2
            line3
            line4
            line5
            line6
            line7
            line8
            line9
            line10
            """
        _ = try await Process.git(["commit", "--allow-empty", "-m", "init"], cwd: repo)
        try baseline.write(to: repo.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "x.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "baseline"], cwd: repo)

        // Modify top and bottom lines so git produces two hunks.
        let modified = """
            TOP-CHANGED
            line2
            line3
            line4
            line5
            line6
            line7
            line8
            line9
            BOTTOM-CHANGED
            """
        try modified.write(to: repo.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "x.txt"], cwd: repo)

        // Confirm two staged hunks before unstaging.
        let before = try await GitService().diff(worktreePath: repo, file: "x.txt", staged: true)
        #expect(before.hunks.count == 2)
        let topHunk = before.hunks[0]

        // Unstage only the top hunk.
        try await GitService().unstageHunk(worktreePath: repo, path: "x.txt", hunk: topHunk)

        // Only the bottom hunk should remain staged.
        let after = try await GitService().diff(worktreePath: repo, file: "x.txt", staged: true)
        #expect(after.hunks.count == 1)
    }

    @Test func diff_includesOriginalPathForStagedRename() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        try "one\ntwo\nthree\n".write(to: repo.appendingPathComponent("old.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "old.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "seed"], cwd: repo)

        _ = try await Process.git(["mv", "old.txt", "new.txt"], cwd: repo)
        try "one\nTWO\nthree\n".write(to: repo.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "new.txt"], cwd: repo)

        let diff = try await GitService().diff(
            worktreePath: repo,
            file: "new.txt",
            staged: true,
            originalPath: "old.txt"
        )

        // Split into a typed intermediate and explicitly-typed closures —
        // the single-expression chain occasionally sends the type checker
        // into a multi-minute timeout under load (observed both locally
        // and in CI), failing the whole file with "unable to type-check
        // this expression in reasonable time".
        let lines: [ParsedDiff.Hunk.Line] = diff.hunks.flatMap(\.lines)
        let addCount: Int = lines.filter { (line: ParsedDiff.Hunk.Line) -> Bool in line.kind == .add }.count
        let deleteCount: Int = lines.filter { (line: ParsedDiff.Hunk.Line) -> Bool in line.kind == .delete }.count
        #expect(addCount == 1)
        #expect(deleteCount == 1)
    }

    /// Renames stage as `D <old>` + `A <new>` in the index. Unstaging both
    /// paths is required to fully clear the rename; passing only the new
    /// path leaves the deletion-of-old staged.
    @Test func unstage_fullyClearsStagedRename() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        try "hello\n".write(to: repo.appendingPathComponent("old.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "old.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "seed"], cwd: repo)

        // Stage a rename: old.txt -> new.txt.
        _ = try await Process.git(["mv", "old.txt", "new.txt"], cwd: repo)

        // Pre-condition: rename is staged (one or two entries depending on
        // detection; the important bit is the staged set is non-empty).
        let before = try await GitService().stagedChangedFiles(at: repo)
        #expect(!before.isEmpty)

        // Unstage both sides of the rename, mirroring DraftCommitTabView.
        try await GitService().unstage(worktreePath: repo, files: ["new.txt", "old.txt"])

        // Everything staged should be gone.
        let after = try await GitService().stagedChangedFiles(at: repo)
        #expect(after.isEmpty)
    }
}
