import Foundation
import Testing
@testable import Alas

@MainActor
@Suite(.serialized)
struct AppStateFocusMainWorktreeTests {
    private struct MemoryStore: PersistenceStoreProtocol {
        let projectsFile: ProjectsFile

        func write<T: Encodable>(_: T, to _: URL) throws {}

        func readIfExists<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
            if type == ProjectsFile.self {
                return projectsFile as? T
            }
            if type == AppConfig.self {
                return AppConfig.defaults as? T
            }
            return nil
        }
    }

    private func makeState(project: ProjectConfig) -> AppState {
        AppState(store: MemoryStore(projectsFile: ProjectsFile(projects: [project])))
    }

    private func worktree(path: String, branch: String, projectId: String = "p1") -> Worktree {
        let url = URL(fileURLWithPath: path)
        return Worktree(
            id: Worktree.makeId(path: url),
            projectId: projectId,
            name: branch,
            branch: branch,
            path: url,
            status: .clean,
            lastActivity: Date()
        )
    }

    /// A real clone resolves a lineage marker inside its `.git`, which the
    /// right pane needs for checkpoint gate clearance before a pull runs.
    private func gitWorktree(path: String, branch: String) -> Worktree {
        let url = URL(fileURLWithPath: path)
        return Worktree(
            id: Worktree.makeId(path: url),
            projectId: "p1",
            name: branch,
            branch: branch,
            path: url,
            status: .clean,
            lastActivity: Date(),
            lineageID: WorktreeService.localLineageID(forWorktreeAt: url)
        )
    }

    @Test func focusesVisibleMainWorktreeForCurrentProject() {
        let project = ProjectConfig(
            id: "p1",
            name: "p1",
            path: "/repo",
            color: "blue",
            addedAt: Date()
        )
        let state = makeState(project: project)
        let main = worktree(path: "/repo", branch: "main")
        let feature = worktree(path: "/repo/wts/feature", branch: "feature")
        state.projectsManager.insertOptimisticWorktree(feature)
        state.projectsManager.insertOptimisticWorktree(main)
        state.selectedWorktreeId = feature.id

        state.focusMainWorktreeForCurrentProject()

        #expect(state.selectedWorktreeId == main.id)
        #expect(state.canFocusMainWorktreeForCurrentProject)
    }

    @Test func focusMainWorktreeNoOpsWhenMainIsNotVisible() {
        let project = ProjectConfig(
            id: "p1",
            name: "p1",
            path: "/repo",
            color: "blue",
            addedAt: Date(),
            hiddenWorktreePaths: ["/repo"]
        )
        let state = makeState(project: project)
        let main = worktree(path: "/repo", branch: "main")
        let feature = worktree(path: "/repo/wts/feature", branch: "feature")
        state.projectsManager.insertOptimisticWorktree(feature)
        state.projectsManager.insertOptimisticWorktree(main)
        state.selectedWorktreeId = feature.id

        state.focusMainWorktreeForCurrentProject()

        #expect(state.selectedWorktreeId == feature.id)
        #expect(!state.canFocusMainWorktreeForCurrentProject)
    }

    // MARK: - Sidebar upstream pull click semantics

    /// Seeds a project whose feature worktree is selected, and returns the
    /// ids needed to drive the sidebar's `↓N` badge clicks on its main.
    private func makePullClickFixture() -> (state: AppState, mainID: String) {
        let project = ProjectConfig(
            id: "p1",
            name: "p1",
            path: "/repo",
            color: "blue",
            addedAt: Date()
        )
        let state = makeState(project: project)
        let main = worktree(path: "/repo", branch: "main")
        let feature = worktree(path: "/repo/wts/feature", branch: "feature")
        state.projectsManager.insertOptimisticWorktree(feature)
        state.projectsManager.insertOptimisticWorktree(main)
        state.selectedWorktreeId = feature.id
        return (state, main.id)
    }

    @Test func sidebarPullKeepsSelectionOnFirstClick() {
        let (state, mainID) = makePullClickFixture()

        state.pullWorktreeFromSidebar(id: mainID)

        // The pull may not have been admitted (the path has no git repo),
        // but either way the first click must not move the selection.
        #expect(state.selectedWorktreeId != mainID)
        #expect(state.worktreeUpstreamStatusStore.isPullingUpstream(worktreeID: mainID))
    }

    @Test func sidebarPullSecondClickWhileInFlightSelectsWorktree() {
        let (state, mainID) = makePullClickFixture()
        state.worktreeUpstreamStatusStore.markPullingUpstream(worktreeID: mainID)

        state.pullWorktreeFromSidebar(id: mainID)

        #expect(state.selectedWorktreeId == mainID)
        // The in-flight pull is untouched: the second click routes to
        // selection only.
        #expect(state.worktreeUpstreamStatusStore.isPullingUpstream(worktreeID: mainID))
    }

    // MARK: - Sidebar pull outcome notifications name the repository

    /// Clone on `main` tracking `origin/main` at the base commit. Built once
    /// per process and copied per test; git stays real per AGENTS.md.
    private struct GitFixture: Sendable {
        let clone: URL
        let remote: URL

        func remove() {
            try? FileManager.default.removeItem(at: clone)
            try? FileManager.default.removeItem(at: remote)
        }
    }

    private static let baseFixtureTemplate = Task { try await buildBaseFixture() }

    private static func buildBaseFixture() async throws -> GitFixture {
        let remote = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-pullnotif-rmt-\(UUID().uuidString)")
        let seed = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-pullnotif-seed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: seed) }
        _ = try await Process.git(["init", "--bare", "-q", remote.path], cwd: nil)
        _ = try await Process.git(["clone", "-q", remote.path, seed.path], cwd: nil)
        _ = try await Process.git(["config", "user.email", "s@e"], cwd: seed)
        _ = try await Process.git(["config", "user.name", "s"], cwd: seed)
        _ = try await Process.git(["config", "commit.gpgsign", "false"], cwd: seed)
        _ = try await Process.git(["checkout", "-q", "-b", "main"], cwd: seed)
        try "base\n".write(to: seed.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "a.txt"], cwd: seed)
        _ = try await Process.git(["commit", "-q", "-m", "base"], cwd: seed)
        _ = try await Process.git(["push", "-q", "-u", "origin", "main"], cwd: seed)
        _ = try await Process.git(["--git-dir", remote.path, "symbolic-ref", "HEAD", "refs/heads/main"], cwd: nil)

        let clone = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-pullnotif-clone-\(UUID().uuidString)")
        _ = try await Process.git(["clone", "-q", remote.path, clone.path], cwd: nil)
        // Local to the template clone and inherited by every copy: copies
        // commit locally (the conflict case) and must not depend on the
        // developer machine's global identity or signing config.
        _ = try await Process.git(["config", "user.email", "c@e"], cwd: clone)
        _ = try await Process.git(["config", "user.name", "c"], cwd: clone)
        _ = try await Process.git(["config", "commit.gpgsign", "false"], cwd: clone)
        return GitFixture(clone: clone, remote: remote)
    }

    /// Copy of the shared base fixture: a fresh clone tracking a bare remote
    /// whose `main` is at the base commit.
    private func makeCloneFixture() async throws -> GitFixture {
        let template = try await Self.baseFixtureTemplate.value
        let copy = GitFixture(
            clone: FileManager.default.temporaryDirectory
                .appendingPathComponent("alas-pullnotif-clone-\(UUID().uuidString)"),
            remote: FileManager.default.temporaryDirectory
                .appendingPathComponent("alas-pullnotif-rmt-\(UUID().uuidString)")
        )
        try FileManager.default.copyItem(at: template.clone, to: copy.clone)
        try FileManager.default.copyItem(at: template.remote, to: copy.remote)
        _ = try await Process.git(["remote", "set-url", "origin", copy.remote.path], cwd: copy.clone)
        // Copying rewrites every stat field the index cached for tracked files.
        _ = try await Process.git(["update-index", "-q", "--refresh"], cwd: copy.clone)
        return copy
    }

    /// Pushes one commit touching `file` from a throwaway clone.
    private static func pushToRemoteMain(_ fixture: GitFixture, file: String, contents: String) async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-pullnotif-push-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = try await Process.git(["clone", "-q", fixture.remote.path, tmp.path], cwd: nil)
        _ = try await Process.git(["config", "user.email", "x@e"], cwd: tmp)
        _ = try await Process.git(["config", "user.name", "x"], cwd: tmp)
        _ = try await Process.git(["config", "commit.gpgsign", "false"], cwd: tmp)
        try contents.write(to: tmp.appendingPathComponent(file), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", file], cwd: tmp)
        _ = try await Process.git(["commit", "-q", "-m", "remote edit"], cwd: tmp)
        _ = try await Process.git(["push", "-q", "origin", "main"], cwd: tmp)
    }

    private func makeGitFixtureState(clone: URL) -> AppState {
        // A project name distinct from the branch and from the clone's last
        // path component, so a regression to either fails.
        let project = ProjectConfig(
            id: "p1",
            name: "Fixture Repo",
            path: clone.path,
            color: "blue",
            addedAt: Date()
        )
        let state = AppState(store: MemoryStore(projectsFile: ProjectsFile(projects: [project])))
        let main = gitWorktree(path: clone.path, branch: "main")
        state.projectsManager.insertOptimisticWorktree(main)
        // Selecting the pulled worktree is the sidebar flow being exercised —
        // the banner surface posts under it.
        state.selectedWorktreeId = main.id
        return state
    }

    /// Polls `condition` up to ~15s and reports failure on the deadline. The
    /// sidebar pull posts asynchronously on the main actor after a dozen real
    /// git processes, which a loaded CI runner can stretch past five seconds.
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }

    /// The sidebar pull task clears the pulling flag last — after the
    /// notification, before and after it awaits the final upstream-status
    /// refresh — so the flag dropping is the terminal event. Assertions and
    /// cleanup below must not race that background git work.
    private func awaitPullCompletion(_ state: AppState, worktreeID: String) async throws {
        try await waitUntil {
            !state.inAppNotifications.entries.isEmpty
                && !state.worktreeUpstreamStatusStore.isPullingUpstream(worktreeID: worktreeID)
        }
    }

    @Test func sidebarPullSuccessNotificationNamesRepo() async throws {
        let fixture = try await makeCloneFixture()
        defer { fixture.remove() }
        try await Self.pushToRemoteMain(fixture, file: "b.txt", contents: "new\n")
        let state = makeGitFixtureState(clone: fixture.clone)

        state.pullWorktreeFromSidebar(id: Worktree.makeId(path: fixture.clone))
        try await awaitPullCompletion(state, worktreeID: Worktree.makeId(path: fixture.clone))

        #expect(state.inAppNotifications.entries.map(\.message) == ["Pulled main from Fixture Repo"])
        #expect(state.inAppNotifications.entries.map(\.severity) == [.success])
    }

    @Test func sidebarPullConflictNotificationNamesRepo() async throws {
        let fixture = try await makeCloneFixture()
        defer { fixture.remove() }
        // Local edit of a.txt conflicts with the pushed remote edit of a.txt.
        try "local change\n".write(to: fixture.clone.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["commit", "-q", "-am", "local edit"], cwd: fixture.clone)
        try await Self.pushToRemoteMain(fixture, file: "a.txt", contents: "remote change\n")
        let state = makeGitFixtureState(clone: fixture.clone)

        state.pullWorktreeFromSidebar(id: Worktree.makeId(path: fixture.clone))
        try await awaitPullCompletion(state, worktreeID: Worktree.makeId(path: fixture.clone))

        #expect(state.inAppNotifications.entries.map(\.message) == ["Pull of main in Fixture Repo hit conflicts"])
        #expect(state.inAppNotifications.entries.map(\.severity) == [.error])
        // The conflict leaves the clone mid-rebase; abort before cleanup.
        _ = try? await Process.git(["rebase", "--abort"], cwd: fixture.clone)
    }

    @Test func sidebarPullErrorNotificationNamesRepo() async throws {
        let fixture = try await makeCloneFixture()
        defer { fixture.remove() }
        try await Self.pushToRemoteMain(fixture, file: "b.txt", contents: "new\n")
        // An unstaged tracked-file modification blocks the rebase step of the
        // pull with a non-conflict exit, deterministically reaching .error.
        try "dirty\n".write(to: fixture.clone.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let state = makeGitFixtureState(clone: fixture.clone)

        state.pullWorktreeFromSidebar(id: Worktree.makeId(path: fixture.clone))
        try await awaitPullCompletion(state, worktreeID: Worktree.makeId(path: fixture.clone))

        guard let entry = state.inAppNotifications.entries.first else {
            Issue.record("no notification was posted")
            return
        }
        #expect(entry.severity == .error)
        // Only the prefix is pinned: the tail is git's stderr text.
        #expect(entry.message.hasPrefix("Pull of main in Fixture Repo failed:"))
    }
}
