import Foundation
import Testing
@testable import Alas

@Suite(.serialized)
struct GitServiceReviewRequestDraftTests {
    @Test func loadsCommittedBranchContextAndExcludesWorkingTreeDiff() async throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        try await git(["init", "-b", "main"], cwd: repo)
        try await git(["config", "user.email", "test@example.com"], cwd: repo)
        try await git(["config", "user.name", "Test User"], cwd: repo)
        try write("README.md", "Initial\n", in: repo)
        try await git(["add", "README.md"], cwd: repo)
        try await git(["commit", "-m", "chore: initial"], cwd: repo)
        try await git(["checkout", "-b", "feature/pr-drafts"], cwd: repo)
        try write("Sources/A.swift", "let committed = 1\n", in: repo)
        try await git(["add", "Sources/A.swift"], cwd: repo)
        try await git(["commit", "-m", "feat: add committed file"], cwd: repo)
        try write("Sources/Uncommitted.swift", "let uncommitted = 1\n", in: repo)

        let context = try await GitService().reviewRequestDraftContext(
            worktreePath: repo,
            baseRef: "main"
        )

        #expect(context.commitSubjects == ["feat: add committed file"])
        #expect(context.changedFiles.map(\.path) == ["Sources/A.swift"])
        #expect(context.diff.contains("Sources/A.swift"))
        #expect(!context.diff.contains("Uncommitted.swift"))
        #expect(context.hasUncommittedChanges)
    }

    @Test func loadsRenameDestinationOriginalPathAndCounts() async throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        try await git(["init", "-b", "main"], cwd: repo)
        try await git(["config", "user.email", "test@example.com"], cwd: repo)
        try await git(["config", "user.name", "Test User"], cwd: repo)
        try write("Sources/Old.swift", """
        let line1 = 1
        let line2 = 2
        let line3 = 3
        let line4 = 4
        let line5 = 5
        let line6 = 6
        let line7 = 7
        let line8 = 8
        let line9 = 9
        let line10 = 10

        """, in: repo)
        try await git(["add", "Sources/Old.swift"], cwd: repo)
        try await git(["commit", "-m", "chore: add old file"], cwd: repo)
        try await git(["checkout", "-b", "feature/rename"], cwd: repo)
        try await git(["mv", "Sources/Old.swift", "Sources/New.swift"], cwd: repo)
        try write("Sources/New.swift", """
        let line1 = 1
        let line2 = 2
        let line3 = 3
        let line4 = 4
        let line5 = 50
        let line6 = 6
        let line7 = 7
        let line8 = 8
        let line9 = 9
        let line10 = 10
        let line11 = 11

        """, in: repo)
        try await git(["add", "Sources/New.swift"], cwd: repo)
        try await git(["commit", "-m", "refactor: rename file"], cwd: repo)

        let context = try await GitService().reviewRequestDraftContext(
            worktreePath: repo,
            baseRef: "main"
        )

        let file = try #require(context.changedFiles.first)
        #expect(context.changedFiles.count == 1)
        #expect(file.path == "Sources/New.swift")
        #expect(file.originalPath == "Sources/Old.swift")
        #expect(file.status.hasPrefix("R"))
        #expect(file.add > 0)
        #expect(file.del > 0)
    }

    private func makeRepo() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-pr-draft-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ path: String, _ contents: String, in repo: URL) throws {
        let url = repo.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    @discardableResult
    private func git(_ args: [String], cwd: URL) async throws -> ProcessResult {
        let result = try await Process.git(args, cwd: cwd)
        #expect(result.exitCode == 0, Comment(rawValue: result.stderr))
        return result
    }
}
