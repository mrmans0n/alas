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

    /// Sets up two conflict regions in `a.txt` so per-block accept
    /// tests can target the second conflict explicitly. Base has 7
    /// lines; feature and main each edit lines 1 and 7, with 5 context
    /// lines in between — enough for git to produce two disjoint hunks.
    fileprivate static func makeTwoConflictBranches(_ repo: URL) async throws {
        try writeFile(repo, "a.txt", "L1 base\nL2 keep\nL3 keep\nL4 keep\nL5 keep\nL6 keep\nL7 base\n")
        _ = try await Process.git(["add", "a.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "base"], cwd: repo)
        _ = try await Process.git(["checkout", "-q", "-b", "feature"], cwd: repo)
        try writeFile(repo, "a.txt", "L1 feature\nL2 keep\nL3 keep\nL4 keep\nL5 keep\nL6 keep\nL7 feature\n")
        _ = try await Process.git(["commit", "-q", "-am", "feature"], cwd: repo)
        _ = try await Process.git(["checkout", "-q", "main"], cwd: repo)
        try writeFile(repo, "a.txt", "L1 main\nL2 keep\nL3 keep\nL4 keep\nL5 keep\nL6 keep\nL7 main\n")
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
        let block = ConflictBlock(
            local: "ours\n", base: nil, remote: "theirs\n",
            localLabel: "HEAD", remoteLabel: "feature",
            lineRangeInMerged: 0 ... 4
        )
        model.setAnnotation("LOCAL renamed; REMOTE changed default.", for: block)
        #expect(model.annotation(for: block) == "LOCAL renamed; REMOTE changed default.")
    }

    @Test func annotationKeyedByBlockContentSurvivesResolution() {
        let model = MergeConflictTabModel(
            worktreePath: URL(fileURLWithPath: "/tmp/unused"),
            relativePath: "a.txt",
            gitService: GitService()
        )
        // Two conflicts with distinguishable sides.
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

        // Manually cache an annotation for the SECOND conflict (block "b").
        let blocks = model.regions.compactMap { (r: ConflictRegion) -> ConflictBlock? in
            if case .conflict(let b) = r { return b } else { return nil }
        }
        #expect(blocks.count == 2)
        model.setAnnotation("about b", for: blocks[1])
        #expect(model.annotation(for: blocks[1]) == "about b")

        // Now resolve the FIRST conflict. After reparse the only remaining
        // conflict is the "b" block, now at ordinal 0. Its annotation must
        // still resolve to "about b" — not the empty string the OLD ordinal 1
        // index would have produced under the old [Int: String] scheme.
        // (Navigate to ordinal 0 via previousConflict from reparse's default.)
        model.previousConflict() // ensure we're at ordinal 0
        model.acceptLocal()
        #expect(model.conflictCount == 1)

        let remaining = model.regions.compactMap { (r: ConflictRegion) -> ConflictBlock? in
            if case .conflict(let b) = r { return b } else { return nil }
        }
        #expect(remaining.count == 1)
        #expect(model.annotation(for: remaining[0]) == "about b")
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

    @Test func loadClearsAnyPendingAgentProposal() async throws {
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
        // Simulate a pending agent proposal from a prior session/conflict.
        model.setAgentProposalForTesting("stale proposal\n")
        #expect(model.agentProposal != nil)

        // Reloading the tab (e.g. re-focused for a fresh conflict) must
        // clear the stale proposal so the user can't accidentally Apply
        // it onto the newly loaded conflict.
        await model.load()
        #expect(model.agentProposal == nil)
    }

    @Test func loadGenerationIncrementsOnEveryLoadAttempt() async throws {
        // Both successful and failed loads must bump the generation — stale
        // async guards (binary cache, requestAgentResolveFile) rely on it
        // changing even when a reload fails.
        let repo = try await Self.makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Self.makeConflictingBranches(repo)
        _ = try await Process.git(["merge", "feature", "--no-edit"], cwd: repo)

        let model = MergeConflictTabModel(
            worktreePath: repo,
            relativePath: "a.txt",
            gitService: GitService()
        )
        #expect(model.loadGeneration == 0)
        await model.load()
        let first = model.loadGeneration
        #expect(first > 0)
        await model.load()
        #expect(model.loadGeneration > first)

        // Now make load() fail by abort'ing the merge so a.txt is no longer
        // conflicted. The generation must still bump.
        _ = try await Process.git(["merge", "--abort"], cwd: repo)
        let beforeFailedLoad = model.loadGeneration
        await model.load()
        #expect(model.loadError != nil)
        #expect(model.loadGeneration > beforeFailedLoad)
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

    @Test func acceptLocalForBlockTargetsThatBlockNotCurrentIndex() async throws {
        let repo = try await Self.makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Self.makeTwoConflictBranches(repo)
        _ = try await Process.git(["merge", "feature", "--no-edit"], cwd: repo)
        let model = MergeConflictTabModel(
            worktreePath: repo,
            relativePath: "a.txt",
            gitService: GitService()
        )
        await model.load()
        #expect(model.conflictCount == 2)
        let blocks = model.allConflictBlocks()
        #expect(blocks.count == 2)
        let secondBlock = try #require(blocks.last)
        // Cursor is at ordinal 0 after load(); accept block 1.
        #expect(model.currentConflictIndex == 0)
        model.acceptLocal(for: secondBlock)
        #expect(model.conflictCount == 1)
        let remaining = try #require(model.allConflictBlocks().first)
        #expect(remaining.local.contains("L1 main"))
    }

    @Test func wordDiffModeDefaultsToCharacters() async throws {
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
        #expect(model.wordDiffMode == .characters)
    }

    @Test func wordDiffModeIsMutableAndDoesNotResetOnReload() async throws {
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
        model.wordDiffMode = .words
        await model.load()
        #expect(model.wordDiffMode == .words)
    }

    @Test func flatTextForWritingSerializesRegionsWithoutMarkers() async throws {
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
        let flat = model.flatTextForWriting()
        #expect(!flat.contains("<<<<<<<"))
        #expect(!flat.contains("======="))
        #expect(!flat.contains(">>>>>>>"))
        #expect(flat.contains("main line"))
        #expect(flat.contains("feature line"))
    }

    @Test func resetToInitialStackRestoresBothHunks() async throws {
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
        let block = try #require(model.allConflictBlocks().first)
        let localBefore = block.local
        let remoteBefore = block.remote
        let labelLocal = block.localLabel
        let labelRemote = block.remoteLabel
        model.acceptLocal(for: block)
        #expect(model.conflictCount == 0)
        model.appendConflictBlock(
            originalLocal: localBefore,
            originalRemote: remoteBefore,
            originalBase: nil,
            originalLocalLabel: labelLocal,
            originalRemoteLabel: labelRemote
        )
        #expect(model.conflictCount == 1)
    }

    @Test func acceptForBlockShiftsLaterCursorDownByOne() async throws {
        let repo = try await Self.makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Self.makeTwoConflictBranches(repo)
        _ = try await Process.git(["merge", "feature", "--no-edit"], cwd: repo)
        let model = MergeConflictTabModel(
            worktreePath: repo,
            relativePath: "a.txt",
            gitService: GitService()
        )
        await model.load()
        #expect(model.conflictCount == 2)
        let firstBlock = try #require(model.allConflictBlocks().first)
        // Position cursor on the SECOND conflict (ordinal 1), then
        // accept the FIRST. Expected: cursor lands on ordinal 0 (the
        // formerly-ordinal-1 block, now the only one left).
        model.nextConflict()
        #expect(model.currentConflictIndex == 1)
        model.acceptLocal(for: firstBlock)
        #expect(model.conflictCount == 1)
        #expect(model.currentConflictIndex == 0)
    }

    @Test func setRowContentEditsTextRegion() async throws {
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
        // The fixture's conflict is the whole file (single conflict
        // block, no surrounding text). After resolving via accept
        // LOCAL we get a single .text region containing "main line".
        let block = try #require(model.allConflictBlocks().first)
        model.acceptLocal(for: block)
        #expect(model.conflictCount == 0)
        model.setRowContent(at: 0, to: "edited line")
        #expect(model.flatTextForWriting().contains("edited line"))
        #expect(!model.flatTextForWriting().contains("main line"))
    }

    @Test func setRowContentEditsLocalHunkAndPreservesRemote() async throws {
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
        #expect(model.conflictCount == 1)
        // Conflict spans rows 0 (LOCAL "main line") and 1 (REMOTE
        // "feature line"). Edit row 0 → LOCAL becomes "renamed line".
        model.setRowContent(at: 0, to: "renamed line")
        let block = try #require(model.allConflictBlocks().first)
        #expect(block.local.contains("renamed line"))
        #expect(block.remote.contains("feature line"))
        #expect(model.conflictCount == 1) // structure preserved
    }

    @Test func setRowContentPreservesMarkerStructureForFutureAccepts() async throws {
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
        #expect(model.conflictCount == 1)
        // Edit the LOCAL hunk's first row inline.
        model.setRowContent(at: 0, to: "tweaked main line")
        // After the edit, resultText should still contain the marker
        // structure so a subsequent acceptLocal can find the block.
        #expect(model.resultText.contains("<<<<<<<"))
        #expect(model.resultText.contains("======="))
        #expect(model.resultText.contains(">>>>>>>"))
        // And accepting LOCAL must actually resolve the conflict.
        let block = try #require(model.allConflictBlocks().first)
        model.acceptLocal(for: block)
        #expect(model.conflictCount == 0)
        #expect(model.flatTextForWriting().contains("tweaked main line"))
    }

    @Test func applyEditedFullTextHandlesDeletion() async throws {
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
        let originalBlock = try #require(model.allConflictBlocks().first)
        // Conflict: local "main line\n", remote "feature line\n".
        // RESULT pane shows: ["main line", "feature line"] = 2 lines.
        // Simulate user deleting the remote line.
        model.applyEditedFullText("main line\n")
        let block = try #require(model.allConflictBlocks().first)
        #expect(block.local.contains("main line"))
        #expect(block.remote == "")
        _ = originalBlock
    }

    @Test func applyEditedFullTextAbsorbsInsertedLinesIntoLocalHunk() async throws {
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
        // Conflict: local "main line\n", remote "feature line\n".
        // RESULT (markerless, stacked) = "main line\nfeature line\n".
        // User adds a new line inside LOCAL hunk by typing Enter after
        // "main line". New buffer = "main line\nextra\nfeature line\n".
        model.applyEditedFullText("main line\nextra\nfeature line\n")
        let block = try #require(model.allConflictBlocks().first)
        #expect(block.local.contains("main line"))
        #expect(block.local.contains("extra"))
        #expect(block.remote.contains("feature line"))
    }

    @Test func applyEditedFullTextSkipsBaseRowsWhenShowBaseIsOn() async throws {
        // Build a zdiff3-style conflict with BASE.
        let model = MergeConflictTabModel(
            worktreePath: URL(fileURLWithPath: "/tmp/unused"),
            relativePath: "a.txt",
            gitService: GitService()
        )
        model.resultText = "<<<<<<< HEAD\nL\n||||||| ancestor\nB\n=======\nR\n>>>>>>> feature\n"
        model.reparse()
        let block = try #require(model.allConflictBlocks().first)
        #expect(block.base == "B\n")
        // With showBase ON, RESULT pane shows L, B, R (3 rows).
        // User edits L to "L-edited". New buffer = "L-edited\nB\nR\n".
        model.applyEditedFullText("L-edited\nB\nR\n", showBase: true)
        let updated = try #require(model.allConflictBlocks().first)
        #expect(updated.local.contains("L-edited"))
        #expect(updated.remote.contains("R")) // unchanged, NOT "B"
        #expect(updated.base == "B\n") // BASE preserved as-is
        _ = block
    }

    @Test func applyEditedFullTextAppendsTrailingLinesAtEndOfFile() async throws {
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
        let block = try #require(model.allConflictBlocks().first)
        model.acceptLocal(for: block)
        // After accept LOCAL, the file is "main line\n" (a single .text region).
        // User appends a new line at the end.
        model.applyEditedFullText("main line\nappended\n")
        #expect(model.flatTextForWriting().contains("appended"))
    }

    @Test func acceptAfterEditedHunkUsesUpdatedLineRanges() async throws {
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
        // Edit the LOCAL hunk to add a new line.
        // Original RESULT pane content (markerless, stacked):
        //   "main line\nfeature line\n"
        // After insert in LOCAL: "main line\nextra local\nfeature line\n"
        model.applyEditedFullText("main line\nextra local\nfeature line\n")
        let block = try #require(model.allConflictBlocks().first)
        #expect(block.local.contains("extra local"))
        // Now accept LOCAL. The accept must replace the FULL marker
        // block in resultText, even though the block's line count
        // grew. After accept: conflictCount == 0, and the file
        // contains both LOCAL lines without any leftover markers.
        model.acceptLocal(for: block)
        #expect(model.conflictCount == 0)
        let flat = model.flatTextForWriting()
        #expect(flat.contains("main line"))
        #expect(flat.contains("extra local"))
        #expect(!flat.contains("<<<<<<<"))
        #expect(!flat.contains("======="))
        #expect(!flat.contains(">>>>>>>"))
    }

    @Test func setRowContentRoutesToRemoteWhenLocalHunkIsEmpty() async throws {
        // Regression test: when LOCAL is empty (e.g., addedByThem),
        // visual row 0 of the conflict belongs to REMOTE, not LOCAL.
        // setRowContent must route the edit accordingly.
        let model = MergeConflictTabModel(
            worktreePath: URL(fileURLWithPath: "/tmp/unused"),
            relativePath: "a.txt",
            gitService: GitService()
        )
        // Seed the model's regions manually with a single empty-local
        // conflict. resultText needs to match so reparse() agrees.
        let block = ConflictBlock(
            local: "",
            base: nil,
            remote: "added by them\n",
            localLabel: "HEAD",
            remoteLabel: "feature",
            lineRangeInMerged: 0 ... 2
        )
        model.resultText = "<<<<<<< HEAD\n=======\nadded by them\n>>>>>>> feature\n"
        model.reparse()
        #expect(model.conflictCount == 1)
        // Row 0 is REMOTE's first line (no LOCAL rows in this conflict).
        model.setRowContent(at: 0, to: "tweaked")
        let updated = try #require(model.allConflictBlocks().first)
        #expect(updated.local == "") // LOCAL untouched
        #expect(updated.remote.contains("tweaked"))
        _ = block // silence unused
    }
}
