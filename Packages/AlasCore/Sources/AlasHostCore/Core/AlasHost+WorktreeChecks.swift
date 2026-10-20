import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasAgents
import AlasAgentKit

/// Why a worktree a caller waited for was not created.
public struct WorktreeCreationFailure: Error, Equatable, Sendable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

/// A worktree creation checked and ready to start, and the path to show for it.
public struct PreparedWorktreeCreation: Sendable {
    public var request: WorktreeCreateRequest
    /// Local paths as configured; a remote one as it lands on its host.
    public var shownPath: String
}

/// Why a worktree cannot be created or deleted as asked.
public enum WorktreeCheckRefusal: Error, Equatable, LocalizedError {
    case projectUnavailable
    case folderProject
    case invalidBranch(String)
    case destinationTaken
    case destinationUnchecked(String)
    /// A Workspace checkout manages the worktree, or ownership cannot be told.
    case workspaceOwned(String)
    case checkpointRecovery
    case unsavedChanges

    public var errorDescription: String? {
        switch self {
        case .projectUnavailable: "The current worktree's project is no longer available."
        case .folderProject: AlasCoreContext.folderWorktreeCreationMessage
        case .invalidBranch(let message): "invalid branch name: \(message)"
        case .destinationTaken: "A worktree already exists at this path."
        case .destinationUnchecked(let message): "Could not check the worktree destination: \(message)"
        case .workspaceOwned(let message): message
        case .checkpointRecovery: WorktreeRemovalResult.checkpointRecoveryMessage
        case .unsavedChanges: "worktree has unsaved editor changes; save them or rerun with --force to delete"
        }
    }
}

extension WorktreesAPI {
    /// Checks a new worktree for `branch` in `projectID` and prepares its
    /// destination on the project's host. Without `base`, the configured
    /// default branch, else `main`, `master` or `trunk`, is used.
    public func prepareCreate(projectID: String, branch: String, base: String?, caller: HostCaller) async throws -> PreparedWorktreeCreation {
        caller.log("worktrees.prepareCreate", branch)
        let project = try creatableProject(projectID, branch: branch)
        let prepared: (destination: URL, rendered: URL, exists: Bool)
        do {
            prepared = try await core.preparedCreationDestination(project: project, branch: branch)
        } catch {
            throw WorktreeCheckRefusal.destinationUnchecked(error.localizedDescription)
        }
        guard !prepared.exists else { throw WorktreeCheckRefusal.destinationTaken }
        let resolvedBase = if let base {
            base
        } else {
            WorktreeBaseBranch.preferred(
                availableBranches: (try? await core.branches(of: project)) ?? [],
                configuredDefault: core.environment.configuration().worktrees.baseBranch
            )
        }
        var request = WorktreeCreateRequest(projectID: projectID, base: resolvedBase, branch: branch, destination: prepared.destination)
        request.destinationAlreadyPrepared = true
        let shownPath = prepared.destination.isRemoteAlasPath ? RemotePath.display(prepared.destination.path) : prepared.rendered.path
        return PreparedWorktreeCreation(request: request, shownPath: shownPath)
    }

    /// The git project `projectID`, where a worktree for `branch` may be created.
    func creatableProject(_ projectID: String, branch: String) throws -> ProjectConfig {
        guard let project = core.projects.projects.first(where: { $0.id == projectID }) else {
            throw WorktreeCheckRefusal.projectUnavailable
        }
        guard !project.isFolder else { throw WorktreeCheckRefusal.folderProject }
        if case .invalid(let message) = GitNameValidator.validateBranchName(branch) {
            throw WorktreeCheckRefusal.invalidBranch(message)
        }
        return project
    }

    /// `request` checked as `prepareCreate` checks it, with the default base
    /// when it names none.
    func checkedCreation(_ request: WorktreeCreateRequest) async throws -> WorktreeCreateRequest {
        let project = try creatableProject(request.projectID, branch: request.branch)
        var request = request
        if !request.destinationAlreadyPrepared {
            // Checked where it is created, which on a remote host can be
            // another path than the one asked for.
            let exists: Bool
            do {
                request.destination = try await core.preparedDestination(request.destination, project: project)
                request.destinationAlreadyPrepared = true
                exists = try await core.creationDestinationExists(request.destination, project: project)
            } catch {
                throw WorktreeCheckRefusal.destinationUnchecked(error.localizedDescription)
            }
            guard !exists else { throw WorktreeCheckRefusal.destinationTaken }
        }
        if request.base.isEmpty {
            request.base = WorktreeBaseBranch.preferred(
                availableBranches: (try? await core.branches(of: project)) ?? [],
                configuredDefault: core.environment.configuration().worktrees.baseBranch
            )
        }
        return request
    }

    /// Why `worktree` cannot be deleted before it is claimed: its Workspace
    /// checkout, or, unless `force`, unsaved editor changes.
    func deletionCheck(_ worktree: Worktree, force: Bool) throws {
        if let refusal = core.environment.workspaceDeletionRefusal(for: worktree) {
            throw WorktreeCheckRefusal.workspaceOwned(refusal)
        }
        if !force, core.environment.hasUnsavedEditorChanges(in: worktree) {
            throw WorktreeCheckRefusal.unsavedChanges
        }
    }

    /// Claims a worktree for a deletion, as `beginDelete(_:caller:)` does,
    /// once its Workspace checkout, a checkpoint being recovered and, unless
    /// `force`, unsaved editor changes allow it.
    public func beginDelete(_ worktree: Worktree, force: Bool, caller: HostCaller) async throws -> UUID {
        if let refusal = core.environment.workspaceDeletionRefusal(for: worktree) {
            throw WorktreeCheckRefusal.workspaceOwned(refusal)
        }
        // Claimed before any `await`: the checks below yield to other
        // main-actor work, and an unclaimed gap would admit new sessions.
        let claim = try beginDelete(worktree, caller: caller)
        guard await !core.environment.checkpointRecoveryBlocksRemoval(worktree) else {
            releaseClaim(claim, for: worktree)
            throw WorktreeCheckRefusal.checkpointRecovery
        }
        if !force, core.environment.hasUnsavedEditorChanges(in: worktree) {
            releaseClaim(claim, for: worktree)
            throw WorktreeCheckRefusal.unsavedChanges
        }
        return claim
    }
}

extension WorktreesAPI {
    /// Runs `create` with a new worktree for `rendered` in `projectID`,
    /// suffixed to the first branch and path no worktree takes yet, one at a
    /// time per project so the next pick sees the worktree `create` made.
    public func withFreeName<T>(
        projectID: String,
        rendered: String,
        caller: HostCaller,
        _ create: (PreparedWorktreeCreation) async -> Result<T, WorktreeCreationFailure>
    ) async -> Result<T, WorktreeCreationFailure> {
        caller.log("worktrees.withFreeName", rendered)
        let gate = core.freeNameGates[projectID] ?? SerialGate()
        core.freeNameGates[projectID] = gate
        await gate.enter()
        defer { gate.leave() }
        guard let project = core.projects.projects.first(where: { $0.id == projectID }) else {
            return .failure(.init(message: WorktreeCheckRefusal.projectUnavailable.localizedDescription))
        }
        guard !project.isFolder else { return .failure(.init(message: AlasCoreContext.folderWorktreeCreationMessage)) }
        let repoPath = URL(fileURLWithPath: project.path)
        let git = GitService()
        // Local branches only: `WorktreeService.add` decides whether to reuse
        // a branch from `refs/heads/<branch>`, and a remote-tracking
        // `origin/nightly` with no local branch is still cut from the base.
        let existingBranches = Set((try? await git.localBranches(at: repoPath)) ?? [])
        let config = core.environment.configuration().worktrees
        let probe = core.worktreeDestinationExistence
        let host = project.host
        let free = await ScheduledWorktreeDestination.firstFree(
            rendered: rendered,
            pathTemplate: config.pathTemplate,
            worktreeRoot: config.rootPath,
            repoName: project.name,
            existingBranches: existingBranches,
            pathState: { await probe($0, host) }
        )
        let branch: String
        let destination: URL
        switch free {
        case let .free(freeBranch, freeDestination):
            branch = freeBranch
            destination = freeDestination
        case .exhausted:
            return .failure(.init(
                message: "Could not find a free branch and worktree path for \(rendered); clean up old scheduled worktrees."
            ))
        case .undeterminable(let path):
            return .failure(.init(message: "Could not check whether \(path.path) already exists on \(host ?? "this Mac")."))
        }
        let base = WorktreeBaseBranch.preferred(
            availableBranches: (try? await core.branches(of: project)) ?? [],
            configuredDefault: config.baseBranch
        )
        guard !Task.isCancelled else { return .failure(.init(message: "Cancelled before the worktree was created.")) }
        let request = WorktreeCreateRequest(projectID: projectID, base: base, branch: branch, destination: destination)
        let shown = destination.isRemoteAlasPath ? RemotePath.display(destination.path) : destination.path
        return await create(PreparedWorktreeCreation(request: request, shownPath: shown))
    }
}
