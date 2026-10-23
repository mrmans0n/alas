import Foundation
import AlasModel
import AlasFeatures

/// A worktree a paired host lists, with what decides its controls.
public struct PeerHostWorktree: Equatable, Sendable {
    public var snapshot: WorktreeSnapshot
    public var project: ProjectSnapshot
    /// `worktree.isMainWorktree`, else its standardized path equals the project's.
    public var isMain: Bool
    /// The active Workspace checkout managing it (workspaceID set, not archived,
    /// a member with this project id and standardized worktree path).
    public var workspaceCheckoutName: String?

    public init(snapshot: WorktreeSnapshot, project: ProjectSnapshot, isMain: Bool, workspaceCheckoutName: String?) {
        self.snapshot = snapshot
        self.project = project
        self.isMain = isMain
        self.workspaceCheckoutName = workspaceCheckoutName
    }

    /// Archive and Delete follow the local rules, on a host that serves them.
    public func controls(lifecycleSupported: Bool) -> PeerWorktreeControls {
        guard lifecycleSupported, !isMain, project.kind != .folder, workspaceCheckoutName == nil else { return .hidden }
        switch snapshot.operation {
        case .creating, .preparingDelete, .deleting, .archiving, .createFailed: return .hidden
        case nil, .launchFailed, .deleteFailed: break
        }
        return project.host == nil ? .available : .disabled(reason: PeerWorktreeControls.remoteProjectReason)
    }
}

extension PeerHostChannel.State {
    /// Non-archived worktrees of listed projects, in snapshot order.
    public func visibleWorktrees() -> [PeerHostWorktree] {
        func standardized(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }
        let projectsByID = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let activeCheckouts = workspaceCheckouts.filter { $0.workspaceID != nil && $0.archivedAt == nil }
        return worktrees.compactMap { snapshot in
            let worktree = snapshot.worktree
            guard !snapshot.isArchived, let project = projectsByID[worktree.projectId] else { return nil }
            let path = worktree.path.standardizedFileURL.path
            let owner = activeCheckouts.first { checkout in
                checkout.members.contains { $0.projectID == worktree.projectId && standardized($0.worktreePath) == path }
            }
            return PeerHostWorktree(
                snapshot: snapshot, project: project,
                isMain: worktree.isMainWorktree ?? (path == standardized(project.path)),
                workspaceCheckoutName: owner?.name
            )
        }
    }
}

public enum PeerWorktreeControls: Equatable, Sendable {
    case hidden
    case disabled(reason: String)
    case available

    public static let remoteProjectReason = "Worktrees of remote projects can only be archived or deleted on the host Mac."
}

/// Archives or deletes a host's worktree: the user confirms a delete, then
/// each refusal the user can overrule (git changes, unsaved editor changes on
/// the host) is asked about on its own before the request is sent again.
public enum PeerWorktreeRemoval {
    public enum Action: Equatable, Sendable {
        case archive
        case delete(keepBranch: Bool, deleteBranchIfMerged: Bool)
    }

    public enum Confirmation: Equatable, Sendable {
        case delete(branch: String, keepBranch: Bool)
        case force(branch: String)
        case discardUnsavedEdits(branch: String, archiving: Bool)
    }

    public enum Outcome: Equatable, Sendable {
        case done, cancelled
        case refused(message: String)
    }

    @MainActor
    public static func run(
        _ action: Action, on worktree: WorktreeSnapshot,
        request: @MainActor (HostRequest) async -> HostResponse,
        confirm: @MainActor (Confirmation) async -> Bool
    ) async -> Outcome {
        let branch = worktree.worktree.branch
        if case .delete(let keepBranch, _) = action,
           !(await confirm(.delete(branch: branch, keepBranch: keepBranch))) { return .cancelled }
        var force = false, discard = false
        while true {
            switch await request(makeRequest(action, worktree.worktree, force: force, discard: discard)) {
            case .done: return .done
            case .failure(.worktreeDeletion(.needsForce)) where !force && action != .archive:
                guard await confirm(.force(branch: branch)) else { return .cancelled }
                force = true
            case .failure(.worktreeDeletion(.unsavedEdits)) where !discard,
                 .failure(.worktreeArchive(.unsavedEdits)) where !discard:
                guard await confirm(.discardUnsavedEdits(branch: branch, archiving: action == .archive)) else { return .cancelled }
                discard = true
            case .failure(let error): return .refused(message: message(for: error))
            default: return .refused(message: "The host sent an unexpected reply.")
            }
        }
    }

    private static func makeRequest(_ action: Action, _ worktree: Worktree, force: Bool, discard: Bool) -> HostRequest {
        let ref = WorktreeRef(projectID: worktree.projectId, path: worktree.path.path)
        switch action {
        case .archive:
            return .archiveWorktree(worktree: ref, lineageID: worktree.lineageID, branch: worktree.branch, discardUnsavedEdits: discard)
        case .delete(_, let deleteBranchIfMerged):
            return .deleteWorktree(
                worktree: ref, lineageID: worktree.lineageID, branch: worktree.branch, force: force,
                deleteBranchIfMerged: deleteBranchIfMerged, discardUnsavedEdits: discard
            )
        }
    }

    public static func message(for error: HostError) -> String {
        switch error {
        case .worktreeDeletion(let refusal): refusal.localizedDescription
        case .worktreeArchive(let refusal): refusal.localizedDescription
        case .failed(let message): message
        case .operationInProgress: "Wait for the current worktree operation to finish."
        case .notFound: "The host no longer lists this worktree."
        default: String(describing: error)
        }
    }
}
