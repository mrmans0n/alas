import Foundation
import os

private let creationLogger = Logger(subsystem: "io.nlopez.alas", category: "WorktreeCreation")

/// One request to create a worktree.
public struct WorktreeCreateRequest: Sendable {
    public var projectID: String
    public var base: String
    public var branch: String
    public var destination: URL
    /// The destination is already canonical and its parent exists.
    public var destinationAlreadyPrepared = false
    public var runsStartupScripts = true
    /// Fetch `base` from its remote first, on a best-effort basis.
    public var fetchesBaseFirst = false
    /// The branch carries a temporary name that the first prompt replaces, so
    /// it must be new and is recorded as pending right after creation.
    public var namesBranchFromFirstPrompt = false
    public var ggWorktreeMode: GGWorktreeMode = .inherit
    public var issueAttachment: IssueAttachment?
    /// Where the new worktree opens. Kept with a failure so a retry opens the
    /// same surface.
    public var launchSurface: WorktreeLaunchSurface = .none
    /// The app asks for hook approval, so a cancelled one fails the creation
    /// for a retry. Without anyone to ask, the scripts are skipped instead.
    public var cancelledHookApprovalFails = false

    public init(projectID: String, base: String, branch: String, destination: URL) {
        self.projectID = projectID
        self.base = base
        self.branch = branch
        self.destination = destination
    }
}

/// A creation `beginCreate` started: the optimistic row and its claim.
public struct PendingWorktreeCreation: Sendable {
    public let request: WorktreeCreateRequest
    public let worktree: Worktree
    let claim: UUID
}

public enum WorktreeCreationOutcome: Equatable, Sendable {
    case created(Worktree)
    /// Created, but what it records in the project list (a pending branch
    /// name, the GG mode, the issue attachment) could not be saved.
    case createdButNotSaved(Worktree, String)
    /// Left on the row as `.createFailed`, for retry. `unsaved` is a save
    /// that failed before it did, such as a pending branch name.
    case failed(String, unsaved: String? = nil)
    /// The project was removed meanwhile, along with the row.
    case projectRemoved
}

/// Why `AlasCoreContext.beginCreate` did not start.
public enum WorktreeCreationRefusal: Codable, LocalizedError, Equatable {
    case folderProject
    /// A worktree is already listed at the destination, and it is not a
    /// failed creation being retried.
    case alreadyListed

    public var errorDescription: String? {
        switch self {
        case .folderProject: "Folder projects are not git repositories and cannot create worktrees."
        case .alreadyListed: "A worktree already exists at this path."
        }
    }
}

extension AlasCoreContext {
    /// Creates a worktree through the same routine as the app, runs its
    /// create script unless the request says not to (or, with nobody to ask,
    /// its repository hook is unapproved), and refreshes the project.
    public func createWorktree(_ request: WorktreeCreateRequest) async throws -> Worktree {
        let pending = try await beginCreate(request)
        switch await finishCreate(pending) {
        case .created(let worktree), .createdButNotSaved(let worktree, _): return worktree
        case .failed(let message, _): throw WorktreeCreationError(message: message)
        case .projectRemoved: throw ProjectCreationError.projectNotFound
        }
    }

    /// Creates a worktree for `branch` from `base` at `destination`; see
    /// `createWorktree(_:)`.
    public func createWorktree(
        projectID: String,
        branch: String,
        base: String,
        destination: URL,
        runStartupScripts: Bool = true
    ) async throws -> Worktree {
        var request = WorktreeCreateRequest(projectID: projectID, base: base, branch: branch, destination: destination)
        request.runsStartupScripts = runStartupScripts
        return try await createWorktree(request)
    }

    /// Lists the new worktree right away, claimed `.creating` so nothing
    /// starts in it until `finishCreate` is done.
    public func beginCreate(_ request: WorktreeCreateRequest) async throws -> PendingWorktreeCreation {
        guard let project = projects.projects.first(where: { $0.id == request.projectID }) else {
            throw ProjectCreationError.projectNotFound
        }
        guard !project.isFolder else { throw WorktreeCreationRefusal.folderProject }
        // Both the optimistic row and the created worktree derive their id
        // from this path, so it is canonicalized once, here.
        let destination = request.destinationAlreadyPrepared
            ? request.destination
            : try await WorktreeLifecycle.preparedCreateWorktreeDestination(
                repoPath: URL(fileURLWithPath: project.path),
                destination: request.destination
            )
        // Preparing a remote destination awaits SSH; the project can be gone.
        guard projects.projects.contains(where: { $0.id == request.projectID }) else {
            throw ProjectCreationError.projectNotFound
        }
        let id = Worktree.makeId(path: destination)
        if projects.worktrees(projectId: request.projectID).contains(where: { $0.id == id }) {
            guard case .createFailed = projects.operationState(forWorktreeId: id, projectId: request.projectID) else {
                throw WorktreeCreationRefusal.alreadyListed
            }
        }
        let worktree = Worktree(
            id: id,
            projectId: request.projectID,
            name: request.branch,
            branch: request.branch,
            path: destination,
            status: .clean,
            lastActivity: Date()
        )
        try refuseIfStopping()
        projects.insertOptimisticWorktree(worktree)
        let claim = projects.claimOperation(.creating, for: worktree)
        return PendingWorktreeCreation(request: request, worktree: worktree, claim: claim)
    }

    /// Creates the worktree `beginCreate` listed. A failure is left on its
    /// row as `.createFailed`, carrying what a retry needs.
    public func finishCreate(_ pending: PendingWorktreeCreation) async -> WorktreeCreationOutcome {
        let request = pending.request
        guard let project = projects.projects.first(where: { $0.id == request.projectID }) else {
            return .projectRemoved
        }
        let repoPath = URL(fileURLWithPath: project.path)
        // Each save writes the whole project list, so the last one decides
        // whether what the creation recorded is durable.
        var saveFailure: String?
        func save() {
            do {
                try saveProjects()
                saveFailure = nil
            } catch {
                saveFailure = error.localizedDescription
            }
        }
        do {
            if request.fetchesBaseFirst {
                await fetchBase(request.base, in: repoPath)
            }
            let created = try await WorktreeLifecycle.performCreateWorktree(
                repoPath: repoPath,
                base: request.base,
                branch: request.branch,
                destination: pending.worktree.path,
                projectId: request.projectID,
                // A temporary name must never check out an existing branch:
                // the first prompt would rename that branch.
                requiresNewBranch: request.namesBranchFromFirstPrompt
            )
            guard projects.projects.contains(where: { $0.id == request.projectID }) else { return .projectRemoved }
            // Recorded as soon as the branch exists: a later step failing
            // must not strand the worktree on its temporary name.
            if request.namesBranchFromFirstPrompt {
                projects.setPendingAutoBranchName(
                    projectId: request.projectID,
                    worktreeId: created.id,
                    placeholder: created.branch
                )
                save()
            }
            do {
                try await runWorktreeCreateScripts(
                    project: project,
                    worktree: created,
                    includeUserStartupScript: request.runsStartupScripts
                )
            } catch RepoHookPreflightError.cancelled where !request.cancelledHookApprovalFails {}
            guard projects.projects.contains(where: { $0.id == request.projectID }) else { return .projectRemoved }

            // A path archived before is a new worktree now.
            let wasHidden = projects.isWorktreeHidden(projectId: request.projectID, path: created.path)
            projects.setWorktreeHidden(projectId: request.projectID, path: created.path, hidden: false)
            // The worktree exists from here on, and git is the source of
            // truth for it: a refresh that fails is left to the next one
            // rather than reported as a failed creation, which a retry could
            // only repeat against the existing path.
            var needsSave = wasHidden
            do {
                needsSave = try await environment.refreshProjectWorktrees(request.projectID, in: self) || needsSave
            } catch {
                creationLogger.error("Refresh after creating a worktree failed: \(error.localizedDescription, privacy: .public)")
            }
            guard projects.projects.contains(where: { $0.id == request.projectID }) else { return .projectRemoved }
            projects.setGGWorktreeMode(projectId: request.projectID, worktreeId: created.id, mode: request.ggWorktreeMode)
            needsSave = needsSave || request.ggWorktreeMode != .inherit
            if let attachment = request.issueAttachment {
                projects.setIssueAttachment(projectId: request.projectID, worktreeId: created.id, attachment: attachment)
                needsSave = true
            }
            projects.finishOperation(pending.claim, for: pending.worktree)
            // An earlier failed save is retried here, so the final write
            // decides what is reported whatever the refresh saved meanwhile.
            if needsSave || saveFailure != nil {
                save()
            }
            return saveFailure.map { .createdButNotSaved(created, $0) } ?? .created(created)
        } catch {
            let message = error.localizedDescription
            projects.finishOperation(pending.claim, for: pending.worktree, leaving: .createFailed(
                projectId: request.projectID,
                message: message,
                base: request.base,
                ggWorktreeMode: request.ggWorktreeMode,
                launchSurface: request.launchSurface,
                issueAttachment: request.issueAttachment,
                namesBranchFromFirstPrompt: request.namesBranchFromFirstPrompt
            ))
            return .failed(message, unsaved: saveFailure)
        }
    }

    /// Records that a created worktree's surface could not open, for retry.
    public func recordLaunchFailure(_ worktree: Worktree, message: String, launchSurface: WorktreeLaunchSurface) {
        projects.setOperationState(
            for: worktree,
            state: .launchFailed(projectId: worktree.projectId, message: message, launchSurface: launchSurface)
        )
    }

    /// Clears a launch failure once its retry opened the surface.
    public func clearLaunchFailure(_ worktree: Worktree) {
        guard case .launchFailed = projects.operationState(for: worktree) else { return }
        projects.setOperationState(for: worktree, state: nil)
    }

    private func fetchBase(_ base: String, in repoPath: URL) async {
        guard let fetch = try? await GitService().remoteForFetch(worktreePath: repoPath, ref: base) else { return }
        do {
            _ = try await GitService().fetchRef(worktreePath: repoPath, remote: fetch.remote, branch: fetch.branch)
        } catch {
            creationLogger.error("Fetch failed before creating worktree: \(String(describing: error), privacy: .public)")
        }
    }
}
