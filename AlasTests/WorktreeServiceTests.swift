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
    @Test func removeDeletesCleanWorktreeContainingSubmodule() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        let submoduleRepo = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-submodule-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: submoduleRepo) }
        try FileManager.default.createDirectory(at: submoduleRepo, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: submoduleRepo)
        try "initial".write(
            to: submoduleRepo.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        _ = try await Process.git(["add", "tracked.txt"], cwd: submoduleRepo)
        _ = try await Process.git(["commit", "-q", "-m", "submodule init"], cwd: submoduleRepo)

        _ = try await Process.git(
            ["-c", "protocol.file.allow=always", "submodule", "add", "-q", submoduleRepo.path, "Deps/Submodule"],
            cwd: repo
        )
        _ = try await Process.git(["commit", "-q", "-am", "add submodule"], cwd: repo)

        let dest = repo.deletingLastPathComponent().appendingPathComponent("\(repo.lastPathComponent)-submodule")
        defer { try? FileManager.default.removeItem(at: dest) }
        let svc = WorktreeService()
        let wt = try await svc.add(
            repoPath: repo, base: "main", branch: "feat/submodule",
            destination: dest, projectId: "p"
        )
        _ = try await Process.git(
            ["-c", "protocol.file.allow=always", "submodule", "update", "--init", "-q"],
            cwd: dest
        )

        try await svc.remove(repoPath: repo, worktree: wt, deleteBranchIfMerged: false)

        let listed = try await svc.list(repoPath: repo, projectId: "p")
        #expect(listed.count == 1)
        #expect(!FileManager.default.fileExists(atPath: dest.path))
    }

    @Test func removeDoesNotForceDeleteIgnoredDirtySubmodule() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        let submoduleRepo = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-submodule-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: submoduleRepo) }
        try FileManager.default.createDirectory(at: submoduleRepo, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: submoduleRepo)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "submodule init"], cwd: submoduleRepo)

        _ = try await Process.git(
            ["-c", "protocol.file.allow=always", "submodule", "add", "-q", submoduleRepo.path, "Deps/Submodule"],
            cwd: repo
        )
        _ = try await Process.git(["commit", "-q", "-am", "add submodule"], cwd: repo)

        let dest = repo.deletingLastPathComponent()
            .appendingPathComponent("\(repo.lastPathComponent)-ignored-dirty-submodule")
        defer { try? FileManager.default.removeItem(at: dest) }
        let svc = WorktreeService()
        let wt = try await svc.add(
            repoPath: repo, base: "main", branch: "feat/ignored-dirty-submodule",
            destination: dest, projectId: "p"
        )
        _ = try await Process.git(
            ["-c", "protocol.file.allow=always", "submodule", "update", "--init", "-q"],
            cwd: dest
        )
        _ = try await Process.git(["config", "submodule.Deps/Submodule.ignore", "all"], cwd: dest)
        try "dirty".write(
            to: dest.appendingPathComponent("Deps/Submodule/tracked.txt"),
            atomically: true,
            encoding: .utf8
        )

        await #expect(throws: WorktreeService.WorktreeError.self) {
            try await svc.remove(repoPath: repo, worktree: wt, deleteBranchIfMerged: false)
        }
        #expect(FileManager.default.fileExists(atPath: dest.path))
    }

    @Test func removeDoesNotForceDeleteHiddenUntrackedFile() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        let submoduleRepo = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-submodule-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: submoduleRepo) }
        try FileManager.default.createDirectory(at: submoduleRepo, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: submoduleRepo)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "submodule init"], cwd: submoduleRepo)

        _ = try await Process.git(
            ["-c", "protocol.file.allow=always", "submodule", "add", "-q", submoduleRepo.path, "Deps/Submodule"],
            cwd: repo
        )
        _ = try await Process.git(["commit", "-q", "-am", "add submodule"], cwd: repo)

        let dest = repo.deletingLastPathComponent()
            .appendingPathComponent("\(repo.lastPathComponent)-hidden-untracked")
        defer { try? FileManager.default.removeItem(at: dest) }
        let svc = WorktreeService()
        let wt = try await svc.add(
            repoPath: repo, base: "main", branch: "feat/hidden-untracked",
            destination: dest, projectId: "p"
        )
        _ = try await Process.git(
            ["-c", "protocol.file.allow=always", "submodule", "update", "--init", "-q"],
            cwd: dest
        )
        _ = try await Process.git(["config", "status.showUntrackedFiles", "no"], cwd: dest)
        try "keep me".write(
            to: dest.appendingPathComponent("untracked.txt"),
            atomically: true,
            encoding: .utf8
        )

        await #expect(throws: WorktreeService.WorktreeError.self) {
            try await svc.remove(repoPath: repo, worktree: wt, deleteBranchIfMerged: false)
        }
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("untracked.txt").path))
    }

    @Test func removeDoesNotForceDeleteSubmoduleHiddenUntrackedFile() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        let submoduleRepo = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-submodule-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: submoduleRepo) }
        try FileManager.default.createDirectory(at: submoduleRepo, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: submoduleRepo)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "submodule init"], cwd: submoduleRepo)

        _ = try await Process.git(
            ["-c", "protocol.file.allow=always", "submodule", "add", "-q", submoduleRepo.path, "Deps/Submodule"],
            cwd: repo
        )
        _ = try await Process.git(["commit", "-q", "-am", "add submodule"], cwd: repo)

        let dest = repo.deletingLastPathComponent()
            .appendingPathComponent("\(repo.lastPathComponent)-submodule-hidden-untracked")
        defer { try? FileManager.default.removeItem(at: dest) }
        let svc = WorktreeService()
        let wt = try await svc.add(
            repoPath: repo, base: "main", branch: "feat/submodule-hidden-untracked",
            destination: dest, projectId: "p"
        )
        _ = try await Process.git(
            ["-c", "protocol.file.allow=always", "submodule", "update", "--init", "-q"],
            cwd: dest
        )
        let submodulePath = dest.appendingPathComponent("Deps/Submodule")
        _ = try await Process.git(["config", "status.showUntrackedFiles", "no"], cwd: submodulePath)
        try "keep me".write(
            to: submodulePath.appendingPathComponent("hidden.txt"),
            atomically: true,
            encoding: .utf8
        )

        await #expect(throws: WorktreeService.WorktreeError.self) {
            try await svc.remove(repoPath: repo, worktree: wt, deleteBranchIfMerged: false)
        }
        #expect(FileManager.default.fileExists(atPath: submodulePath.appendingPathComponent("hidden.txt").path))
    }

    @Test func removeDoesNotForceDeleteNestedSubmoduleGitlinkChangeHiddenByIgnoreConfig() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        let nestedRepo = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-nested-submodule-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: nestedRepo) }
        try FileManager.default.createDirectory(at: nestedRepo, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: nestedRepo)
        try "one".write(to: nestedRepo.appendingPathComponent("nested.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "nested.txt"], cwd: nestedRepo)
        _ = try await Process.git(["commit", "-q", "-m", "nested one"], cwd: nestedRepo)
        let firstNestedSha = try await Process.git(["rev-parse", "HEAD"], cwd: nestedRepo)
        try "two".write(to: nestedRepo.appendingPathComponent("nested.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["commit", "-q", "-am", "nested two"], cwd: nestedRepo)
        let secondNestedSha = try await Process.git(["rev-parse", "HEAD"], cwd: nestedRepo)

        let submoduleRepo = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-submodule-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: submoduleRepo) }
        try FileManager.default.createDirectory(at: submoduleRepo, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: submoduleRepo)
        _ = try await Process.git(
            ["-c", "protocol.file.allow=always", "submodule", "add", "-q", nestedRepo.path, "Nested"],
            cwd: submoduleRepo
        )
        _ = try await Process.git(["checkout", "-q", firstNestedSha.stdout.trimmingCharacters(in: .whitespacesAndNewlines)], cwd: submoduleRepo.appendingPathComponent("Nested"))
        _ = try await Process.git(["add", "."], cwd: submoduleRepo)
        _ = try await Process.git(["commit", "-q", "-m", "add nested submodule"], cwd: submoduleRepo)

        _ = try await Process.git(
            ["-c", "protocol.file.allow=always", "submodule", "add", "-q", submoduleRepo.path, "Deps/Submodule"],
            cwd: repo
        )
        _ = try await Process.git(["commit", "-q", "-am", "add submodule"], cwd: repo)

        let dest = repo.deletingLastPathComponent()
            .appendingPathComponent("\(repo.lastPathComponent)-nested-submodule-change")
        defer { try? FileManager.default.removeItem(at: dest) }
        let svc = WorktreeService()
        let wt = try await svc.add(
            repoPath: repo, base: "main", branch: "feat/nested-submodule-change",
            destination: dest, projectId: "p"
        )
        _ = try await Process.git(
            ["-c", "protocol.file.allow=always", "submodule", "update", "--init", "--recursive", "-q"],
            cwd: dest
        )

        let submodulePath = dest.appendingPathComponent("Deps/Submodule")
        let nestedPath = submodulePath.appendingPathComponent("Nested")
        _ = try await Process.git(["config", "submodule.Nested.ignore", "all"], cwd: submodulePath)
        _ = try await Process.git(
            ["checkout", "-q", secondNestedSha.stdout.trimmingCharacters(in: .whitespacesAndNewlines)],
            cwd: nestedPath
        )

        await #expect(throws: WorktreeService.WorktreeError.self) {
            try await svc.remove(repoPath: repo, worktree: wt, deleteBranchIfMerged: false)
        }
        #expect(FileManager.default.fileExists(atPath: nestedPath.path))
    }

    @Test func removeDoesNotForceDeleteSubmoduleLocalBranch() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        let submoduleRepo = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-submodule-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: submoduleRepo) }
        try FileManager.default.createDirectory(at: submoduleRepo, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: submoduleRepo)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "submodule init"], cwd: submoduleRepo)

        _ = try await Process.git(
            ["-c", "protocol.file.allow=always", "submodule", "add", "-q", submoduleRepo.path, "Deps/Submodule"],
            cwd: repo
        )
        _ = try await Process.git(["commit", "-q", "-am", "add submodule"], cwd: repo)

        let dest = repo.deletingLastPathComponent()
            .appendingPathComponent("\(repo.lastPathComponent)-submodule-local-branch")
        defer { try? FileManager.default.removeItem(at: dest) }
        let svc = WorktreeService()
        let wt = try await svc.add(
            repoPath: repo, base: "main", branch: "feat/submodule-local-branch",
            destination: dest, projectId: "p"
        )
        _ = try await Process.git(
            ["-c", "protocol.file.allow=always", "submodule", "update", "--init", "-q"],
            cwd: dest
        )

        let submodulePath = dest.appendingPathComponent("Deps/Submodule")
        let recordedSha = try await Process.git(["rev-parse", "HEAD"], cwd: submodulePath)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await Process.git(["switch", "-q", "-c", "local-only"], cwd: submodulePath)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "local submodule commit"], cwd: submodulePath)
        _ = try await Process.git(["checkout", "-q", recordedSha], cwd: submodulePath)

        await #expect(throws: WorktreeService.WorktreeError.self) {
            try await svc.remove(repoPath: repo, worktree: wt, deleteBranchIfMerged: false)
        }
        #expect(FileManager.default.fileExists(atPath: submodulePath.path))
    }

    // Note: ExtraBranchAtRemoteCommit was removed for the same reason as the
    // tag-name tests above — a local branch pointing at a remote-reachable
    // commit is "clean enough" under reachability semantics. The
    // LocalBranch test still covers truly local branch commits.

    @Test func removeDoesNotForceDeleteSubmoduleLocalOnlyTag() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        let submoduleRepo = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-submodule-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: submoduleRepo) }
        try FileManager.default.createDirectory(at: submoduleRepo, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: submoduleRepo)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "submodule init"], cwd: submoduleRepo)

        _ = try await Process.git(
            ["-c", "protocol.file.allow=always", "submodule", "add", "-q", submoduleRepo.path, "Deps/Submodule"],
            cwd: repo
        )
        _ = try await Process.git(["commit", "-q", "-am", "add submodule"], cwd: repo)

        let dest = repo.deletingLastPathComponent()
            .appendingPathComponent("\(repo.lastPathComponent)-submodule-local-tag")
        defer { try? FileManager.default.removeItem(at: dest) }
        let svc = WorktreeService()
        let wt = try await svc.add(
            repoPath: repo, base: "main", branch: "feat/submodule-local-tag",
            destination: dest, projectId: "p"
        )
        _ = try await Process.git(
            ["-c", "protocol.file.allow=always", "submodule", "update", "--init", "-q"],
            cwd: dest
        )

        let submodulePath = dest.appendingPathComponent("Deps/Submodule")
        let recordedSha = try await Process.git(["rev-parse", "HEAD"], cwd: submodulePath)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "tagged local commit"], cwd: submodulePath)
        _ = try await Process.git(["tag", "local-only"], cwd: submodulePath)
        _ = try await Process.git(["checkout", "-q", recordedSha], cwd: submodulePath)

        await #expect(throws: WorktreeService.WorktreeError.self) {
            try await svc.remove(repoPath: repo, worktree: wt, deleteBranchIfMerged: false)
        }
        #expect(FileManager.default.fileExists(atPath: submodulePath.path))
    }

    // Note: three previous tests (LocalTagOnRemoteCommit, RetargetedRemoteTag,
    // RetaggedAnnotatedRemoteTag) were removed alongside the script rewrite.
    // The new check is reachability-based: a local tag whose target commit
    // is already reachable from any remote ref is now considered "clean
    // enough" to force-delete — the data is in the remote; only the local
    // label differs. The remaining LocalOnlyTag test still covers the case
    // where the tag's target commit is itself local-only.

    @Test func removeDoesNotForceDeleteSubmoduleReflogOnlyCommit() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        let submoduleRepo = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-submodule-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: submoduleRepo) }
        try FileManager.default.createDirectory(at: submoduleRepo, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: submoduleRepo)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "submodule init"], cwd: submoduleRepo)

        _ = try await Process.git(
            ["-c", "protocol.file.allow=always", "submodule", "add", "-q", submoduleRepo.path, "Deps/Submodule"],
            cwd: repo
        )
        _ = try await Process.git(["commit", "-q", "-am", "add submodule"], cwd: repo)

        let dest = repo.deletingLastPathComponent()
            .appendingPathComponent("\(repo.lastPathComponent)-submodule-reflog")
        defer { try? FileManager.default.removeItem(at: dest) }
        let svc = WorktreeService()
        let wt = try await svc.add(
            repoPath: repo, base: "main", branch: "feat/submodule-reflog",
            destination: dest, projectId: "p"
        )
        _ = try await Process.git(
            ["-c", "protocol.file.allow=always", "submodule", "update", "--init", "-q"],
            cwd: dest
        )

        let submodulePath = dest.appendingPathComponent("Deps/Submodule")
        let recordedSha = try await Process.git(["rev-parse", "HEAD"], cwd: submodulePath)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "reflog only"], cwd: submodulePath)
        _ = try await Process.git(["checkout", "-q", recordedSha], cwd: submodulePath)

        await #expect(throws: WorktreeService.WorktreeError.self) {
            try await svc.remove(repoPath: repo, worktree: wt, deleteBranchIfMerged: false)
        }
        #expect(FileManager.default.fileExists(atPath: submodulePath.path))
    }

    @Test func removePropagatesOriginalSubmoduleErrorWhenHelperFails() async throws {
        // When the safety helpers throw (e.g. the submodule's gitdir is
        // corrupt / unreadable / times out), `remove()` must NOT swallow
        // the original "submodules cannot be moved" stderr from
        // `git worktree remove` and surface the helper's failure instead.
        // It should rethrow `WorktreeError.gitFailed` with the original
        // stderr and leave the worktree on disk.
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        let submoduleRepo = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-submodule-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: submoduleRepo) }
        try FileManager.default.createDirectory(at: submoduleRepo, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: submoduleRepo)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "submodule init"], cwd: submoduleRepo)

        _ = try await Process.git(
            ["-c", "protocol.file.allow=always", "submodule", "add", "-q", submoduleRepo.path, "Deps/Submodule"],
            cwd: repo
        )
        _ = try await Process.git(["commit", "-q", "-am", "add submodule"], cwd: repo)

        let dest = repo.deletingLastPathComponent()
            .appendingPathComponent("\(repo.lastPathComponent)-submodule-broken")
        defer { try? FileManager.default.removeItem(at: dest) }
        let svc = WorktreeService()
        let wt = try await svc.add(
            repoPath: repo, base: "main", branch: "feat/submodule-broken",
            destination: dest, projectId: "p"
        )
        _ = try await Process.git(
            ["-c", "protocol.file.allow=always", "submodule", "update", "--init", "-q"],
            cwd: dest
        )

        // Corrupt the submodule's gitfile so `git submodule foreach`
        // inside the safety helpers fails. The submodule directory and
        // .gitmodules entry still exist, so the parent's `git worktree
        // remove` still trips the "submodules cannot be moved" guard.
        let gitfile = dest.appendingPathComponent("Deps/Submodule/.git")
        try? "gitdir: /nonexistent/broken/path\n".write(to: gitfile, atomically: true, encoding: .utf8)

        do {
            try await svc.remove(repoPath: repo, worktree: wt, deleteBranchIfMerged: false)
            Issue.record("expected throw")
        } catch let WorktreeService.WorktreeError.gitFailed(stderr) {
            // Must be the original git-worktree-remove stderr, not the
            // helper's internal failure (e.g., "not a git repository").
            let lower = stderr.lowercased()
            #expect(
                lower.contains("submodules") && lower.contains("cannot be moved"),
                "expected original submodules error, got: \(stderr)"
            )
        }
        #expect(FileManager.default.fileExists(atPath: dest.path))
    }

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

    @Test func addSucceedsWhenLfsHookFailsAfterCheckout() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        // Add a real committed file so checkout has work to do.
        try "hello".write(
            to: repo.appendingPathComponent("dummy.txt"),
            atomically: true, encoding: .utf8
        )
        _ = try await Process.git(["add", "."], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "add file"], cwd: repo)

        // Set up a custom hooks directory with a post-checkout hook that
        // mimics Git LFS failing because git-lfs is missing.
        let hooksDir = repo.appendingPathComponent("custom-hooks")
        try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        let hook = hooksDir.appendingPathComponent("post-checkout")
        let hookScript = """
        #!/bin/bash
        echo "This repository is configured for Git LFS but git-lfs was not found on your path."
        exit 1
        """
        try hookScript.write(to: hook, atomically: true, encoding: .utf8)
        _ = try await Process.git(["config", "--local", "core.hooksPath", hooksDir.path], cwd: repo)
        // Make the hook executable.
        _ = try await Process.run("/bin/chmod", args: ["+x", hook.path], cwd: repo)

        let dest = repo.deletingLastPathComponent()
            .appendingPathComponent("\(repo.lastPathComponent)-hook")
        defer { try? FileManager.default.removeItem(at: dest) }
        let svc = WorktreeService()
        let wt = try await svc.add(
            repoPath: repo, base: "main", branch: "feat/hook",
            destination: dest, projectId: "p"
        )
        #expect(wt.branch == "feat/hook")
        #expect(FileManager.default.fileExists(atPath: dest.path))
        let listed = try await svc.list(repoPath: repo, projectId: "p")
        #expect(listed.count == 2)
    }
}
