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

    @Test func appStateBlocksDirtyBuffersBelowSelectedCheckpointPaths() async throws {
        let state = AppState()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("checkpoint-dirty-descendant-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("config", isDirectory: true), withIntermediateDirectories: true)
        try "saved".write(to: root.appendingPathComponent("config/local.json"), atomically: true, encoding: .utf8)
        let worktree = Worktree(
            id: "dirty-descendant-worktree",
            projectId: "project",
            name: "main",
            branch: "main",
            path: root,
            status: .clean,
            lastActivity: .now,
            lineageID: "lineage"
        )
        let tab = state.tabs.openEditor(worktreeId: worktree.id, relativePath: "config/local.json", revealLine: nil, revealCharacter: nil)
        let buffer = state.tabs.buffer(worktreeId: worktree.id, tabId: tab.id, worktreeRoot: root, relativePath: "config/local.json")
        await buffer.awaitLoadForTesting()
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "dirty ")

        let coordination = state.checkpointCoordination(for: worktree, selectedPaths: ["config"])

        #expect(coordination.dirtyEditorPaths == ["config/local.json"])
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

    @Test func appStateTreatsMissingCheckpointPaneStateAsRecoveryUnknown() async throws {
        let state = AppState()

        #expect(state.checkpointFileWritesDisabled(worktreeId: "uncached-worktree"))
        #expect(state.checkpointTerminalAdmissionDisabled(worktreeId: "uncached-worktree"))
        #expect(DraftCommitTabView.checkpointLeaseActiveForRecovery(rightPane: nil))
    }

    @Test func appStateDiscoversCheckpointRecoveryBeforeBlockingKnownWorktreeWrites() async throws {
        let repo = try await CheckpointTestRepository.make()
        defer { repo.remove() }
        let state = AppState()
        let project = try await state.projectsManager.addProject(path: repo.root, displayName: "test", color: "#000000")
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        let worktree = try #require(state.projectsManager.worktrees(projectId: project.id).first)

        #expect(state.checkpointFileWritesDisabled(worktreeId: worktree.id))
        #expect(await !state.checkpointFileWritesDisabledAfterDiscovery(worktreeId: worktree.id))
        #expect(await !state.checkpointTerminalAdmissionDisabledAfterDiscovery(worktreeId: worktree.id))
    }

    @Test func appStateBlocksACPAdmissionDuringCheckpointRecoveryLease() async throws {
        let repo = try await CheckpointTestRepository.make()
        defer { repo.remove() }
        let state = AppState()
        let project = try await state.projectsManager.addProject(path: repo.root, displayName: "test", color: "#000000")
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        let worktree = try #require(state.projectsManager.worktrees(projectId: project.id).first)
        let lineageID = try #require(worktree.lineageID)
        let store = WorktreeCheckpointStore()
        let operationID = UUID()
        let journal = CheckpointRestoreJournal(
            id: operationID,
            lineageID: lineageID,
            checkpointID: UUID(),
            recoveryCheckpointID: UUID(),
            phase: .prepared,
            stagingRoot: worktree.path.appendingPathComponent(".alas-checkpoint-restore-\(operationID.uuidString.lowercased())").path,
            selectedPaths: ["File.swift"],
            expectedFingerprint: "fingerprint",
            expectedIndexChecksum: "checksum"
        )
        try await store.writeJournal(journal)
        defer { try? FileManager.default.removeItem(at: Paths.checkpointsRoot.appendingPathComponent(lineageID, isDirectory: true)) }

        #expect(await state.checkpointACPAdmissionDisabledAfterDiscovery(worktreeId: worktree.id))
        await #expect(throws: (any Error).self) {
            try await state.startACPSession(
                worktree: worktree,
                sessionID: UUID().uuidString,
                agentID: "test-agent",
                promptID: UUID(),
                prompt: "hello"
            )
        }
    }
}
