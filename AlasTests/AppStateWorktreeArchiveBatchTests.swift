import Testing
import Foundation
@testable import Alas

@MainActor
struct AppStateWorktreeArchiveBatchTests {
    @Test func batchArchiveHidesEveryItemWithoutTouchingDisk() async throws {
        let fixture = try await makeCleanupFixture(worktreeCount: 3)
        defer { fixture.cleanUpAfterTest() }
        let targets = Array(fixture.worktrees.dropFirst())

        let results = await fixture.state.batchArchiveWorktrees(targets)

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

    /// A failed delete does not hold the worktree, so the cleanup sheet can
    /// select it and archiving it goes ahead, clearing the failure.
    @Test func batchArchiveArchivesAFailedDelete() async throws {
        let fixture = try await makeCleanupFixture(worktreeCount: 2)
        defer { fixture.cleanUpAfterTest() }
        let target = fixture.worktrees[1]
        fixture.state.core.failWorktreeClaim(try fixture.state.core.beginDelete(target), for: target, message: "permission denied")

        let results = await fixture.state.batchArchiveWorktrees([target])

        #expect(results.map(\.outcome) == [.archived])
        #expect(fixture.state.projectsManager.operationState(for: target) == nil)
    }

    @Test func batchArchiveSkipsMainWorktree() async throws {
        let fixture = try await makeCleanupFixture(worktreeCount: 2)
        defer { fixture.cleanUpAfterTest() }
        let main = fixture.worktrees[0]

        let results = await fixture.state.batchArchiveWorktrees([main])

        #expect(results[0].outcome == .skipped(reason: "Main worktree"))
        #expect(fixture.state.projectsManager
            .archivedWorktrees(projectId: fixture.project.id).isEmpty)
    }

    /// An open buffer can still be edited while the archive awaits; those
    /// edits were never acknowledged, so the archive is refused rather than
    /// closing their editor.
    @Test func archiveRefusesEditsMadeAfterTheUnsavedChangesWereAcknowledged() async throws {
        let environment = EditingBeforeQuiesce()
        let fixture = try await makeCleanupFixture(worktreeCount: 2, hostEnvironment: environment)
        defer { fixture.cleanUpAfterTest() }
        let target = fixture.worktrees[1]
        try "disk\n".write(to: target.path.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let tab = fixture.state.tabs.appendEditor(worktreeId: target.id, title: "a.txt", relativePath: "a.txt")
        let buffer = fixture.state.tabs.buffer(worktreeId: target.id, tabId: tab.id, worktreeRoot: target.path, relativePath: "a.txt")
        await buffer.awaitLoadForTesting()
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "acknowledged ")
        let authorization = WorktreeCleanupArchiveAuthorization(
            dirtyTabsByWorktree: [target.id: [tab.id: buffer.editGeneration]],
            sessionIDsByWorktree: [:],
            unavailableReasons: [:],
            bufferResolution: .discard
        )
        environment.edit = { buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "later ") }

        let results = await fixture.state.batchArchiveWorktrees(authorization, [target])

        #expect(results.map(\.outcome) == [.skipped(reason: AppState.UnacknowledgedEditsError().localizedDescription)])
        #expect(!fixture.state.projectsManager.isWorktreeHidden(projectId: fixture.project.id, path: target.path))
        #expect(fixture.state.tabs.tabs(forWorktree: target.id).contains { $0.id == tab.id })
    }

    /// A host-verb delete that nobody confirmed edits for refuses an edit
    /// made while it stops the worktree, rather than closing its editor.
    @Test func hostDeleteRefusesEditsMadeWhileItRuns() async throws {
        let environment = EditingBeforeQuiesce()
        let fixture = try await makeCleanupFixture(worktreeCount: 2, hostEnvironment: environment)
        defer { fixture.cleanUpAfterTest() }
        let target = fixture.worktrees[1]
        // Ignored, so the checkout stays clean and the delete reaches the quiesce.
        let exclude = URL(fileURLWithPath: fixture.project.path).appendingPathComponent(".git/info/exclude")
        try FileManager.default.createDirectory(at: exclude.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "notes.txt\n".write(to: exclude, atomically: true, encoding: .utf8)
        try "disk\n".write(to: target.path.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let tab = fixture.state.tabs.appendEditor(worktreeId: target.id, title: "notes.txt", relativePath: "notes.txt")
        let buffer = fixture.state.tabs.buffer(worktreeId: target.id, tabId: tab.id, worktreeRoot: target.path, relativePath: "notes.txt")
        await buffer.awaitLoadForTesting()
        environment.edit = { buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "later ") }

        await #expect(throws: (any Error).self) {
            try await fixture.state.host.worktrees.delete(target, caller: .localUser(uid: 501))
        }
        #expect(fixture.state.tabs.tabs(forWorktree: target.id).contains { $0.id == tab.id })
        #expect(FileManager.default.fileExists(atPath: target.path.path))
    }

    @Test func archiveRoundTripRestoresTheWorktree() async throws {
        let fixture = try await makeCleanupFixture(worktreeCount: 2)
        defer { fixture.cleanUpAfterTest() }
        let target = fixture.worktrees[1]

        _ = await fixture.state.batchArchiveWorktrees([target])
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

/// Edits a buffer right as the archive starts stopping the worktree, after
/// every check made before it.
private final class EditingBeforeQuiesce: AppHostEnvironment {
    var edit: () -> Void = {}

    override func quiesceWorktree(_ worktree: Worktree, in core: AlasCoreContext) async throws {
        edit()
        try await super.quiesceWorktree(worktree, in: core)
    }
}
