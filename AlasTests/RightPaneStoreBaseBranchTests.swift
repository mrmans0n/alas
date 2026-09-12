import Testing
import Foundation
@testable import Alas

@MainActor
@Suite(.serialized)
struct RightPaneStoreBaseBranchTests {
    private func makeWorktree(at path: URL, branch: String) -> Worktree {
        Worktree(
            id: Worktree.makeId(path: path),
            projectId: "test-project",
            name: branch,
            branch: branch,
            path: path,
            status: .clean,
            lastActivity: Date()
        )
    }

    private func makeRepoOnMain(branch: String = "main") async throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-basebranch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", branch], cwd: tmp)
        _ = try await Process.git(["config", "user.email", "t@e.com"], cwd: tmp)
        _ = try await Process.git(["config", "user.name", "t"], cwd: tmp)
        try "1\n".write(to: tmp.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "."], cwd: tmp)
        _ = try await Process.git(["commit", "-q", "-m", "feat: initial"], cwd: tmp)
        return tmp
    }

    @Test func effectiveBaseBranchSwitchesToOriginWhenOnBase() {
        let wt = makeWorktree(at: URL(fileURLWithPath: "/tmp/main"), branch: "main")
        #expect(RightPaneStore.effectiveBaseBranch(worktree: wt, baseBranch: "main") == "origin/main")
    }

    @Test func effectiveBaseBranchKeepsBaseWhenOnDifferentBranch() {
        let wt = makeWorktree(at: URL(fileURLWithPath: "/tmp/feature"), branch: "feature/x")
        #expect(RightPaneStore.effectiveBaseBranch(worktree: wt, baseBranch: "main") == "main")
    }

    @Test func effectiveBaseBranchIsNoOpForEmptyBaseBranch() {
        let wt = makeWorktree(at: URL(fileURLWithPath: "/tmp/empty"), branch: "main")
        #expect(RightPaneStore.effectiveBaseBranch(worktree: wt, baseBranch: "").isEmpty)
    }

    @Test func effectiveBaseBranchRespectsRemoteQualifiedBase() {
        let wt = makeWorktree(at: URL(fileURLWithPath: "/tmp/upstream"), branch: "upstream/main")
        #expect(RightPaneStore.effectiveBaseBranch(worktree: wt, baseBranch: "upstream/main") == "origin/upstream/main")
    }

    @Test func cachedReviewSnapshotRequiresTheConfiguredBaseBranch() async throws {
        let repo = try await makeRepoOnMain()
        defer { try? FileManager.default.removeItem(at: repo) }
        let worktree = makeWorktree(at: repo, branch: "feature/cache-base")
        let store = RightPaneStore(git: GitService())
        let state = store.state(for: worktree, baseBranch: "main", comparisonMode: .manual)

        await state.refresh(forceReviewLoopRemote: true)

        #expect(store.reviewSnapshot(worktreeId: worktree.id, baseBranch: "main") != nil)
        #expect(store.reviewSnapshot(worktreeId: worktree.id, baseBranch: "release") == nil)
    }

    @Test func activeStateRequiresTheConfiguredReviewBase() async throws {
        let repo = try await makeRepoOnMain()
        defer { try? FileManager.default.removeItem(at: repo) }
        let worktree = makeWorktree(at: repo, branch: "feature/mission-summary")
        let store = RightPaneStore(git: GitService())
        let state = store.state(for: worktree, baseBranch: "main", comparisonMode: .manual)

        #expect(store.activeState(worktreeId: worktree.id, baseBranch: "main") === state)
        #expect(store.activeState(worktreeId: worktree.id, baseBranch: "release") == nil)
    }

    @Test func reactivatingRightPaneDefaultsToChangesTab() async throws {
        let repo = try await makeRepoOnMain()
        defer { try? FileManager.default.removeItem(at: repo) }
        let worktree = makeWorktree(at: repo, branch: "feature/default-tab")
        let store = RightPaneStore(git: GitService())

        let state = store.state(for: worktree, baseBranch: "main", comparisonMode: .manual)
        state.activeTab = .files

        store.deactivate()
        let backgroundState = store.state(for: worktree, baseBranch: "main", comparisonMode: .manual)

        #expect(backgroundState.activeTab == .files)

        store.prepareForVisiblePane(worktreeId: worktree.id)

        #expect(backgroundState.activeTab == .changes)
    }

    @Test func switchingWorktreesPreservesSelectedTab() async throws {
        let firstRepo = try await makeRepoOnMain()
        defer { try? FileManager.default.removeItem(at: firstRepo) }
        let secondRepo = try await makeRepoOnMain()
        defer { try? FileManager.default.removeItem(at: secondRepo) }
        let first = makeWorktree(at: firstRepo, branch: "feature/first")
        let second = makeWorktree(at: secondRepo, branch: "feature/second")
        let store = RightPaneStore(git: GitService())

        let firstState = store.state(for: first, baseBranch: "main", comparisonMode: .manual)
        firstState.activeTab = .files

        _ = store.state(for: second, baseBranch: "main", comparisonMode: .manual)
        let reactivated = store.state(for: first, baseBranch: "main", comparisonMode: .manual)

        #expect(reactivated.activeTab == .files)
    }

    @Test func pendingFileRevealKeepsFilesTabWhenPaneAppears() async throws {
        let repo = try await makeRepoOnMain()
        defer { try? FileManager.default.removeItem(at: repo) }
        let worktree = makeWorktree(at: repo, branch: "feature/reveal")
        let store = RightPaneStore(git: GitService())
        let state = store.state(for: worktree, baseBranch: "main", comparisonMode: .manual)

        state.reveal(path: "a.txt", opensPane: true)
        store.prepareForVisiblePane(worktreeId: worktree.id)

        #expect(state.activeTab == .files)
    }

    @Test func existingFileRevealDoesNotPreventDefaultTabWhenPaneReopens() async throws {
        let repo = try await makeRepoOnMain()
        defer { try? FileManager.default.removeItem(at: repo) }
        let worktree = makeWorktree(at: repo, branch: "feature/reveal-default")
        let store = RightPaneStore(git: GitService())
        let state = store.state(for: worktree, baseBranch: "main", comparisonMode: .manual)

        state.reveal(path: "a.txt")
        store.prepareForVisiblePane(worktreeId: worktree.id)

        #expect(state.activeTab == .changes)
    }

    @Test func visibleWorktreeSwitchConsumesPendingFileReveal() async throws {
        let repo = try await makeRepoOnMain()
        defer { try? FileManager.default.removeItem(at: repo) }
        let worktree = makeWorktree(at: repo, branch: "feature/reveal-switch")
        let store = RightPaneStore(git: GitService())
        let state = store.state(for: worktree, baseBranch: "main", comparisonMode: .manual)

        state.reveal(path: "a.txt", opensPane: true)
        store.consumePendingRevealForVisiblePane(worktreeId: worktree.id)
        store.prepareForVisiblePane(worktreeId: worktree.id)

        #expect(state.activeTab == .changes)
    }

    @Test func visiblePaneDefaultSurvivesInitialRefresh() async throws {
        let repo = try await makeRepoOnMain()
        defer { try? FileManager.default.removeItem(at: repo) }
        let worktree = makeWorktree(at: repo, branch: "feature/refresh-default")
        let store = RightPaneStore(git: GitService())
        let state = store.state(for: worktree, baseBranch: "main", comparisonMode: .manual)

        store.prepareForVisiblePane(worktreeId: worktree.id)
        await state.refresh(forceReviewLoopRemote: true)

        #expect(state.activeTab == .changes)
    }

    @Test func asyncProbeConfirmsSlashNamedOriginRef() async throws {
        let repo = try await makeRepoOnMain(branch: "release/1.0")
        defer { try? FileManager.default.removeItem(at: repo) }

        let head = try await Process.git(["rev-parse", "HEAD"], cwd: repo).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await Process.git(["update-ref", "refs/remotes/origin/release/1.0", head], cwd: repo)

        let store = RightPaneStore(git: GitService())
        let state = store.state(for: makeWorktree(at: repo, branch: "release/1.0"), baseBranch: "release/1.0", comparisonMode: .manual)
        #expect(state.baseBranch == "origin/release/1.0")

        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(state.baseBranch == "origin/release/1.0")
    }

    @Test func asyncProbeFallsBackForSlashNamedOriginRefWhenLocalBranchExists() async throws {
        let repo = try await makeRepoOnMain(branch: "release/1.0")
        defer { try? FileManager.default.removeItem(at: repo) }

        // No origin ref, but the local branch release/1.0 exists. The generic
        // resolver would return the local branch; our direct origin probe must
        // fall back to the configured base branch instead.
        let store = RightPaneStore(git: GitService())
        let state = store.state(for: makeWorktree(at: repo, branch: "release/1.0"), baseBranch: "release/1.0", comparisonMode: .manual)
        #expect(state.baseBranch == "origin/release/1.0")

        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(state.baseBranch == "release/1.0")
    }

    @Test func stateRemembersVerifiedFallbackAcrossRenders() async throws {
        let repo = try await makeRepoOnMain()
        defer { try? FileManager.default.removeItem(at: repo) }

        let store = RightPaneStore(git: GitService())
        let wt = makeWorktree(at: repo, branch: "main")
        let state = store.state(for: wt, baseBranch: "main", comparisonMode: .manual)
        #expect(state.baseBranch == "origin/main")
        #expect(state.lastConfigBaseBranch == "main")

        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(state.baseBranch == "main")
        #expect(state.lastConfigBaseBranch == "main")

        // Simulate repeated renders with the same configured base branch. The
        // store must not reset baseBranch back to the non-existent origin/main
        // or re-trigger fallback probes each time.
        for _ in 0..<3 {
            _ = store.state(for: wt, baseBranch: "main", comparisonMode: .manual)
            try await Task.sleep(nanoseconds: 50_000_000)
            #expect(state.baseBranch == "main")
            #expect(state.lastConfigBaseBranch == "main")
            #expect(state.userOverrodeBaseBranch == false)
        }
    }

    @Test func asyncProbeConfirmsOriginMainWhenRefExists() async throws {
        let repo = try await makeRepoOnMain()
        defer { try? FileManager.default.removeItem(at: repo) }

        let head = try await Process.git(["rev-parse", "HEAD"], cwd: repo).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await Process.git(["update-ref", "refs/remotes/origin/main", head], cwd: repo)

        let store = RightPaneStore(git: GitService())
        let state = store.state(for: makeWorktree(at: repo, branch: "main"), baseBranch: "main", comparisonMode: .manual)
        #expect(state.baseBranch == "origin/main")

        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(state.baseBranch == "origin/main")
    }

    @Test func asyncProbeFallsBackWhenOriginMainMissing() async throws {
        let repo = try await makeRepoOnMain()
        defer { try? FileManager.default.removeItem(at: repo) }

        let store = RightPaneStore(git: GitService())
        let state = store.state(for: makeWorktree(at: repo, branch: "main"), baseBranch: "main", comparisonMode: .manual)
        #expect(state.baseBranch == "origin/main")

        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(state.baseBranch == "main")
    }

    @Test func asyncProbeDoesNotOverrideUserSelection() async throws {
        let repo = try await makeRepoOnMain()
        defer { try? FileManager.default.removeItem(at: repo) }

        let head = try await Process.git(["rev-parse", "HEAD"], cwd: repo).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await Process.git(["update-ref", "refs/remotes/origin/main", head], cwd: repo)
        _ = try await Process.git(["branch", "develop"], cwd: repo)

        let store = RightPaneStore(git: GitService())
        let state = store.state(for: makeWorktree(at: repo, branch: "main"), baseBranch: "main", comparisonMode: .manual)
        #expect(state.baseBranch == "origin/main")

        state.selectBaseBranch("develop")
        #expect(state.userOverrodeBaseBranch)

        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(state.baseBranch == "develop")
    }
}
