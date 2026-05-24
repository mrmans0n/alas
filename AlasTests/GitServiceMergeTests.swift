import Testing
import Foundation
@testable import Alas

@Suite(.serialized)
struct GitServiceMergeTests {
    fileprivate static func makeRepo() async throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-merge-\(UUID().uuidString)")
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

    /// Creates two branches `main` and `feature` whose tips both modify the
    /// same line of `a.txt`, so a merge will produce a conflict.
    fileprivate static func makeConflictingBranches(_ repo: URL) async throws {
        try writeFile(repo, "a.txt", "base\n")
        _ = try await Process.git(["add", "a.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "base"], cwd: repo)
        _ = try await Process.git(["checkout", "-q", "-b", "feature"], cwd: repo)
        try writeFile(repo, "a.txt", "feature change\n")
        _ = try await Process.git(["commit", "-q", "-am", "feature change"], cwd: repo)
        _ = try await Process.git(["checkout", "-q", "main"], cwd: repo)
        try writeFile(repo, "a.txt", "main change\n")
        _ = try await Process.git(["commit", "-q", "-am", "main change"], cwd: repo)
    }

    @Test func mergeStateIsNilWhenNothingInProgress() async throws {
        let repo = try await Self.makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try Self.writeFile(repo, "a.txt", "hi\n")
        _ = try await Process.git(["add", "a.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "init"], cwd: repo)

        let svc = GitService()
        let state = try await svc.mergeState(worktreePath: repo)
        #expect(state == nil)
    }

    @Test func mergeStateDetectsMergeInProgress() async throws {
        let repo = try await Self.makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Self.makeConflictingBranches(repo)

        // Trigger a conflicting merge (exit code non-zero, MERGE_HEAD set).
        _ = try await Process.git(["merge", "feature", "--no-edit"], cwd: repo)

        let svc = GitService()
        let state = try await svc.mergeState(worktreePath: repo)
        guard case .merge(let source) = state else {
            Issue.record("expected .merge state, got \(String(describing: state))")
            return
        }
        #expect(source == "feature" || source == nil)  // git versions vary
    }

    @Test func mergeStateDetectsRebaseInProgress() async throws {
        let repo = try await Self.makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Self.makeConflictingBranches(repo)

        _ = try await Process.git(["checkout", "-q", "feature"], cwd: repo)
        _ = try await Process.git(["rebase", "main"], cwd: repo)

        let svc = GitService()
        let state = try await svc.mergeState(worktreePath: repo)
        guard case .rebase(let plan) = state else {
            Issue.record("expected .rebase state, got \(String(describing: state))")
            return
        }
        #expect(plan.commits.count >= 1)
    }

    @Test func mergeStateDetectsCherryPickInProgress() async throws {
        let repo = try await Self.makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Self.makeConflictingBranches(repo)

        // Cherry-pick feature's tip onto main → conflict, CHERRY_PICK_HEAD set.
        let featureSha = try await Process.git(["rev-parse", "feature"], cwd: repo).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await Process.git(["cherry-pick", featureSha], cwd: repo)

        let svc = GitService()
        let state = try await svc.mergeState(worktreePath: repo)
        guard case .cherryPick(let sha, _) = state else {
            Issue.record("expected .cherryPick state, got \(String(describing: state))")
            return
        }
        #expect(sha.hasPrefix(featureSha.prefix(7)))
    }

    @Test func conflictedFileReadsAllThreeSides() async throws {
        let repo = try await Self.makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Self.makeConflictingBranches(repo)
        _ = try await Process.git(["merge", "feature", "--no-edit"], cwd: repo)

        let svc = GitService()
        let file = try await svc.conflictedFile(worktreePath: repo, relativePath: "a.txt")
        #expect(file.relativePath == "a.txt")
        #expect(file.kind == .bothModified)
        #expect(file.base == "base\n")
        #expect(file.local == "main change\n")
        #expect(file.remote == "feature change\n")
        #expect(file.merged.contains("<<<<<<<"))
        #expect(file.merged.contains(">>>>>>>"))
        #expect(file.isBinary == false)
    }

    @Test func conflictedFileDetectsBinary() async throws {
        let repo = try await Self.makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        // Set up a conflicting binary file by writing different bytes on each branch.
        let bin = Data([0x00, 0x01, 0x02, 0x03, 0x00, 0xFF])
        try bin.write(to: repo.appendingPathComponent("a.bin"))
        _ = try await Process.git(["add", "a.bin"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "base"], cwd: repo)
        _ = try await Process.git(["checkout", "-q", "-b", "feature"], cwd: repo)
        try Data([0x00, 0x01, 0x02, 0xAA, 0x00, 0xFF]).write(to: repo.appendingPathComponent("a.bin"))
        _ = try await Process.git(["commit", "-q", "-am", "feature"], cwd: repo)
        _ = try await Process.git(["checkout", "-q", "main"], cwd: repo)
        try Data([0x00, 0x01, 0x02, 0xBB, 0x00, 0xFF]).write(to: repo.appendingPathComponent("a.bin"))
        _ = try await Process.git(["commit", "-q", "-am", "main"], cwd: repo)
        _ = try await Process.git(["merge", "feature", "--no-edit"], cwd: repo)

        let svc = GitService()
        let file = try await svc.conflictedFile(worktreePath: repo, relativePath: "a.bin")
        #expect(file.isBinary == true)
    }

    @Test func mergeReturnsCleanWhenNoConflict() async throws {
        let repo = try await Self.makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try Self.writeFile(repo, "a.txt", "base\n")
        _ = try await Process.git(["add", "a.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "base"], cwd: repo)
        _ = try await Process.git(["checkout", "-q", "-b", "feature"], cwd: repo)
        try Self.writeFile(repo, "b.txt", "new\n")
        _ = try await Process.git(["add", "b.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "add b"], cwd: repo)
        _ = try await Process.git(["checkout", "-q", "main"], cwd: repo)

        let svc = GitService()
        let result = try await svc.merge(worktreePath: repo, branch: "feature")
        #expect(result == .clean)
    }

    @Test func mergeReturnsConflictWhenConflicting() async throws {
        let repo = try await Self.makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Self.makeConflictingBranches(repo)

        let svc = GitService()
        let result = try await svc.merge(worktreePath: repo, branch: "feature")
        guard case .conflict(let files) = result else {
            Issue.record("expected .conflict, got \(result)")
            return
        }
        #expect(files.contains(where: { $0.path == "a.txt" && $0.conflict == .bothModified }))
    }

    @Test func mergeWritesZdiff3MarkersWithBaseSection() async throws {
        let repo = try await Self.makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Self.makeConflictingBranches(repo)
        let svc = GitService()
        _ = try await svc.merge(worktreePath: repo, branch: "feature")
        let merged = try String(contentsOf: repo.appendingPathComponent("a.txt"), encoding: .utf8)
        #expect(merged.contains("|||||||"))  // zdiff3 base marker
    }

    @Test func rebaseReturnsConflictOnConflict() async throws {
        let repo = try await Self.makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Self.makeConflictingBranches(repo)
        _ = try await Process.git(["checkout", "-q", "feature"], cwd: repo)

        let svc = GitService()
        let result = try await svc.rebase(worktreePath: repo, onto: "main")
        guard case .conflict(let files) = result else {
            Issue.record("expected .conflict, got \(result)")
            return
        }
        #expect(files.contains(where: { $0.path == "a.txt" }))
    }

    @Test func cherryPickReturnsConflictOnConflict() async throws {
        let repo = try await Self.makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Self.makeConflictingBranches(repo)
        let featureSha = try await Process.git(["rev-parse", "feature"], cwd: repo).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let svc = GitService()
        let result = try await svc.cherryPick(worktreePath: repo, sha: featureSha)
        guard case .conflict = result else {
            Issue.record("expected .conflict, got \(result)")
            return
        }
    }

    @Test func markResolvedStagesFile() async throws {
        let repo = try await Self.makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Self.makeConflictingBranches(repo)
        let svc = GitService()
        _ = try await svc.merge(worktreePath: repo, branch: "feature")

        // Pretend the user resolved by writing a distinct resolution so it
        // appears in git status as staged (accepting "ours" verbatim would
        // produce content identical to HEAD, which git omits from status).
        try Self.writeFile(repo, "a.txt", "resolved\n")
        try await svc.markResolved(worktreePath: repo, relativePath: "a.txt")

        let changes = try await svc.status(worktreePath: repo)
        let entry = changes.first { $0.path == "a.txt" }
        // After `git add` the file is staged with no remaining conflict.
        #expect(entry?.stage == .staged)
        #expect(entry?.conflict == nil)
    }

    @Test func continueMergeCommitsAndClearsState() async throws {
        let repo = try await Self.makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Self.makeConflictingBranches(repo)
        let svc = GitService()
        _ = try await svc.merge(worktreePath: repo, branch: "feature")
        try Self.writeFile(repo, "a.txt", "main change\n")
        try await svc.markResolved(worktreePath: repo, relativePath: "a.txt")

        let state = try await svc.mergeState(worktreePath: repo)
        guard case .merge = state else { Issue.record("expected merge state")
        return }

        let result = try await svc.continueOperation(worktreePath: repo, op: state!)
        #expect(result == .clean)
        let after = try await svc.mergeState(worktreePath: repo)
        #expect(after == nil)
    }

    @Test func useOursAcceptsHeadContent() async throws {
        let repo = try await Self.makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Self.makeConflictingBranches(repo)
        let svc = GitService()
        _ = try await svc.merge(worktreePath: repo, branch: "feature")

        try await svc.useOurs(worktreePath: repo, relativePath: "a.txt")
        let content = try String(contentsOf: repo.appendingPathComponent("a.txt"), encoding: .utf8)
        #expect(content == "main change\n")
    }

    @Test func useTheirsAcceptsIncomingContent() async throws {
        let repo = try await Self.makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Self.makeConflictingBranches(repo)
        let svc = GitService()
        _ = try await svc.merge(worktreePath: repo, branch: "feature")

        try await svc.useTheirs(worktreePath: repo, relativePath: "a.txt")
        let content = try String(contentsOf: repo.appendingPathComponent("a.txt"), encoding: .utf8)
        #expect(content == "feature change\n")
    }

    @Test func abortMergeRestoresHead() async throws {
        let repo = try await Self.makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Self.makeConflictingBranches(repo)
        let svc = GitService()
        let headBefore = try await Process.git(["rev-parse", "HEAD"], cwd: repo).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await svc.merge(worktreePath: repo, branch: "feature")

        let state = try await svc.mergeState(worktreePath: repo)
        try await svc.abortOperation(worktreePath: repo, op: state!)

        let headAfter = try await Process.git(["rev-parse", "HEAD"], cwd: repo).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(headBefore == headAfter)
        let mergedFile = try String(contentsOf: repo.appendingPathComponent("a.txt"), encoding: .utf8)
        #expect(!mergedFile.contains("<<<<<<<"))
        let after = try await svc.mergeState(worktreePath: repo)
        #expect(after == nil)
    }

    @Test func mergeStateDetectsRebaseApplyInProgress() async throws {
        let repo = try await Self.makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Self.makeConflictingBranches(repo)

        _ = try await Process.git(["checkout", "-q", "feature"], cwd: repo)
        _ = try await Process.git(["-c", "rebase.backend=apply", "rebase", "main"], cwd: repo)

        let svc = GitService()
        let state = try await svc.mergeState(worktreePath: repo)
        guard case .rebase(let plan) = state else {
            Issue.record("expected .rebase via rebase-apply, got \(String(describing: state))")
            return
        }
        #expect(plan.commits.count >= 1)
        #expect(plan.commits.contains { $0.state == .current })
    }

    @Test func mergeStateIgnoresGitAmInProgress() async throws {
        // `git am` also uses .git/rebase-apply but writes an `applying`
        // sentinel instead of `rebasing`. We must not classify it as a rebase
        // (the UI would otherwise drive `rebase --continue/--abort`, which
        // errors with "It looks like 'git am' is in progress").
        let repo = try await Self.makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try Self.writeFile(repo, "a.txt", "base\n")
        _ = try await Process.git(["add", "a.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "base"], cwd: repo)

        // Create a patch that conflicts with the current worktree so `git am`
        // pauses with `.git/rebase-apply/` populated and the `applying` sentinel.
        try Self.writeFile(repo, "a.txt", "in-worktree change\n")

        let patch = """
        From 0000000000000000000000000000000000000000 Mon Sep 17 00:00:00 2001
        From: t <t@e>
        Date: Sun, 24 May 2026 21:56:13 +0200
        Subject: patch

        ---
         a.txt | 2 +-
         1 file changed, 1 insertion(+), 1 deletion(-)

        diff --git a/a.txt b/a.txt
        index 1111111..2222222 100644
        --- a/a.txt
        +++ b/a.txt
        @@ -1 +1 @@
        -base
        +patched
        --
        2.43.0

        """
        let patchURL = repo.appendingPathComponent("conflict.patch")
        try patch.write(to: patchURL, atomically: true, encoding: .utf8)
        _ = try await Process.git(["am", "--3way", patchURL.path], cwd: repo)
        // Confirm git am actually paused (rebase-apply dir exists, with `applying`).
        let applyDir = repo.appendingPathComponent(".git/rebase-apply")
        guard FileManager.default.fileExists(atPath: applyDir.path) else {
            Issue.record("expected git am to leave .git/rebase-apply populated")
            return
        }

        let svc = GitService()
        let state = try await svc.mergeState(worktreePath: repo)
        #expect(state == nil)
    }

    @Test func cherryPickMergeCommitUsesFirstParentMainline() async throws {
        let repo = try await Self.makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        // Build a merge commit on `feature`, then try to cherry-pick it onto `main`.
        try Self.writeFile(repo, "a.txt", "base\n")
        _ = try await Process.git(["add", "a.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "base"], cwd: repo)
        _ = try await Process.git(["checkout", "-q", "-b", "feature"], cwd: repo)
        try Self.writeFile(repo, "b.txt", "from-feature\n")
        _ = try await Process.git(["add", "b.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "add b"], cwd: repo)
        _ = try await Process.git(["checkout", "-q", "main"], cwd: repo)
        try Self.writeFile(repo, "c.txt", "from-main\n")
        _ = try await Process.git(["add", "c.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "add c"], cwd: repo)
        // Create the merge commit on `feature` so it has 2 parents:
        _ = try await Process.git(["checkout", "-q", "feature"], cwd: repo)
        _ = try await Process.git(["-c", "core.editor=true", "merge", "main", "--no-ff"], cwd: repo)
        let mergeSha = try await Process.git(["rev-parse", "HEAD"], cwd: repo).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Hard-reset main to before c.txt was added, then cherry-pick the merge commit.
        _ = try await Process.git(["checkout", "-q", "main"], cwd: repo)
        _ = try await Process.git(["reset", "--hard", "HEAD~1"], cwd: repo)

        let svc = GitService()
        let result = try await svc.cherryPick(worktreePath: repo, sha: mergeSha)
        // Without -m the cherry-pick would error with "is a merge but no -m option was given"
        // and classifyOperationResult would map it to .error. With -m 1 the result should
        // be .clean (merge commit applied cleanly).
        #expect(result == .clean)
    }

    @Test func keepDeletedRemovesFileAndStages() async throws {
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
        // Merge feature → main: ours deleted, theirs modified → DU (deletedByUs)
        let svc = GitService()
        _ = try await svc.merge(worktreePath: repo, branch: "feature")

        try await svc.keepDeleted(worktreePath: repo, relativePath: "a.txt")
        // File must be gone from the worktree.
        let exists = FileManager.default.fileExists(atPath: repo.appendingPathComponent("a.txt").path)
        #expect(exists == false)
        // The conflict is resolved: a.txt must no longer appear with a conflict flag.
        // For a DU conflict, HEAD already had the file deleted; `git rm` removes
        // the worktree copy and clears the index entry, so a.txt won't appear in
        // `git status` at all (index and HEAD agree on "absent"). Either absent
        // or present-without-conflict is acceptable.
        let changes = try await svc.status(worktreePath: repo)
        let entry = changes.first { $0.path == "a.txt" }
        #expect(entry?.conflict == nil)
    }
}
