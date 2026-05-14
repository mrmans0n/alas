import Testing
import Foundation
@testable import Alas

// Swift Testing parallelizes tests within a suite by default, and
// `-parallel-testing-enabled NO` only disables xctest-level parallelism.
// Each test here spins up an ephemeral repo and shells out to git; running
// four of those concurrently on macos-26 has reproducibly hung at
// `git branch --list` after `git branch -d` (presumably git/dyld/codesign
// contention). Force-serialize so each git invocation runs cleanly.
@Suite(.serialized)
struct WorktreeServiceTests {
    private func makeRepo() async throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-wt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: dir)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "init"], cwd: dir)
        return dir
    }

    @Test func listFindsMain() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let svc = WorktreeService()
        let trees = try await svc.list(repoPath: repo, projectId: "p")
        #expect(trees.count == 1)
        #expect(trees.first?.branch == "main")
    }

    @Test func addCreatesWorktree() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let dest = repo.deletingLastPathComponent().appendingPathComponent("\(repo.lastPathComponent)-feat")
        defer { try? FileManager.default.removeItem(at: dest) }
        let svc = WorktreeService()
        let wt = try await svc.add(
            repoPath: repo, base: "main", branch: "feat/x",
            destination: dest, projectId: "p"
        )
        #expect(wt.branch == "feat/x")
        #expect(FileManager.default.fileExists(atPath: dest.path))

        let listed = try await svc.list(repoPath: repo, projectId: "p")
        #expect(listed.count == 2)
    }

    @Test func removeDeletesWorktree() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let dest = repo.deletingLastPathComponent().appendingPathComponent("\(repo.lastPathComponent)-rm")
        let svc = WorktreeService()
        let wt = try await svc.add(
            repoPath: repo, base: "main", branch: "feat/rm",
            destination: dest, projectId: "p"
        )
        try await svc.remove(repoPath: repo, worktree: wt, deleteBranchIfMerged: false)
        let listed = try await svc.list(repoPath: repo, projectId: "p")
        #expect(listed.count == 1)
    }

    @Test func removeWithDeleteBranchUsesRealBranchName() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        // Path basename "feat-rm" differs from branch "feat/rm" — proves we use
        // the branch name from the Worktree, not derived from the path.
        let dest = repo.deletingLastPathComponent().appendingPathComponent("\(repo.lastPathComponent)-feat-rm")
        let svc = WorktreeService()
        let wt = try await svc.add(
            repoPath: repo, base: "main", branch: "feat/rm",
            destination: dest, projectId: "p"
        )
        try await svc.remove(repoPath: repo, worktree: wt, deleteBranchIfMerged: true)
        // The worktree is gone.
        let listed = try await svc.list(repoPath: repo, projectId: "p")
        #expect(listed.count == 1)
        // The branch is gone too (because git allows -d on the same branch the
        // worktree was on once the worktree is removed). If the wrong name had
        // been derived from the path basename ("feat-rm-..."), `git branch -d`
        // would have silently no-op'd via try? and `feat/rm` would still exist.
        let branches = try await Process.git(["branch", "--list", "feat/rm"], cwd: repo)
        #expect(branches.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

extension WorktreeServiceTests {
    @Test func removeFailsOnDirtyWorktreeWithoutForce() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let dest = repo.deletingLastPathComponent().appendingPathComponent("\(repo.lastPathComponent)-dirty")
        defer { try? FileManager.default.removeItem(at: dest) }
        let svc = WorktreeService()
        let wt = try await svc.add(
            repoPath: repo, base: "main", branch: "feat/dirty",
            destination: dest, projectId: "p"
        )
        // Make the worktree dirty by writing an untracked file.
        try "hello".write(
            to: dest.appendingPathComponent("untracked.txt"),
            atomically: true, encoding: .utf8
        )

        await #expect(throws: WorktreeService.WorktreeError.self) {
            try await svc.remove(repoPath: repo, worktree: wt, deleteBranchIfMerged: false)
        }
    }

    @Test func removeWithForceSucceedsOnDirtyWorktree() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let dest = repo.deletingLastPathComponent().appendingPathComponent("\(repo.lastPathComponent)-force")
        let svc = WorktreeService()
        let wt = try await svc.add(
            repoPath: repo, base: "main", branch: "feat/force",
            destination: dest, projectId: "p"
        )
        try "hello".write(
            to: dest.appendingPathComponent("untracked.txt"),
            atomically: true, encoding: .utf8
        )

        try await svc.remove(repoPath: repo, worktree: wt, deleteBranchIfMerged: false, force: true)

        let listed = try await svc.list(repoPath: repo, projectId: "p")
        #expect(listed.count == 1) // only main remains
    }
}

extension WorktreeServiceTests {
    @Test func addForExistingBranchSucceedsWithoutDashB() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        _ = try await Process.git(["branch", "nacho/starfin-deprecation"], cwd: repo)
        let dest = repo.deletingLastPathComponent().appendingPathComponent("\(repo.lastPathComponent)-existing")
        defer { try? FileManager.default.removeItem(at: dest) }
        let svc = WorktreeService()
        let wt = try await svc.add(
            repoPath: repo, base: "main", branch: "nacho/starfin-deprecation",
            destination: dest, projectId: "p"
        )
        #expect(wt.branch == "nacho/starfin-deprecation")
        #expect(FileManager.default.fileExists(atPath: dest.path))
        let listed = try await svc.list(repoPath: repo, projectId: "p")
        #expect(listed.count == 2)
    }

    @Test func errorMessagePropagatesGitStderr() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let dest = repo.deletingLastPathComponent().appendingPathComponent("\(repo.lastPathComponent)-conflict")
        defer { try? FileManager.default.removeItem(at: dest) }
        // Create a file at the destination so git worktree add fails.
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "block".write(to: dest, atomically: true, encoding: .utf8)
        let svc = WorktreeService()
        do {
            _ = try await svc.add(
                repoPath: repo, base: "main", branch: "feat/conflict",
                destination: dest, projectId: "p"
            )
            Issue.record("expected worktree add to fail")
        } catch let error as WorktreeService.WorktreeError {
            let msg = error.localizedDescription
            #expect(!msg.contains("WorktreeError error"))
            #expect(msg.count > 10)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }
}

extension WorktreeServiceTests {
    @Test func addSucceedsWhenLfsFilterIsMissing() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        // Configure a broken LFS filter so git would fail without overrides.
        _ = try await Process.git(
            ["config", "--local", "filter.lfs.process", "/nonexistent/git-lfs filter-process"],
            cwd: repo
        )
        _ = try await Process.git(
            ["config", "--local", "filter.lfs.smudge", "/nonexistent/git-lfs smudge"],
            cwd: repo
        )
        _ = try await Process.git(
            ["config", "--local", "filter.lfs.clean", "/nonexistent/git-lfs clean"],
            cwd: repo
        )
        _ = try await Process.git(
            ["config", "--local", "filter.lfs.required", "true"],
            cwd: repo
        )

        // Add .gitattributes and a file that triggers the filter.
        try "*.txt filter=lfs".write(
            to: repo.appendingPathComponent(".gitattributes"),
            atomically: true, encoding: .utf8
        )
        try "hello".write(
            to: repo.appendingPathComponent("dummy.txt"),
            atomically: true, encoding: .utf8
        )
        _ = try await Process.git(["add", "."], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "add lfs file"], cwd: repo)

        let dest = repo.deletingLastPathComponent()
            .appendingPathComponent("\(repo.lastPathComponent)-lfs")
        defer { try? FileManager.default.removeItem(at: dest) }
        let svc = WorktreeService()
        let wt = try await svc.add(
            repoPath: repo, base: "main", branch: "feat/lfs",
            destination: dest, projectId: "p"
        )
        #expect(wt.branch == "feat/lfs")
        #expect(FileManager.default.fileExists(atPath: dest.path))
    }
}
