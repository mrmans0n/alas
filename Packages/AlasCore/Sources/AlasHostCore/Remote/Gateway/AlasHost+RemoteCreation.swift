import Foundation
import os
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasAgents
import AlasIntegrations

private let logger = Logger(subsystem: "io.nlopez.alas", category: "RemoteCreation")

/// A session a Remote client asks for in an existing worktree.
@_spi(Testing) public struct RemoteSessionCreation: Equatable, Sendable {
    public var worktreeID: String
    public var agentID: String
    public var modelID: String?
    public var effortID: String?

    public init(worktreeID: String, agentID: String, modelID: String? = nil, effortID: String? = nil) {
        self.worktreeID = worktreeID
        self.agentID = agentID
        self.modelID = modelID
        self.effortID = effortID
    }
}

/// A new worktree and a session in it, as a Remote client asks for them.
@_spi(Testing) public struct RemoteWorktreeSessionCreation: Equatable, Sendable {
    public var projectID: String
    public var base: String
    public var branch: String
    public var agentID: String
    public var modelID: String?
    public var effortID: String?
    /// What the client says about the worktree-create hook; nil from
    /// clients that cannot ask their user.
    public var repoHook: RepoHookConsent?

    public init(
        projectID: String, base: String, branch: String, agentID: String,
        modelID: String? = nil, effortID: String? = nil, repoHook: RepoHookConsent? = nil
    ) {
        self.projectID = projectID
        self.base = base
        self.branch = branch
        self.agentID = agentID
        self.modelID = modelID
        self.effortID = effortID
        self.repoHook = repoHook
    }
}

extension AlasHost {
    /// Creates a session for a Remote client in a visible worktree that no
    /// operation holds, starting it as the app's settings say.
    func remoteCreateSession(_ request: RemoteSessionCreation, caller: HostCaller) async -> RemoteCreateSessionResult {
        guard let (project, worktree) = core.projects.projects.lazy.compactMap({ project in
            self.core.projects.visibleWorktrees(projectId: project.id).first { $0.id == request.worktreeID }.map { (project, $0) }
        }).first else {
            return .failure("Worktree is no longer available.")
        }
        switch core.projects.operationState(forWorktreeId: worktree.id, projectId: project.id) {
        case .creating, .preparingDelete, .deleting, .archiving, .createFailed:
            return .failure("Worktree is no longer available.")
        case nil, .launchFailed, .deleteFailed:
            break
        }
        let summary: HostSessionSummary
        do {
            summary = try await sessions.create(
                .worktree(WorktreeRef(projectID: project.id, path: worktree.path.path)),
                agentID: request.agentID,
                modelID: request.modelID,
                effortID: request.effortID,
                autoRun: core.environment.configuration().harness.acpAutoRunByDefault,
                caller: caller
            )
        } catch SessionRefusal.agentUnavailable {
            return .failure("Agent is no longer available.")
        } catch SessionRefusal.ownerUnavailable(let reason) {
            return .failure(reason)
        } catch {
            return .failure("Could not create session.")
        }
        guard let manager = core.sessionManagers[summary.owner] else { return .failure("Could not create session.") }
        return .success(remoteSessionSummary(
            id: summary.id, in: manager,
            worktree: core.remoteWorktreeSummaryWithoutMetrics(project: project, worktree: worktree)
        ))
    }

    /// Creates a worktree from `base` in a Git project, then a session in it.
    func remoteCreateWorktreeSession(_ request: RemoteWorktreeSessionCreation, caller: HostCaller) async -> RemoteCreateWorktreeSessionResult {
        func refused(_ message: String = "Could not create worktree.") -> RemoteCreateWorktreeSessionResult {
            .failure(stage: .worktree, message: message, worktreeId: nil)
        }
        guard let project = core.projects.projects.first(where: { $0.id == request.projectID }) else {
            return refused("Repository is no longer available.")
        }
        guard !project.isFolder else { return refused(AlasCoreContext.folderWorktreeCreationMessage) }
        guard core.environment.admitsAgent(request.agentID, remoteHost: project.host) else { return refused() }
        guard case .valid = GitNameValidator.validateBranchName(request.branch) else { return refused() }
        let branches: [String]
        do {
            branches = try await core.branches(of: project)
            guard branches.contains(request.base) else { return refused() }
        } catch {
            logger.error("Could not load branches for remote worktree creation in project \(project.id, privacy: .private): \(String(describing: error), privacy: .private)")
            return refused("Could not load branches.")
        }

        let destination: URL
        do {
            let prepared = try await core.preparedCreationDestination(project: project, branch: request.branch)
            destination = prepared.destination
            if prepared.exists { return refused("A worktree already exists at this path.") }
        } catch {
            logger.error("Could not preflight remote worktree creation for project \(project.id, privacy: .private): \(String(describing: error), privacy: .private)")
            return refused()
        }

        // Fetched before the hook is read, so the script approved is the one
        // the checkout gets; the creation below then doesn't fetch again.
        let fetchesBase = core.environment.configuration().worktrees.fetchRemoteBeforeCreate
        let repoPath = URL(fileURLWithPath: project.path)
        if fetchesBase { await core.fetchBase(request.base, in: repoPath) }

        let gate: RepoHookGate
        do {
            // The worktree checks out the local branch when it exists
            // (`WorktreeService.add`), and is otherwise created from base.
            let ref = try await AlasCoreContext.firstExistingRef(
                ["refs/heads/\(request.branch)", "refs/heads/\(request.base)", "refs/remotes/\(request.base)"], repoPath: repoPath
            ) ?? request.base
            gate = try await core.gateRepoHook(event: .worktreeCreate, project: project, consent: request.repoHook) {
                await RepoHookLoader.loadCommitted(event: .worktreeCreate, ref: ref, repoPath: repoPath, host: project.host)
            }
        } catch {
            return refused(error.localizedDescription)
        }
        if case .needsApproval(let hook) = gate { return .needsRepoHookApproval(hook) }

        var creation = WorktreeCreateRequest(projectID: project.id, base: request.base, branch: request.branch, destination: destination)
        creation.destinationAlreadyPrepared = true
        creation.launchSurface = .delegated
        creation.asksAboutRepoHooks = false
        let worktree: Worktree
        do {
            worktree = try await worktrees.create(creation, caller: caller)
        } catch {
            logger.error("Could not create remote worktree for project \(project.id, privacy: .private): \(error.localizedDescription, privacy: .private)")
            return refused()
        }
        if gate == .skippedUnapproved {
            logger.notice("Skipped the unapproved worktree-create hook of project \(project.id, privacy: .private) for a client that cannot ask")
            noteAttention([.worktreeNotice(HostWorktreeNotice(
                id: UUID(), worktreeID: worktree.id, title: "Setup hook not run", body: "It needs approval in Alas."
            ))])
        }
        let sessionRequest = RemoteSessionCreation(
            worktreeID: worktree.id, agentID: request.agentID, modelID: request.modelID, effortID: request.effortID
        )
        let session = if let remoteSessionCreator {
            await remoteSessionCreator(sessionRequest)
        } else {
            await remoteCreateSession(sessionRequest, caller: caller)
        }
        switch session {
        case .success(let summary):
            return .success(summary)
        case .failure:
            return .failure(stage: .session, message: "Worktree created, but the session could not be created.", worktreeId: worktree.id)
        }
    }

    /// The session as a Remote list shows it.
    func remoteSessionSummary(id: String, in manager: ACPSessionManager, worktree: RemoteWorktreeSummary?) -> RemoteSessionSummary {
        let session = manager.liveSession(for: id)
        let row = manager.sessionRows.first { $0.id == id }
        let streamingState = core.reportedStreamingState(of: id, live: manager.runners[id]?.session.transcript.streamingState ?? session?.transcript.streamingState) ?? .idle
        return RemoteSessionSummary(
            id: id,
            title: session?.title ?? row?.title ?? "",
            agentId: session?.agentId ?? row?.agentId ?? "",
            status: RemoteSessionGateway.stateString(streamingState),
            canDrive: manager.isWriter(for: id),
            projectId: worktree == nil ? nil : core.projects.projects.first { project in
                core.projects.worktrees(projectId: project.id).contains { $0.id == manager.worktreeId }
            }?.id,
            worktreeId: worktree == nil ? nil : manager.worktreeId,
            updatedAt: row?.updatedAt ?? 0,
            worktree: worktree
        )
    }
}

extension AlasCoreContext {
    /// The first of `refs` that exists, as full refs so a same-named tag
    /// can't stand in for a branch.
    fileprivate static func firstExistingRef(_ refs: [String], repoPath: URL) async throws -> String? {
        for ref in refs {
            if try await Process.git(["show-ref", "--verify", "--quiet", ref], cwd: repoPath).exitCode == 0 { return ref }
        }
        return nil
    }

    /// A project's branches.

    func branches(of project: ProjectConfig) async throws -> [String] {
        let repoPath = URL(fileURLWithPath: project.path)
        if let worktreeBranchLoader { return try await worktreeBranchLoader(repoPath) }
        return try await GitService().branches(at: repoPath)
    }

    /// Renders the configured destination for a new worktree, prepares it
    /// for the project's own host (remote home and virtual path), and checks
    /// whether it is taken there. A same-path directory on this Mac says
    /// nothing about a remote project, so existence is never checked before
    /// preparation.
    @_spi(AppHost) public func preparedCreationDestination(
        project: ProjectConfig,
        branch: String
    ) async throws -> (destination: URL, rendered: URL, exists: Bool) {
        let config = environment.configuration()
        let rendered = WorktreePathTemplateRenderer.render(
            template: config.worktrees.pathTemplate,
            worktreeRoot: config.worktrees.rootPath,
            repoName: project.name,
            branch: branch
        )
        let destination = try await preparedDestination(rendered, project: project)
        return (destination, rendered, try await creationDestinationExists(destination, project: project))
    }

    /// `destination` as a worktree of `project` is created at it: on a
    /// remote host, rewritten to that host's home.
    func preparedDestination(_ destination: URL, project: ProjectConfig) async throws -> URL {
        let repoPath = URL(fileURLWithPath: project.path)
        if let worktreeDestinationPreparer {
            return try await worktreeDestinationPreparer(repoPath, destination)
        }
        return try await WorktreeLifecycle.preparedCreateWorktreeDestination(repoPath: repoPath, destination: destination)
    }

    /// Whether something already sits at `destination`, on the project's own host.
    func creationDestinationExists(_ destination: URL, project: ProjectConfig) async throws -> Bool {
        guard let host = project.host ?? RemoteHostRegistry.shared.host(forPath: project.path) else {
            return FileManager.default.fileExists(atPath: destination.path)
        }
        let command = "test -e \(SSHCommand.shellQuote(destination.path))"
        let result = if let remoteCommandRunner {
            try await remoteCommandRunner(host, nil, command)
        } else {
            try await RemoteExec.run(host: host, cwd: nil, command: command)
        }
        switch result.exitCode {
        case 0: return true
        case 1: return false
        default: throw RemoteWorktreeDestinationCheckError()
        }
    }
}

struct RemoteWorktreeDestinationCheckError: LocalizedError {
    var errorDescription: String? {
        "The remote host did not report whether the destination already exists."
    }
}
