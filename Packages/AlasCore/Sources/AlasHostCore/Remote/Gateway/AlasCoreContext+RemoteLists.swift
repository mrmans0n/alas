import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasAgents
import AlasACP

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
        let settings = environment.configuration().worktrees
        return projects.projects.filter { !$0.isFolder }.map {
            RemoteProjectOption(id: $0.id, name: $0.name, linkedProjectId: $0.linkedProjectId,
                                branchNaming: Self.remoteBranchNaming(for: $0, settings: settings))
        }
    }

    static func remoteBranchNaming(for project: ProjectConfig, settings: AppConfig.Worktrees) -> RemoteWorktreeBranchNaming {
        RemoteWorktreeBranchNaming(
            prefix: settings.branchPrefix,
            template: WorktreeBranchName.normalizedTemplate(project.worktreeBranchTemplate)
                ?? WorktreeBranchName.normalizedTemplate(settings.branchTemplate),
            timeZoneIdentifier: TimeZone.autoupdatingCurrent.identifier
        )
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
                        projectId: project.id,
                        linkedProjectId: summary.linkedProjectId
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
        await loadRepositoryKey(of: project)
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
            return listed(RemoteWorktreeSummaryBuilder.make(
                projectName: project.name,
                worktree: worktree,
                isMain: projects.isMain(worktree, in: project),
                metrics: .available(comparisonRef: commitResult.comparisonRef, commitCount: commitResult.commits.count, changes: changes)
            ), project: project)
        } catch {
            return remoteWorktreeSummaryWithoutMetrics(project: project, worktree: worktree)
        }
    }

    @_spi(AppHost) public func remoteWorktreeSummaryWithoutMetrics(project: ProjectConfig, worktree: Worktree) -> RemoteWorktreeSummary {
        listed(RemoteWorktreeSummaryBuilder.make(
            projectName: project.name,
            worktree: worktree,
            isMain: projects.isMain(worktree, in: project),
            isFolder: project.isFolder,
            metrics: .unavailable
        ), project: project)
    }

    /// A summary with its repository identity, as far as it is known. A
    /// Machine checkout's worktree is shown under its local project, by that
    /// project's name.
    private func listed(_ summary: RemoteWorktreeSummary, project: ProjectConfig) -> RemoteWorktreeSummary {
        var summary = summary
        summary.repositoryKey = repositoryKey(of: project)
        guard let primaryId = project.linkedProjectId,
              let primary = projects.projects.first(where: { $0.id == primaryId })
        else { return summary }
        var listed = RemoteWorktreeSummary(
            projectName: primary.name,
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
            isMain: summary.isMain,
            createdAt: summary.createdAt,
            lastActivity: summary.lastActivity,
            isFolder: summary.isFolder
        )
        listed.linkedProjectId = primaryId
        listed.repositoryKey = summary.repositoryKey
        return listed
    }

    /// The project whose origin names the repository: a Machine checkout's
    /// local project, since the link already matched their origins.
    private func repositoryOwner(of project: ProjectConfig) -> ProjectConfig? {
        if project.isFolder { return nil }
        guard let primaryId = project.linkedProjectId else { return project.host == nil ? project : nil }
        return projects.projects.first { $0.id == primaryId && $0.host == nil && !$0.isFolder }
    }

    private func repositoryKey(of project: ProjectConfig) -> String? {
        repositoryOwner(of: project).flatMap { repositoryKeys[$0.id] ?? nil }
    }

    /// Reads the owning project's origin the first time it is needed. A
    /// failed read is not remembered, so the next list tries again.
    private func loadRepositoryKey(of project: ProjectConfig) async {
        guard let owner = repositoryOwner(of: project), repositoryKeys[owner.id] == nil,
              let remotes = try? await GitService().remotes(worktreePath: URL(fileURLWithPath: owner.path))
        else { return }
        repositoryKeys[owner.id] = .some(remotes.first { $0.name == "origin" && $0.direction == .fetch }
            .flatMap { GitRemoteIdentity.normalized($0.url) })
    }

    nonisolated static let folderWorktreeCreationMessage = "Folder projects are not git repositories and cannot create worktrees."
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
