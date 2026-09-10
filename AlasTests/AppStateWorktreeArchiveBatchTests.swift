import Testing
import Foundation
@testable import Alas

@MainActor
struct AppStateWorktreeArchiveBatchTests {
    @Test func batchArchiveHidesEveryItemWithoutTouchingDisk() async throws {
        let fixture = try await makeCleanupFixture(worktreeCount: 3)
        let targets = Array(fixture.worktrees.dropFirst())

        let results = fixture.state.batchArchiveWorktrees(targets)

        #expect(results.allSatisfy { $0.outcome == .archived })
        #expect(fixture.state.projectsManager
            .archivedWorktrees(projectId: fixture.project.id).count == targets.count)
        #expect(fixture.state.projectsManager
            .visibleWorktrees(projectId: fixture.project.id)
            .allSatisfy { wt in !targets.contains { $0.id == wt.id } })
        // Files are untouched.
        for target in targets {
            #expect(FileManager.default.fileExists(atPath: target.path.path))
        }
    }

    @Test func batchArchiveSkipsMainWorktree() async throws {
        let fixture = try await makeCleanupFixture(worktreeCount: 2)
        let main = fixture.worktrees[0]

        let results = fixture.state.batchArchiveWorktrees([main])

        #expect(results[0].outcome == .skipped(reason: "Main worktree"))
        #expect(fixture.state.projectsManager
            .archivedWorktrees(projectId: fixture.project.id).isEmpty)
    }

    @Test func archiveRoundTripRestoresTheWorktree() async throws {
        let fixture = try await makeCleanupFixture(worktreeCount: 2)
        let target = fixture.worktrees[1]

        _ = fixture.state.batchArchiveWorktrees([target])
        #expect(fixture.state.projectsManager
            .visibleWorktrees(projectId: fixture.project.id)
            .contains { $0.id == target.id } == false)

        fixture.state.unarchiveWorktree(
            projectId: fixture.project.id,
            path: target.path
        )
        #expect(fixture.state.projectsManager
            .visibleWorktrees(projectId: fixture.project.id)
            .contains { $0.id == target.id })
        #expect(fixture.state.projectsManager
            .archivedWorktrees(projectId: fixture.project.id).isEmpty)
    }

    /// Archive state lives in `ProjectConfig.hiddenWorktreePaths`, which is
    /// what persists to disk — so a config round-trip is the relaunch test.
    @Test func archivedStateSurvivesAConfigRoundTrip() throws {
        var project = ProjectConfig(
            id: "p",
            name: "alas",
            path: "/tmp/repo",
            color: "blue",
            addedAt: Date()
        )
        project.hiddenWorktreePaths = ["/tmp/wt-a", "/tmp/wt-b"]

        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(ProjectConfig.self, from: data)

        #expect(decoded.hiddenWorktreePaths == ["/tmp/wt-a", "/tmp/wt-b"])
    }

    @Test func unarchivedStateSurvivesAConfigRoundTrip() throws {
        var project = ProjectConfig(
            id: "p",
            name: "alas",
            path: "/tmp/repo",
            color: "blue",
            addedAt: Date(),
            hiddenWorktreePaths: ["/tmp/wt-a"]
        )
        project.hiddenWorktreePaths.removeAll { $0 == "/tmp/wt-a" }

        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(ProjectConfig.self, from: data)

        #expect(decoded.hiddenWorktreePaths.isEmpty)
    }
}
