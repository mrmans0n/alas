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

}
