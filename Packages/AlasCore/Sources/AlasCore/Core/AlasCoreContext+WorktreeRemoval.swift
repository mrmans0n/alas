import Foundation
import os

private let removalLogger = Logger(subsystem: "io.nlopez.alas", category: "WorktreeRemoval")

/// One request to remove a worktree from disk.
public struct WorktreeRemovalRequest: Sendable {
    public var worktree: Worktree
    /// The repository the worktree belongs to.
    public var repoPath: URL
    public var force: Bool
    public var deleteBranchIfMerged: Bool
    public var verifiedMergedBranchSHA: String?
    /// The content fingerprint the caller confirmed. The removal is refused
    /// if the worktree changed since, and Git's preflight is not repeated.
    public var authorizedContentFingerprint: String?
    /// Checked under the project mutation gate right before removal. A reason
    /// skips the removal.
    public var revalidate: @MainActor @Sendable () async -> String?

    public init(
        worktree: Worktree,
        repoPath: URL,
        force: Bool,
        deleteBranchIfMerged: Bool,
        verifiedMergedBranchSHA: String? = nil,
        authorizedContentFingerprint: String? = nil,
        revalidate: @escaping @MainActor @Sendable () async -> String? = { nil }
    ) {
        self.worktree = worktree
        self.repoPath = repoPath
        self.force = force
        self.deleteBranchIfMerged = deleteBranchIfMerged
        self.verifiedMergedBranchSHA = verifiedMergedBranchSHA
        self.authorizedContentFingerprint = authorizedContentFingerprint
        self.revalidate = revalidate
    }
}

public enum WorktreeRemovalResult: Equatable, Sendable {
    case removed
    /// Git would refuse without `force` (changes, a lock). Nothing was touched.
    case needsForce(String)
    /// The worktree changed since the caller confirmed. Nothing was removed.
    case skipped(String)
    /// An interrupted checkpoint restore must be recovered first.
    case checkpointRecoveryPending
    case failed(String)

    /// The reason a removal skipped because its confirmed content changed.
    public static let changedDeleteRisksMessage = "Git deletion risks changed since confirmation"
}

extension AlasCoreContext {
    /// Removes a worktree whose claim the caller already holds. The order is
    /// fixed: refuse what cannot proceed before anything stops; stop
    /// everything using the checkout; remove it under the project mutation
    /// gate; then drop what belonged to it. A refusal after the quiesce (Git
    /// failing after its preflight, or `revalidate` objecting) leaves the
    /// worktree in place with its sessions already stopped.
    public func removeWorktree(_ request: WorktreeRemovalRequest) async -> WorktreeRemovalResult {
        let worktree = request.worktree
        if await checkpointRecoveryBlocksRemoval(worktree) {
            return .checkpointRecoveryPending
        }
        if !request.force, request.authorizedContentFingerprint == nil {
            // The preflight has its own missing-LFS fallback; anything it still
            // cannot answer refuses before anything is stopped.
            do {
                if try await WorktreeService().deletePreflight(worktreePath: worktree.path).requiresForce {
                    return .needsForce(WorktreeService.dirtyWorktreeMessage)
                }
            } catch {
                return .failed("\(error.localizedDescription)")
            }
        }

        // Nothing may keep using the checkout while its files go.
        await stopHeadlessRuns(worktreeID: worktree.id)
        do {
            try await quiesceWorktree(worktree)
        } catch {
            return .failed("Could not stop everything using the worktree: \(error.localizedDescription)")
        }

        let outcome: WorktreeRemovalOutcome
        do {
            outcome = try await ProjectMutationGate.shared.withMutation(projectID: worktree.projectId) {
                if let reason = await request.revalidate() {
                    throw RemovalSkipped(reason: reason)
                }
                return try await WorktreeLifecycle.performRemoveWorktree(
                    repoPath: request.repoPath,
                    worktree: worktree,
                    deleteBranchIfMerged: request.deleteBranchIfMerged,
                    force: request.force,
                    verifiedMergedBranchSHA: request.verifiedMergedBranchSHA,
                    authorizedDeleteContentFingerprint: request.authorizedContentFingerprint
                )
            }
        } catch let skipped as RemovalSkipped {
            return .skipped(skipped.reason)
        } catch is WorktreeLifecycle.DeleteContentFingerprintMismatch {
            return .skipped(WorktreeRemovalResult.changedDeleteRisksMessage)
        } catch let WorktreeService.WorktreeError.gitFailed(stderr) {
            if stderr == WorktreeRemovalResult.changedDeleteRisksMessage {
                return .skipped(stderr)
            }
            return WorktreeService.requiresForceRetry(forRemovalRefusal: stderr) ? .needsForce(stderr) : .failed(stderr)
        } catch {
            return .failed("\(error)")
        }

        await discardRuns(worktreeID: worktree.id, deletingHistory: true)?.value
        if case .staged(let ticket) = outcome {
            do {
                try launchWorktreeCleanup(ticket)
            } catch {
                removalLogger.error(
                    "Could not launch worktree cleanup for \(ticket.stagedPath.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
            // Also covers a cleanup that could not be launched.
            let cleanupProjects = projects.projects
            Task.detached(priority: .utility) {
                WorktreeTrashCleaner.sweep(projects: cleanupProjects)
            }
        }
        return .removed
    }

    /// Cancels the worktree's headless runs and waits until their records
    /// have settled.
    func stopHeadlessRuns(worktreeID: String) async {
        let running = headlessRuns.values.filter { $0.worktreeID == worktreeID }.map(\.task)
        for run in running {
            run.cancel()
        }
        for run in running {
            _ = try? await run.value
        }
    }

    // MARK: - Archive

    /// Archives a worktree whose `.archiving` claim the caller holds: stops
    /// its headless runs and quiesces it like a removal, then hides it and
    /// persists that. Its runs settle as lost but keep their history, and
    /// nothing leaves the disk. Throws, leaving the worktree visible, when it
    /// cannot be quiesced or the save fails.
    public func performArchive(
        _ worktree: Worktree,
        revalidate: @MainActor () async -> (any Error)? = { nil }
    ) async throws {
        await stopHeadlessRuns(worktreeID: worktree.id)
        try await quiesceWorktree(worktree)
        // Ownership can change while everything stops (a Workspace checkout
        // registering this worktree), so it is checked again right before hiding.
        if let refusal = await revalidate() {
            throw refusal
        }
        let wasHidden = projects.isWorktreeHidden(projectId: worktree.projectId, path: worktree.path)
        projects.setWorktreeHidden(projectId: worktree.projectId, path: worktree.path, hidden: true)
        do {
            try saveProjects()
        } catch {
            projects.setWorktreeHidden(projectId: worktree.projectId, path: worktree.path, hidden: wasHidden)
            throw error
        }
        discardRuns(worktreeID: worktree.id, deletingHistory: false)
    }

    /// Archives `worktree` through the same routine as the app, claiming it
    /// so nothing new starts in it meanwhile. The main checkout and members of
    /// an active Workspace checkout are refused.
    public func archiveWorktree(_ worktree: Worktree) async throws {
        guard let project = projects.projects.first(where: { $0.id == worktree.projectId }) else {
            throw ProjectCreationError.projectNotFound
        }
        guard !projects.isMain(worktree, in: project) else { throw WorktreeArchiveRefusal.mainWorktree }
        switch projects.operationState(for: worktree) {
        case nil, .deleteFailed: break
        default: throw WorktreeArchiveRefusal.operationInProgress
        }
        let claim = WorktreeOperationState.archiving(projectId: project.id)
        projects.setOperationState(for: worktree, state: claim)
        defer {
            if projects.operationState(for: worktree) == claim {
                projects.setOperationState(for: worktree, state: nil)
            }
        }
        if let refusal = await workspaceOwnershipRefusal(for: worktree) {
            throw WorktreeArchiveRefusal.ownedByWorkspaceCheckout(refusal)
        }
        try await performArchive(worktree, revalidate: { [weak self] in
            await self?.workspaceOwnershipRefusal(for: worktree).map(WorktreeArchiveRefusal.ownedByWorkspaceCheckout)
        })
    }

    /// Shows an archived worktree again. Sessions and runs are not restored.
    /// Refused while any operation holds the worktree.
    public func unarchiveWorktree(path: URL, projectID: String) throws {
        guard projects.projects.contains(where: { $0.id == projectID }) else {
            throw ProjectCreationError.projectNotFound
        }
        guard projects.operationState(forWorktreeId: Worktree.makeId(path: path), projectId: projectID)?.blocksAdmission != true else {
            throw WorktreeArchiveRefusal.operationInProgress
        }
        let wasHidden = projects.isWorktreeHidden(projectId: projectID, path: path)
        projects.setWorktreeHidden(projectId: projectID, path: path, hidden: false)
        do {
            try saveProjects()
        } catch {
            projects.setWorktreeHidden(projectId: projectID, path: path, hidden: wasHidden)
            throw error
        }
    }

    /// Reactivates an archived Workspace checkout. Until `publish` (which
    /// refreshes whatever snapshot callers read ownership from) returns, its
    /// members count as owned, so no archive slips in while the checkout's
    /// state is in flight.
    public func unarchiveWorkspaceCheckout(
        id: UUID,
        publish: @MainActor () async -> Void = {}
    ) async throws -> WorkspaceCheckout {
        unarchivingWorkspaceCheckouts[id, default: 0] += 1
        defer {
            unarchivingWorkspaceCheckouts[id]! -= 1
            if unarchivingWorkspaceCheckouts[id] == 0 { unarchivingWorkspaceCheckouts[id] = nil }
        }
        let checkout = try await workspaceCoordinator().unarchive(checkoutID: id)
        await publish()
        return checkout
    }

    /// Whether `unarchiveWorkspaceCheckout` is reactivating checkout `id`.
    public func isUnarchivingWorkspaceCheckout(_ id: UUID) -> Bool {
        unarchivingWorkspaceCheckouts[id] != nil
    }

    /// Whether an interrupted checkpoint restore references the checkout.
    /// An unreadable journal store counts as one.
    public static func hasPendingCheckpointRecovery(_ worktree: Worktree) async -> Bool {
        guard let lineageID = worktree.lineageID ?? WorktreeService.existingLocalLineageID(forWorktreeAt: worktree.path)
        else { return false }
        guard let journals = try? await WorktreeCheckpointStore().recoverableJournals(lineageID: lineageID) else {
            return true
        }
        return !journals.isEmpty
    }
}

/// Why `AlasCoreContext.archiveWorktree` or `unarchiveWorktree` refused.
public enum WorktreeArchiveRefusal: Error, Equatable {
    /// The project's main checkout is never archived.
    case mainWorktree
    /// Another operation holds the worktree.
    case operationInProgress
    /// An active Workspace checkout manages this worktree.
    case ownedByWorkspaceCheckout(String)
}

/// Why `AlasCoreContext.deleteWorktree` did not delete.
public enum WorktreeDeletionRefusal: Error, Equatable {
    /// The project's main checkout is never deleted.
    case mainWorktree
    /// Remote checkouts carry no lineage marker to tell a replacement apart;
    /// only the app's confirmed flow deletes them.
    case remoteUnsupported
    /// The worktree carries no lineage, so a replacement could not be told apart.
    case unknownIdentity
    /// Another operation holds the worktree.
    case operationInProgress
    /// Git would refuse without `force`.
    case needsForce(String)
    /// The checkout changed (replaced, switched branch, or claimed by a
    /// Workspace checkout) since the caller looked.
    case changed(String)
    /// An interrupted checkpoint restore must be recovered first.
    case checkpointRecoveryPending
    case failed(String)
}

extension AlasCoreContext {
    /// Deletes `worktree`, and its branch when merged and
    /// `deleteBranchIfMerged`, through the same routine as the app. It claims
    /// the worktree so nothing new starts in it, and is refused for the main
    /// checkout, remote checkouts and worktrees without a lineage. Throws if
    /// the project list cannot be saved afterwards; the worktree is gone by then.
    public func deleteWorktree(_ worktree: Worktree, force: Bool = false, deleteBranchIfMerged: Bool = false) async throws {
        guard let project = projects.projects.first(where: { $0.id == worktree.projectId }) else {
            throw ProjectCreationError.projectNotFound
        }
        guard !worktree.path.isRemoteAlasPath else { throw WorktreeDeletionRefusal.remoteUnsupported }
        guard !projects.isMain(worktree, in: project) else { throw WorktreeDeletionRefusal.mainWorktree }
        guard let lineageID = worktree.lineageID else { throw WorktreeDeletionRefusal.unknownIdentity }
        switch projects.operationState(for: worktree) {
        case nil, .deleteFailed: break
        default: throw WorktreeDeletionRefusal.operationInProgress
        }
        let claim = WorktreeOperationState.deleting(projectId: project.id)
        projects.setOperationState(for: worktree, state: claim)
        defer {
            if projects.operationState(for: worktree) == claim {
                projects.setOperationState(for: worktree, state: nil)
            }
        }

        let result = await removeWorktree(WorktreeRemovalRequest(
            worktree: worktree,
            repoPath: URL(fileURLWithPath: project.path),
            force: force,
            deleteBranchIfMerged: deleteBranchIfMerged,
            revalidate: { [weak self] in
                guard WorktreeService.existingLocalLineageID(forWorktreeAt: worktree.path) == lineageID else {
                    return "The path holds a different checkout"
                }
                guard WorktreeService.localBranchName(forWorktreeAt: worktree.path) == worktree.branch else {
                    return "The checkout is on another branch"
                }
                return await self?.workspaceOwnershipRefusal(for: worktree)
            }
        ))
        switch result {
        case .removed:
            break
        case .needsForce(let refusal):
            throw WorktreeDeletionRefusal.needsForce(refusal)
        case .skipped(let reason):
            throw WorktreeDeletionRefusal.changed(reason)
        case .checkpointRecoveryPending:
            throw WorktreeDeletionRefusal.checkpointRecoveryPending
        case .failed(let message):
            throw WorktreeDeletionRefusal.failed(message)
        }

        let changed: Bool
        do {
            changed = try await projects.refreshWorktrees(projectId: project.id)
        } catch {
            // The removal succeeded, so the row must not survive a failed
            // refresh, in memory or on disk.
            projects.dropRemovedWorktree(id: worktree.id, projectId: project.id)
            changed = true
        }
        if changed {
            try saveProjects()
        }
    }

    /// Why an active Workspace checkout keeps `worktree` from being deleted
    /// on its own, matched like the app's worktree-cleanup ownership.
    /// Unreadable Workspace state refuses too.
    func workspaceOwnershipRefusal(for worktree: Worktree) async -> String? {
        // Read before the load: an unarchive can finish, and leave the set,
        // while the load is suspended. One starting later is refused by the
        // claim the caller holds.
        let unarchiving = unarchivingWorkspaceCheckouts
        let state: WorkspaceStateFile
        switch await workspaceStore.load() {
        case .missing: return nil
        case .unreadable: return "Workspace ownership could not be verified"
        case .loaded(let loaded): state = loaded
        }
        let path = worktree.path.standardizedFileURL.path
        let owner = state.checkouts.first { checkout in
            checkout.workspaceID != nil
                && (checkout.archivedAt == nil || unarchiving[checkout.id] != nil)
                && checkout.members.contains { member in
                guard member.projectID == worktree.projectId,
                      URL(fileURLWithPath: checkout.inAppWorktreePath(member.worktreePath)).standardizedFileURL.path == path
                else { return false }
                if let memberLineage = member.gitLineageID, let lineage = worktree.lineageID, memberLineage != lineage {
                    return false
                }
                return !(member.availability == .explicitlyDeleted && member.cleanup?.worktreeRemoved == true)
            }
        }
        return owner.map { "Workspace checkout \u{201C}\($0.fallbackWorkspaceName)\u{201D} manages this worktree" }
    }
}

private struct RemovalSkipped: Error {
    let reason: String
}
