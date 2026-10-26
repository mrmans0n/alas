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

    /// Sessions: the worktree manager's runners plus a starting one. Terminals: its runs, pending
    /// run launches, and host consoles (`hasHostConsoles`). No dirty editors, no other git mutation.
    func checkpointCoordination(for worktree: Worktree) -> CheckpointCoordinationSnapshot {
        let manager = sessionManagers[.worktree(worktree.id)]
        let sessions = (manager?.runners.count ?? 0) + (manager?.hasStartingSession == true ? 1 : 0)
        let terminals = processRuns.values.filter { $0.worktreeID == worktree.id }.count
            + pendingRunLaunches.keys.filter { $0.worktreeID == worktree.id }.count
            + (hasHostConsoles?([worktree.id]) == true ? 1 : 0)
        let repositoryName = projects.projects.first { $0.id == worktree.projectId }?.name ?? worktree.name
        return CheckpointCoordinationSnapshot(
            dirtyEditorPaths: [], activeTerminalCount: terminals, activeACPCount: sessions, otherGitMutationActive: false,
            scopeDescription: CheckpointCoordinationSnapshot.scopeDescription(repositoryName: repositoryName, workspaceName: nil)
        )
    }

    /// `id` if the worktree's catalog lists it, else notFound(what: "checkpoint <id>").
    /// A Mac never names another worktree's checkpoint, or one deleted since it listed them.
    func listedCheckpoint(_ id: CheckpointID, in target: CheckpointWorktreeTarget) async throws -> CheckpointID {
        guard try await checkpoints.summaries(target: target).summaries.contains(where: { $0.id == id }) else {
            throw HostError.notFound(what: "checkpoint \(id)")
        }
        return id
    }

    func checkpointCatalog(in worktree: Worktree) async throws -> CheckpointCatalogSnapshot {
        try await checkpoints.summaries(target: requireCheckpointTarget(for: worktree))
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
            target: target, id: listedCheckpoint(id, in: target), coordination: checkpointCoordination(for: worktree),
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
            let coordination = checkpointCoordination(for: worktree)
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
        case .stage, .unstage, .discard, .commit, .push, .pull, .fetch, .stash, .applyStash, .popStash, .dropStash,
             .continueOperation, .skipOperation, .abortOperation, .useOurs, .useTheirs, .keepDeleted, .markResolved, .cherryPick,
             .revert, .editCommit:
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
