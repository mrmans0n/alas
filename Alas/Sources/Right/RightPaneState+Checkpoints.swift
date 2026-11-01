import AppKit
import Foundation
import Observation
import os

extension RightPaneState {
    var checkpointTarget: CheckpointWorktreeTarget? {
        if let provided = checkpointTargetProvider?() { return provided }
        guard !worktree.path.isRemoteAlasPath,
              let lineageID = worktree.lineageID ?? WorktreeService.existingLocalLineageID(forWorktreeAt: worktree.path)
        else { return nil }
        return .init(
            worktreeID: worktree.id,
            projectID: worktree.projectId,
            path: worktree.path,
            lineageID: lineageID,
            branch: worktree.branch,
            repositoryName: worktree.name,
            workspaceName: nil
        )
    }

    private func checkpointCoordination(selectedPaths: Set<String>) -> CheckpointCoordinationSnapshot {
        checkpointCoordinationProvider?(selectedPaths) ?? .clear
    }

    func loadCheckpointSnapshot(
        target: CheckpointWorktreeTarget?
    ) async -> Result<(CheckpointCatalogSnapshot, [CheckpointRestoreJournal]), CheckpointSnapshotLoadError>? {
        guard let target else { return nil }
        do {
            async let catalog = checkpointService.summaries(target: target)
            async let journals = checkpointService.nonterminalJournals(target: target)
            return .success(try await (catalog, journals))
        } catch {
            return .failure(.init(message: error.localizedDescription))
        }
    }

    func publishCheckpointSnapshot(
        _ result: Result<(CheckpointCatalogSnapshot, [CheckpointRestoreJournal]), CheckpointSnapshotLoadError>?,
        snapshotGeneration: Int,
        checkpointGeneration: UInt
    ) {
        guard snapshotGeneration == snapshotInvalidationGeneration,
              checkpointGeneration == checkpointLoadGeneration
        else { return }
        guard let result else {
            checkpointSummaries = []
            checkpointStorageUsage = 0
            nonterminalCheckpointJournals = []
            checkpointJournalDiscoverySucceeded = worktree.path.isRemoteAlasPath || isFolder
            checkpointLoadError = worktree.path.isRemoteAlasPath ? CheckpointRestoreBlocker.remoteTarget.description : nil
            return
        }
        switch result {
        case let .success((catalog, journals)):
            checkpointSummaries = catalog.summaries
            checkpointStorageUsage = catalog.byteCount
            nonterminalCheckpointJournals = journals
            checkpointJournalDiscoverySucceeded = true
            checkpointLoadError = nil
            let availableCheckpointIDs = Set(catalog.summaries.filter { $0.unavailableReason == nil }.map(\.id))
            expandedCheckpointIDs.formIntersection(availableCheckpointIDs)
            checkpointFileListPageIndices = checkpointFileListPageIndices.filter { id, _ in
                availableCheckpointIDs.contains(id)
            }
            checkpointManifests = checkpointManifests.filter { id, _ in
                availableCheckpointIDs.contains(id)
            }
        case let .failure(error):
            checkpointJournalDiscoverySucceeded = false
            checkpointLoadError = error.message
        }
    }

    func refreshCheckpoints() async {
        checkpointLoadGeneration &+= 1
        let checkpointGeneration = checkpointLoadGeneration
        let snapshotGeneration = snapshotInvalidationGeneration
        let result = await loadCheckpointSnapshot(target: checkpointTarget)
        publishCheckpointSnapshot(
            result,
            snapshotGeneration: snapshotGeneration,
            checkpointGeneration: checkpointGeneration
        )
    }

    func checkpointMutationsDisabledAfterJournalRevalidation() async -> Bool {
        guard checkpointOperationInFlight == nil else { return true }
        guard let target = checkpointTarget else {
            nonterminalCheckpointJournals = []
            checkpointJournalDiscoverySucceeded = worktree.path.isRemoteAlasPath || isFolder
            checkpointLoadError = worktree.path.isRemoteAlasPath ? CheckpointRestoreBlocker.remoteTarget.description : nil
            return checkpointMutationsDisabled
        }
        do {
            nonterminalCheckpointJournals = try await checkpointService.nonterminalJournals(target: target)
            checkpointJournalDiscoverySucceeded = true
            checkpointLoadError = nil
        } catch {
            checkpointJournalDiscoverySucceeded = false
            checkpointLoadError = error.localizedDescription
        }
        return checkpointMutationsDisabled
    }

    func checkpointRestoreBlocksWritersAfterJournalRevalidation() async -> Bool {
        guard checkpointOperationInFlight == nil else { return true }
        guard let target = checkpointTarget else {
            nonterminalCheckpointJournals = []
            return false
        }
        do {
            nonterminalCheckpointJournals = try await checkpointService.nonterminalJournals(target: target)
            checkpointJournalDiscoverySucceeded = true
            checkpointLoadError = nil
        } catch {
            checkpointJournalDiscoverySucceeded = false
            checkpointLoadError = error.localizedDescription
        }
        return checkpointRestoreBlocksWriters
    }

    func checkpointMutationAllowedAfterJournalRevalidation() async -> Bool {
        !(await checkpointMutationsDisabledAfterJournalRevalidation())
    }

    func requireCheckpointMutationAllowedAfterJournalRevalidation() async throws {
        guard await checkpointMutationAllowedAfterJournalRevalidation() else {
            throw GGMutationError.operationInFlight
        }
    }

    func requestCheckpointCreation() {
        guard !checkpointMutationsDisabled else { return }
        lastCheckpointStatus = nil
        pendingCheckpointCreation = .init()
    }

    func cancelCheckpointCreation() {
        pendingCheckpointCreation = nil
    }

    @discardableResult
    func createCheckpoint(label: String) async -> WorktreeCheckpointManifest? {
        let normalized = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            lastCheckpointError = "Enter a checkpoint name."
            return nil
        }
        guard let target = checkpointTarget else {
            lastCheckpointError = CheckpointRestoreBlocker.remoteTarget.description
            return nil
        }
        guard checkpointOperationInFlight == nil else { return nil }
        checkpointOperationInFlight = .capture
        lastCheckpointError = nil
        lastCheckpointStatus = nil
        watcher.stop()
        markSnapshotUnknown()
        defer {
            watcher.start()
            checkpointOperationInFlight = nil
        }
        do {
            let summary = try await checkpointService.createManual(target: target, label: normalized)
            let manifest = try await checkpointService.manifest(target: target, id: summary.id)
            checkpointManifests[summary.id] = manifest
            await refresh()
            return manifest
        } catch {
            lastCheckpointError = error.localizedDescription
            await refresh()
            return nil
        }
    }

    func toggleCheckpointExpanded(_ id: CheckpointID) {
        if expandedCheckpointIDs.contains(id) {
            expandedCheckpointIDs.remove(id)
            checkpointFileListPageIndices[id] = nil
        } else {
            expandedCheckpointIDs.insert(id)
            loadCheckpointManifest(id: id)
        }
    }

    /// Current 0-based page of an expanded checkpoint's file list.
    func checkpointFileListPage(for id: CheckpointID) -> Int {
        checkpointFileListPageIndices[id] ?? 0
    }

    /// Moves to the next page, clamped to the manifest's last page so it
    /// never advances past the end.
    func advanceCheckpointFileListPage(_ id: CheckpointID) {
        guard let totalGroups = checkpointManifests[id]?.groups.count, totalGroups > 0 else { return }
        let lastPage = (totalGroups - 1) / CheckpointPresentation.maxInlineFileGroups
        let next = min(checkpointFileListPage(for: id) + 1, lastPage)
        checkpointFileListPageIndices[id] = next == 0 ? nil : next
    }

    /// Moves to the previous page, clamped at the first.
    func retreatCheckpointFileListPage(_ id: CheckpointID) {
        let previous = max(0, checkpointFileListPage(for: id) - 1)
        checkpointFileListPageIndices[id] = previous == 0 ? nil : previous
    }

    func loadCheckpointManifest(id: CheckpointID) {
        guard checkpointManifests[id] == nil,
              !loadingCheckpointManifestIDs.contains(id),
              let target = checkpointTarget
        else { return }
        loadingCheckpointManifestIDs.insert(id)
        checkpointManifestErrors[id] = nil
        Task { @MainActor in
            defer { self.loadingCheckpointManifestIDs.remove(id) }
            do {
                self.checkpointManifests[id] = try await self.checkpointService.manifest(target: target, id: id)
            } catch {
                self.checkpointManifestErrors[id] = error.localizedDescription
            }
        }
    }

    func previewCheckpointRestore(id: CheckpointID, selectedGroupIDs: Set<UUID>? = nil) async {
        guard let target = checkpointTarget else {
            lastCheckpointError = CheckpointRestoreBlocker.remoteTarget.description
            return
        }
        guard !hasInterruptedCheckpointRestore else {
            lastCheckpointError = CheckpointRestoreBlocker.interruptedRestore.description
            return
        }
        guard checkpointOperationInFlight == nil else {
            lastCheckpointError = "Another checkpoint operation is in progress."
            return
        }
        checkpointOperationInFlight = .preview
        lastCheckpointError = nil
        lastCheckpointStatus = nil
        defer { checkpointOperationInFlight = nil }
        do {
            // The service resolves current-only paths as well as checkpoint paths.
            // Probe first, then pass the selected concrete group paths into the
            // fresh coordination snapshot used for the preview that is shown.
            let resolved = try await checkpointService.restorePreview(
                target: target,
                id: id,
                coordination: .clear,
                selectedGroupIDs: selectedGroupIDs
            )
            let selected = selectedGroupIDs ?? resolved.selectedGroupIDs
            let selectedPaths = Set(resolved.groups
                .filter { selected.contains($0.id) }
                .flatMap(\.memberPaths))
            checkpointRestorePreview = try await checkpointService.restorePreview(
                target: target,
                id: id,
                coordination: checkpointCoordination(selectedPaths: selectedPaths),
                selectedGroupIDs: selected
            )
        } catch {
            lastCheckpointError = CheckpointRestoreErrorPresentation.message(error)
        }
    }

    func restoreCheckpoint(preview: CheckpointRestorePreview, selectedGroupIDs: Set<UUID>) async {
        guard let target = checkpointTarget else {
            lastCheckpointError = CheckpointRestoreBlocker.remoteTarget.description
            return
        }
        guard !hasInterruptedCheckpointRestore else {
            lastCheckpointError = CheckpointRestoreBlocker.interruptedRestore.description
            return
        }
        guard checkpointOperationInFlight == nil else { return }
        checkpointOperationInFlight = .restore
        lastCheckpointError = nil
        lastCheckpointStatus = nil
        let selectedPaths = Set(preview.groups.filter { selectedGroupIDs.contains($0.id) }.flatMap(\.memberPaths))
        // Coordinate before clearing any local mutation state. In particular,
        // an active stash or discard must remain visible to the service.
        let coordination = checkpointCoordination(selectedPaths: selectedPaths)
        watcher.stop()
        markSnapshotUnknown()
        defer {
            watcher.start()
            checkpointOperationInFlight = nil
        }
        do {
            _ = try await checkpointService.restore(
                target: target,
                preview: preview,
                selectedGroupIDs: selectedGroupIDs,
                coordination: coordination
            )
            checkpointRestorePreview = nil
            await refresh()
        } catch {
            lastCheckpointError = CheckpointRestoreErrorPresentation.message(error)
            await refresh()
        }
    }

    func deleteCheckpoint(id: CheckpointID) async {
        guard let target = checkpointTarget else {
            lastCheckpointError = CheckpointRestoreBlocker.remoteTarget.description
            return
        }
        guard checkpointOperationInFlight == nil else { return }
        checkpointOperationInFlight = .delete
        lastCheckpointError = nil
        lastCheckpointStatus = nil
        watcher.stop()
        markSnapshotUnknown()
        defer {
            watcher.start()
            checkpointOperationInFlight = nil
        }
        do {
            let catalog = try await checkpointService.delete(target: target, id: id)
            checkpointSummaries = catalog.summaries
            checkpointStorageUsage = catalog.byteCount
            checkpointManifests[id] = nil
            expandedCheckpointIDs.remove(id)
            checkpointFileListPageIndices[id] = nil
            pendingCheckpointDeletion = nil
            await refresh()
        } catch {
            lastCheckpointError = CheckpointRestoreErrorPresentation.message(error)
            await refresh()
        }
    }

    func recoverCheckpointRestore(operationID: UUID) async {
        guard let target = checkpointTarget else {
            lastCheckpointError = CheckpointRestoreBlocker.remoteTarget.description
            return
        }
        guard checkpointOperationInFlight == nil else { return }
        checkpointOperationInFlight = .recovery
        lastCheckpointError = nil
        lastCheckpointStatus = nil
        defer { checkpointOperationInFlight = nil }
        do {
            let journals = try await checkpointService.nonterminalJournals(target: target)
            guard let journal = journals.first(where: { $0.id == operationID }) else {
                lastCheckpointError = "The interrupted checkpoint restore is no longer available."
                return
            }
            let coordination = checkpointCoordination(selectedPaths: Set(journal.selectedPaths))
            watcher.stop()
            markSnapshotUnknown()
            defer {
                watcher.start()
            }
            _ = try await checkpointService.recoverInterruptedRestore(
                target: target,
                operationID: operationID,
                coordination: coordination
            )
            await refresh()
            lastCheckpointStatus = "Recovered pre-restore state from interrupted checkpoint restore."
        } catch {
            lastCheckpointError = error.localizedDescription
            await refresh()
        }
    }
}
