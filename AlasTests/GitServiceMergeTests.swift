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
}
