import Foundation
import Testing
@testable import Alas

private enum RecordingCheckpointServiceError: Error { case unsupported }

private actor RecordingCheckpointService: WorktreeCheckpointServicing {
    private let target: CheckpointWorktreeTarget
    private let summary: WorktreeCheckpointSummary
    private let manifestValue: WorktreeCheckpointManifest
    private var created = false
    private var callCount = 0

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
        return []
    }

    func createManual(target: CheckpointWorktreeTarget, label: String) async throws -> WorktreeCheckpointSummary {
        callCount += 1
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
        throw RecordingCheckpointServiceError.unsupported
    }

    func diffContent(target: CheckpointWorktreeTarget, id: CheckpointID, path: String) async -> CheckpointDiffContent {
        callCount += 1
        return .unavailable("not used")
    }

    func restore(target: CheckpointWorktreeTarget, preview: CheckpointRestorePreview, selectedGroupIDs: Set<UUID>,
                 coordination: CheckpointCoordinationSnapshot) async throws -> CheckpointRestoreResult {
        callCount += 1
        throw RecordingCheckpointServiceError.unsupported
    }

    func recoverInterruptedRestore(target: CheckpointWorktreeTarget, operationID: UUID,
                                   coordination: CheckpointCoordinationSnapshot) async throws -> CheckpointRestoreResult {
        callCount += 1
        throw RecordingCheckpointServiceError.unsupported
    }

    func calls() -> Int { callCount }
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
}
