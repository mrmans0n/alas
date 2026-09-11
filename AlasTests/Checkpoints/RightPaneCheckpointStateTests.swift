import Foundation
import Testing
@testable import Alas

private enum RecordingCheckpointServiceError: Error { case unsupported }

private actor RecordingCheckpointService: WorktreeCheckpointServicing {
    private let target: CheckpointWorktreeTarget
    private let summary: WorktreeCheckpointSummary
    private let manifestValue: WorktreeCheckpointManifest
    private let restoreGroupID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private var created = false
    private var callCount = 0
    private var journals: [CheckpointRestoreJournal] = []
    private var previewCoordinations: [CheckpointCoordinationSnapshot] = []
    private var restoreCoordinations: [CheckpointCoordinationSnapshot] = []
    private var recoveryCoordinations: [CheckpointCoordinationSnapshot] = []
    private var createShouldFail = false

    init(target: CheckpointWorktreeTarget) throws {
        self.target = target
        summary = .init(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            kind: .manual,
            label: "Before edit",
            createdAt: .now,
            byteCount: 12,
            stagedFileCount: 1,
            unstagedFileCount: 0,
            untrackedFileCount: 0,
            unavailableReason: nil
        )
        manifestValue = try .init(
            id: summary.id,
            kind: .manual,
            label: summary.label,
            byteCount: 12,
            lineageID: target.lineageID,
            capturedPath: target.path.path,
            repositoryName: target.repositoryName,
            branch: target.branch,
            headOID: String(repeating: "a", count: 40),
            exclusions: [.init(relativePath: ".env", reason: .likelySecret)],
            groups: [],
            paths: []
        )
    }

    func summaries(target: CheckpointWorktreeTarget) async throws -> CheckpointCatalogSnapshot {
        callCount += 1
        return .init(lineageID: target.lineageID, summaries: created ? [summary] : [], byteCount: created ? 12 : 0)
    }

    func nonterminalJournals(target: CheckpointWorktreeTarget) async throws -> [CheckpointRestoreJournal] {
        callCount += 1
        return journals
    }

    func createManual(target: CheckpointWorktreeTarget, label: String) async throws -> WorktreeCheckpointSummary {
        callCount += 1
        guard !createShouldFail else { throw RecordingCheckpointServiceError.unsupported }
        guard label == "Before edit" else { throw RecordingCheckpointServiceError.unsupported }
        created = true
        return summary
    }

    func manifest(target: CheckpointWorktreeTarget, id: CheckpointID) async throws -> WorktreeCheckpointManifest {
        callCount += 1
        guard id == summary.id else { throw RecordingCheckpointServiceError.unsupported }
        return manifestValue
    }

    func delete(target: CheckpointWorktreeTarget, id: CheckpointID) async throws -> CheckpointCatalogSnapshot {
        callCount += 1
        throw RecordingCheckpointServiceError.unsupported
    }

    func restorePreview(target: CheckpointWorktreeTarget, id: CheckpointID, coordination: CheckpointCoordinationSnapshot,
                        selectedGroupIDs: Set<UUID>?) async throws -> CheckpointRestorePreview {
        callCount += 1
        previewCoordinations.append(coordination)
        let selected = selectedGroupIDs ?? [restoreGroupID]
        return .init(
            id: UUID(),
            checkpointID: id,
            checkpointLabel: summary.label,
            currentFingerprint: "current",
            groups: [.init(
                id: restoreGroupID,
                primaryPath: "selected.swift",
                memberPaths: ["related.swift", "selected.swift"],
                renameSource: "related.swift",
                effects: []
            )],
            blocker: coordination.dirtyEditorPaths.isEmpty ? nil : .dirtyEditorBuffer,
            scopeDescription: coordination.scopeDescription,
            selectedGroupIDs: selected
        )
    }

    func diffContent(target: CheckpointWorktreeTarget, id: CheckpointID, path: String) async -> CheckpointDiffContent {
        callCount += 1
        return .unavailable("not used")
    }

    func restore(target: CheckpointWorktreeTarget, preview: CheckpointRestorePreview, selectedGroupIDs: Set<UUID>,
                 coordination: CheckpointCoordinationSnapshot) async throws -> CheckpointRestoreResult {
        callCount += 1
        restoreCoordinations.append(coordination)
        return .init(recoveryCheckpointID: summary.id, restoredPaths: [])
    }

    func recoverInterruptedRestore(target: CheckpointWorktreeTarget, operationID: UUID,
                                   coordination: CheckpointCoordinationSnapshot) async throws -> CheckpointRestoreResult {
        callCount += 1
        recoveryCoordinations.append(coordination)
        journals.removeAll { $0.id == operationID }
        return .init(recoveryCheckpointID: summary.id, restoredPaths: [])
    }

    func calls() -> Int { callCount }
    func failNextCreate() { createShouldFail = true }
    func installJournal(_ journal: CheckpointRestoreJournal) { journals = [journal] }
    func previewCoordinationHistory() -> [CheckpointCoordinationSnapshot] { previewCoordinations }
    func restoreCoordinationHistory() -> [CheckpointCoordinationSnapshot] { restoreCoordinations }
    func recoveryCoordinationHistory() -> [CheckpointCoordinationSnapshot] { recoveryCoordinations }
}

@MainActor
@Suite("Right pane checkpoint state")
struct RightPaneCheckpointStateTests {
    @Test func createRejectsBlankLabelsAndPublishesCaptureOnlyAfterTheServiceSucceeds() async throws {
        let repository = try await CheckpointTestRepository.make()
        defer { repository.remove() }
        let service = try RecordingCheckpointService(target: repository.target)
        let worktree = Worktree(
            id: repository.target.worktreeID,
            projectId: repository.target.projectID,
            name: repository.target.repositoryName,
            branch: repository.target.branch,
            path: repository.root,
            status: .clean,
            lastActivity: .now,
            lineageID: repository.target.lineageID
        )
        let state = RightPaneState(worktree: worktree, baseBranch: "main", checkpointService: service)
        state.checkpointTargetProvider = { repository.target }

        await state.createCheckpoint(label: "   ")
        #expect(state.lastCheckpointError == "Enter a checkpoint name.")
        #expect(state.checkpointSummaries.isEmpty)

        await state.createCheckpoint(label: "Before edit")
        #expect(state.checkpointSummaries.map(\.label) == ["Before edit"])
        #expect(state.checkpointManifests.values.flatMap(\.exclusions).map(\.relativePath) == [".env"])
    }

    @Test func remoteWorktreesExposeTheApprovedReasonWithoutCallingTheService() async throws {
        let repository = try await CheckpointTestRepository.make()
        defer { repository.remove() }
        let service = try RecordingCheckpointService(target: repository.target)
        RemoteHostRegistry.shared.register(root: repository.root.path, host: "remote.example")
        defer { RemoteHostRegistry.shared.unregister(root: repository.root.path) }
        let remote = Worktree(
            id: "remote",
            projectId: "project",
            name: "Remote",
            branch: "main",
            path: repository.root,
            status: .clean,
            lastActivity: .now
        )
        let state = RightPaneState(worktree: remote, baseBranch: "main", checkpointService: service)

        await state.createCheckpoint(label: "Before edit")

        #expect(state.lastCheckpointError == "Checkpoints are not available for remote worktrees yet.")
        #expect(state.checkpointSummaries.isEmpty)
        let calls = await service.calls()
        #expect(calls == 0)
    }

    @Test func previewRestoreAndRecoveryCoordinateUsingConcreteAffectedPaths() async throws {
        let repository = try await CheckpointTestRepository.make()
        defer { repository.remove() }
        let service = try RecordingCheckpointService(target: repository.target)
        let state = makeState(repository: repository, service: service)
        var coordinatedPaths: [Set<String>] = []
        state.checkpointCoordinationProvider = { paths in
            coordinatedPaths.append(paths)
            return .init(
                dirtyEditorPaths: paths,
                activeTerminalCount: 0,
                activeACPCount: 0,
                otherGitMutationActive: false,
                scopeDescription: "This repository only"
            )
        }

        let checkpointID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        await state.previewCheckpointRestore(id: checkpointID)
        let preview = try #require(state.checkpointRestorePreview)
        #expect(coordinatedPaths.last == Set(["related.swift", "selected.swift"]))
        #expect((await service.previewCoordinationHistory()).last?.dirtyEditorPaths == Set(["related.swift", "selected.swift"]))

        await state.restoreCheckpoint(preview: preview, selectedGroupIDs: preview.selectedGroupIDs)
        #expect((await service.restoreCoordinationHistory()).last?.dirtyEditorPaths == Set(["related.swift", "selected.swift"]))

        let operationID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        await service.installJournal(.init(
            id: operationID,
            lineageID: repository.target.lineageID,
            checkpointID: checkpointID,
            recoveryCheckpointID: checkpointID,
            phase: .applyingFiles,
            stagingRoot: "staging",
            selectedPaths: ["journal-a.swift", "journal-b.swift"],
            expectedFingerprint: "fingerprint",
            expectedIndexChecksum: "checksum"
        ))
        await state.recoverCheckpointRestore(operationID: operationID)
        #expect((await service.recoveryCoordinationHistory()).last?.dirtyEditorPaths == Set(["journal-a.swift", "journal-b.swift"]))
    }

    @Test func failedCheckpointDeleteRefreshesTheChangesSnapshot() async throws {
        let repository = try await CheckpointTestRepository.make()
        defer { repository.remove() }
        let service = try RecordingCheckpointService(target: repository.target)
        let state = makeState(repository: repository, service: service)
        await state.refresh()
        #expect(state.hasLoadedSnapshot)

        await state.deleteCheckpoint(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)

        #expect(state.hasLoadedSnapshot)
        #expect(state.lastCheckpointError != nil)
    }

    @Test func failedCheckpointCaptureRefreshesTheChangesSnapshot() async throws {
        let repository = try await CheckpointTestRepository.make()
        defer { repository.remove() }
        let service = try RecordingCheckpointService(target: repository.target)
        let state = makeState(repository: repository, service: service)
        await state.refresh()
        #expect(state.hasLoadedSnapshot)

        await service.failNextCreate()
        await state.createCheckpoint(label: "Before edit")

        #expect(state.hasLoadedSnapshot)
        #expect(state.lastCheckpointError != nil)
        #expect(state.checkpointSummaries.isEmpty)
    }

    @Test func interruptedRestoreDisablesNewCheckpointMutationsButAllowsRecovery() async throws {
        let repository = try await CheckpointTestRepository.make()
        defer { repository.remove() }
        let service = try RecordingCheckpointService(target: repository.target)
        let state = makeState(repository: repository, service: service)
        state.checkpointCoordinationProvider = { paths in
            .init(
                dirtyEditorPaths: paths,
                activeTerminalCount: 0,
                activeACPCount: 0,
                otherGitMutationActive: false,
                scopeDescription: "This repository only"
            )
        }
        let operationID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let checkpointID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        await service.installJournal(.init(
            id: operationID,
            lineageID: repository.target.lineageID,
            checkpointID: checkpointID,
            recoveryCheckpointID: checkpointID,
            phase: .prepared,
            stagingRoot: "staging",
            selectedPaths: ["selected.swift"],
            expectedFingerprint: "fingerprint",
            expectedIndexChecksum: "checksum"
        ))

        await state.refresh()
        #expect(state.hasInterruptedCheckpointRestore)
        #expect(state.checkpointMutationsDisabled)

        state.requestCheckpointCreation()
        #expect(state.pendingCheckpointCreation == nil)

        await state.previewCheckpointRestore(id: checkpointID)
        #expect(state.lastCheckpointError == CheckpointRestoreBlocker.interruptedRestore.description)

        await state.recoverCheckpointRestore(operationID: operationID)
        #expect((await service.recoveryCoordinationHistory()).last?.dirtyEditorPaths == Set(["selected.swift"]))
        #expect(state.lastCheckpointStatus == "Recovered pre-restore state from interrupted checkpoint restore.")
    }

    private func makeState(repository: CheckpointTestRepository, service: RecordingCheckpointService) -> RightPaneState {
        let worktree = Worktree(
            id: repository.target.worktreeID,
            projectId: repository.target.projectID,
            name: repository.target.repositoryName,
            branch: repository.target.branch,
            path: repository.root,
            status: .clean,
            lastActivity: .now,
            lineageID: repository.target.lineageID
        )
        let state = RightPaneState(worktree: worktree, baseBranch: "main", checkpointService: service)
        state.checkpointTargetProvider = { repository.target }
        return state
    }
}
