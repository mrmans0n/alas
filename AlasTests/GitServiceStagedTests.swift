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
}
