import Foundation
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct RightPaneOptimisticStageTests {
    @Test func stageAndUnstageProjectImmediately() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let state = makeState(at: repo)
        await state.refresh()

        let unstaged = try #require(state.changes.first { $0.path == "file.txt" })
        state.stageAll([unstaged])
        #expect(state.displayChanges.first { $0.path == "file.txt" }?.stage == .staged)

        #expect(await state.finishPendingStageMutations())
        #expect(state.changes.first { $0.path == "file.txt" }?.stage == .staged)
        let staged = try #require(state.changes.first { $0.path == "file.txt" })
        state.unstageAll([staged])
        #expect(state.displayChanges.first { $0.path == "file.txt" }?.stage == .unstaged)
    }

    @Test func orderedMutationsUseLatestStageForOverlappingPaths() {
        let changes = [changedFile("file.txt", stage: .unstaged)]

        let projected = RightPaneState.applyingStageMutations(
            [
                (paths: ["file.txt"], target: .staged),
                (paths: ["file.txt"], target: .unstaged),
            ],
            to: changes
        )

        #expect(projected == changes)
    }

    @Test func mutationProjectsEveryEntryForItsPathAndLeavesOthersUnchanged() {
        let changes = [
            changedFile("mixed.txt", stage: .staged, add: 2),
            changedFile("mixed.txt", stage: .unstaged, del: 3),
            changedFile("other.txt", stage: .unstaged),
        ]

        let projected = RightPaneState.applyingStageMutations(
            [(paths: ["mixed.txt"], target: .staged)],
            to: changes
        )

        #expect(projected.filter { $0.path == "mixed.txt" }.allSatisfy { $0.stage == .staged })
        #expect(projected.first { $0.path == "other.txt" }?.stage == .unstaged)
    }

    @Test func failedStageRollsBackToAuthoritativeChanges() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let state = makeState(at: repo)
        await state.refresh()
        let file = try #require(state.changes.first { $0.path == "file.txt" })
        try Data().write(to: repo.appendingPathComponent(".git/index.lock"))

        state.stageAll([file])
        #expect(state.displayChanges.first { $0.path == "file.txt" }?.stage == .staged)

        #expect(!(await state.finishPendingStageMutations()))
        #expect(state.sidebarError != nil)
        #expect(state.displayChanges.first { $0.path == "file.txt" }?.stage == .unstaged)
    }

    private func makeRepo() async throws -> URL {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-optimistic-stage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: repo)
        _ = try await Process.git(["config", "user.email", "test@example.com"], cwd: repo)
        _ = try await Process.git(["config", "user.name", "Test"], cwd: repo)
        try "base\n".write(to: repo.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "file.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "base"], cwd: repo)
        try "changed\n".write(to: repo.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        return repo
    }

    private func makeState(at path: URL) -> RightPaneState {
        RightPaneState(
            worktree: Worktree(
                id: Worktree.makeId(path: path),
                projectId: "project",
                name: "test",
                branch: "main",
                path: path,
                status: .clean,
                lastActivity: Date()
            ),
            baseBranch: "main"
        )
    }

    private func changedFile(
        _ path: String,
        stage: ChangeStage,
        add: Int = 0,
        del: Int = 0
    ) -> ChangedFile {
        ChangedFile(
            path: path,
            status: "M",
            stage: stage,
            add: add,
            del: del,
            renameFrom: nil
        )
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Condition was not met before timeout")
    }
}
