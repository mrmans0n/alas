import Foundation

enum RepoHookPreflightError: LocalizedError {
    case cancelled

    var errorDescription: String? {
        switch self {
        case .cancelled: "Repository hook approval was cancelled."
        }
    }
}

extension AppState {
    func preparedRepoHook(
        event: RepoHookEvent,
        project: ProjectConfig,
        worktree: Worktree,
        context: RepoHookApprovalContext,
        includeUserStartupScript: Bool = true
    ) async throws -> String? {
        guard includeUserStartupScript, usesInheritedRepoHook(event: event, project: project) else {
            return nil
        }

        while true {
            switch await repoHookLoader.load(event: event, worktreeRoot: worktree.path, host: project.host) {
            case .missing, .empty:
                return nil
            case .failed:
                return nil
            case let .loaded(hook):
                if projectsManager.isRepoHookApproved(projectId: project.id, hash: hook.hash) {
                    return hook.text
                }

                switch await repoHookApprovalQueue.requestDecision(hook: hook, context: context) {
                case .approve:
                    if projectsManager.approveRepoHook(projectId: project.id, hash: hook.hash) {
                        saveProjects()
                    }
                    return hook.text
                case .skip:
                    return nil
                case .retry:
                    continue
                case .cancel:
                    throw RepoHookPreflightError.cancelled
                }
            }
        }
    }

    private func usesInheritedRepoHook(event: RepoHookEvent, project: ProjectConfig) -> Bool {
        let mode: ProjectStartupScriptMode = switch event {
        case .sessionOpen: project.startupScripts.sessionOpenMode
        case .worktreeCreate: project.startupScripts.worktreeCreateMode
        }
        return mode == .useGlobal || mode == .appendToGlobal
    }

    func preparedWorkspaceRepoHook(_ request: WorkspaceRepoHookRequest) async throws -> String? {
        guard var project = projectsManager.projects.first(where: { $0.id == request.projectID }),
              let mode = request.memberPolicy.projectWorktreeCreateMode,
              let script = request.memberPolicy.projectWorktreeCreateScript
        else {
            return nil
        }
        project.startupScripts.worktreeCreateMode = mode
        project.startupScripts.worktreeCreateScript = script
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
