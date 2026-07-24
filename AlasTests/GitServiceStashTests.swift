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
            GitStashFile(path: "Sources/New.swift", status: "R", add: 1, del: 2, oldPath: "Sources/Old.swift"),
        ])
    }

    @Test func parseStashFilesHandlesBraceRenameNumstatUsingNewPath() {
        let numstat = "1\t2\tSources/{Old.swift => New.swift}\n"
        let nameStatus = "R100\tSources/Old.swift\tSources/New.swift\n"

        let files = GitService.parseStashFiles(numstat: numstat, nameStatus: nameStatus)

        #expect(files == [
            GitStashFile(path: "Sources/New.swift", status: "R", add: 1, del: 2, oldPath: "Sources/Old.swift"),
        ])
    }

    @Test func stashFileDecodesMissingUntrackedOriginAsTracked() throws {
        let data = Data("""
        {"path":"file.txt","status":"M","add":1,"del":0}
        """.utf8)

        let file = try JSONDecoder().decode(GitStashFile.self, from: data)

        #expect(!file.isUntracked)
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
        #expect(file == GitStashFile(path: "new.txt", status: "A", add: 1, del: 0, isUntracked: true))
        let diff = try await service.stashDiff(worktreePath: repo, stash: stash, file: file)
        #expect(diff.hunks.contains { hunk in hunk.lines.contains { $0.kind == .add && $0.text == "new" } })
    }

    @Test func stashImagePairUsesFirstParentAndStashSnapshot() async throws {
        let fixture = try await StashImageFixture.modified()
        defer { fixture.remove() }

        let pair = try await GitService().imageDiffPairForStash(
            worktreePath: fixture.repo,
            stash: fixture.stash,
            file: fixture.file
        )

        #expect(pair.kind == .modified)
        #expect(pair.beforeImage != nil)
        #expect(pair.afterImage != nil)
    }

    @Test func untrackedStashImageHasMissingBeforeAndThirdParentAfter() async throws {
        let fixture = try await StashImageFixture.untracked()
        defer { fixture.remove() }

        let pair = try await GitService().imageDiffPairForStash(
            worktreePath: fixture.repo,
            stash: fixture.stash,
            file: fixture.file
        )

        #expect(fixture.file.isUntracked)
        #expect(pair.kind == .added)
        #expect(pair.beforeImage == nil)
        #expect(pair.afterImage != nil)
    }

    @Test func corruptStashImageIsFailedInsteadOfMissingAndCanBeRetried() async throws {
        let fixture = try await StashImageFixture.corrupt()
        defer { fixture.remove() }

        let pair = try await GitService().imageDiffPairForStash(
            worktreePath: fixture.repo,
            stash: fixture.stash,
            file: fixture.file
        )

        #expect(pair.beforeImage != nil)
        guard case .failed(let failure) = pair.after else {
            Issue.record("Expected corrupt stash image data to be a failed side.")
            return
        }
        #expect(failure.message == "decode")
        #expect(pair.hasFailure)
    }

    @Test func stashDiffForRenameIncludesChangedLinesFromOriginalPath() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "one\ntwo\nthree\nfour\nfive\n".write(to: repo.appendingPathComponent("old.txt"), atomically: true, encoding: .utf8)
        try await gitOK(["add", "old.txt"], cwd: repo)
        try await gitOK(["commit", "-q", "-m", "add old"], cwd: repo)
        try await gitOK(["mv", "old.txt", "new.txt"], cwd: repo)
        try "one\nchanged\nthree\nfour\nfive\n".write(to: repo.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)

        let service = GitService()
        _ = try await service.pushStash(worktreePath: repo, message: "rename", includeUntracked: false)
        let stash = try #require(try await service.stashes(worktreePath: repo).first)
        let file = try #require(try await service.stashFiles(worktreePath: repo, stash: stash).first)

        #expect(file == GitStashFile(path: "new.txt", status: "R", add: 1, del: 1, oldPath: "old.txt"))
        let diff = try await service.stashDiff(worktreePath: repo, stash: stash, file: file)
        #expect(diff.hunks.contains { hunk in
            hunk.lines.contains { $0.kind == .delete && $0.text == "two" }
                && hunk.lines.contains { $0.kind == .add && $0.text == "changed" }
        })
    }

    @Test func stashDiffLoadsCapturedShaAfterRefMoves() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        let service = GitService()
        try "base\nold stash\n".write(to: repo.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        _ = try await service.pushStash(worktreePath: repo, message: "old", includeUntracked: false)
        let oldStash = try #require(try await service.stashes(worktreePath: repo).first)
        let oldFile = try #require(try await service.stashFiles(worktreePath: repo, stash: oldStash).first)

        try "base\nnew stash\n".write(to: repo.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        _ = try await service.pushStash(worktreePath: repo, message: "new", includeUntracked: false)

        let diff = try await service.stashDiff(worktreePath: repo, stash: oldStash, file: oldFile)

        #expect(diff.hunks.contains { hunk in
            hunk.lines.contains { $0.kind == .add && $0.text == "old stash" }
        })
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

    @Test func dropStashRejectsRefThatNowPointsAtDifferentSha() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        let service = GitService()
        try "base\nold stash\n".write(to: repo.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        _ = try await service.pushStash(worktreePath: repo, message: "old", includeUntracked: false)
        let staleRef = try #require(try await service.stashes(worktreePath: repo).first)

        try "base\nnew stash\n".write(to: repo.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        _ = try await service.pushStash(worktreePath: repo, message: "new", includeUntracked: false)

        await #expect(throws: (any Error).self) {
            try await service.dropStash(worktreePath: repo, stash: staleRef)
        }
        let stashes = try await service.stashes(worktreePath: repo)
        #expect(stashes.count == 2)
        #expect(stashes[0].subject.contains("new"))
        #expect(stashes[1].subject.contains("old"))
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

private struct StashImageFixture {
    let repo: URL
    let stash: GitStash
    let file: GitStashFile

    func remove() {
        try? FileManager.default.removeItem(at: repo)
    }

    static func modified() async throws -> Self {
        let repo = try await makeRepo()
        let url = repo.appendingPathComponent("logo.png")
        try red.write(to: url)
        try await git(["add", "logo.png"], cwd: repo)
        try await git(["commit", "-q", "-m", "add image"], cwd: repo)
        try blue.write(to: url)
        _ = try await GitService().pushStash(
            worktreePath: repo,
            message: "image",
            includeUntracked: false
        )
        return try await fixture(repo: repo, path: "logo.png")
    }

    static func untracked() async throws -> Self {
        let repo = try await makeRepo()
        try red.write(to: repo.appendingPathComponent("new.png"))
        _ = try await GitService().pushStash(
            worktreePath: repo,
            message: "untracked image",
            includeUntracked: true
        )
        return try await fixture(repo: repo, path: "new.png")
    }

    static func corrupt() async throws -> Self {
        let repo = try await makeRepo()
        let url = repo.appendingPathComponent("logo.png")
        try red.write(to: url)
        try await git(["add", "logo.png"], cwd: repo)
        try await git(["commit", "-q", "-m", "add image"], cwd: repo)
        try Data("not an image".utf8).write(to: url)
        _ = try await GitService().pushStash(
            worktreePath: repo,
            message: "corrupt image",
            includeUntracked: false
        )
        return try await fixture(repo: repo, path: "logo.png")
    }

    private static func fixture(repo: URL, path: String) async throws -> Self {
        let service = GitService()
        let stash = try #require(try await service.stashes(worktreePath: repo).first)
        let file = try #require(
            try await service.stashFiles(worktreePath: repo, stash: stash)
                .first { $0.path == path }
        )
        return Self(repo: repo, stash: stash, file: file)
    }

    private static func makeRepo() async throws -> URL {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-stash-image-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try await git(["init", "-q", "-b", "main"], cwd: repo)
        try await git(["config", "user.email", "t@example.com"], cwd: repo)
        try await git(["config", "user.name", "Test User"], cwd: repo)
        try "seed\n".write(
            to: repo.appendingPathComponent("seed.txt"),
            atomically: true,
            encoding: .utf8
        )
        try await git(["add", "seed.txt"], cwd: repo)
        try await git(["commit", "-q", "-m", "seed"], cwd: repo)
        return repo
    }

    private static func git(_ args: [String], cwd: URL) async throws {
        let result = try await Process.git(args, cwd: cwd)
        guard result.exitCode == 0 else {
            throw ProcessError.nonZeroExit(result.exitCode, result.stderr)
        }
    }

    private static let red = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
    )!
    private static let blue = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgYPgPAAEDAQAIicLsAAAAAElFTkSuQmCC"
    )!
}
