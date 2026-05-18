import Testing
import Foundation
@testable import Alas

@Suite(.serialized)
struct GitServiceDiscardTests {
    private func makeRepo() async throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-disc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: dir)
        _ = try await Process.git(["config", "user.email", "t@e"], cwd: dir)
        _ = try await Process.git(["config", "user.name", "t"], cwd: dir)
        return dir
    }

    private func writeFile(_ repo: URL, _ name: String, _ contents: String) throws {
        try contents.write(
            to: repo.appendingPathComponent(name),
            atomically: true,
            encoding: .utf8
        )
    }

    private func exists(_ repo: URL, _ name: String) -> Bool {
        FileManager.default.fileExists(atPath: repo.appendingPathComponent(name).path)
    }

    @Test func emptyFilesIsNoOp() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let svc = GitService()
        try await svc.discardPaths(worktreePath: repo, files: [])
    }

    @Test func discardsTrackedModifiedFile() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try writeFile(repo, "a.txt", "original\n")
        _ = try await Process.git(["add", "a.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "init"], cwd: repo)
        try writeFile(repo, "a.txt", "modified\n")

        let svc = GitService()
        try await svc.discardPaths(worktreePath: repo, files: ["a.txt"])
        let contents = try String(contentsOf: repo.appendingPathComponent("a.txt"), encoding: .utf8)
        #expect(contents == "original\n")
        let status = try await svc.status(worktreePath: repo)
        #expect(status.isEmpty)
    }

    @Test func discardsStagedModification() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try writeFile(repo, "a.txt", "original\n")
        _ = try await Process.git(["add", "a.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "init"], cwd: repo)
        try writeFile(repo, "a.txt", "staged\n")
        _ = try await Process.git(["add", "a.txt"], cwd: repo)

        let svc = GitService()
        try await svc.discardPaths(worktreePath: repo, files: ["a.txt"])
        let contents = try String(contentsOf: repo.appendingPathComponent("a.txt"), encoding: .utf8)
        #expect(contents == "original\n")
        let status = try await svc.status(worktreePath: repo)
        #expect(status.isEmpty)
    }

    @Test func discardsUntrackedFile() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try writeFile(repo, "seed.txt", "x\n")
        _ = try await Process.git(["add", "seed.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "init"], cwd: repo)
        try writeFile(repo, "u.txt", "untracked\n")

        let svc = GitService()
        try await svc.discardPaths(worktreePath: repo, files: ["u.txt"])
        #expect(!exists(repo, "u.txt"))
    }

    @Test func discardsStagedAdd() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try writeFile(repo, "seed.txt", "x\n")
        _ = try await Process.git(["add", "seed.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "init"], cwd: repo)
        try writeFile(repo, "added.txt", "new\n")
        _ = try await Process.git(["add", "added.txt"], cwd: repo)

        let svc = GitService()
        try await svc.discardPaths(worktreePath: repo, files: ["added.txt"])
        #expect(!exists(repo, "added.txt"))
        let status = try await svc.status(worktreePath: repo)
        #expect(status.allSatisfy { $0.path != "added.txt" })
    }

    @Test func discardsMixedTrackedAndUntracked() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try writeFile(repo, "a.txt", "v1\n")
        _ = try await Process.git(["add", "a.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "init"], cwd: repo)
        try writeFile(repo, "a.txt", "v2\n")
        try writeFile(repo, "u.txt", "untracked\n")

        let svc = GitService()
        try await svc.discardPaths(worktreePath: repo, files: ["a.txt", "u.txt"])
        let contents = try String(contentsOf: repo.appendingPathComponent("a.txt"), encoding: .utf8)
        #expect(contents == "v1\n")
        #expect(!exists(repo, "u.txt"))
    }

    @Test func discardsStagedRenameBothPaths() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try writeFile(repo, "a.txt", "content\n")
        _ = try await Process.git(["add", "a.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "init"], cwd: repo)
        _ = try await Process.git(["mv", "a.txt", "b.txt"], cwd: repo)

        let svc = GitService()
        try await svc.discardPaths(worktreePath: repo, files: ["b.txt", "a.txt"])
        #expect(exists(repo, "a.txt"))
        #expect(!exists(repo, "b.txt"))
        let status = try await svc.status(worktreePath: repo)
        #expect(status.isEmpty)
    }

    @Test func discardsStagedAddOnUnbornHead() async throws {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-unborn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: repo)
        _ = try await Process.git(["config", "user.email", "t@e"], cwd: repo)
        _ = try await Process.git(["config", "user.name", "t"], cwd: repo)
        try "hello\n".write(
            to: repo.appendingPathComponent("a.txt"),
            atomically: true,
            encoding: .utf8
        )
        _ = try await Process.git(["add", "a.txt"], cwd: repo)

        let svc = GitService()
        try await svc.discardPaths(worktreePath: repo, files: ["a.txt"])
        #expect(!FileManager.default.fileExists(atPath: repo.appendingPathComponent("a.txt").path))
    }

    @Test func tolerantOfMissingUntrackedPath() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try writeFile(repo, "seed.txt", "x\n")
        _ = try await Process.git(["add", "seed.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "init"], cwd: repo)

        // Path was never created — discardPaths should swallow ENOENT.
        let svc = GitService()
        try await svc.discardPaths(worktreePath: repo, files: ["ghost.txt"])
    }

    @Test func applyPatchReverseRemovesOneHunk() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        // 10 lines so changes to line 1 and line 10 produce two separate hunks
        // (git's 3-line context windows do not overlap).
        try writeFile(repo, "a.txt", "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n")
        _ = try await Process.git(["add", "a.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "init"], cwd: repo)
        // Two distinct hunks: change line 1 → A, change line 10 → E.
        try writeFile(repo, "a.txt", "A\n2\n3\n4\n5\n6\n7\n8\n9\nE\n")

        let svc = GitService()
        let parsed = try await svc.diff(worktreePath: repo, file: "a.txt")
        #expect(parsed.hunks.count == 2)
        let firstHunk = parsed.hunks[0]
        let patch = HunkPatchBuilder.patch(file: "a.txt", hunk: firstHunk, tracked: true)
        try await svc.applyPatchReverse(worktreePath: repo, patch: patch)

        let contents = try String(contentsOf: repo.appendingPathComponent("a.txt"), encoding: .utf8)
        // First hunk discarded → line 1 back to "1", line 10 still "E".
        #expect(contents == "1\n2\n3\n4\n5\n6\n7\n8\n9\nE\n")
    }

    @Test func applyPatchReverseThrowsWhenAlreadyApplied() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try writeFile(repo, "a.txt", "1\n")
        _ = try await Process.git(["add", "a.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "init"], cwd: repo)
        // Build a patch that doesn't match current state.
        let bogus = """
        diff --git a/a.txt b/a.txt
        --- a/a.txt
        +++ b/a.txt
        @@ -1,1 +1,1 @@
        -nope
        +never
        """ + "\n"
        let svc = GitService()
        await #expect(throws: (any Error).self) {
            try await svc.applyPatchReverse(worktreePath: repo, patch: bogus)
        }
    }
}
