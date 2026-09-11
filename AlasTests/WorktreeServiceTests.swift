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

    @Test func addFrozenRollsBackTheLocalWorktreeWhenLineageRecordingFails() async throws {
        let repo = try await makeRepo()
        let destination = repo.deletingLastPathComponent().appendingPathComponent("\(repo.lastPathComponent)-frozen-lineage-fail")
        defer {
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.removeItem(at: repo)
        }
        let base = try await Process.git(["rev-parse", "HEAD"], cwd: repo)
        let commit = base.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let service = WorktreeService()
        try await service.prepareFrozenBranch(repoPath: repo, branch: "frozen/lineage-fail", intent: .create(atCommit: commit))

        await #expect(throws: (any Error).self) {
            try await service.addFrozen(
                repoPath: repo,
                branch: "frozen/lineage-fail",
                destination: destination,
                projectId: "p",
                intent: .create(atCommit: commit),
                localLineage: { _, _ in nil }
            )
        }

        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let registrations = try await Process.git(["worktree", "list", "--porcelain"], cwd: repo)
        #expect(!registrations.stdout.contains(destination.path))
    }

    @Test func remoteAddFrozenRollsBackTheWorktreeWhenLineageRecordingFails() async throws {
        let service = WorktreeService()
        let runner = FrozenRemoteRunner(results: [
            .init(exitCode: 0, stdout: "", stderr: ""),
            .init(exitCode: 0, stdout: "abc\n", stderr: ""),
            .init(exitCode: 0, stdout: "", stderr: ""),
            .init(exitCode: 0, stdout: "abc\n", stderr: ""),
            .init(exitCode: 6, stdout: "", stderr: "marker failed"),
            .init(exitCode: 0, stdout: "", stderr: "")
        ])

        await #expect(throws: (any Error).self) {
            try await service.addFrozen(
                repoPath: URL(fileURLWithPath: "/repo"),
                branch: "feature/workspace",
                destination: URL(fileURLWithPath: "/checkout/member"),
                projectId: "p",
                intent: .create(atCommit: "abc"),
                expectedLineageID: "lineage",
                remoteHost: "builder.example",
                remoteExistence: { _, _ in .missing },
                remoteRun: { host, command in
                    await runner.run(host: host, command: command)
                }
            )
        }

        let commands = await runner.commands
        #expect(commands.count == 6)
        #expect(commands[2].contains("worktree add"))
        #expect(commands[3].contains("rev-parse --verify HEAD"))
        #expect(commands[4].contains("alas-worktree-lineage"))
        #expect(commands[5].contains("worktree remove -f -f --"))
        #expect(commands[5].contains("/checkout/member"))
    }

    @Test func remoteAddFrozenRollsBackTheWorktreeWhenCreatedHeadDiffersFromFrozenCommit() async throws {
        let service = WorktreeService()
        let runner = FrozenRemoteRunner(results: [
            .init(exitCode: 0, stdout: "", stderr: ""),
            .init(exitCode: 0, stdout: "abc\n", stderr: ""),
            .init(exitCode: 0, stdout: "", stderr: ""),
            .init(exitCode: 0, stdout: "def\n", stderr: ""),
            .init(exitCode: 0, stdout: "", stderr: "")
        ])

        await #expect(throws: (any Error).self) {
            try await service.addFrozen(
                repoPath: URL(fileURLWithPath: "/repo"),
                branch: "feature/workspace",
                destination: URL(fileURLWithPath: "/checkout/member"),
                projectId: "p",
                intent: .create(atCommit: "abc"),
                expectedLineageID: "lineage",
                remoteHost: "builder.example",
                remoteExistence: { _, _ in .missing },
                remoteRun: { host, command in
                    await runner.run(host: host, command: command)
                }
            )
        }

        let commands = await runner.commands
        #expect(commands.count == 5)
        #expect(commands[2].contains("worktree add"))
        #expect(commands[3].contains("rev-parse --verify HEAD"))
        #expect(commands[4].contains("worktree remove -f -f --"))
    }

    @Test func remoteAddFrozenRollsBackTheWorktreeWhenLineageRecordingThrows() async throws {
        let service = WorktreeService()
        let runner = ThrowingFrozenRemoteRunner()

        await #expect(throws: (any Error).self) {
            try await service.addFrozen(
                repoPath: URL(fileURLWithPath: "/repo"),
                branch: "feature/workspace",
                destination: URL(fileURLWithPath: "/checkout/member"),
                projectId: "p",
                intent: .create(atCommit: "abc"),
                expectedLineageID: "lineage",
                remoteHost: "builder.example",
                remoteExistence: { _, _ in .missing },
                remoteRun: { host, command in
                    try await runner.run(host: host, command: command)
                }
            )
        }

        let commands = await runner.commands
        #expect(commands.count == 6)
        #expect(commands[2].contains("worktree add"))
        #expect(commands[3].contains("rev-parse --verify HEAD"))
        #expect(commands[4].contains("alas-worktree-lineage"))
        #expect(commands[5].contains("worktree remove -f -f --"))
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

private actor FrozenRemoteRunner {
    private var results: [ProcessResult]
    private(set) var commands: [String] = []

    init(results: [ProcessResult]) {
        self.results = results
    }

    func run(host: String, command: String) -> ProcessResult {
        commands.append(command)
        return results.isEmpty ? .init(exitCode: 1, stdout: "", stderr: "") : results.removeFirst()
    }
}

private enum FrozenRemoteError: Error { case transport }

private actor ThrowingFrozenRemoteRunner {
    private(set) var commands: [String] = []

    func run(host: String, command: String) throws -> ProcessResult {
        commands.append(command)
        switch commands.count {
        case 1:
            return .init(exitCode: 0, stdout: "", stderr: "")
        case 2:
            return .init(exitCode: 0, stdout: "abc\n", stderr: "")
        case 3:
            return .init(exitCode: 0, stdout: "", stderr: "")
        case 4:
            return .init(exitCode: 0, stdout: "abc\n", stderr: "")
        case 5:
            throw FrozenRemoteError.transport
        default:
            return .init(exitCode: 0, stdout: "", stderr: "")
        }
    }
}

extension WorktreeServiceTests {
    private struct LinkedWorktreeFixture {
        let repo: URL
        let service: WorktreeService
        let worktree: Worktree

        func removeFiles() {
            try? FileManager.default.removeItem(at: worktree.path)
            try? FileManager.default.removeItem(at: repo)
        }
    }

    private func makeLinkedWorktree(suffix: String) async throws -> LinkedWorktreeFixture {
        let repo = try await makeRepo()
        let destination = repo.deletingLastPathComponent()
            .appendingPathComponent("\(repo.lastPathComponent)-\(suffix)")
        let service = WorktreeService()
        let worktree = try await service.add(
            repoPath: repo,
            base: "main",
            branch: "feature/\(suffix)",
            destination: destination,
            projectId: "p"
        )
        return LinkedWorktreeFixture(repo: repo, service: service, worktree: worktree)
    }

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

    @Test func fastLocalRemoveReturnsStagedTicketBeforeFilesAreDeleted() async throws {
        let repo = try await makeRepo()
        let destination = repo.deletingLastPathComponent()
            .appendingPathComponent("\(repo.lastPathComponent)-fast")
        defer {
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.removeItem(at: repo)
        }
        let service = WorktreeService()
        let worktree = try await service.add(
            repoPath: repo,
            base: "main",
            branch: "feature/fast",
            destination: destination,
            projectId: "p"
        )
        try "keep until cleaner".write(
            to: destination.appendingPathComponent("marker.txt"),
            atomically: true,
            encoding: .utf8
        )

        let outcome = try await service.removeFastLocal(
            repoPath: repo,
            worktree: worktree,
            deleteBranchIfMerged: false,
            force: true
        )
        guard case .staged(let ticket) = outcome else {
            Issue.record("Expected staged removal")
            return
        }
        defer { try? FileManager.default.removeItem(at: ticket.trashRoot) }

        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(FileManager.default.fileExists(
            atPath: ticket.stagedPath.appendingPathComponent("marker.txt").path
        ))
        #expect(try await service.list(repoPath: repo, projectId: "p").count == 1)
    }

    @Test func fastLocalRemoveSurvivesWhenProjectPathIsTheRemovedWorktree() async throws {
        let fixture = try await makeLinkedWorktree(suffix: "project-path-target")
        defer { fixture.removeFiles() }

        let outcome = try await fixture.service.removeFastLocal(
            repoPath: fixture.worktree.path,
            worktree: fixture.worktree,
            deleteBranchIfMerged: true,
            force: false
        )
        guard case .staged(let ticket) = outcome else {
            Issue.record("Expected staged removal")
            return
        }
        defer { try? FileManager.default.removeItem(at: ticket.trashRoot) }

        #expect(!FileManager.default.fileExists(atPath: fixture.worktree.path.path))
        let worktrees = try await fixture.service.list(repoPath: fixture.repo, projectId: "p")
        #expect(worktrees.count == 1)
        #expect(!worktrees.contains { $0.path.standardizedFileURL == fixture.worktree.path.standardizedFileURL })
        let branches = try await Process.git(
            ["branch", "--list", fixture.worktree.branch],
            cwd: fixture.repo
        )
        #expect(branches.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test func fastLocalRemoveDeletesBranchMergedIntoSurvivingLinkedProject() async throws {
        let fixture = try await makeLinkedWorktree(suffix: "linked-project-merge")
        let project = fixture.repo.deletingLastPathComponent()
            .appendingPathComponent("\(fixture.repo.lastPathComponent)-project")
        defer {
            try? FileManager.default.removeItem(at: project)
            fixture.removeFiles()
        }
        let commit = try await Process.git(
            ["commit", "--allow-empty", "-m", "only merged into project"],
            cwd: fixture.worktree.path
        )
        try #require(commit.exitCode == 0)
        _ = try await fixture.service.add(
            repoPath: fixture.repo,
            base: fixture.worktree.branch,
            branch: "project",
            destination: project,
            projectId: "p"
        )

        _ = try await fixture.service.removeFastLocal(
            repoPath: project,
            worktree: fixture.worktree,
            deleteBranchIfMerged: true
        )

        let branches = try await Process.git(
            ["branch", "--list", fixture.worktree.branch], cwd: project
        )
        #expect(branches.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test func fastLocalRemovePersistsRecoveryJournalBeforeMovingFiles() async throws {
        let fixture = try await makeLinkedWorktree(suffix: "pending-before-rename")
        defer { fixture.removeFiles() }
        _ = try await fixture.service.removeFastLocal(
            repoPath: fixture.repo,
            worktree: fixture.worktree,
            deleteBranchIfMerged: false,
            moveItem: { source, destination in
                let identifier = destination.lastPathComponent.split(separator: ".").last!
                let pending = destination.deletingLastPathComponent()
                    .appendingPathComponent(".alas-worktree-deletion-pending.\(identifier)")
                #expect(FileManager.default.fileExists(atPath: pending.path))
                try FileManager.default.moveItem(at: source, to: destination)
            }
        )
    }

    @Test func fastLocalRemoveDeletesStagedFilesSynchronouslyWhenCommitMarkerCannotBeWritten() async throws {
        let fixture = try await makeLinkedWorktree(suffix: "marker-write-failure")
        let trashRoot = WorktreeTrash.root(
            commonGitDirectory: fixture.repo.appendingPathComponent(".git")
        )
        defer {
            try? FileManager.default.removeItem(at: trashRoot)
            fixture.removeFiles()
        }

        let outcome = try await fixture.service.removeFastLocal(
            repoPath: fixture.repo,
            worktree: fixture.worktree,
            deleteBranchIfMerged: false,
            force: false,
            moveItem: { source, destination in
                try FileManager.default.moveItem(at: source, to: destination)
                guard let directoryIdentity = WorktreeTrash.directoryIdentity(at: destination) else {
                    throw CocoaError(.fileReadUnknown)
                }
                let ticket = WorktreeTrashCleanupTicket(
                    trashRoot: destination.deletingLastPathComponent(),
                    stagedPath: destination,
                    directoryIdentity: directoryIdentity
                )
                try FileManager.default.createDirectory(
                    at: WorktreeTrash.committedMarkerURL(for: ticket),
                    withIntermediateDirectories: false
                )
            }
        )

        #expect(outcome == .synchronous)
        #expect(!FileManager.default.fileExists(atPath: fixture.worktree.path.path))
        let stagedDirectories = try FileManager.default.contentsOfDirectory(
            at: trashRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        #expect(stagedDirectories.isEmpty)
        #expect(try await fixture.service.list(repoPath: fixture.repo, projectId: "p").count == 1)
    }

    @Test func fastLocalRemoveFailsClosedWhenWorktreeBecameDirty() async throws {
        let fixture = try await makeLinkedWorktree(suffix: "became-dirty")
        defer { fixture.removeFiles() }
        try "dirty".write(
            to: fixture.worktree.path.appendingPathComponent("new.txt"),
            atomically: true,
            encoding: .utf8
        )

        await #expect(throws: WorktreeService.WorktreeError.self) {
            try await fixture.service.removeFastLocal(
                repoPath: fixture.repo,
                worktree: fixture.worktree,
                deleteBranchIfMerged: false,
                force: false
            )
        }
        #expect(FileManager.default.fileExists(atPath: fixture.worktree.path.path))
    }

    @Test func fastLocalRemoveRestoresWorktreeMadeDirtyDuringStaging() async throws {
        let fixture = try await makeLinkedWorktree(suffix: "dirty-during-stage")
        let dirtyFile = fixture.worktree.path.appendingPathComponent("new-during-stage.txt")
        let trashRoot = WorktreeTrash.root(
            commonGitDirectory: fixture.repo.appendingPathComponent(".git")
        )
        defer {
            try? FileManager.default.removeItem(at: trashRoot)
            fixture.removeFiles()
        }

        await #expect(throws: WorktreeService.WorktreeError.self) {
            try await fixture.service.removeFastLocal(
                repoPath: fixture.repo,
                worktree: fixture.worktree,
                deleteBranchIfMerged: false,
                force: false,
                moveItem: { source, destination in
                    try FileManager.default.moveItem(at: source, to: destination)
                    try "do not discard".write(
                        to: destination.appendingPathComponent(dirtyFile.lastPathComponent),
                        atomically: true,
                        encoding: .utf8
                    )
                }
            )
        }

        #expect(FileManager.default.fileExists(atPath: dirtyFile.path))
        let registrations = try await Process.git(
            ["worktree", "list", "--porcelain"],
            cwd: fixture.repo
        )
        #expect(registrations.stdout.contains(fixture.worktree.path.path))
    }

    @Test func fastLocalRemoveDoesNotStageReplacementDirectoryEvenWithForce() async throws {
        let fixture = try await makeLinkedWorktree(suffix: "replaced-before-stage")
        let displaced = fixture.worktree.path.deletingLastPathComponent()
            .appendingPathComponent("\(fixture.worktree.path.lastPathComponent)-displaced")
        defer {
            try? FileManager.default.removeItem(at: fixture.worktree.path)
            try? FileManager.default.removeItem(at: displaced)
            try? FileManager.default.removeItem(at: fixture.repo)
        }
        try FileManager.default.moveItem(at: fixture.worktree.path, to: displaced)
        try FileManager.default.createDirectory(
            at: fixture.worktree.path,
            withIntermediateDirectories: true
        )
        let unrelatedMarker = fixture.worktree.path.appendingPathComponent("unrelated.txt")
        try "do not delete".write(to: unrelatedMarker, atomically: true, encoding: .utf8)

        await #expect(throws: WorktreeService.WorktreeError.self) {
            try await fixture.service.removeFastLocal(
                repoPath: fixture.repo,
                worktree: fixture.worktree,
                deleteBranchIfMerged: false,
                force: true
            )
        }

        #expect(FileManager.default.fileExists(atPath: unrelatedMarker.path))
    }

    @Test func fastLocalRemoveRestoresReplacementStagedDuringRenameWithoutRemovingRegistration() async throws {
        let fixture = try await makeLinkedWorktree(suffix: "replaced-during-stage")
        let originalPath = fixture.worktree.path.standardizedFileURL
        let displaced = originalPath.deletingLastPathComponent()
            .appendingPathComponent("\(originalPath.lastPathComponent)-displaced")
        let unrelatedMarker = originalPath.appendingPathComponent("unrelated.txt")
        defer {
            try? FileManager.default.removeItem(at: originalPath)
            try? FileManager.default.removeItem(at: displaced)
            try? FileManager.default.removeItem(at: fixture.repo)
        }

        await #expect(throws: WorktreeService.WorktreeError.self) {
            try await fixture.service.removeFastLocal(
                repoPath: fixture.repo,
                worktree: fixture.worktree,
                deleteBranchIfMerged: false,
                force: true,
                moveItem: { source, destination in
                    if source.standardizedFileURL == originalPath {
                        try FileManager.default.moveItem(at: source, to: displaced)
                        try FileManager.default.createDirectory(
                            at: source,
                            withIntermediateDirectories: true
                        )
                        try "do not delete".write(
                            to: unrelatedMarker,
                            atomically: true,
                            encoding: .utf8
                        )
                    }
                    try FileManager.default.moveItem(at: source, to: destination)
                }
            )
        }

        #expect(FileManager.default.fileExists(atPath: unrelatedMarker.path))
        #expect(FileManager.default.fileExists(atPath: displaced.appendingPathComponent(".git").path))
        let registrations = try await Process.git(
            ["worktree", "list", "--porcelain"],
            cwd: fixture.repo
        )
        let registeredPaths = registrations.stdout
            .split(separator: "\n")
            .compactMap { line -> String? in
                guard line.hasPrefix("worktree ") else { return nil }
                return URL(fileURLWithPath: String(line.dropFirst("worktree ".count)))
                    .resolvingSymlinksInPath()
                    .path
            }
        #expect(registeredPaths.contains(originalPath.resolvingSymlinksInPath().path))
    }

    @Test func fastLocalRemoveFallsBackWhenRenameFails() async throws {
        let fixture = try await makeLinkedWorktree(suffix: "rename-fallback")
        defer { fixture.removeFiles() }

        let outcome = try await fixture.service.removeFastLocal(
            repoPath: fixture.repo,
            worktree: fixture.worktree,
            deleteBranchIfMerged: false,
            force: false,
            moveItem: { _, _ in throw CocoaError(.fileWriteNoPermission) }
        )

        #expect(outcome == .synchronous)
        #expect(!FileManager.default.fileExists(atPath: fixture.worktree.path.path))
    }

    @Test func fastLocalRemoveRestoresPathWhenRegistryRemovalFails() async throws {
        let fixture = try await makeLinkedWorktree(suffix: "rollback")
        defer { fixture.removeFiles() }
        _ = try await Process.git(["worktree", "lock", fixture.worktree.path.path], cwd: fixture.repo)

        await #expect(throws: WorktreeService.WorktreeError.self) {
            try await fixture.service.removeFastLocal(
                repoPath: fixture.repo,
                worktree: fixture.worktree,
                deleteBranchIfMerged: false,
                force: false
            )
        }

        #expect(FileManager.default.fileExists(atPath: fixture.worktree.path.path))
    }

    @Test func fastLocalRemoveUsesDoubleForceForApprovedLockedWorktree() async throws {
        let fixture = try await makeLinkedWorktree(suffix: "locked-fast")
        defer { fixture.removeFiles() }
        _ = try await Process.git(["worktree", "lock", fixture.worktree.path.path], cwd: fixture.repo)

        let outcome = try await fixture.service.removeFastLocal(
            repoPath: fixture.repo,
            worktree: fixture.worktree,
            deleteBranchIfMerged: false,
            force: true
        )
        guard case .staged(let ticket) = outcome else {
            Issue.record("Expected staged removal")
            return
        }
        defer { try? FileManager.default.removeItem(at: ticket.trashRoot) }
        #expect(!FileManager.default.fileExists(atPath: fixture.worktree.path.path))
    }

    @Test func fastLocalRemoveNeverStagesARegisteredRemotePath() async throws {
        let fixture = try await makeLinkedWorktree(suffix: "remote-fallback")
        defer { fixture.removeFiles() }
        RemoteHostRegistry.shared.register(root: fixture.worktree.path.path, host: "test-host")
        defer { RemoteHostRegistry.shared.unregister(root: fixture.worktree.path.path) }

        let outcome = try await fixture.service.removeFastLocal(
            repoPath: fixture.repo,
            worktree: fixture.worktree,
            deleteBranchIfMerged: false,
            force: false,
            usesRemoteHostRegistry: false
        )

        #expect(outcome == .synchronous)
        #expect(!FileManager.default.fileExists(atPath: fixture.worktree.path.path))
    }

    @Test func fastLocalRemoveWithDeleteBranchUsesRealBranchName() async throws {
        let repo = try await makeRepo()
        let destination = repo.deletingLastPathComponent()
            .appendingPathComponent("\(repo.lastPathComponent)-feature-name")
        defer {
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.removeItem(at: repo)
        }
        let service = WorktreeService()
        let worktree = try await service.add(
            repoPath: repo,
            base: "main",
            branch: "feature/name",
            destination: destination,
            projectId: "p"
        )

        let outcome = try await service.removeFastLocal(
            repoPath: repo,
            worktree: worktree,
            deleteBranchIfMerged: true,
            force: false
        )
        guard case .staged(let ticket) = outcome else {
            Issue.record("Expected staged removal")
            return
        }
        defer { try? FileManager.default.removeItem(at: ticket.trashRoot) }

        let branches = try await Process.git(["branch", "--list", "feature/name"], cwd: repo)
        #expect(branches.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// Squash-merging breaks the ancestry chain `git branch -d` relies on:
    /// the resulting commit on the base branch is not a descendant of the
    /// original branch tip by history alone, so an un-forced delete
    /// genuinely fails. `verifiedMergedBranchSHA` trusts a stronger,
    /// external signal (the code host's own record of the merge) — the
    /// branch's tip as of that verification — and uses `-D` instead, once
    /// it re-confirms the branch's current tip still matches.
    @Test func fastLocalRemoveDeletesSquashMergedBranchWhenForgeVerified() async throws {
        let repo = try await makeRepo()
        let destination = repo.deletingLastPathComponent()
            .appendingPathComponent("\(repo.lastPathComponent)-squash-verified")
        defer {
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.removeItem(at: repo)
        }
        let service = WorktreeService()
        let worktree = try await service.add(
            repoPath: repo,
            base: "main",
            branch: "feature/squash",
            destination: destination,
            projectId: "p"
        )
        try "content".write(
            to: destination.appendingPathComponent("file.txt"),
            atomically: true,
            encoding: .utf8
        )
        _ = try await Process.git(["add", "."], cwd: destination)
        _ = try await Process.git(["commit", "-q", "-m", "feature work"], cwd: destination)
        let branchTip = try await Process.git(["rev-parse", "feature/squash"], cwd: repo)
        let verifiedSHA = branchTip.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let squash = try await Process.git(["merge", "--squash", "feature/squash"], cwd: repo)
        #expect(squash.exitCode == 0)
        let squashCommit = try await Process.git(["commit", "-q", "-m", "squashed"], cwd: repo)
        #expect(squashCommit.exitCode == 0)

        // Sanity check the premise: an unverified `-d` genuinely can't do this.
        let plainDelete = try await Process.git(["branch", "-d", "feature/squash"], cwd: repo)
        #expect(plainDelete.exitCode != 0)

        let outcome = try await service.removeFastLocal(
            repoPath: repo,
            worktree: worktree,
            deleteBranchIfMerged: true,
            force: false,
            verifiedMergedBranchSHA: verifiedSHA
        )
        guard case .staged(let ticket) = outcome else {
            Issue.record("Expected staged removal")
            return
        }
        defer { try? FileManager.default.removeItem(at: ticket.trashRoot) }

        let branches = try await Process.git(["branch", "--list", "feature/squash"], cwd: repo)
        #expect(branches.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// Without forge verification, a squash-merged branch is left behind —
    /// this is the pre-existing, unchanged behavior for every worktree the
    /// scanner hasn't independently confirmed via the code host.
    @Test func fastLocalRemoveKeepsSquashMergedBranchWithoutForgeVerification() async throws {
        let repo = try await makeRepo()
        let destination = repo.deletingLastPathComponent()
            .appendingPathComponent("\(repo.lastPathComponent)-squash-unverified")
        defer {
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.removeItem(at: repo)
        }
        let service = WorktreeService()
        let worktree = try await service.add(
            repoPath: repo,
            base: "main",
            branch: "feature/squash-unverified",
            destination: destination,
            projectId: "p"
        )
        try "content".write(
            to: destination.appendingPathComponent("file.txt"),
            atomically: true,
            encoding: .utf8
        )
        _ = try await Process.git(["add", "."], cwd: destination)
        _ = try await Process.git(["commit", "-q", "-m", "feature work"], cwd: destination)
        _ = try await Process.git(["merge", "--squash", "feature/squash-unverified"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "squashed"], cwd: repo)

        let outcome = try await service.removeFastLocal(
            repoPath: repo,
            worktree: worktree,
            deleteBranchIfMerged: true,
            force: false
            // verifiedMergedBranchSHA defaults to nil
        )
        guard case .staged(let ticket) = outcome else {
            Issue.record("Expected staged removal")
            return
        }
        defer { try? FileManager.default.removeItem(at: ticket.trashRoot) }

        let branches = try await Process.git(["branch", "--list", "feature/squash-unverified"], cwd: repo)
        #expect(!branches.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// A `verifiedMergedBranchSHA` that no longer matches the branch's actual
    /// tip must not be trusted for `-D`: a commit landed on the branch after
    /// whatever scan produced that SHA, and force-deleting on stale evidence
    /// would discard it. This is exactly the TOCTOU gap re-reading the tip
    /// immediately before the delete decision closes.
    @Test func fastLocalRemoveKeepsSquashMergedBranchWhenVerifiedSHAIsStale() async throws {
        let repo = try await makeRepo()
        let destination = repo.deletingLastPathComponent()
            .appendingPathComponent("\(repo.lastPathComponent)-squash-stale")
        defer {
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.removeItem(at: repo)
        }
        let service = WorktreeService()
        let worktree = try await service.add(
            repoPath: repo,
            base: "main",
            branch: "feature/squash-stale",
            destination: destination,
            projectId: "p"
        )
        try "content".write(
            to: destination.appendingPathComponent("file.txt"),
            atomically: true,
            encoding: .utf8
        )
        _ = try await Process.git(["add", "."], cwd: destination)
        _ = try await Process.git(["commit", "-q", "-m", "feature work"], cwd: destination)
        let staleSHA = "0000000000000000000000000000000000000000"
        let squash = try await Process.git(["merge", "--squash", "feature/squash-stale"], cwd: repo)
        #expect(squash.exitCode == 0)
        let squashCommit = try await Process.git(["commit", "-q", "-m", "squashed"], cwd: repo)
        #expect(squashCommit.exitCode == 0)

        // A new commit lands on the branch after the (stale) SHA was
        // "verified" — simulating the exact race the re-check guards
        // against.
        try "more".write(
            to: destination.appendingPathComponent("file2.txt"),
            atomically: true,
            encoding: .utf8
        )
        _ = try await Process.git(["add", "."], cwd: destination)
        _ = try await Process.git(["commit", "-q", "-m", "one more commit"], cwd: destination)

        let outcome = try await service.removeFastLocal(
            repoPath: repo,
            worktree: worktree,
            deleteBranchIfMerged: true,
            force: false,
            verifiedMergedBranchSHA: staleSHA
        )
        guard case .staged(let ticket) = outcome else {
            Issue.record("Expected staged removal")
            return
        }
        defer { try? FileManager.default.removeItem(at: ticket.trashRoot) }

        let branches = try await Process.git(["branch", "--list", "feature/squash-stale"], cwd: repo)
        #expect(!branches.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test func fastLocalRemoveReportsBothPathsWhenRollbackFails() async throws {
        let fixture = try await makeLinkedWorktree(suffix: "rollback-fails")
        defer { fixture.removeFiles() }
        _ = try await Process.git(["worktree", "lock", fixture.worktree.path.path], cwd: fixture.repo)
        let originalPath = fixture.worktree.path.standardizedFileURL

        do {
            _ = try await fixture.service.removeFastLocal(
                repoPath: fixture.repo,
                worktree: fixture.worktree,
                deleteBranchIfMerged: false,
                force: false,
                moveItem: { source, destination in
                    if source.standardizedFileURL == originalPath {
                        try FileManager.default.moveItem(at: source, to: destination)
                        try "collision".write(to: source, atomically: true, encoding: .utf8)
                    } else {
                        throw CocoaError(.fileWriteFileExists)
                    }
                }
            )
            Issue.record("Expected registry and rollback failure")
        } catch {
            let message = error.localizedDescription
            #expect(message.contains(fixture.worktree.path.path))
            let trash = WorktreeTrash.root(
                commonGitDirectory: fixture.repo.appendingPathComponent(".git")
            )
            let staged = try #require(
                FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil).first
            )
            #expect(message.contains(staged.path))
            #expect(FileManager.default.fileExists(atPath: staged.appendingPathComponent(".git").path))
            try? FileManager.default.removeItem(at: trash)
        }
    }

    @Test func fastLocalRemoveRollbackFailureIsNotSweepEligible() async throws {
        let fixture = try await makeLinkedWorktree(suffix: "rollback-not-committed")
        defer { fixture.removeFiles() }
        _ = try await Process.git(["worktree", "lock", fixture.worktree.path.path], cwd: fixture.repo)
        let originalPath = fixture.worktree.path.standardizedFileURL

        await #expect(throws: WorktreeService.WorktreeError.self) {
            try await fixture.service.removeFastLocal(
                repoPath: fixture.repo,
                worktree: fixture.worktree,
                deleteBranchIfMerged: false,
                force: false,
                moveItem: { source, destination in
                    if source.standardizedFileURL == originalPath {
                        try FileManager.default.moveItem(at: source, to: destination)
                        try "collision".write(to: source, atomically: true, encoding: .utf8)
                    } else {
                        throw CocoaError(.fileWriteFileExists)
                    }
                }
            )
        }

        let common = fixture.repo.appendingPathComponent(".git")
        let staged = try #require(
            FileManager.default.contentsOfDirectory(
                at: WorktreeTrash.root(commonGitDirectory: common),
                includingPropertiesForKeys: nil
            ).first
        )
        #expect(FileManager.default.fileExists(atPath: staged.appendingPathComponent(".git").path))
        #expect(WorktreeTrash.staleTickets(
            commonGitDirectories: [common],
            olderThan: .distantFuture
        ).isEmpty)
    }

    @Test func rollbackFailureIgnoresCommitMarkerLookalikeInsideWorktree() async throws {
        let fixture = try await makeLinkedWorktree(suffix: "rollback-marker-lookalike")
        defer { fixture.removeFiles() }
        try ".alas-worktree-deletion-committed\n".write(
            to: fixture.repo.appendingPathComponent(".git/info/exclude"),
            atomically: true,
            encoding: .utf8
        )
        try "1\n".write(
            to: fixture.worktree.path.appendingPathComponent(".alas-worktree-deletion-committed"),
            atomically: true,
            encoding: .utf8
        )
        _ = try await Process.git(["worktree", "lock", fixture.worktree.path.path], cwd: fixture.repo)
        let originalPath = fixture.worktree.path.standardizedFileURL

        await #expect(throws: WorktreeService.WorktreeError.self) {
            try await fixture.service.removeFastLocal(
                repoPath: fixture.repo,
                worktree: fixture.worktree,
                deleteBranchIfMerged: false,
                force: false,
                moveItem: { source, destination in
                    if source.standardizedFileURL == originalPath {
                        try FileManager.default.moveItem(at: source, to: destination)
                        try "collision".write(to: source, atomically: true, encoding: .utf8)
                    } else {
                        throw CocoaError(.fileWriteFileExists)
                    }
                }
            )
        }

        #expect(WorktreeTrash.staleTickets(
            commonGitDirectories: [fixture.repo.appendingPathComponent(".git")],
            olderThan: .distantFuture
        ).isEmpty)
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

    private struct MissingLFSFixture {
        let repo: URL
        let destination: URL
        let worktree: Worktree
        let marker: URL

        func removeFiles() {
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.removeItem(at: repo)
        }
    }

    private func makeMissingLFSFixture(suffix: String) async throws -> MissingLFSFixture {
        let repo = try await makeRepo()
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
            .appendingPathComponent("\(repo.lastPathComponent)-\(suffix)")
        let branch = "feat/\(suffix)"
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
        return MissingLFSFixture(
            repo: repo,
            destination: dest,
            worktree: wt,
            marker: dest.appendingPathComponent("data.bin")
        )
    }

    @Test func removeRetriesWithoutLFSFiltersWhenGitStatusRequiresMissingLFS() async throws {
        let fixture = try await makeMissingLFSFixture(suffix: "missing-lfs-remove")
        defer { fixture.removeFiles() }

        try await WorktreeService().remove(
            repoPath: fixture.repo,
            worktree: fixture.worktree,
            deleteBranchIfMerged: false
        )

        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    @Test func fastLocalRemovePreservesMissingLFSCleanSemantics() async throws {
        let fixture = try await makeMissingLFSFixture(suffix: "fast-missing-lfs")
        defer { fixture.removeFiles() }

        let outcome = try await WorktreeService().removeFastLocal(
            repoPath: fixture.repo,
            worktree: fixture.worktree,
            deleteBranchIfMerged: false
        )
        guard case .staged(let ticket) = outcome else {
            Issue.record("Expected staged removal")
            return
        }
        defer { try? FileManager.default.removeItem(at: ticket.trashRoot) }

        #expect(!FileManager.default.fileExists(atPath: fixture.worktree.path.path))
        #expect(FileManager.default.fileExists(
            atPath: ticket.stagedPath.appendingPathComponent(fixture.marker.lastPathComponent).path
        ))
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

        func removeFiles() {
            try? FileManager.default.removeItem(at: worktree.path)
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: submoduleRepo)
        }
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

    @Test func fastLocalRemoveSupportsInitializedSubmodulesAfterForceApproval() async throws {
        let fixture = try await makeRepoWithInitializedSubmodule(suffix: "fast-submodule")
        defer { fixture.removeFiles() }

        let outcome = try await fixture.service.removeFastLocal(
            repoPath: fixture.repo,
            worktree: fixture.worktree,
            deleteBranchIfMerged: false,
            force: true
        )
        guard case .staged(let ticket) = outcome else {
            Issue.record("Expected staged removal")
            return
        }
        defer { try? FileManager.default.removeItem(at: ticket.trashRoot) }

        let listed = try await fixture.service.list(repoPath: fixture.repo, projectId: "p")
        #expect(listed.count == 1)
    }

    @Test func fastLocalRemoveRestoresWhenSubmoduleLocalStateAppearsAfterApproval() async throws {
        let fixture = try await makeRepoWithInitializedSubmodule(
            suffix: "fast-submodule-local-state-race"
        )
        let trashRoot = WorktreeTrash.root(
            commonGitDirectory: fixture.repo.appendingPathComponent(".git")
        )
        defer {
            try? FileManager.default.removeItem(at: trashRoot)
            fixture.removeFiles()
        }

        await #expect(throws: WorktreeService.WorktreeError.self) {
            try await fixture.service.removeFastLocal(
                repoPath: fixture.repo,
                worktree: fixture.worktree,
                deleteBranchIfMerged: false,
                force: true,
                moveItem: { source, destination in
                    if source.standardizedFileURL == fixture.worktree.path.standardizedFileURL {
                        let submodule = source.appendingPathComponent("Deps/Submodule")
                        let process = Foundation.Process()
                        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                        process.arguments = ["tag", "local-after-approval"]
                        process.currentDirectoryURL = submodule
                        try process.run()
                        process.waitUntilExit()
                        guard process.terminationStatus == 0 else {
                            throw CocoaError(.fileWriteUnknown)
                        }
                    }
                    try FileManager.default.moveItem(at: source, to: destination)
                }
            )
        }

        #expect(FileManager.default.fileExists(atPath: fixture.worktree.path.path))
        #expect(FileManager.default.fileExists(
            atPath: fixture.worktree.path.appendingPathComponent("Deps/Submodule").path
        ))
        let registrations = try await Process.git(
            ["worktree", "list", "--porcelain"],
            cwd: fixture.repo
        )
        #expect(registrations.stdout.contains(fixture.worktree.path.path))
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
