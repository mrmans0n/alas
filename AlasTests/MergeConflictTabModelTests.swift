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

    @Test func acceptLocalReplacesMarkerBlockWithLocalContent() async throws {
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

        model.acceptLocal()
        #expect(!model.resultText.contains("<<<<<<<"))
        #expect(model.resultText.contains("main line"))
        #expect(model.conflictCount == 0)
        #expect(model.currentConflictIndex == nil)
    }

    @Test func acceptRemoteReplacesMarkerBlockWithRemoteContent() async throws {
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

        model.acceptRemote()
        #expect(!model.resultText.contains("<<<<<<<"))
        #expect(model.resultText.contains("feature line"))
    }

    @Test func acceptBothPreservesBothSides() async throws {
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

        model.acceptBoth()
        #expect(!model.resultText.contains("<<<<<<<"))
        #expect(model.resultText.contains("main line"))
        #expect(model.resultText.contains("feature line"))
    }

    @Test func nextAndPreviousNavigateConflicts() {
        let model = MergeConflictTabModel(
            worktreePath: URL(fileURLWithPath: "/tmp/unused"),
            relativePath: "a.txt",
            gitService: GitService()
        )
        // Bypass load() and inject a synthetic two-conflict resultText.
        model.resultText = """
        head
        <<<<<<< HEAD
        a-ours
        =======
        a-theirs
        >>>>>>> feature
        middle
        <<<<<<< HEAD
        b-ours
        =======
        b-theirs
        >>>>>>> feature
        tail

        """
        model.reparse()
        #expect(model.conflictCount == 2)
        #expect(model.currentConflictIndex == 0)

        model.nextConflict()
        #expect(model.currentConflictIndex == 1)
        model.nextConflict()
        #expect(model.currentConflictIndex == 1) // clamped at last

        model.previousConflict()
        #expect(model.currentConflictIndex == 0)
        model.previousConflict()
        #expect(model.currentConflictIndex == 0) // clamped at first
    }

    @Test func markFileResolvedStagesViaGitService() async throws {
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
        model.acceptLocal()
        try await model.markFileResolved()

        // After mark-resolved, status no longer lists a.txt as conflicted.
        let changes = try await GitService().status(worktreePath: repo)
        let entry = changes.first { $0.path == "a.txt" }
        #expect(entry?.conflict == nil)
    }
}
