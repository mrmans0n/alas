import Testing
import Foundation
@testable import Alas

@MainActor
@Suite(.serialized)
struct MergeConflictTabModelTests {
    fileprivate static func makeRepo() async throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-mctm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: dir)
        _ = try await Process.git(["config", "user.email", "t@e"], cwd: dir)
        _ = try await Process.git(["config", "user.name", "t"], cwd: dir)
        _ = try await Process.git(["config", "commit.gpgsign", "false"], cwd: dir)
        return dir
    }

    fileprivate static func writeFile(_ repo: URL, _ name: String, _ contents: String) throws {
        try contents.write(
            to: repo.appendingPathComponent(name),
            atomically: true,
            encoding: .utf8
        )
    }

    /// Same conflict-producing layout as Plan 1's GitServiceMergeTests:
    /// base → feature edits a.txt; main edits a.txt differently.
    fileprivate static func makeConflictingBranches(_ repo: URL) async throws {
        try writeFile(repo, "a.txt", "base line\n")
        _ = try await Process.git(["add", "a.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "base"], cwd: repo)
        _ = try await Process.git(["checkout", "-q", "-b", "feature"], cwd: repo)
        try writeFile(repo, "a.txt", "feature line\n")
        _ = try await Process.git(["commit", "-q", "-am", "feature"], cwd: repo)
        _ = try await Process.git(["checkout", "-q", "main"], cwd: repo)
        try writeFile(repo, "a.txt", "main line\n")
        _ = try await Process.git(["commit", "-q", "-am", "main"], cwd: repo)
    }

    @Test func loadPopulatesSidesAndRegions() async throws {
        let repo = try await Self.makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Self.makeConflictingBranches(repo)
        _ = try await Process.git(["merge", "feature", "--no-edit"], cwd: repo)

        let model = MergeConflictTabModel(
            worktreePath: repo,
            relativePath: "a.txt",
            gitService: GitService()
        )
        await model.load()

        #expect(model.conflictedFile?.local == "main line\n")
        #expect(model.conflictedFile?.remote == "feature line\n")
        #expect(model.conflictedFile?.base == "base line\n")
        #expect(model.regions.count >= 1)
        #expect(model.conflictCount == 1)
        #expect(model.currentConflictIndex == 0)
        #expect(model.resultText.contains("<<<<<<<"))
    }

    @Test func loadOnNonConflictedFileRecordsError() async throws {
        let repo = try await Self.makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try Self.writeFile(repo, "a.txt", "hi\n")
        _ = try await Process.git(["add", "a.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "init"], cwd: repo)

        let model = MergeConflictTabModel(
            worktreePath: repo,
            relativePath: "a.txt",
            gitService: GitService()
        )
        await model.load()
        #expect(model.conflictedFile == nil)
        #expect(model.loadError != nil)
    }
}
