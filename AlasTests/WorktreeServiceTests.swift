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

    @Test func listUsesEachHeadCommitTimeWhenRefsArePacked() async throws {
        let repo = try await makeRepo()
        let root = repo.deletingLastPathComponent()
        let one = root.appendingPathComponent("\(repo.lastPathComponent)-packed-one")
        let two = root.appendingPathComponent("\(repo.lastPathComponent)-packed-two")
        defer {
            try? FileManager.default.removeItem(at: one)
            try? FileManager.default.removeItem(at: two)
            try? FileManager.default.removeItem(at: repo)
        }

        _ = try await Process.git(["branch", "packed-one"], cwd: repo)
        _ = try await Process.git(["branch", "packed-two"], cwd: repo)
        _ = try await Process.git(["worktree", "add", "-q", one.path, "packed-one"], cwd: repo)
        _ = try await Process.git(["worktree", "add", "-q", two.path, "packed-two"], cwd: repo)

        let oneEpoch: TimeInterval = 1_738_411_200
        let twoEpoch: TimeInterval = 1_740_830_400

        var oneEnv = Process.gitEnv()
        oneEnv["GIT_AUTHOR_DATE"] = "2025-02-01T12:00:00Z"
        oneEnv["GIT_COMMITTER_DATE"] = "2025-02-01T12:00:00Z"
        let oneCommit = try await Process.run(
            "/usr/bin/env",
            args: ["git", "commit", "-q", "--allow-empty", "-m", "one"],
            cwd: one,
            env: oneEnv
        )
        try #require(oneCommit.exitCode == 0)

        var twoEnv = Process.gitEnv()
        twoEnv["GIT_AUTHOR_DATE"] = "2025-03-01T12:00:00Z"
        twoEnv["GIT_COMMITTER_DATE"] = "2025-03-01T12:00:00Z"
        let twoCommit = try await Process.run(
            "/usr/bin/env",
            args: ["git", "commit", "-q", "--allow-empty", "-m", "two"],
            cwd: two,
            env: twoEnv
        )
        try #require(twoCommit.exitCode == 0)

        let packed = try await Process.git(["pack-refs", "--all", "--prune"], cwd: repo)
        try #require(packed.exitCode == 0)

        let trees = try await WorktreeService().list(repoPath: repo, projectId: "p")
        let byBranch = Dictionary(uniqueKeysWithValues: trees.map { ($0.branch, $0) })

        #expect(byBranch["packed-one"]?.lastActivity == Date(timeIntervalSince1970: oneEpoch))
        #expect(byBranch["packed-two"]?.lastActivity == Date(timeIntervalSince1970: twoEpoch))
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

    @Test func addFrozenReturnsTheCreatedLocalLineage() async throws {
        let repo = try await makeRepo()
        let destination = repo.deletingLastPathComponent().appendingPathComponent("\(repo.lastPathComponent)-frozen")
        defer {
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.removeItem(at: repo)
        }
        let base = try await Process.git(["rev-parse", "HEAD"], cwd: repo)
        let commit = base.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let service = WorktreeService()
        try await service.prepareFrozenBranch(repoPath: repo, branch: "frozen/lineage", intent: .create(atCommit: commit))

        let worktree = try await service.addFrozen(repoPath: repo, branch: "frozen/lineage", destination: destination, projectId: "p", intent: .create(atCommit: commit))

        #expect(worktree.lineageID != nil)
        #expect(worktree.lineageID == WorktreeService.existingLocalLineageID(forWorktreeAt: destination))
    }

    @Test func removeLockedWorktreeUsesDoubleForceWhenRequested() async throws {
        let repo = try await makeRepo()
        let destination = repo.deletingLastPathComponent().appendingPathComponent("\(repo.lastPathComponent)-locked")
        defer {
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.removeItem(at: repo)
        }
        _ = try await Process.git(["branch", "locked"], cwd: repo)
        _ = try await Process.git(["worktree", "add", "-q", destination.path, "locked"], cwd: repo)
        _ = try await Process.git(["worktree", "lock", destination.path], cwd: repo)
        let worktree = Worktree(
            id: Worktree.makeId(path: destination),
            projectId: "p",
            name: "locked",
            branch: "locked",
            path: destination,
            status: .clean,
            lastActivity: .distantPast
        )

        try await WorktreeService().remove(
            repoPath: repo,
            worktree: worktree,
            deleteBranchIfMerged: false,
            force: true,
            forceTwice: true,
            usesRemoteHostRegistry: false
        )

        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func addRecreatesAPrunableWorktreeRegistration() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let dest = repo.deletingLastPathComponent()
            .appendingPathComponent("\(repo.lastPathComponent)-prunable")
        defer { try? FileManager.default.removeItem(at: dest) }
        let svc = WorktreeService()
        _ = try await svc.add(
            repoPath: repo,
            base: "main",
            branch: "feat/prunable",
            destination: dest,
            projectId: "p"
        )
        try FileManager.default.removeItem(at: dest)

        let recreated = try await svc.add(
            repoPath: repo,
            base: "main",
            branch: "feat/prunable",
            destination: dest,
            projectId: "p"
        )

        #expect(recreated.branch == "feat/prunable")
        #expect(FileManager.default.fileExists(atPath: dest.path))
    }

    @Test func addRecreatesADetachedPrunableWorktreeRegistration() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let dest = repo.deletingLastPathComponent()
            .appendingPathComponent("\(repo.lastPathComponent)-detached-prunable")
        defer { try? FileManager.default.removeItem(at: dest) }
        let svc = WorktreeService()
        _ = try await svc.add(
            repoPath: repo,
            base: "main",
            branch: "feat/detached-prunable",
            destination: dest,
            projectId: "p"
        )
        _ = try await Process.git(["checkout", "--detach"], cwd: dest)
        _ = try await Process.git(["branch", "-D", "feat/detached-prunable"], cwd: repo)
        try FileManager.default.removeItem(at: dest)

        let recreated = try await svc.add(
            repoPath: repo,
            base: "main",
            branch: "feat/detached-prunable",
            destination: dest,
            projectId: "p"
        )

        #expect(recreated.branch == "feat/detached-prunable")
        #expect(FileManager.default.fileExists(atPath: dest.path))
    }

    @Test func addRecreatesAnAbsentLockedWorktreeRegistration() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let dest = repo.deletingLastPathComponent()
            .appendingPathComponent("\(repo.lastPathComponent)-locked-missing")
        defer { try? FileManager.default.removeItem(at: dest) }
        let svc = WorktreeService()
        _ = try await svc.add(
            repoPath: repo,
            base: "main",
            branch: "feat/locked-missing",
            destination: dest,
            projectId: "p"
        )
        _ = try await Process.git(["worktree", "lock", dest.path], cwd: repo)
        try FileManager.default.removeItem(at: dest)

        let recreated = try await svc.add(
            repoPath: repo,
            base: "main",
            branch: "feat/locked-missing",
            destination: dest,
            projectId: "p"
        )

        #expect(recreated.branch == "feat/locked-missing")
        #expect(FileManager.default.fileExists(atPath: dest.path))
    }

    @Test func prunableRecoveryDoesNotOverrideALiveBranchCheckout() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let root = repo.deletingLastPathComponent()
        let staleDest = root.appendingPathComponent("\(repo.lastPathComponent)-stale-registration")
        let liveDest = root.appendingPathComponent("\(repo.lastPathComponent)-live-branch")
        defer {
            try? FileManager.default.removeItem(at: staleDest)
            try? FileManager.default.removeItem(at: liveDest)
        }
        let svc = WorktreeService()
        _ = try await svc.add(
            repoPath: repo,
            base: "main",
            branch: "feat/stale-registration",
            destination: staleDest,
            projectId: "p"
        )
        _ = try await Process.git(["checkout", "--detach"], cwd: staleDest)
        try FileManager.default.removeItem(at: staleDest)
        _ = try await svc.add(
            repoPath: repo,
            base: "main",
            branch: "feat/live-branch",
            destination: liveDest,
            projectId: "p"
        )

        do {
            _ = try await svc.add(
                repoPath: repo,
                base: "main",
                branch: "feat/live-branch",
                destination: staleDest,
                projectId: "p"
            )
            Issue.record("expected the live branch checkout to remain protected")
        } catch let error as WorktreeService.WorktreeError {
            #expect(error.localizedDescription.contains("already used by worktree"))
        }
        #expect(FileManager.default.fileExists(atPath: liveDest.path))
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
    @Test func deletePreflightReportsCleanForCleanWorktree() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let dest = repo.deletingLastPathComponent().appendingPathComponent("\(repo.lastPathComponent)-preflight-clean")
        defer { try? FileManager.default.removeItem(at: dest) }
        let svc = WorktreeService()
        let wt = try await svc.add(
            repoPath: repo, base: "main", branch: "feat/preflight-clean",
            destination: dest, projectId: "p"
        )

        let preflight = try await svc.deletePreflight(worktreePath: wt.path)

        #expect(preflight.requiresForce == false)
        #expect(preflight.reasons.isEmpty)
        #expect(preflight.submoduleLocalState == .none)
    }

    @Test func deletePreflightReportsDirtyForUntrackedFile() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let dest = repo.deletingLastPathComponent().appendingPathComponent("\(repo.lastPathComponent)-preflight-dirty")
        defer { try? FileManager.default.removeItem(at: dest) }
        let svc = WorktreeService()
        let wt = try await svc.add(
            repoPath: repo, base: "main", branch: "feat/preflight-dirty",
            destination: dest, projectId: "p"
        )
        try "local".write(to: dest.appendingPathComponent("local.txt"), atomically: true, encoding: .utf8)

        let preflight = try await svc.deletePreflight(worktreePath: wt.path)

        #expect(preflight.requiresForce == true)
        #expect(preflight.reasons == [.dirty])
        #expect(preflight.submoduleLocalState == .none)
    }

    @Test func deletePreflightReportsLockedWorktree() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let dest = repo.deletingLastPathComponent().appendingPathComponent("\(repo.lastPathComponent)-preflight-locked")
        defer { try? FileManager.default.removeItem(at: dest) }
        let svc = WorktreeService()
        let wt = try await svc.add(
            repoPath: repo, base: "main", branch: "feat/preflight-locked",
            destination: dest, projectId: "p"
        )
        let lock = try await Process.git(["worktree", "lock", wt.path.path], cwd: repo)
        #expect(lock.exitCode == 0)

        let preflight = try await svc.deletePreflight(worktreePath: wt.path)

        #expect(preflight.requiresForce == true)
        #expect(preflight.reasons.contains(.locked))
    }

    @Test func lockedDeletePreflightReasonIsParsedFromPorcelain() {
        let path = URL(fileURLWithPath: "/repos/app-worktree")
        let porcelain = """
        worktree /repos/app
        HEAD abc
        branch refs/heads/main

        worktree /repos/app-worktree
        HEAD def
        branch refs/heads/feature
        locked

        """

        #expect(WorktreeService.porcelainMarksWorktreeLocked(porcelain, worktreePath: path))
    }

    @Test func deletePreflightReportsInitializedSubmodulesWithoutLocalState() async throws {
        let fixture = try await makeRepoWithInitializedSubmodule(suffix: "preflight-submodule-clean")
        defer {
            try? FileManager.default.removeItem(at: fixture.repo)
            try? FileManager.default.removeItem(at: fixture.submoduleRepo)
            try? FileManager.default.removeItem(at: fixture.worktree.path)
        }

        let preflight = try await fixture.service.deletePreflight(worktreePath: fixture.worktree.path)

        #expect(preflight.requiresForce == true)
        #expect(preflight.reasons == [.containsInitializedSubmodules])
        #expect(preflight.submoduleLocalState == .none)
    }

    @Test func deletePreflightReportsInitializedSubmoduleWithLocalOnlyBranch() async throws {
        let fixture = try await makeRepoWithInitializedSubmodule(suffix: "preflight-submodule-local-branch")
        defer {
            try? FileManager.default.removeItem(at: fixture.repo)
            try? FileManager.default.removeItem(at: fixture.submoduleRepo)
            try? FileManager.default.removeItem(at: fixture.worktree.path)
        }
        let submodulePath = fixture.worktree.path.appendingPathComponent("Deps/Submodule")
        _ = try await Process.git(["branch", "local-only", "HEAD"], cwd: submodulePath)

        let preflight = try await fixture.service.deletePreflight(worktreePath: fixture.worktree.path)

        #expect(preflight.requiresForce == true)
        #expect(preflight.reasons == [.containsInitializedSubmodules])
        #expect(preflight.submoduleLocalState == .present)
    }

    @Test func deletePreflightReportsUnknownSubmoduleLocalStateWhenCheckFails() async throws {
        let fixture = try await makeRepoWithInitializedSubmodule(suffix: "preflight-submodule-broken")
        defer {
            try? FileManager.default.removeItem(at: fixture.repo)
            try? FileManager.default.removeItem(at: fixture.submoduleRepo)
            try? FileManager.default.removeItem(at: fixture.worktree.path)
        }
        let gitfile = fixture.worktree.path.appendingPathComponent("Deps/Submodule/.git")
        try "gitdir: /nonexistent/broken/path\n".write(to: gitfile, atomically: true, encoding: .utf8)

        let preflight = try await fixture.service.deletePreflight(worktreePath: fixture.worktree.path)

        #expect(preflight.requiresForce == true)
        #expect(preflight.reasons == [.containsInitializedSubmodules])
        #expect(preflight.submoduleLocalState == .unknown)
    }

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

    @Test func removeRetriesWithoutLFSFiltersWhenGitStatusRequiresMissingLFS() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        let lfsOverride = [
            "-c", "filter.lfs.process=",
            "-c", "filter.lfs.smudge=",
            "-c", "filter.lfs.clean=",
            "-c", "filter.lfs.required=false"
        ]
        try "*.bin filter=lfs diff=lfs merge=lfs -text\n".write(
            to: repo.appendingPathComponent(".gitattributes"),
            atomically: true,
            encoding: .utf8
        )
        let pointer = """
        version https://git-lfs.github.com/spec/v1
        oid sha256:\(String(repeating: "0", count: 64))
        size 1

        """
        try pointer.write(
            to: repo.appendingPathComponent("data.bin"),
            atomically: true,
            encoding: .utf8
        )
        _ = try await Process.git(lfsOverride + ["add", ".gitattributes", "data.bin"], cwd: repo)
        _ = try await Process.git(lfsOverride + ["commit", "-q", "-m", "add lfs pointer"], cwd: repo)

        let dest = repo.deletingLastPathComponent()
            .appendingPathComponent("\(repo.lastPathComponent)-missing-lfs-remove")
        let branch = "feat/missing-lfs-remove"
        _ = try await Process.git(
            lfsOverride + ["worktree", "add", "-q", dest.path, "-b", branch],
            cwd: repo
        )
        _ = try await Process.git(["config", "filter.lfs.process", "missing-git-lfs filter-process"], cwd: repo)
        _ = try await Process.git(["config", "filter.lfs.clean", "missing-git-lfs clean -- %f"], cwd: repo)
        _ = try await Process.git(["config", "filter.lfs.smudge", "missing-git-lfs smudge -- %f"], cwd: repo)
        _ = try await Process.git(["config", "filter.lfs.required", "true"], cwd: repo)

        let wt = Worktree(
            id: Worktree.makeId(path: dest),
            projectId: "p",
            name: branch,
            branch: branch,
            path: dest,
            status: .clean,
            lastActivity: Date()
        )
        try await WorktreeService().remove(repoPath: repo, worktree: wt, deleteBranchIfMerged: false)

        #expect(!FileManager.default.fileExists(atPath: dest.path))
    }

    @Test func removePreservesSmudgedLFSCleanSemanticsWhenGitLFSIsMissing() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        let lfsOverride = [
            "-c", "filter.lfs.process=",
            "-c", "filter.lfs.smudge=",
            "-c", "filter.lfs.clean=",
            "-c", "filter.lfs.required=false"
        ]
        try "*.bin filter=lfs diff=lfs merge=lfs -text\n".write(
            to: repo.appendingPathComponent(".gitattributes"),
            atomically: true,
            encoding: .utf8
        )
        let smudgedContent = "real lfs content"
        let dataPath = repo.appendingPathComponent("data.bin")
        try smudgedContent.write(to: dataPath, atomically: true, encoding: .utf8)
        let sha = try await Process.run("/usr/bin/shasum", args: ["-a", "256", dataPath.path])
            .stdout
            .split(separator: " ")
            .first
            .map(String.init) ?? ""
        let pointer = """
        version https://git-lfs.github.com/spec/v1
        oid sha256:\(sha)
        size \(Data(smudgedContent.utf8).count)

        """
        try pointer.write(to: dataPath, atomically: true, encoding: .utf8)
        _ = try await Process.git(lfsOverride + ["add", ".gitattributes", "data.bin"], cwd: repo)
        _ = try await Process.git(lfsOverride + ["commit", "-q", "-m", "add lfs pointer"], cwd: repo)

        let dest = repo.deletingLastPathComponent()
            .appendingPathComponent("\(repo.lastPathComponent)-smudged-lfs-remove")
        let branch = "feat/smudged-lfs-remove"
        _ = try await Process.git(
            lfsOverride + ["worktree", "add", "-q", dest.path, "-b", branch],
            cwd: repo
        )
        try smudgedContent.write(
            to: dest.appendingPathComponent("data.bin"),
            atomically: true,
            encoding: .utf8
        )
        let fakeClean = """
        /bin/sh -c '/bin/cat >/dev/null; /usr/bin/printf "version https://git-lfs.github.com/spec/v1\\noid sha256:\(sha)\\nsize \(Data(smudgedContent.utf8).count)\\n"'
        """
        _ = try await Process.git(["-c", "filter.lfs.clean=\(fakeClean)", "add", "data.bin"], cwd: dest)
        _ = try await Process.git(["config", "filter.lfs.process", "missing-git-lfs filter-process"], cwd: repo)
        _ = try await Process.git(["config", "filter.lfs.clean", "missing-git-lfs clean -- %f"], cwd: repo)
        _ = try await Process.git(["config", "filter.lfs.smudge", "missing-git-lfs smudge -- %f"], cwd: repo)
        _ = try await Process.git(["config", "filter.lfs.required", "true"], cwd: repo)

        let wt = Worktree(
            id: Worktree.makeId(path: dest),
            projectId: "p",
            name: branch,
            branch: branch,
            path: dest,
            status: .clean,
            lastActivity: Date()
        )
        try await WorktreeService().remove(repoPath: repo, worktree: wt, deleteBranchIfMerged: false)

        #expect(!FileManager.default.fileExists(atPath: dest.path))
    }

    @Test func removeDoesNotForceDeleteSmudgedLFSFileWithModeChangeWhenGitLFSIsMissing() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        let lfsOverride = [
            "-c", "filter.lfs.process=",
            "-c", "filter.lfs.smudge=",
            "-c", "filter.lfs.clean=",
            "-c", "filter.lfs.required=false"
        ]
        try "*.bin filter=lfs diff=lfs merge=lfs -text\n".write(
            to: repo.appendingPathComponent(".gitattributes"),
            atomically: true,
            encoding: .utf8
        )
        let smudgedContent = "real lfs content"
        let dataPath = repo.appendingPathComponent("data.bin")
        try smudgedContent.write(to: dataPath, atomically: true, encoding: .utf8)
        let sha = try await Process.run("/usr/bin/shasum", args: ["-a", "256", dataPath.path])
            .stdout
            .split(separator: " ")
            .first
            .map(String.init) ?? ""
        let pointer = """
        version https://git-lfs.github.com/spec/v1
        oid sha256:\(sha)
        size \(Data(smudgedContent.utf8).count)

        """
        try pointer.write(to: dataPath, atomically: true, encoding: .utf8)
        _ = try await Process.git(lfsOverride + ["add", ".gitattributes", "data.bin"], cwd: repo)
        _ = try await Process.git(lfsOverride + ["commit", "-q", "-m", "add lfs pointer"], cwd: repo)

        let dest = repo.deletingLastPathComponent()
            .appendingPathComponent("\(repo.lastPathComponent)-smudged-lfs-mode-change")
        let branch = "feat/smudged-lfs-mode-change"
        _ = try await Process.git(
            lfsOverride + ["worktree", "add", "-q", dest.path, "-b", branch],
            cwd: repo
        )
        let destData = dest.appendingPathComponent("data.bin")
        try smudgedContent.write(to: destData, atomically: true, encoding: .utf8)
        let fakeClean = """
        /bin/sh -c '/bin/cat >/dev/null; /usr/bin/printf "version https://git-lfs.github.com/spec/v1\\noid sha256:\(sha)\\nsize \(Data(smudgedContent.utf8).count)\\n"'
        """
        _ = try await Process.git(["-c", "filter.lfs.clean=\(fakeClean)", "add", "data.bin"], cwd: dest)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destData.path)
        _ = try await Process.git(["config", "filter.lfs.process", "missing-git-lfs filter-process"], cwd: repo)
        _ = try await Process.git(["config", "filter.lfs.clean", "missing-git-lfs clean -- %f"], cwd: repo)
        _ = try await Process.git(["config", "filter.lfs.smudge", "missing-git-lfs smudge -- %f"], cwd: repo)
        _ = try await Process.git(["config", "filter.lfs.required", "true"], cwd: repo)

        let wt = Worktree(
            id: Worktree.makeId(path: dest),
            projectId: "p",
            name: branch,
            branch: branch,
            path: dest,
            status: .clean,
            lastActivity: Date()
        )
        await #expect(throws: WorktreeService.WorktreeError.self) {
            try await WorktreeService().remove(repoPath: repo, worktree: wt, deleteBranchIfMerged: false)
        }

        #expect(FileManager.default.fileExists(atPath: destData.path))
    }
}

extension WorktreeServiceTests {
    private struct InitializedSubmoduleFixture {
        let repo: URL
        let submoduleRepo: URL
        let service: WorktreeService
        let worktree: Worktree
    }

    private func makeRepoWithInitializedSubmodule(suffix: String) async throws -> InitializedSubmoduleFixture {
        let repo = try await makeRepo()

        let submoduleRepo = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-submodule-\(UUID().uuidString)")
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

        let dest = repo.deletingLastPathComponent().appendingPathComponent("\(repo.lastPathComponent)-\(suffix)")
        let svc = WorktreeService()
        let wt = try await svc.add(
            repoPath: repo, base: "main", branch: "feat/\(suffix)",
            destination: dest, projectId: "p"
        )
        _ = try await Process.git(
            ["-c", "protocol.file.allow=always", "submodule", "update", "--init", "-q"],
            cwd: dest
        )

        return InitializedSubmoduleFixture(repo: repo, submoduleRepo: submoduleRepo, service: svc, worktree: wt)
    }

    @Test func removeWithoutForceFailsForCleanInitializedSubmodule() async throws {
        let fixture = try await makeRepoWithInitializedSubmodule(suffix: "submodule-no-force")
        defer {
            try? FileManager.default.removeItem(at: fixture.repo)
            try? FileManager.default.removeItem(at: fixture.submoduleRepo)
            try? FileManager.default.removeItem(at: fixture.worktree.path)
        }

        await #expect(throws: WorktreeService.WorktreeError.self) {
            try await fixture.service.remove(
                repoPath: fixture.repo,
                worktree: fixture.worktree,
                deleteBranchIfMerged: false,
                force: false
            )
        }

        #expect(FileManager.default.fileExists(atPath: fixture.worktree.path.path))
    }

    @Test func removeWithForceDeletesCleanInitializedSubmodule() async throws {
        let fixture = try await makeRepoWithInitializedSubmodule(suffix: "submodule-force")
        defer {
            try? FileManager.default.removeItem(at: fixture.repo)
            try? FileManager.default.removeItem(at: fixture.submoduleRepo)
            try? FileManager.default.removeItem(at: fixture.worktree.path)
        }

        try await fixture.service.remove(
            repoPath: fixture.repo,
            worktree: fixture.worktree,
            deleteBranchIfMerged: false,
            force: true
        )

        let listed = try await fixture.service.list(repoPath: fixture.repo, projectId: "p")
        #expect(listed.count == 1)
        #expect(!FileManager.default.fileExists(atPath: fixture.worktree.path.path))
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

    @Test func removeDoesNotForceDeleteSubmoduleExtraBranchAtRemoteCommit() async throws {
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
            .appendingPathComponent("\(repo.lastPathComponent)-submodule-extra-branch")
        defer { try? FileManager.default.removeItem(at: dest) }
        let svc = WorktreeService()
        let wt = try await svc.add(
            repoPath: repo, base: "main", branch: "feat/submodule-extra-branch",
            destination: dest, projectId: "p"
        )
        _ = try await Process.git(
            ["-c", "protocol.file.allow=always", "submodule", "update", "--init", "-q"],
            cwd: dest
        )

        let submodulePath = dest.appendingPathComponent("Deps/Submodule")
        _ = try await Process.git(["branch", "keep-me", "HEAD"], cwd: submodulePath)

        await #expect(throws: WorktreeService.WorktreeError.self) {
            try await svc.remove(repoPath: repo, worktree: wt, deleteBranchIfMerged: false)
        }
        #expect(FileManager.default.fileExists(atPath: submodulePath.path))
    }

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

    @Test func removeDoesNotForceDeleteSubmoduleLocalTagOnRemoteCommit() async throws {
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
            .appendingPathComponent("\(repo.lastPathComponent)-submodule-local-remote-tag")
        defer { try? FileManager.default.removeItem(at: dest) }
        let svc = WorktreeService()
        let wt = try await svc.add(
            repoPath: repo, base: "main", branch: "feat/submodule-local-remote-tag",
            destination: dest, projectId: "p"
        )
        _ = try await Process.git(
            ["-c", "protocol.file.allow=always", "submodule", "update", "--init", "-q"],
            cwd: dest
        )

        let submodulePath = dest.appendingPathComponent("Deps/Submodule")
        _ = try await Process.git(["tag", "local-only"], cwd: submodulePath)

        await #expect(throws: WorktreeService.WorktreeError.self) {
            try await svc.remove(repoPath: repo, worktree: wt, deleteBranchIfMerged: false)
        }
        #expect(FileManager.default.fileExists(atPath: submodulePath.path))
    }

    @Test func removeDoesNotForceDeleteSubmoduleRetargetedRemoteTag() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        let submoduleRepo = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-submodule-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: submoduleRepo) }
        try FileManager.default.createDirectory(at: submoduleRepo, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: submoduleRepo)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "tagged remote commit"], cwd: submoduleRepo)
        _ = try await Process.git(["tag", "shared"], cwd: submoduleRepo)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "current remote commit"], cwd: submoduleRepo)

        _ = try await Process.git(
            ["-c", "protocol.file.allow=always", "submodule", "add", "-q", submoduleRepo.path, "Deps/Submodule"],
            cwd: repo
        )
        _ = try await Process.git(["commit", "-q", "-am", "add submodule"], cwd: repo)

        let dest = repo.deletingLastPathComponent()
            .appendingPathComponent("\(repo.lastPathComponent)-submodule-retargeted-tag")
        defer { try? FileManager.default.removeItem(at: dest) }
        let svc = WorktreeService()
        let wt = try await svc.add(
            repoPath: repo, base: "main", branch: "feat/submodule-retargeted-tag",
            destination: dest, projectId: "p"
        )
        _ = try await Process.git(
            ["-c", "protocol.file.allow=always", "submodule", "update", "--init", "-q"],
            cwd: dest
        )

        let submodulePath = dest.appendingPathComponent("Deps/Submodule")
        _ = try await Process.git(["tag", "-f", "shared", "HEAD"], cwd: submodulePath)

        await #expect(throws: WorktreeService.WorktreeError.self) {
            try await svc.remove(repoPath: repo, worktree: wt, deleteBranchIfMerged: false)
        }
        #expect(FileManager.default.fileExists(atPath: submodulePath.path))
    }

    @Test func removeDoesNotForceDeleteSubmoduleRetaggedAnnotatedRemoteTag() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        let submoduleRepo = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-submodule-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: submoduleRepo) }
        try FileManager.default.createDirectory(at: submoduleRepo, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: submoduleRepo)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "current remote commit"], cwd: submoduleRepo)
        _ = try await Process.git(["tag", "-a", "shared", "-m", "remote annotation"], cwd: submoduleRepo)

        _ = try await Process.git(
            ["-c", "protocol.file.allow=always", "submodule", "add", "-q", submoduleRepo.path, "Deps/Submodule"],
            cwd: repo
        )
        _ = try await Process.git(["commit", "-q", "-am", "add submodule"], cwd: repo)

        let dest = repo.deletingLastPathComponent()
            .appendingPathComponent("\(repo.lastPathComponent)-submodule-retagged-annotated")
        defer { try? FileManager.default.removeItem(at: dest) }
        let svc = WorktreeService()
        let wt = try await svc.add(
            repoPath: repo, base: "main", branch: "feat/submodule-retagged-annotated",
            destination: dest, projectId: "p"
        )
        _ = try await Process.git(
            ["-c", "protocol.file.allow=always", "submodule", "update", "--init", "-q"],
            cwd: dest
        )

        let submodulePath = dest.appendingPathComponent("Deps/Submodule")
        _ = try await Process.git(["tag", "-f", "-a", "shared", "-m", "local annotation", "HEAD"], cwd: submodulePath)

        await #expect(throws: WorktreeService.WorktreeError.self) {
            try await svc.remove(repoPath: repo, worktree: wt, deleteBranchIfMerged: false)
        }
        #expect(FileManager.default.fileExists(atPath: submodulePath.path))
    }

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
