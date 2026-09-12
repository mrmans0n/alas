import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("Checkpoint coordination")
struct CheckpointCoordinationTests {
    @Test func unsavedRelativePathsIncludeLiveDirtyBuffersAndHotExitSnapshots() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("checkpoint-coordination-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "saved".write(to: root.appendingPathComponent("live.swift"), atomically: true, encoding: .utf8)

        let buffers = EditorBufferStore(rootOverride: root.appendingPathComponent("buffers"))
        let manager = TabsManager(bufferStore: buffers)
        let live = manager.openEditor(worktreeId: "worktree", relativePath: "live.swift", revealLine: nil, revealCharacter: nil)
        let buffer = manager.buffer(worktreeId: "worktree", tabId: live.id, worktreeRoot: root, relativePath: "live.swift")
        await buffer.awaitLoadForTesting()
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "dirty ")

        let restored = manager.openEditor(worktreeId: "worktree", relativePath: "restored.swift", revealLine: nil, revealCharacter: nil)
        try buffers.write(.init(relativePath: "restored.swift", content: "draft", originalText: "", originalMtime: .now, lineEnding: .lf), worktreeId: "worktree", tabId: restored.id)

        #expect(manager.unsavedRelativePaths(forWorktree: "worktree") == ["live.swift", "restored.swift"])
    }

    @Test func appStateCountsCenterGitMutationsInCheckpointCoordination() async throws {
        let state = AppState()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("checkpoint-center-mutation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let worktree = Worktree(
            id: "center-mutation-worktree",
            projectId: "project",
            name: "main",
            branch: "main",
            path: root,
            status: .clean,
            lastActivity: .now,
            lineageID: "lineage"
        )

        #expect(!state.checkpointCoordination(for: worktree, selectedPaths: []).otherGitMutationActive)
        state.beginCenterGitMutation(worktreeId: worktree.id)
        #expect(state.checkpointCoordination(for: worktree, selectedPaths: []).otherGitMutationActive)
        state.endCenterGitMutation(worktreeId: worktree.id)
        #expect(!state.checkpointCoordination(for: worktree, selectedPaths: []).otherGitMutationActive)
    }

    @Test func appStateDisablesEditorFileWritesDuringCheckpointRecoveryLease() async throws {
        let state = AppState()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("checkpoint-editor-lease-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let worktree = Worktree(
            id: "editor-lease-worktree",
            projectId: "project",
            name: "main",
            branch: "main",
            path: root,
            status: .clean,
            lastActivity: .now,
            lineageID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        )
        let pane = state.rightPaneStore.state(for: worktree, baseBranch: "main", comparisonMode: .auto)

        #expect(!state.checkpointFileWritesDisabled(worktreeId: worktree.id))
        pane.nonterminalCheckpointJournals = [
            CheckpointRestoreJournal(
                lineageID: try #require(worktree.lineageID),
                checkpointID: UUID(),
                recoveryCheckpointID: UUID(),
                phase: .prepared,
                stagingRoot: root.appendingPathComponent("staging").path,
                selectedPaths: ["File.swift"],
                expectedFingerprint: "fingerprint",
                expectedIndexChecksum: "checksum"
            )
        ]

        #expect(state.checkpointFileWritesDisabled(worktreeId: worktree.id))
    }
}
