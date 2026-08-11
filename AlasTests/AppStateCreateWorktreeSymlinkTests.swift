import Foundation
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct AppStateCreateWorktreeSymlinkTests {
    private func makeRepo(name: String) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-symlink-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: dir)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "init"], cwd: dir)
        return dir
    }

    /// Wait for the async `createWorktree` Task to clear the `.creating`
    /// operation state, or fail the test if it never does.
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

    @Test
    func createWorktreeThroughSymlinkDoesNotDuplicateRow() async throws {
        // Layout:
        //   <tmp>/real/        — actual repo
        //   <tmp>/link         — symlink → <tmp>/real
        // The destination URL is built through `link`, so its un-resolved
        // form differs from git's canonical output.
        let realRepo = try await makeRepo(name: "real")
        let parent = realRepo.deletingLastPathComponent()
        let linkURL = parent.appendingPathComponent("link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: realRepo)
        defer {
            try? FileManager.default.removeItem(at: linkURL)
            try? FileManager.default.removeItem(at: realRepo)
        }

        let state = AppState()
        // Register the project using the real (resolved) path so the
        // project itself isn't the variable under test.
        let project = try await state.projectsManager.addProject(
            path: realRepo,
            displayName: "symlink-repo",
            color: "#5fb7c4"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        #expect(state.projectsManager.worktrees(projectId: project.id).count == 1)

        // Destination URL routes through the symlink. The un-resolved
        // form has parent = <tmp>/link; the resolved form has
        // parent = <tmp>/real, which is what `git worktree list` will
        // report.
        let destinationThroughSymlink = linkURL.appendingPathComponent("wt-symlink")

        let optimisticId = await state.createWorktree(
            projectId: project.id,
            base: "main",
            branch: "symlink-branch",
            destination: destinationThroughSymlink,
            runStartup: false,
            launchSurface: .none
        )
        #expect(!optimisticId.isEmpty)

        try await waitForOperationToClear(state.projectsManager, id: optimisticId)

        // Exactly one row for the new branch, no lingering `.creating`
        // state, and the surviving row's id matches the optimistic id so
        // `selectedWorktreeId` and tab/terminal routing target the live row.
        let trees = state.projectsManager.worktrees(projectId: project.id)
        let newRows = trees.filter { $0.branch == "symlink-branch" }
        #expect(newRows.count == 1)
        #expect(newRows.first?.id == optimisticId)
        #expect(state.projectsManager.operationState(for: optimisticId) == nil)
        #expect(state.selectedWorktreeId == optimisticId)
    }

    @Test
    func liveMissionCreationAvoidsCollisionAtPreparedSymlinkDestination() async throws {
        let realRepo = try await makeRepo(name: "mission-real")
        let persistenceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-mission-symlink-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: persistenceDirectory, withIntermediateDirectories: true)
        let parent = realRepo.deletingLastPathComponent()
        let linkURL = parent.appendingPathComponent("mission-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: realRepo)
        defer {
            try? FileManager.default.removeItem(at: persistenceDirectory)
            try? FileManager.default.removeItem(at: linkURL)
            try? FileManager.default.removeItem(at: realRepo)
        }

        let state = AppState(missionPersistence: MissionPersistence(
            path: persistenceDirectory.appendingPathComponent("missions.sqlite").path
        ), missionsEnabled: true)
        let project = try await state.projectsManager.addProject(
            path: realRepo,
            displayName: "mission-symlink-repo",
            color: "#5fb7c4"
        )
        let rawDestination = linkURL.appendingPathComponent("mission-worktree")
        let preparedDestination = realRepo.appendingPathComponent("mission-worktree")
        state.projectsManager.insertOptimisticWorktree(Worktree(
            id: "occupied-mission-worktree",
            projectId: project.id,
            name: "occupied",
            branch: "occupied",
            path: preparedDestination,
            status: .clean,
            lastActivity: .now
        ))
        let draft = MissionDraft(
            source: IssueSnapshot(codeHostIssue: MissionFixtures.issue()),
            projectId: project.id,
            baseRef: "missing-base",
            branch: "mission-symlink-branch",
            destinationPath: rawDestination.path,
            agentId: "codex",
            initialPromptId: UUID(),
            initialPrompt: "Investigate."
        )

        let id = try await NewMissionDialogModel.Environment.live(state: state)
            .createMission(draft, false)
        let aggregate = try #require(state.missions.aggregate(id: id))

        #expect(aggregate.primaryLeg?.destinationPath == "\(preparedDestination.path)-2")
    }
}
