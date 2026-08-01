import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("Worktree creation completion")
struct AppStateCreateWorktreeCompletionTests {
    private static let worktree = Worktree(
        id: "worktree",
        projectId: "project",
        name: "feature",
        branch: "feature",
        path: URL(fileURLWithPath: "/tmp/worktree"),
        status: .clean,
        lastActivity: Date(timeIntervalSince1970: 0)
    )

    @Test
    func waiterReturnsOnlyAfterReconciledWorktreeExists() async {
        var states: [WorktreeOperationState?] = [.creating, nil, nil]
        var worktrees: [Worktree?] = [nil, nil, Self.worktree]

        let result = await WorktreeCreationCompletion.wait(
            id: Self.worktree.id,
            maxPolls: 3,
            operationState: { states.removeFirst() },
            worktree: { worktrees.removeFirst() },
            sleep: {}
        )

        #expect(result == .success(Self.worktree))
    }

    @Test
    func waiterPreservesCreateFailureMessage() async {
        let result = await WorktreeCreationCompletion.wait(
            id: "pending",
            maxPolls: 1,
            operationState: {
                .createFailed(projectId: "project", message: "branch exists", base: "main", ggWorktreeMode: .inherit)
            },
            worktree: { nil },
            sleep: {}
        )

        #expect(result == .failure(.init(message: "branch exists")))
    }

    @Test
    func waiterRetriesWhenTheOptimisticRowIsTemporarilyMissing() async {
        var states: [WorktreeOperationState?] = [nil, nil]
        var worktrees: [Worktree?] = [nil, Self.worktree]

        let result = await WorktreeCreationCompletion.wait(
            id: Self.worktree.id,
            maxPolls: 2,
            operationState: { states.removeFirst() },
            worktree: { worktrees.removeFirst() },
            sleep: {}
        )

        #expect(result == .success(Self.worktree))
    }

    @Test
    func waiterReportsDeletionAsAnInterruptedCreation() async {
        let result = await WorktreeCreationCompletion.wait(
            id: "pending",
            maxPolls: 1,
            operationState: { .deleting },
            worktree: { Self.worktree },
            sleep: {}
        )

        #expect(result == .failure(.init(message: "Worktree creation was interrupted.")))
    }

    @Test
    func waiterTimesOutAfterThePollLimit() async {
        var sleeps = 0

        let result = await WorktreeCreationCompletion.wait(
            id: "pending",
            maxPolls: 2,
            operationState: { nil },
            worktree: { nil },
            sleep: { sleeps += 1 }
        )

        #expect(result == .failure(.init(message: "Timed out waiting for worktree creation.")))
        #expect(sleeps == 2)
    }
}
