import Foundation
import os

private let logger = Logger(subsystem: "io.nlopez.alas", category: "RemoteLists")

/// The lists a Remote client picks from: agents, projects, worktrees and
/// branches, as the host knows them.
extension AlasCoreContext {
    /// Enabled ACP agents in launch order, with the models and thinking
    /// levels they advertised. An agent that cannot run on an SSH host lists
    /// those projects as unavailable.
    func remoteAgentOptions() -> [RemoteAgentOption] {
        let enabled = Dictionary(environment.enabledAgents().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = ACPLaunchCatalog.specs.compactMap { enabled[$0.agentID] }
        let sshProjectIDs = projects.projects.filter { $0.host != nil }.map(\.id)
        let catalog = environment.modelCatalog
        return ordered.enumerated().map { index, agent in
            let models = catalog?.models(for: agent.id) ?? []
            let efforts = catalog?.efforts(for: agent.id)?.levels ?? []
            let unavailable = agent.canRunOnRemoteHost ? [] : sshProjectIDs
            return RemoteAgentOption(
                id: agent.id,
                name: agent.displayName,
                isDefault: index == 0,
                models: models.isEmpty ? nil : models.map { RemoteModelOption(id: $0.id, name: $0.name) },
                efforts: efforts.isEmpty ? nil : efforts.map { RemoteEffortOption(id: $0.id, name: $0.name) },
                unavailableProjectIds: unavailable.isEmpty ? nil : unavailable
            )
        }
    }

    /// Projects a worktree can be created in, which folder projects cannot.
    func remoteProjectOptions() -> [RemoteProjectOption] {
        projects.projects.filter { !$0.isFolder }.map { RemoteProjectOption(id: $0.id, name: $0.name) }
    }

    /// Visible worktrees that no operation is creating or removing, with
    /// their Git metrics.
    func remoteWorktreeOptions() async -> [RemoteWorktreeOption] {
        var options: [RemoteWorktreeOption] = []
        for project in projects.projects {
            for worktree in projects.visibleWorktrees(projectId: project.id) {
                switch projects.operationState(forWorktreeId: worktree.id, projectId: project.id) {
                case .creating, .preparingDelete, .deleting, .archiving, .createFailed:
                    continue
                case nil, .launchFailed, .deleteFailed:
                    let summary = await remoteWorktreeSummary(project: project, worktree: worktree)
                    options.append(RemoteWorktreeOption(
                        id: worktree.id,
                        projectName: summary.projectName,
                        worktreeName: summary.worktreeName,
                        branch: summary.branch,
                        path: summary.path,
                        metricsAvailable: summary.metricsAvailable,
                        comparisonRef: summary.comparisonRef,
                        commitCount: summary.commitCount,
                        changedFileCount: summary.changedFileCount,
                        addedLines: summary.addedLines,
                        deletedLines: summary.deletedLines,
                        conflictCount: summary.conflictCount,
                        projectId: project.id
                    ))
                }
            }
        }
        return options
    }

    /// A project's branches and the one a new worktree starts from by default.
    func remoteBranches(projectID: String) async -> RemoteBranchListResult {
        guard let project = projects.projects.first(where: { $0.id == projectID }) else {
            return .failure("Repository is no longer available.")
        }
        guard !project.isFolder else { return .failure(Self.folderWorktreeCreationMessage) }
        do {
            let branches = try await GitService().branches(at: URL(fileURLWithPath: project.path))
            let preferred = WorktreeBaseBranch.preferred(
                availableBranches: branches,
                configuredDefault: environment.configuration().worktrees.baseBranch
            )
            return .success(branches: branches, preferredBase: preferred)
        } catch {
            logger.error("Could not load remote branches for project \(project.id, privacy: .private): \(String(describing: error), privacy: .private)")
            return .failure("Could not load branches.")
        }
    }

    /// A worktree as a Remote list shows it, with its changes against the
    /// configured base when Git can tell.
    @_spi(AppHost) public func remoteWorktreeSummary(project: ProjectConfig, worktree: Worktree) async -> RemoteWorktreeSummary {
        // A folder has no Git metrics to compute.
        if project.isFolder { return remoteWorktreeSummaryWithoutMetrics(project: project, worktree: worktree) }
        let config = environment.configuration()
        let git = GitService()
        do {
            async let status = git.status(worktreePath: worktree.path)
            async let commits = git.commitsAhead(
                at: worktree.path,
                baseBranch: config.worktrees.baseBranch,
                resolution: GitService.BaseResolution.forCommits(mode: config.changes.comparisonMode, userOverrodeBaseBranch: false)
            )
            let (changes, commitResult) = try await (status, commits)
            return RemoteWorktreeSummaryBuilder.make(
                projectName: project.name,
                worktree: worktree,
                isMain: projects.isMain(worktree, in: project),
                metrics: .available(comparisonRef: commitResult.comparisonRef, commitCount: commitResult.commits.count, changes: changes)
            )
        } catch {
            return remoteWorktreeSummaryWithoutMetrics(project: project, worktree: worktree)
        }
    }

    @_spi(AppHost) public func remoteWorktreeSummaryWithoutMetrics(project: ProjectConfig, worktree: Worktree) -> RemoteWorktreeSummary {
        RemoteWorktreeSummaryBuilder.make(
            projectName: project.name,
            worktree: worktree,
            isMain: projects.isMain(worktree, in: project),
            isFolder: project.isFolder,
            metrics: .unavailable
        )
    }

    static let folderWorktreeCreationMessage = "Folder projects are not git repositories and cannot create worktrees."
}

/// The branch a new worktree starts from when the user picks none.
public enum WorktreeBaseBranch {
    /// The configured default when the repository has it, else `main`,
    /// `master` or `trunk`, else the first branch.
    public static func preferred(availableBranches: [String], configuredDefault: String) -> String {
        if !configuredDefault.isEmpty && availableBranches.contains(configuredDefault) {
            return configuredDefault
        }
        for preferred in ["main", "master", "trunk"] where availableBranches.contains(preferred) {
            return preferred
        }
        return availableBranches.first ?? configuredDefault
    }
}
