import Foundation

struct WorktreeCreationFailure: Error, Equatable, Sendable {
    let message: String
}

enum WorktreeCreationCompletion {
    @MainActor
    static func wait(
        id: String,
        maxPolls: Int = 1_200,
        operationState: () -> WorktreeOperationState?,
        worktree: () -> Worktree?,
        reconcile: @MainActor () async -> Void = {},
        sleep: @Sendable () async -> Void = {
            try? await Task.sleep(for: .milliseconds(250))
        }
    ) async -> Result<Worktree, WorktreeCreationFailure> {
        for _ in 0..<maxPolls {
            let reconciledWorktree = worktree()

            switch operationState() {
            case .createFailed(_, let message, _, _):
                await reconcile()
                if operationState() == nil, let reconciledWorktree = worktree() {
                    return .success(reconciledWorktree)
                }
                return .failure(.init(message: message))
            case .creating:
                break
            case .deleting, .deleteFailed:
                return .failure(.init(message: "Worktree creation was interrupted."))
            case nil:
                if let reconciledWorktree {
                    return .success(reconciledWorktree)
                }
            }

            await sleep()
        }

        return .failure(.init(message: "Timed out waiting for worktree creation."))
    }
}
