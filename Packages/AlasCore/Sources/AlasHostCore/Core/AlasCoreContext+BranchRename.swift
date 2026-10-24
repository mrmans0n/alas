import Foundation
import AlasFeatures
import AlasModel
import AlasPlatform
import AlasIntegrations

extension AlasCoreContext {
    /// The worktree has an operation in flight, such as a pending delete.
    public struct WorktreeBusyError: LocalizedError {
        public var errorDescription: String? { "The worktree is busy with another operation." }
    }

    /// Serialized with the project's creates and deletes. A worktree being
    /// created or deleted keeps its branch: a delete has already captured it.
    /// Failure states are settled and do not block a rename.
    public func renameBranchWhileIdle(
        _ worktree: Worktree,
        from: String,
        to: String,
        requireUnpublished: Bool
    ) async throws -> String {
        try await ProjectMutationGate.shared.withMutation(projectID: worktree.projectId) { [self] in
            let isIdle = await MainActor.run {
                switch projects.operationState(forWorktreeId: worktree.id, projectId: worktree.projectId) {
                case .creating, .preparingDelete, .deleting, .archiving: false
                case nil, .createFailed, .launchFailed, .deleteFailed: true
                }
            }
            guard isIdle else { throw WorktreeBusyError() }
            return try await WorktreeService().renameBranch(
                worktreePath: worktree.path,
                from: from,
                to: to,
                requireUnpublished: requireUnpublished
            )
        }
    }

    /// A user's rename of a listed worktree's branch, under the local menu's
    /// rules: never the main checkout, a detached or branchless one, or one
    /// an active Workspace checkout manages (it records the branch by name).
    /// Returns the branch name actually used.
    func renameListedWorktreeBranch(_ worktree: Worktree, to branch: String) async throws -> String {
        guard let project = projects.projects.first(where: { $0.id == worktree.projectId }),
              !WorktreeCleanupScanner.isMainWorktree(worktree, of: project),
              !worktree.branch.isEmpty, !worktree.isDetached
        else { throw HostError.failed(message: "This worktree's branch cannot be renamed.") }
        if let refusal = await workspaceOwnershipRefusal(for: worktree) {
            throw HostError.failed(message: "\(refusal).")
        }
        let renamed = try await renameBranchWhileIdle(worktree, from: worktree.branch, to: branch, requireUnpublished: false)
        if projects.pendingAutoBranchName(projectId: worktree.projectId, worktreeId: worktree.id) != nil {
            projects.removePendingAutoBranchName(projectId: worktree.projectId, worktreeId: worktree.id)
        }
        projects.applyHeadUpdates(projectId: worktree.projectId, branchByWorktreePath: [worktree.path: renamed])
        try saveProjects()
        return renamed
    }
}
