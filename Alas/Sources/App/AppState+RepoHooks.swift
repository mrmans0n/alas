import Foundation

enum RepoHookPreflightError: LocalizedError {
    case cancelled
    case approvalPersistenceFailed

    var errorDescription: String? {
        switch self {
        case .cancelled: "Repository hook approval was cancelled."
        case .approvalPersistenceFailed: "Alas couldn't save this repository hook approval. The hook was not run."
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
            case let .failed(source, message):
                let decision = await repoHookApprovalQueue.requestFailureDecision(
                    failure: .init(event: event, source: source, message: message),
                    context: context
                )
                switch decision {
                case .retry, .approve: continue
                case .skip: return nil
                case .cancel: throw RepoHookPreflightError.cancelled
                }
            case let .loaded(hook):
                if projectsManager.isRepoHookApproved(projectId: project.id, hash: hook.hash) {
                    return hook.text
                }

                switch await repoHookApprovalQueue.requestDecision(
                    hook: hook,
                    projectID: project.id,
                    context: context
                ) {
                case .approve:
                    while true {
                        do {
                            try persistRepoHookApproval(projectId: project.id, hash: hook.hash)
                            return hook.text
                        } catch {
                            let failureDecision = await repoHookApprovalQueue.requestFailureDecision(
                                failure: .init(
                                    event: event,
                                    source: hook.source,
                                    message: error.localizedDescription
                                ),
                                context: context
                            )
                            switch failureDecision {
                            case .retry, .approve:
                                continue
                            case .skip:
                                return nil
                            case .cancel:
                                throw RepoHookPreflightError.cancelled
                            }
                        }
                    }
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

    func persistRepoHookApproval(projectId: String, hash: String) throws {
        guard projectsManager.approveRepoHook(projectId: projectId, hash: hash) else {
            if projectsManager.isRepoHookApproved(projectId: projectId, hash: hash) {
                return
            }
            throw RepoHookPreflightError.approvalPersistenceFailed
        }
        guard saveProjects() else {
            projectsManager.revokeRepoHookApproval(projectId: projectId, hash: hash)
            throw RepoHookPreflightError.approvalPersistenceFailed
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
