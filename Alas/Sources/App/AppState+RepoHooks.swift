import Foundation

extension AppState {
    func preparedRepoHook(
        event: RepoHookEvent,
        project: ProjectConfig,
        worktree: Worktree,
        context: RepoHookApprovalContext,
        includeUserStartupScript: Bool = true
    ) async throws -> String? {
        try await core.preparedRepoHook(
            event: event,
            project: project,
            worktree: worktree,
            context: context,
            includeUserStartupScript: includeUserStartupScript
        )
    }

    func persistRepoHookApproval(projectId: String, hash: String) throws {
        try core.persistRepoHookApproval(projectId: projectId, hash: hash)
    }

    func preparedWorkspaceRepoHook(_ request: WorkspaceRepoHookRequest) async throws -> String? {
        guard let mode = request.memberPolicy.projectWorktreeCreateMode,
              mode == .useGlobal || mode == .appendToGlobal
        else {
            return nil
        }

        while true {
            guard var project = projectsManager.projects.first(where: { $0.id == request.projectID }) else {
                let source = RemoteHostRegistry.shared.host(forPath: request.worktreePath)
                    .map { RepoHookSource.remote(host: $0) } ?? .local
                let failure = RepoHookFailure(
                    event: .worktreeCreate,
                    source: source,
                    message: "The Workspace member's project trust record is unavailable, so its repository hook approval cannot be checked."
                )
                let decision = await repoHookApprovalQueue.requestFailureDecision(
                    failure: failure,
                    context: .workspaceMember
                )
                switch decision {
                case .retry, .approve:
                    continue
                case .skip:
                    return nil
                case .cancel:
                    throw RepoHookPreflightError.cancelled
                }
            }
            project.startupScripts.worktreeCreateMode = mode
            project.startupScripts.worktreeCreateScript = request.memberPolicy.projectWorktreeCreateScript ?? ""
            let path = URL(fileURLWithPath: request.worktreePath)
            let worktree = Worktree(
                id: Worktree.makeId(path: path),
                projectId: project.id,
                name: path.lastPathComponent,
                branch: "",
                path: path,
                status: .clean,
                lastActivity: .now
            )
            return try await preparedRepoHook(
                event: .worktreeCreate,
                project: project,
                worktree: worktree,
                context: .workspaceMember
            )
        }
    }
}
