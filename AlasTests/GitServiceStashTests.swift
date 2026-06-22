import Foundation
import Testing
@testable import Alas

@Suite(.serialized)
struct GitServiceStashTests {
    private func makeRepo() async throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-stash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await gitOK(["init", "-q", "-b", "main"], cwd: dir)
        try await gitOK(["config", "user.email", "t@example.com"], cwd: dir)
        try await gitOK(["config", "user.name", "Test User"], cwd: dir)
        try "base\n".write(to: dir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try await gitOK(["add", "file.txt"], cwd: dir)
        try await gitOK(["commit", "-q", "-m", "base"], cwd: dir)
        return dir
    }

    @discardableResult
    private func gitOK(_ args: [String], cwd: URL) async throws -> ProcessResult {
        let result = try await Process.git(args, cwd: cwd)
        guard result.exitCode == 0 else {
            throw NSError(
                domain: "GitServiceStashTests.gitOK",
                code: Int(result.exitCode),
                userInfo: [NSLocalizedDescriptionKey: result.stderr]
            )
        }
        return result
    }

    @Test func parseStashListPreservesRefSubjectRelativeTimeAndSha() {
        let output = """
        stash@{0}\u{1f}WIP on main: abc123 update parser\u{1f}2 hours ago\u{1f}1111111111111111111111111111111111111111
        stash@{1}\u{1f}custom message\u{1f}3 days ago\u{1f}2222222222222222222222222222222222222222

        """

        let stashes = GitService.parseStashList(output)

        #expect(stashes == [
            GitStash(
                ref: "stash@{0}",
                subject: "WIP on main: abc123 update parser",
                relativeTime: "2 hours ago",
                sha: "1111111111111111111111111111111111111111"
            ),
            GitStash(
                ref: "stash@{1}",
                subject: "custom message",
                relativeTime: "3 days ago",
                sha: "2222222222222222222222222222222222222222"
            ),
        ])
    }

    @Test func parseStashFilesMergesNumstatAndNameStatus() {
        let numstat = """
        12\t3\tSources/App.swift
        -\t-\tAssets/icon.png
        4\t0\tSources/New.swift

        """
        let nameStatus = """
        M\tSources/App.swift
        M\tAssets/icon.png
        A\tSources/New.swift

        """

        let files = GitService.parseStashFiles(numstat: numstat, nameStatus: nameStatus)

        #expect(files == [
            GitStashFile(path: "Sources/App.swift", status: "M", add: 12, del: 3),
            GitStashFile(path: "Assets/icon.png", status: "M", add: 0, del: 0),
            GitStashFile(path: "Sources/New.swift", status: "A", add: 4, del: 0),
        ])
    }

    @Test func parseStashFilesHandlesRenamesUsingNewPath() {
        let numstat = "1\t2\tSources/Old.swift => Sources/New.swift\n"
        let nameStatus = "R100\tSources/Old.swift\tSources/New.swift\n"

        let files = GitService.parseStashFiles(numstat: numstat, nameStatus: nameStatus)

        #expect(files == [
            GitStashFile(path: "Sources/New.swift", status: "R", add: 1, del: 2),
        ])
    }

    @Test func parseStashFilesHandlesBraceRenameNumstatUsingNewPath() {
        let numstat = "1\t2\tSources/{Old.swift => New.swift}\n"
        let nameStatus = "R100\tSources/Old.swift\tSources/New.swift\n"

        let files = GitService.parseStashFiles(numstat: numstat, nameStatus: nameStatus)

        #expect(files == [
            GitStashFile(path: "Sources/New.swift", status: "R", add: 1, del: 2),
        ])
    }

    @Test func pushListFilesAndDiffStash() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "base\nchanged\n".write(to: repo.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

        let service = GitService()
        let result = try await service.pushStash(worktreePath: repo, message: "parser cleanup", includeUntracked: false)

        #expect(result == .clean)
        let stashes = try await service.stashes(worktreePath: repo)
        #expect(stashes.count == 1)
        #expect(stashes[0].subject.contains("parser cleanup"))
        let files = try await service.stashFiles(worktreePath: repo, stash: stashes[0])
        #expect(files == [GitStashFile(path: "file.txt", status: "M", add: 1, del: 0)])
        let diff = try await service.stashDiff(worktreePath: repo, stash: stashes[0], file: files[0])
        #expect(diff.hunks.contains { hunk in hunk.lines.contains { $0.kind == .add && $0.text == "changed" } })
    }

    @Test func pushStashCanIncludeUntrackedFiles() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "new\n".write(to: repo.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)

        let service = GitService()
        let result = try await service.pushStash(worktreePath: repo, message: "", includeUntracked: true)

        #expect(result == .clean)
        let stash = try #require(try await service.stashes(worktreePath: repo).first)
        let files = try await service.stashFiles(worktreePath: repo, stash: stash)
        let file = try #require(files.first { $0.path == "new.txt" })
        #expect(file == GitStashFile(path: "new.txt", status: "A", add: 1, del: 0))
        let diff = try await service.stashDiff(worktreePath: repo, stash: stash, file: file)
        #expect(diff.hunks.contains { hunk in hunk.lines.contains { $0.kind == .add && $0.text == "new" } })
    }

    @Test func applyPopAndDropStash() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "base\nchanged\n".write(to: repo.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

        let service = GitService()
        _ = try await service.pushStash(worktreePath: repo, message: "apply me", includeUntracked: false)
        var stash = try #require(try await service.stashes(worktreePath: repo).first)

        #expect(try await service.applyStash(worktreePath: repo, stash: stash) == .clean)
        #expect(try String(contentsOf: repo.appendingPathComponent("file.txt"), encoding: .utf8) == "base\nchanged\n")
        try await gitOK(["checkout", "--", "file.txt"], cwd: repo)

        #expect(try await service.popStash(worktreePath: repo, stash: stash) == .clean)
        #expect(try await service.stashes(worktreePath: repo).isEmpty)

        _ = try await service.pushStash(worktreePath: repo, message: "drop me", includeUntracked: false)
        stash = try #require(try await service.stashes(worktreePath: repo).first)
        try await service.dropStash(worktreePath: repo, stash: stash)
        #expect(try await service.stashes(worktreePath: repo).isEmpty)
    }

    @Test func applyStashReportsConflictsFromGitStdout() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "stash\n".write(to: repo.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

        let service = GitService()
        _ = try await service.pushStash(worktreePath: repo, message: "conflict me", includeUntracked: false)
        let stash = try #require(try await service.stashes(worktreePath: repo).first)
        try "other\n".write(to: repo.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try await gitOK(["add", "file.txt"], cwd: repo)
        try await gitOK(["commit", "-q", "-m", "other"], cwd: repo)

        guard case .conflict(let message) = try await service.applyStash(worktreePath: repo, stash: stash) else {
            Issue.record("Expected applyStash to report a conflict.")
            return
        }
        #expect(message.contains("CONFLICT"))
    }
}
