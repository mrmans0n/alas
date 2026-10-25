import Foundation
import Testing
@testable import AlasCore

struct GitServiceBatchedDiffTests {
    @Test func sliceDiffByFileMatchesNewSidePathsAndDropsOthers() {
        let raw = """
        diff --git a/x b/y b/x b/y
        @@ -1 +1 @@
        -spaced
        +spaced!
        diff --git a/old.txt b/new.txt
        similarity index 90%
        rename from old.txt
        rename to new.txt
        diff --git "a/tab\\there" "b/tab\\there"
        @@ -1 +1 @@
        -t
        +T
        diff --git a/skipped.txt b/skipped.txt
        @@ -1 +1 @@
        -s
        +S
        """

        let slices = GitService.sliceDiffByFile(raw, files: ["x b/y", "new.txt", "tab\there", "y", "absent.txt"])

        #expect(slices.keys.sorted() == ["new.txt", "tab\there", "x b/y"])
        #expect(slices["x b/y"]?.hasPrefix("diff --git a/x b/y b/x b/y\n@@ -1 +1 @@\n-spaced\n+spaced!") == true)
        #expect(slices["new.txt"]?.contains("rename to new.txt") == true)
        #expect(slices["new.txt"]?.contains("tab") == false)
        #expect(slices["tab\there"]?.hasSuffix("+T") == true)
    }

    @Test func treeDiffsByFileMatchesPerFileRangeDiffs() async throws {
        let repo = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: repo.deletingLastPathComponent()) }
        try write("one\ntwo\nthree\n", "a.txt", in: repo)
        try write(String(repeating: "renamed line\n", count: 20), "old name.txt", in: repo)
        try write("gone\n", "d.txt", in: repo)
        try await git(["add", "-A"], in: repo)
        try await git(["commit", "-q", "-m", "base"], in: repo)
        let base = try await git(["rev-parse", "HEAD"], in: repo)

        try write("one\n2\nthree\nfour\n", "a.txt", in: repo)
        try FileManager.default.removeItem(at: repo.appendingPathComponent("old name.txt"))
        try write(String(repeating: "renamed line\n", count: 20) + "tail\n", "dir b/new name.txt", in: repo)
        try await git(["rm", "-q", "d.txt"], in: repo)
        try write("fresh\n", "added.txt", in: repo)
        try await git(["add", "-A"], in: repo)
        try await git(["commit", "-q", "-m", "head"], in: repo)

        let service = GitService()
        let files = try await service.rangeChangedFiles(at: repo, base: base, head: "HEAD", threeDot: false)
        let revisions = try await service.resolvedRangeTrees(worktreePath: repo, base: base, head: "HEAD", threeDot: false)
        let batched = try await service.treeDiffsByFile(worktreePath: repo, revisions: revisions, paths: files.map(\.path))

        #expect(files.map(\.status).sorted() == ["A", "D", "M", "R"])
        for file in files {
            let single = try await service.rangeDiff(worktreePath: repo, revisions: revisions, file: file.path, originalPath: file.originalPath)
            #expect(batched[file.path] == single, "\(file.path)")
        }
    }

    /// Every file `git status` lists without a rename source diffs the same
    /// batched as singly, whether or not status detects renames.
    @Test(arguments: [true, false])
    func workingCopyDiffsByFileMatchesPerFileDiffs(statusDetectsRenames: Bool) async throws {
        let repo = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: repo.deletingLastPathComponent()) }
        try await git(["config", "status.renames", statusDetectsRenames ? "true" : "false"], in: repo)
        try write("one\ntwo\n", "staged.txt", in: repo)
        try write("alpha\nbeta\n", "both.txt", in: repo)
        try write(String(repeating: "moved line\n", count: 20), "moved.txt", in: repo)
        try await git(["add", "-A"], in: repo)
        try await git(["commit", "-q", "-m", "base"], in: repo)

        try write("one\n2\n", "staged.txt", in: repo)
        try write("alpha\nBETA\n", "both.txt", in: repo)
        try await git(["add", "staged.txt", "both.txt"], in: repo)
        try await git(["mv", "moved.txt", "moved again.txt"], in: repo)
        try write("alpha\nBETA\ngamma\n", "both.txt", in: repo)
        try write("new\n", "untracked.txt", in: repo)

        let service = GitService()
        let changes = try await service.status(worktreePath: repo)
        let unstaged = try await service.workingCopyDiffsByFile(
            worktreePath: repo, staged: false,
            paths: changes.filter { $0.stage == .unstaged }.map(\.path)
        )
        let staged = try await service.workingCopyDiffsByFile(
            worktreePath: repo, staged: true,
            paths: changes.filter { $0.stage == .staged }.map(\.path)
        )

        #expect(changes.contains { $0.renameFrom == "moved.txt" } == statusDetectsRenames)
        #expect(unstaged["untracked.txt"] == nil)
        for change in changes where change.renameFrom == nil && change.path != "untracked.txt" {
            let single = try await service.diff(
                worktreePath: repo, file: change.path,
                staged: change.stage == .staged, originalPath: nil
            )
            let batched = change.stage == .staged ? staged[change.path] : unstaged[change.path]
            #expect(batched == single, "\(change.stage) \(change.path)")
        }
    }

    private func makeRepository() async throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alas-batched-diff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = root.appendingPathComponent("repo")
        try await GitTemplate.repository(at: repo)
        return repo
    }

    private func write(_ contents: String, _ path: String, in repo: URL) throws {
        let url = repo.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    @discardableResult
    private func git(_ arguments: [String], in repo: URL) async throws -> String {
        let (status, data) = try await BlockingWork.run {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-c", "user.name=Test", "-c", "user.email=test@example.com"] + arguments
            process.currentDirectoryURL = repo
            process.standardOutput = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, data)
        }
        #expect(status == 0, "git \(arguments.joined(separator: " "))")
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
