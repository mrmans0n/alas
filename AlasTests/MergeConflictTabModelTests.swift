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

    @Test func acceptingLastConflictAnchorsCursorToPreviousNotZero() {
        let model = MergeConflictTabModel(
            worktreePath: URL(fileURLWithPath: "/tmp/unused"),
            relativePath: "a.txt",
            gitService: GitService()
        )
        // Three conflicts. User is at the third (last). Accept it.
        // Cursor should land on the new last (ordinal 1), NOT on ordinal 0.
        model.resultText = """
        head
        <<<<<<< HEAD
        a-ours
        =======
        a-theirs
        >>>>>>> feature
        middle1
        <<<<<<< HEAD
        b-ours
        =======
        b-theirs
        >>>>>>> feature
        middle2
        <<<<<<< HEAD
        c-ours
        =======
        c-theirs
        >>>>>>> feature
        tail

        """
        model.reparse()
        #expect(model.conflictCount == 3)
        model.nextConflict()   // 0 → 1
        model.nextConflict()   // 1 → 2 (last)
        #expect(model.currentConflictIndex == 2)

        model.acceptLocal()    // resolves the last; reparse runs
        #expect(model.conflictCount == 2)
        #expect(model.currentConflictIndex == 1)   // anchored at new last, not 0
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

    @Test func markFileResolvedDoesNotRecreateMissingFile() async throws {
        // Build a deletedByUs (DU) conflict: feature modifies a.txt, main
        // deletes it. After the merge, the working tree has a.txt (theirs'
        // content). Then simulate the user choosing "Keep deleted" via the
        // right-pane action (Plan 1) — which removes the file from disk
        // BEFORE the user opens the merge editor. Now if Mark resolved
        // writes resultText (empty for a non-existing file), it would
        // recreate the file as a 0-byte addition. It must not.
        let repo = try await Self.makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try Self.writeFile(repo, "a.txt", "base\n")
        _ = try await Process.git(["add", "a.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "base"], cwd: repo)
        _ = try await Process.git(["checkout", "-q", "-b", "feature"], cwd: repo)
        try Self.writeFile(repo, "a.txt", "feature modification\n")
        _ = try await Process.git(["commit", "-q", "-am", "feature"], cwd: repo)
        _ = try await Process.git(["checkout", "-q", "main"], cwd: repo)
        _ = try await Process.git(["rm", "-q", "a.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "delete a"], cwd: repo)
        // Merge feature → main: ours deleted, theirs modified → DU.
        _ = try await Process.git(["merge", "feature", "--no-edit"], cwd: repo)

        // Simulate the user picking "Keep deleted" from the right pane:
        // remove the on-disk file.
        try FileManager.default.removeItem(at: repo.appendingPathComponent("a.txt"))

        // Now: open the merge editor for that path and click Mark resolved.
        let model = MergeConflictTabModel(
            worktreePath: repo,
            relativePath: "a.txt",
            gitService: GitService()
        )
        // load() will see the entry as still conflicted (until we stage).
        await model.load()
        try await model.markFileResolved()

        // The file must NOT have been recreated.
        let recreated = FileManager.default.fileExists(
            atPath: repo.appendingPathComponent("a.txt").path
        )
        #expect(recreated == false)
    }

    @Test func loadSnapshotsInitialConflictCount() async throws {
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
        #expect(model.initialConflictCount == 1)
        model.acceptLocal()
        // After resolution, the snapshot survives:
        #expect(model.initialConflictCount == 1)
        #expect(model.conflictCount == 0)
    }

    @Test func annotationsStartEmptyAndCanBeSet() {
        let model = MergeConflictTabModel(
            worktreePath: URL(fileURLWithPath: "/tmp/unused"),
            relativePath: "a.txt",
            gitService: GitService()
        )
        #expect(model.annotations.isEmpty)
        model.setAnnotation("LOCAL renamed; REMOTE changed default.", forConflictOrdinal: 0)
        #expect(model.annotations[0] == "LOCAL renamed; REMOTE changed default.")
    }

    @Test func applyAgentProposalReplacesResultTextAndReparses() {
        let model = MergeConflictTabModel(
            worktreePath: URL(fileURLWithPath: "/tmp/unused"),
            relativePath: "a.txt",
            gitService: GitService()
        )
        model.resultText = """
        <<<<<<< HEAD
        ours
        =======
        theirs
        >>>>>>> feature

        """
        model.reparse()
        #expect(model.conflictCount == 1)
        model.setAgentProposalForTesting("merged content\n")
        #expect(model.agentProposal == "merged content\n")
        model.applyAgentProposal()
        #expect(model.resultText == "merged content\n")
        #expect(model.conflictCount == 0)
        #expect(model.agentProposal == nil)
    }

    @Test func discardAgentProposalClearsProposalAndKeepsResultText() {
        let model = MergeConflictTabModel(
            worktreePath: URL(fileURLWithPath: "/tmp/unused"),
            relativePath: "a.txt",
            gitService: GitService()
        )
        model.resultText = "before\n"
        model.setAgentProposalForTesting("after\n")
        model.discardAgentProposal()
        #expect(model.agentProposal == nil)
        #expect(model.resultText == "before\n")
    }
}
