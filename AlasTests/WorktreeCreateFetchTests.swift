import Testing
import Foundation
@testable import Alas

// Serialize: each test creates an ephemeral repo and shells out to git.
@Suite(.serialized)
struct GitServiceRemoteForFetchTests {
    private func makeRepoWithRemote() async throws -> (repo: URL, remote: URL) {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-remote-fetch-\(UUID().uuidString)")
        let remote = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-remote-fetch-rmt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: repo)
        _ = try await Process.git(["config", "user.email", "t@e"], cwd: repo)
        _ = try await Process.git(["config", "user.name", "t"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "init"], cwd: repo)
        _ = try await Process.git(["init", "--bare", "-q", remote.path], cwd: nil)
        _ = try await Process.git(["symbolic-ref", "HEAD", "refs/heads/main"], cwd: remote)
        _ = try await Process.git(["remote", "add", "origin", remote.path], cwd: repo)
        _ = try await Process.git(["push", "-q", "-u", "origin", "main"], cwd: repo)
        return (repo, remote)
    }

    @Test func remoteForFetchReturnsRemoteAndBranchForRemoteTrackingRef() async throws {
        let (repo, remote) = try await makeRepoWithRemote()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: remote)
        }
        let svc = GitService()
        let result = try await svc.remoteForFetch(worktreePath: repo, ref: "origin/main")
        #expect(result?.remote == "origin")
        #expect(result?.branch == "main")
    }

    @Test func remoteForFetchReturnsNilForLocalBranch() async throws {
        let (repo, remote) = try await makeRepoWithRemote()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: remote)
        }
        let svc = GitService()
        let result = try await svc.remoteForFetch(worktreePath: repo, ref: "main")
        #expect(result == nil)
    }

    @Test func remoteForFetchReturnsNilForSHA() async throws {
        let (repo, remote) = try await makeRepoWithRemote()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: remote)
        }
        let svc = GitService()
        let sha = try await svc.revParseHEAD(worktreePath: repo)
        let result = try await svc.remoteForFetch(worktreePath: repo, ref: sha)
        #expect(result == nil)
    }

    @Test func remoteForFetchReturnsNilForHEAD() async throws {
        let (repo, remote) = try await makeRepoWithRemote()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: remote)
        }
        let svc = GitService()
        let result = try await svc.remoteForFetch(worktreePath: repo, ref: "HEAD")
        #expect(result == nil)
    }

    @Test func remoteForFetchReturnsRemoteAndBranchForRefsWithSlashInBranchName() async throws {
        let (repo, remote) = try await makeRepoWithRemote()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: remote)
        }
        _ = try await Process.git(["checkout", "-q", "-b", "release/v1"], cwd: repo)
        _ = try await Process.git(["push", "-q", "-u", "origin", "release/v1"], cwd: repo)
        let svc = GitService()
        let result = try await svc.remoteForFetch(worktreePath: repo, ref: "origin/release/v1")
        #expect(result?.remote == "origin")
        #expect(result?.branch == "release/v1")
    }

    @Test func remoteForFetchReturnsNilWhenNoRemotesExist() async throws {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-no-remote-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: repo) }
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: repo)
        _ = try await Process.git(["config", "user.email", "t@e"], cwd: repo)
        _ = try await Process.git(["config", "user.name", "t"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "init"], cwd: repo)

        let svc = GitService()
        let result = try await svc.remoteForFetch(worktreePath: repo, ref: "origin/main")
        #expect(result == nil)
    }
}

@MainActor
@Suite(.serialized)
struct WorktreeCreateFetchTests {
    private func makeRepoWithRemote() async throws -> (repo: URL, remote: URL) {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-wt-fetch-\(UUID().uuidString)")
        let remote = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-wt-fetch-rmt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: repo)
        _ = try await Process.git(["config", "user.email", "t@e"], cwd: repo)
        _ = try await Process.git(["config", "user.name", "t"], cwd: repo)
        try "base\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "."], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "init"], cwd: repo)
        _ = try await Process.git(["init", "--bare", "-q", remote.path], cwd: nil)
        _ = try await Process.git(["symbolic-ref", "HEAD", "refs/heads/main"], cwd: remote)
        _ = try await Process.git(["remote", "add", "origin", remote.path], cwd: repo)
        _ = try await Process.git(["push", "-q", "-u", "origin", "main"], cwd: repo)
        return (repo, remote)
    }

    private func waitForOperationToClear(
        _ mgr: ProjectsManager,
        id: String,
        timeoutSeconds: Double = 10
    ) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if mgr.operationState(for: id) == nil { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        Issue.record("Timed out waiting for operationState to clear for id \(id)")
    }

    @Test func createWorktreeFetchesRemoteBaseWhenSettingEnabled() async throws {
        let (repo, remote) = try await makeRepoWithRemote()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: remote)
        }

        // Push a new commit to remote so local origin/main is behind
        let remoteClone = remote.deletingLastPathComponent()
            .appendingPathComponent("remote-clone-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: remoteClone) }
        _ = try await Process.git(["clone", "-q", remote.path, remoteClone.path], cwd: nil)
        _ = try await Process.git(["config", "user.email", "t@e"], cwd: remoteClone)
        _ = try await Process.git(["config", "user.name", "t"], cwd: remoteClone)
        try "new remote content\n".write(to: remoteClone.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["commit", "-q", "-am", "remote update"], cwd: remoteClone)
        _ = try await Process.git(["push", "-q", "origin", "main"], cwd: remoteClone)

        let state = AppState(store: MemoryStore())
        state.config.worktrees.fetchRemoteBeforeCreate = true
        let project = try await state.projectsManager.addProject(path: repo, displayName: "test", color: "#5fb7c4")
        try await state.projectsManager.refreshWorktrees(projectId: project.id)

        let dest = repo.appendingPathComponent("wt-fetched")
        let id = state.createWorktree(
            projectId: project.id,
            base: "origin/main",
            branch: "fetched-branch",
            destination: dest,
            runStartup: false,
            launchSurface: .none
        )
        #expect(!id.isEmpty)

        try await waitForOperationToClear(state.projectsManager, id: id)
        #expect(state.projectsManager.operationState(for: id) == nil)

        // The new worktree should have the latest remote content because fetch ran first
        let wtContent = try String(contentsOf: dest.appendingPathComponent("a.txt"), encoding: .utf8)
        #expect(wtContent.contains("new remote content"))
    }

    @Test func createWorktreeSkipsFetchForLocalBaseWhenSettingEnabled() async throws {
        let (repo, remote) = try await makeRepoWithRemote()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: remote)
        }

        let state = AppState(store: MemoryStore())
        state.config.worktrees.fetchRemoteBeforeCreate = true
        let project = try await state.projectsManager.addProject(path: repo, displayName: "test", color: "#5fb7c4")
        try await state.projectsManager.refreshWorktrees(projectId: project.id)

        let dest = repo.appendingPathComponent("wt-local")
        let id = state.createWorktree(
            projectId: project.id,
            base: "main",
            branch: "local-branch",
            destination: dest,
            runStartup: false,
            launchSurface: .none
        )
        #expect(!id.isEmpty)

        try await waitForOperationToClear(state.projectsManager, id: id)
        #expect(state.projectsManager.operationState(for: id) == nil)
        #expect(state.projectsManager.worktrees(projectId: project.id).contains { $0.id == id })
    }

    @Test func createWorktreeProceedsWhenFetchFails() async throws {
        let (repo, remote) = try await makeRepoWithRemote()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: remote)
        }

        // Ensure origin/main exists locally (via the initial fetch in makeRepoWithRemote)
        // Break the remote URL so subsequent fetch fails, but the local ref remains.
        _ = try await Process.git(["remote", "set-url", "origin", "/dev/null/nonexistent"], cwd: repo)

        let state = AppState(store: MemoryStore())
        state.config.worktrees.fetchRemoteBeforeCreate = true
        let project = try await state.projectsManager.addProject(path: repo, displayName: "test", color: "#5fb7c4")
        try await state.projectsManager.refreshWorktrees(projectId: project.id)

        let dest = repo.appendingPathComponent("wt-fail-continue")
        let id = state.createWorktree(
            projectId: project.id,
            base: "origin/main",
            branch: "fail-continue-branch",
            destination: dest,
            runStartup: false,
            launchSurface: .none
        )
        #expect(!id.isEmpty)

        try await waitForOperationToClear(state.projectsManager, id: id)
        #expect(state.projectsManager.operationState(for: id) == nil)
        #expect(state.projectsManager.worktrees(projectId: project.id).contains { $0.id == id })
    }

    @Test func createWorktreeSkipsFetchWhenSettingDisabled() async throws {
        let (repo, remote) = try await makeRepoWithRemote()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: remote)
        }

        let state = AppState(store: MemoryStore())
        state.config.worktrees.fetchRemoteBeforeCreate = false
        let project = try await state.projectsManager.addProject(path: repo, displayName: "test", color: "#5fb7c4")
        try await state.projectsManager.refreshWorktrees(projectId: project.id)

        let dest = repo.appendingPathComponent("wt-no-fetch")
        let id = state.createWorktree(
            projectId: project.id,
            base: "origin/main",
            branch: "no-fetch-branch",
            destination: dest,
            runStartup: false,
            launchSurface: .none
        )
        #expect(!id.isEmpty)

        try await waitForOperationToClear(state.projectsManager, id: id)
        #expect(state.projectsManager.operationState(for: id) == nil)
        #expect(state.projectsManager.worktrees(projectId: project.id).contains { $0.id == id })
    }

    private struct MemoryStore: PersistenceStoreProtocol {
        func write<T: Encodable>(_: T, to _: URL) throws {}
        func readIfExists<T: Decodable>(_: T.Type, from _: URL) throws -> T? { return nil }
    }
}
