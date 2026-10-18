import Foundation
import os

private let removalLogger = Logger(subsystem: "io.nlopez.alas", category: "WorktreeRemoval")

/// One request to remove a worktree from disk.
@_spi(AppHost) public struct WorktreeRemovalRequest: Sendable {
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
    /// Refuse, as the editors close, any unsaved change; see
    /// `WorktreeDeleteOptions.refusesUnsavedEdits`.
    public var refusesUnsavedEdits = false

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
    /// The reason a deletion skipped because its claim or checkout changed.
    public static let changedSinceConfirmationMessage = "Worktree changed since confirmation"
    public static let checkpointRecoveryMessage = "An interrupted checkpoint restore needs recovery before this worktree can be deleted."
}

/// How `AlasCoreContext.deleteWorktree(_:claim:options:)` removes a worktree
/// and what it leaves on the row when it does not.
public struct WorktreeDeleteOptions: Sendable {
    public var force = false
    public var deleteBranchIfMerged = false
    public var verifiedMergedBranchSHA: String?
    /// The content fingerprint the caller confirmed; see `WorktreeRemovalRequest`.
    public var authorizedContentFingerprint: String?
    /// When Git refuses without force, keep the claim (as `.preparingDelete`)
    /// so the caller can ask, then delete again with `force` or release it.
    /// Otherwise the refusal is left on the row as `.deleteFailed`.
    public var keepsClaimForForcePrompt = false
    /// Leave a skipped deletion on the row as `.deleteFailed`, for retry.
    /// Batches report skips in their own results and restore the row.
    public var recordsSkips = true
    /// Refresh the project once removed. A batch passes false and calls
    /// `finishDeletions` once for all of its removals.
    public var refreshesProject = true
    /// More checks right before removal, under the project mutation gate.
    /// A reason skips the deletion.
    public var revalidate: @MainActor @Sendable () async -> String? = { nil }
    /// Nobody confirmed discarding unsaved editor changes: one made while
    /// the deletion runs refuses it as the editors close, rather than being
    /// discarded with them.
    public var refusesUnsavedEdits = false

    public init() {}
}

public enum WorktreeDeletionOutcome: Equatable, Sendable {
    case deleted
    /// Removed, but the project list could not be saved afterwards, so the
    /// row may come back on the next launch.
    case deletedButNotSaved(String)
    /// Git refused without force.
    case needsForce(String)
    /// The worktree changed since the caller confirmed. Nothing was removed.
    case skipped(String)
    case failed(String)
}

extension AlasCoreContext {
    /// Removes a worktree whose claim the caller already holds. The order is
    /// fixed: refuse what cannot proceed before anything stops; stop
    /// everything using the checkout; remove it under the project mutation
    /// gate; then drop what belonged to it. A refusal after the quiesce (Git
    /// failing after its preflight, or `revalidate` objecting) leaves the
    /// worktree in place with its sessions already stopped.
    @_spi(AppHost) public func removeWorktree(_ request: WorktreeRemovalRequest) async -> WorktreeRemovalResult {
        let worktree = request.worktree
        if await environment.checkpointRecoveryBlocksRemoval(worktree) {
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
        await stopProcessRuns(worktreeID: worktree.id)
        do {
            try await environment.quiesceWorktree(worktree, refusingUnsavedEdits: request.refusesUnsavedEdits, in: self)
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
                try environment.launchWorktreeCleanup(ticket)
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

    // MARK: - Archive

    /// Archives a worktree whose `.archiving` claim the caller holds: stops
    /// its headless runs and quiesces it like a removal, then hides it and
    /// persists that. Its runs settle as lost but keep their history, and
    /// nothing leaves the disk. Throws, leaving the worktree visible, when it
    /// cannot be quiesced or the save fails.
    func performArchive(
        _ worktree: Worktree,
        revalidate: @MainActor () async -> (any Error)? = { nil }
    ) async throws {
        await stopProcessRuns(worktreeID: worktree.id)
        try await environment.quiesceWorktree(worktree, in: self)
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
    /// an active Workspace checkout are refused. With `verifiesCheckout`, so
    /// is a local checkout whose lineage or branch on disk no longer matches
    /// `worktree`, checked right before it is hidden.
    public func archiveWorktree(_ worktree: Worktree, verifiesCheckout: Bool = false) async throws {
        try await archiveWorktree(worktree, claim: beginArchive(worktree), verifiesCheckout: verifiesCheckout)
    }

    /// Why the checkout at `worktree`'s path is no longer the one with
    /// `lineageID` on `worktree`'s branch; nil while it still is.
    nonisolated static func checkoutChange(_ worktree: Worktree, lineageID: String) -> String? {
        guard WorktreeService.existingLocalLineageID(forWorktreeAt: worktree.path) == lineageID else {
            return "The path holds a different checkout"
        }
        guard WorktreeService.localBranchName(forWorktreeAt: worktree.path) == worktree.branch else {
            return "The checkout is on another branch"
        }
        return nil
    }

    /// Claims `worktree` for archiving, for callers that ask the user
    /// something (such as saving buffers) before `archiveWorktree(_:claim:)`.
    /// Release the claim if the archive does not go ahead.
    public func beginArchive(_ worktree: Worktree) throws -> UUID {
        try refuseIfStopping()
        guard let project = projects.projects.first(where: { $0.id == worktree.projectId }) else {
            throw ProjectCreationError.projectNotFound
        }
        guard !projects.isMain(worktree, in: project) else { throw WorktreeArchiveRefusal.mainWorktree }
        guard WorktreeOperationState.admitsLifecycleOperation(projects.operationState(for: worktree)) else {
            throw WorktreeArchiveRefusal.operationInProgress
        }
        return projects.claimOperation(.archiving(projectId: project.id), for: worktree)
    }

    /// Releases a claim a `begin…` call returned, when its operation does
    /// not go ahead. Whatever state the claim replaced comes back.
    public func releaseWorktreeClaim(_ claim: UUID, for worktree: Worktree) {
        projects.releaseOperation(claim, for: worktree)
    }

    /// Archives a worktree claimed by `beginArchive`, and releases the claim.
    public func archiveWorktree(_ worktree: Worktree, claim: UUID, verifiesCheckout: Bool = false) async throws {
        defer { projects.releaseOperation(claim, for: worktree) }
        // Each check reads the claim after the ownership await: a refresh can
        // clear it meanwhile, and whatever is listed then is not this claim's.
        if let refusal = await workspaceOwnershipRefusal(for: worktree) {
            throw WorktreeArchiveRefusal.ownedByWorkspaceCheckout(refusal)
        }
        guard projects.holdsClaim(claim, for: worktree) else { throw WorktreeArchiveRefusal.operationInProgress }
        try await performArchive(worktree, revalidate: { [weak self] in
            guard let self else { return nil }
            let refusal = await workspaceOwnershipRefusal(for: worktree)
            guard projects.holdsClaim(claim, for: worktree) else { return WorktreeArchiveRefusal.operationInProgress }
            if verifiesCheckout {
                // Stopping everything takes a while; another process can
                // replace or switch the checkout meanwhile.
                guard !worktree.path.isRemoteAlasPath else { return WorktreeArchiveRefusal.remoteUnsupported }
                guard let lineageID = worktree.lineageID else { return WorktreeArchiveRefusal.changed("The worktree's identity is unknown") }
                if let change = Self.checkoutChange(worktree, lineageID: lineageID) {
                    return WorktreeArchiveRefusal.changed(change)
                }
            }
            return refusal.map(WorktreeArchiveRefusal.ownedByWorkspaceCheckout)
        })
        projects.finishOperation(claim, for: worktree)
    }

    /// Shows an archived worktree again. Sessions and runs are not restored.
    /// Refused while any operation holds the worktree.
    public func unarchiveWorktree(path: URL, projectID: String) throws {
        try refuseIfStopping()
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
public enum WorktreeArchiveRefusal: Codable, LocalizedError, Equatable {
    /// The project's main checkout is never archived.
    case mainWorktree
    /// Another operation holds the worktree.
    case operationInProgress
    /// An active Workspace checkout manages this worktree.
    case ownedByWorkspaceCheckout(String)
    /// The checkout was replaced or switched branch since the caller looked.
    case changed(String)
    /// A remote checkout's identity cannot be checked, so only the app,
    /// whose user sees it, archives one.
    case remoteUnsupported

    private enum OwnedByWorkspaceCheckoutCodingKeys: String, CodingKey { case _0 = "reason" }
    private enum ChangedCodingKeys: String, CodingKey { case _0 = "reason" }

    public var errorDescription: String? {
        switch self {
        case .mainWorktree: "The main checkout cannot be archived."
        case .operationInProgress: "Wait for the current worktree operation to finish."
        case .ownedByWorkspaceCheckout(let reason): "\(reason)."
        case .changed(let reason): reason
        case .remoteUnsupported: "Remote worktrees can only be archived from the app."
        }
    }
}

/// Why `AlasCoreContext.deleteWorktree` did not delete.
public enum WorktreeDeletionRefusal: Codable, LocalizedError, Equatable {
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

    private enum NeedsForceCodingKeys: String, CodingKey { case _0 = "message" }
    private enum ChangedCodingKeys: String, CodingKey { case _0 = "message" }
    private enum FailedCodingKeys: String, CodingKey { case _0 = "message" }

    public var errorDescription: String? {
        switch self {
        case .mainWorktree: "The main checkout cannot be deleted."
        case .remoteUnsupported: "Remote worktrees can only be deleted from the app."
        case .unknownIdentity: "The worktree's identity is unknown, so a replacement could not be told apart."
        case .operationInProgress: "Wait for the current worktree operation to finish."
        case .needsForce(let refusal): refusal
        case .changed(let reason): reason
        case .remoteUnsupported: "Remote worktrees can only be archived from the app."
        case .checkpointRecoveryPending: WorktreeRemovalResult.checkpointRecoveryMessage
        case .failed(let message): message
        }
    }
}

extension AlasCoreContext {
    /// Deletes `worktree`, and its branch when merged and
    /// `deleteBranchIfMerged`, through the same routine as the app. It claims
    /// the worktree so nothing new starts in it, and is refused for the main
    /// checkout, remote checkouts and worktrees without a lineage. Throws if
    /// the project list cannot be saved afterwards; the worktree is gone by then.
    public func deleteWorktree(_ worktree: Worktree, force: Bool = false, deleteBranchIfMerged: Bool = false) async throws {
        guard !worktree.path.isRemoteAlasPath else { throw WorktreeDeletionRefusal.remoteUnsupported }
        guard let lineageID = worktree.lineageID else { throw WorktreeDeletionRefusal.unknownIdentity }
        let claim = try beginDelete(worktree)
        var options = WorktreeDeleteOptions()
        options.force = force
        options.deleteBranchIfMerged = deleteBranchIfMerged
        options.recordsSkips = false
        options.refreshesProject = false
        options.revalidate = { Self.checkoutChange(worktree, lineageID: lineageID) }
        options.refusesUnsavedEdits = !force
        switch await deleteWorktree(worktree, claim: claim, options: options) {
        case .deleted, .deletedButNotSaved:
            try await finishDeletions([(worktree, claim)])
        case .needsForce(let refusal):
            throw WorktreeDeletionRefusal.needsForce(refusal)
        case .skipped(let reason):
            throw WorktreeDeletionRefusal.changed(reason)
        case .failed(let message) where message == WorktreeRemovalResult.checkpointRecoveryMessage:
            throw WorktreeDeletionRefusal.checkpointRecoveryPending
        case .failed(let message):
            throw WorktreeDeletionRefusal.failed(message)
        }
    }

    /// Claims `worktree` for deletion (as `.preparingDelete`), for callers
    /// that confirm first. Pass the claim to `deleteWorktree(_:claim:options:)`,
    /// or release it if the deletion does not go ahead.
    public func beginDelete(_ worktree: Worktree) throws -> UUID {
        try refuseIfStopping()
        guard let project = projects.projects.first(where: { $0.id == worktree.projectId }) else {
            throw ProjectCreationError.projectNotFound
        }
        guard !projects.isMain(worktree, in: project) else { throw WorktreeDeletionRefusal.mainWorktree }
        guard WorktreeOperationState.admitsLifecycleOperation(projects.operationState(for: worktree)) else {
            throw WorktreeDeletionRefusal.operationInProgress
        }
        return projects.claimOperation(.preparingDelete, for: worktree)
    }

    /// Claims a Workspace checkout's member worktrees `.deleting`, all or
    /// none, for the checkout's own deletion: a member another operation
    /// holds refuses it, and what was claimed is released.
    public func claimWorkspaceMembersForDeletion(_ worktrees: [Worktree]) throws -> [(worktree: Worktree, claim: UUID)] {
        var claimed: [(worktree: Worktree, claim: UUID)] = []
        for worktree in worktrees {
            guard WorktreeOperationState.admitsLifecycleOperation(projects.operationState(for: worktree)) else {
                releaseWorktreeClaims(claimed)
                throw WorkspaceCheckoutCoordinatorError.operationInProgress
            }
            claimed.append((worktree, projects.claimOperation(.deleting(projectId: worktree.projectId), for: worktree)))
        }
        return claimed
    }

    /// Releases claims a deletion did not use; one a checkout recreated at
    /// the same path opened meanwhile is left alone.
    public func releaseWorktreeClaims(_ claims: [(worktree: Worktree, claim: UUID)]) {
        for (worktree, claim) in claims {
            projects.releaseOperation(claim, for: worktree)
        }
    }

    /// Ends the claim of a worktree that is gone, so nothing the claim
    /// replaced comes back for its path.
    public func finishWorktreeClaim(_ claim: UUID, for worktree: Worktree) {
        projects.finishOperation(claim, for: worktree)
    }

    /// Marks a claimed deletion as confirmed: the row reads as being deleted
    /// from here on.
    public func confirmDelete(_ claim: UUID, for worktree: Worktree) {
        projects.updateClaim(claim, to: .deleting(projectId: worktree.projectId), for: worktree)
    }

    /// Ends a claim a `begin…` call returned, leaving `message` on the row as
    /// a failure the user can retry.
    public func failWorktreeClaim(_ claim: UUID, for worktree: Worktree, message: String) {
        projects.finishOperation(claim, for: worktree, leaving: .deleteFailed(message: message))
    }

    /// Deletes a worktree claimed by `beginDelete`. Ownership by an active
    /// Workspace checkout is checked before anything stops and again right
    /// before removal. The claim ends here, except when Git asks for force
    /// and `keepsClaimForForcePrompt` holds it for the caller's prompt, or a
    /// removal whose refresh `finishDeletions` still owes.
    public func deleteWorktree(_ worktree: Worktree, claim: UUID, options: WorktreeDeleteOptions) async -> WorktreeDeletionOutcome {
        guard let project = projects.projects.first(where: { $0.id == worktree.projectId }) else {
            projects.releaseOperation(claim, for: worktree)
            return .failed("Could not find the project for this worktree.")
        }
        let ownership = await workspaceOwnershipRefusal(for: worktree)
        guard projects.holdsClaim(claim, for: worktree) else {
            return .skipped(WorktreeRemovalResult.changedSinceConfirmationMessage)
        }
        if let ownership {
            return settleSkippedDeletion(worktree, claim: claim, reason: ownership, options: options)
        }
        projects.updateClaim(claim, to: .deleting(projectId: project.id), for: worktree)

        var removal = WorktreeRemovalRequest(
            worktree: worktree,
            repoPath: URL(fileURLWithPath: project.path),
            force: options.force,
            deleteBranchIfMerged: options.deleteBranchIfMerged,
            verifiedMergedBranchSHA: options.verifiedMergedBranchSHA,
            authorizedContentFingerprint: options.authorizedContentFingerprint,
            revalidate: { [weak self] in
                if let reason = await options.revalidate() { return reason }
                guard let self else { return WorktreeRemovalResult.changedSinceConfirmationMessage }
                let ownership = await workspaceOwnershipRefusal(for: worktree)
                guard projects.holdsClaim(claim, for: worktree) else {
                    return WorktreeRemovalResult.changedSinceConfirmationMessage
                }
                return ownership
            }
        )
        removal.refusesUnsavedEdits = options.refusesUnsavedEdits
        let result = await removeWorktree(removal)
        switch result {
        case .removed:
            if options.refreshesProject {
                do {
                    try await finishDeletions([(worktree, claim)])
                } catch {
                    return .deletedButNotSaved(error.localizedDescription)
                }
            }
            return .deleted
        case .needsForce(let refusal) where options.force:
            projects.finishOperation(claim, for: worktree, leaving: .deleteFailed(message: refusal))
            return .failed(refusal)
        case .needsForce(let refusal):
            if options.keepsClaimForForcePrompt {
                projects.updateClaim(claim, to: .preparingDelete, for: worktree)
            } else {
                projects.finishOperation(claim, for: worktree, leaving: .deleteFailed(message: refusal))
            }
            return .needsForce(refusal)
        case .checkpointRecoveryPending:
            let message = WorktreeRemovalResult.checkpointRecoveryMessage
            projects.finishOperation(claim, for: worktree, leaving: .deleteFailed(message: message))
            return .failed(message)
        case .failed(let message):
            projects.finishOperation(claim, for: worktree, leaving: .deleteFailed(message: message))
            return .failed(message)
        case .skipped(let reason):
            return settleSkippedDeletion(worktree, claim: claim, reason: reason, options: options)
        }
    }

    /// Refreshes each project the removals belong to, once, then ends their
    /// claims. The claims outlive the refresh: until it runs the removed rows
    /// are still listed and must not admit new work. A refresh that fails
    /// drops the removed rows instead, so they cannot resolve as live
    /// worktrees. Throws if the project list cannot be saved.
    public func finishDeletions(_ deletions: [(worktree: Worktree, claim: UUID)]) async throws {
        var saveError: (any Error)?
        for projectID in Array(Set(deletions.map(\.worktree.projectId))).sorted() {
            let removed = deletions.filter { $0.worktree.projectId == projectID }
            var needsSave: Bool
            do {
                needsSave = try await environment.refreshProjectWorktrees(projectID, in: self)
            } catch {
                for deletion in removed {
                    projects.dropRemovedWorktree(id: deletion.worktree.id, projectId: projectID)
                }
                needsSave = true
            }
            // Finished, not released: nothing the claim replaced comes back
            // for a removed path, nor for a checkout recreated at it since.
            for deletion in removed {
                projects.finishOperation(deletion.claim, for: deletion.worktree)
            }
            if needsSave {
                do { try saveProjects() } catch { saveError = saveError ?? error }
            }
        }
        if let saveError { throw saveError }
    }

    private func settleSkippedDeletion(
        _ worktree: Worktree,
        claim: UUID,
        reason: String,
        options: WorktreeDeleteOptions
    ) -> WorktreeDeletionOutcome {
        if options.recordsSkips, reason != WorktreeRemovalResult.changedDeleteRisksMessage {
            projects.finishOperation(claim, for: worktree, leaving: .deleteFailed(message: reason))
        } else {
            projects.releaseOperation(claim, for: worktree)
        }
        return .skipped(reason)
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
