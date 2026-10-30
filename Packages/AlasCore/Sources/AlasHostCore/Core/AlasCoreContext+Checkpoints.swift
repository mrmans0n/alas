import Foundation
import AlasFeatures
import AlasModel
import AlasPlatform
import os

private let checkpointLogger = Logger(subsystem: "io.nlopez.alas", category: "AlasHost")

extension AlasCoreContext {
    /// Nil for a remote path, a folder project or no lineage; repository name from the project, no workspace.
    func checkpointTarget(for worktree: Worktree) -> CheckpointWorktreeTarget? {
        let project = projects.projects.first { $0.id == worktree.projectId }
        guard !worktree.path.isRemoteAlasPath, project?.isFolder != true,
              let lineageID = worktree.lineageID ?? WorktreeService.existingLocalLineageID(forWorktreeAt: worktree.path)
        else { return nil }
        return CheckpointWorktreeTarget(
            worktreeID: worktree.id, projectID: worktree.projectId, path: worktree.path, lineageID: lineageID,
            branch: worktree.branch, repositoryName: project?.name ?? worktree.name, workspaceName: nil
        )
    }

    /// The app's automatic checkpoint before a prompt, on a headless host: nil
    /// without a target or on any failure, which never holds the prompt back.
    /// The store keeps at most 50 automatic checkpoints, oldest pruned, as the app's.
    func captureAutomaticCheckpoint(_ worktree: Worktree, prompt: String, hasAttachments: Bool) async -> CheckpointID? {
        guard let target = checkpointTarget(for: worktree) else { return nil }
        do {
            let label = AutomaticCheckpointLabel.make(prompt: prompt, hasAttachments: hasAttachments)
            return try await checkpoints.createAutomatic(target: target, label: label).id
        } catch {
            checkpointLogger.error("Automatic checkpoint failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Sessions: runners plus a starting one of the worktree's manager and, as
    /// the app counts a checkout as a shared session owner, of every Workspace
    /// checkout that manages it. Terminals: their runs, pending run launches,
    /// and host consoles (`hasHostConsoles`). No dirty editors, no other git mutation.
    /// With `hold`, the owners counted take no new writer until the hold is
    /// removed: claimed in the same turn as the count, so none slips between.
    func checkpointCoordination(for worktree: Worktree, holding hold: UUID? = nil) async -> CheckpointCoordinationSnapshot {
        let checkouts: [WorkspaceCheckout]? = switch await workspaceStore.load() {
        case .missing: []
        case .unreadable: nil
        case .loaded(let state): state.checkouts
        }
        if let hold {
            let owners = Self.checkpointWriterOwners(for: worktree, checkouts: checkouts, knownOwners: Array(sessionManagers.keys))
            checkpointRestoreHolds[hold] = Set(owners.map(\.storageKey))
        }
        let counts = Self.checkpointWriterCounts(
            for: worktree, checkouts: checkouts,
            sessions: sessionManagers.mapValues { $0.runners.count + ($0.hasStartingSession ? 1 : 0) },
            runOwnerKeys: processRuns.values.map(\.worktreeID) + pendingRunLaunches.keys.map(\.worktreeID),
            hasConsoles: { self.hasHostConsoles?($0) == true }
        )
        let repositoryName = projects.projects.first { $0.id == worktree.projectId }?.name ?? worktree.name
        return CheckpointCoordinationSnapshot(
            dirtyEditorPaths: [], activeTerminalCount: counts.terminals, activeACPCount: counts.sessions, otherGitMutationActive: false,
            scopeDescription: CheckpointCoordinationSnapshot.scopeDescription(repositoryName: repositoryName, workspaceName: nil)
        )
    }

    /// The restore writers of `worktree`'s owners: itself and each checkout that
    /// manages it (`checkoutManages`), or every checkout when the Workspace state
    /// is unreadable (`checkouts` nil). `sessions` counts writers per owner;
    /// `runOwnerKeys` holds one owner storage key per run or pending launch.
    nonisolated static func checkpointWriterCounts(
        for worktree: Worktree, checkouts: [WorkspaceCheckout]?, sessions: [SessionOwnerID: Int],
        runOwnerKeys: [String], hasConsoles: (Set<String>) -> Bool
    ) -> (sessions: Int, terminals: Int) {
        let owners = checkpointWriterOwners(for: worktree, checkouts: checkouts, knownOwners: Array(sessions.keys))
        let keys = Set(owners.map(\.storageKey))
        return (
            owners.reduce(0) { $0 + (sessions[$1] ?? 0) },
            runOwnerKeys.filter(keys.contains).count + (hasConsoles(keys) ? 1 : 0)
        )
    }

    /// `worktree` and each checkout that manages it, or, with unreadable
    /// Workspace state, every checkout among `knownOwners`.
    nonisolated static func checkpointWriterOwners(
        for worktree: Worktree, checkouts: [WorkspaceCheckout]?, knownOwners: [SessionOwnerID]
    ) -> [SessionOwnerID] {
        let checkoutOwners: [SessionOwnerID] = if let checkouts {
            checkouts.filter { checkoutManages($0, worktree) }.map { .workspaceCheckout($0.id, $0.executionLocation) }
        } else {
            knownOwners.filter { $0.worktreeID == nil }
        }
        return [.worktree(worktree.id)] + checkoutOwners
    }

    /// Whether a running checkpoint restore keeps new sessions, consoles and
    /// runs out of `owner`.
    func isHeldByCheckpointRestore(_ owner: SessionOwnerID) -> Bool {
        checkpointRestoreHolds.values.contains { $0.contains(owner.storageKey) }
    }

    /// `id` if the worktree's catalog lists it, else notFound(what: "checkpoint <id>").
    /// A Mac never names another worktree's checkpoint, or one deleted since it listed them.
    func listedCheckpoint(_ id: CheckpointID, in target: CheckpointWorktreeTarget) async throws -> CheckpointID {
        guard try await checkpoints.summaries(target: target).summaries.contains(where: { $0.id == id }) else {
            throw HostError.notFound(what: "checkpoint \(id)")
        }
        return id
    }

    /// The answer to `listCheckpoints`, with whether a restore awaits recovery:
    /// not while one runs, whose journal is open too.
    func checkpointCatalog(in worktree: Worktree) async throws -> HostResponse {
        let target = try requireCheckpointTarget(for: worktree)
        let catalog = try await checkpoints.summaries(target: target)
        let journals = try await checkpoints.nonterminalJournals(target: target)
        return .checkpoints(
            catalog: catalog, interruptedRestore: !journals.isEmpty && !isHeldByCheckpointRestore(.worktree(worktree.id))
        )
    }

    func checkpointManifest(_ id: CheckpointID, in worktree: Worktree) async throws -> WorktreeCheckpointManifest {
        let target = try requireCheckpointTarget(for: worktree)
        return try await checkpoints.manifest(target: target, id: listedCheckpoint(id, in: target))
    }

    /// The service bounds what it reads; an image it decoded is answered as a note, its pixels never sent.
    func checkpointDiff(_ id: CheckpointID, path: String, in worktree: Worktree) async throws -> HostDiff {
        let target = try requireCheckpointTarget(for: worktree)
        try await Self.refuseOutside([path], of: worktree.path)
        let listed = try await listedCheckpoint(id, in: target)
        switch await checkpoints.diffContent(target: target, id: listed, path: path) {
        case .text(let diff): return HostDiff(diff)
        case .image: return HostDiff(hunks: [], truncated: false, note: "Image changes are not shown from a host.")
        case .binary: return HostDiff(hunks: [], truncated: false, note: "Binary files cannot be shown.")
        case .unavailable(let message): throw HostError.failed(message: message)
        }
    }

    func checkpointRestorePreview(_ id: CheckpointID, groupIDs: Set<UUID>?, in worktree: Worktree) async throws -> CheckpointRestorePreview {
        let target = try requireCheckpointTarget(for: worktree)
        return try await checkpoints.restorePreview(
            target: target, id: listedCheckpoint(id, in: target), coordination: await checkpointCoordination(for: worktree),
            selectedGroupIDs: groupIDs
        )
    }

    /// A checkpoint change, under the project's gate: refused, as locally, for
    /// every restore blocker the host sees, and for a preview gone stale.
    func applyCheckpointChange(_ change: HostWorktreeChange, to worktree: Worktree) async throws -> HostResponse {
        let target = try requireCheckpointTarget(for: worktree)
        switch change {
        case .createCheckpoint(let label):
            guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw HostError.invalidRequest(reason: "A checkpoint needs a name.")
            }
            let created = try await checkpoints.createManual(target: target, label: label)
            return .checkpointManifest(manifest: try await checkpoints.manifest(target: target, id: created.id))
        case .deleteCheckpoint(let id):
            _ = try await checkpoints.delete(target: target, id: listedCheckpoint(id, in: target))
        case .restoreCheckpoint(let id, let groupIDs, let fingerprint):
            // Held until the restore ends, so no writer starts after the count.
            let hold = UUID()
            defer { checkpointRestoreHolds[hold] = nil }
            let coordination = await checkpointCoordination(for: worktree, holding: hold)
            let preview = try await checkpoints.restorePreview(
                target: target, id: listedCheckpoint(id, in: target), coordination: coordination, selectedGroupIDs: groupIDs
            )
            if let blocker = preview.blocker { throw HostError.failed(message: blocker.description) }
            guard preview.currentFingerprint == fingerprint else {
                throw HostError.failed(message: "Refresh the restore preview before trying again.")
            }
            do {
                // The service takes the recovery checkpoint first.
                _ = try await checkpoints.restore(target: target, preview: preview, selectedGroupIDs: groupIDs, coordination: coordination)
            } catch {
                throw HostError.failed(message: CheckpointRestoreErrorPresentation.message(error))
            }
        case .recoverCheckpointRestore:
            // As the app's Recover, for each interrupted restore in journal
            // order, held as a restore is; none left is already done.
            let hold = UUID()
            defer { checkpointRestoreHolds[hold] = nil }
            let coordination = await checkpointCoordination(for: worktree, holding: hold)
            for journal in try await checkpoints.nonterminalJournals(target: target) {
                do {
                    _ = try await checkpoints.recoverInterruptedRestore(target: target, operationID: journal.id, coordination: coordination)
                } catch {
                    throw HostError.failed(message: CheckpointRestoreErrorPresentation.message(error))
                }
            }
        case .stage, .unstage, .discard, .commit, .push, .pull, .fetch, .stash, .applyStash, .popStash, .dropStash,
             .continueOperation, .skipOperation, .abortOperation, .useOurs, .useTheirs, .keepDeleted, .markResolved, .cherryPick,
             .revert, .merge, .rebase, .editCommit:
            preconditionFailure("not a checkpoint change")
        }
        return .done
    }

    private func requireCheckpointTarget(for worktree: Worktree) throws -> CheckpointWorktreeTarget {
        guard let target = checkpointTarget(for: worktree) else {
            throw HostError.failed(message: "Checkpoints are not available for this worktree.")
        }
        return target
    }
}
