import Foundation
import Testing
@testable import Alas

struct CheckpointRestorePreviewTests {
    @Test func previewUnionsPathsAndPreservesDeselectedStates() async throws {
        let repo = try await CheckpointTestRepository.make()
        defer { repo.remove() }
        for path in ["a.swift", "b.swift", "old.swift", "clean-at-capture.swift", "unselected.swift"] {
            try repo.write("original\n", to: path)
        }
        try await repo.commitAll("baseline")
        try repo.write("staged\n", to: "a.swift")
        try await repo.stage("a.swift")
        try repo.write("unstaged\n", to: "b.swift")
        try await repo.git(["mv", "old.swift", "new.swift"])
        let storeRoot = repo.root.appendingPathComponent(".git/checkpoint-store")
        let service = WorktreeCheckpointService(store: .init(root: storeRoot))
        let checkpoint = try await service.createManual(target: repo.target, label: "Saved")
        try repo.write("later\n", to: "clean-at-capture.swift")
        try await repo.stage("clean-at-capture.swift")
        try repo.write("keep\n", to: "unselected.swift")
        try await repo.stage("unselected.swift")
        try repo.write("keep disk\n", to: "unselected.swift")
        try repo.write("new\n", to: "later.txt")
        let before = try await repo.status()
        let preview = try await service.restorePreview(target: repo.target, id: checkpoint.id, coordination: .clear)
        #expect(preview.blocker == nil)
        #expect(preview.groups.map(\.primaryPath) == ["a.swift", "b.swift", "clean-at-capture.swift", "later.txt", "new.swift", "unselected.swift"])
        #expect(preview.selectedGroupIDs == Set(preview.groups.map(\.id)))
        let rename = try #require(preview.groups.first { $0.primaryPath == "new.swift" })
        #expect(rename.memberPaths == ["new.swift", "old.swift"])
        #expect(rename.renameSource == "old.swift")
        let clean = try #require(preview.groups.first { $0.primaryPath == "clean-at-capture.swift" })
        #expect(clean.effects.map(\.description) == ["index: staged modification -> clean", "working tree: modified -> checkpoint contents"])
        let later = try #require(preview.groups.first { $0.primaryPath == "later.txt" })
        #expect(later.effects.map(\.description).contains("untracked file will be removed"))
        let omitted = try #require(preview.groups.first { $0.primaryPath == "unselected.swift" })
        let selected = preview.selectedGroupIDs.subtracting([omitted.id])
        let selective = try await service.restorePreview(target: repo.target, id: checkpoint.id, coordination: .clear, selectedGroupIDs: selected)
        let preserved = try #require(selective.groups.first { $0.id == omitted.id })
        #expect(preserved.effects.map(\.description) == ["index: unchanged", "working tree: unchanged"])
        #expect(preserved.effects.allSatisfy { $0.before == $0.after })
        #expect(try await repo.status() == before)
        #expect(try await repo.index("unselected.swift") == Data("keep\n".utf8))
        #expect(try repo.disk("unselected.swift") == Data("keep disk\n".utf8))
    }

    @Test func blockersHaveDeterministicPriorityAndScope() {
        var blockers: Set<CheckpointRestoreBlocker> = [.corruptCheckpoint, .dirtyEditorBuffer, .activeSession, .otherGitMutation, .indexLock, .gitOperation, .changedHEAD, .lineageMismatch, .interruptedRestore]
        for expected: CheckpointRestoreBlocker in [.interruptedRestore, .lineageMismatch, .changedHEAD, .gitOperation, .indexLock, .otherGitMutation, .dirtyEditorBuffer, .activeSession, .corruptCheckpoint] {
            #expect(CheckpointRestoreBlocker.highestPriority(in: blockers) == expected)
            blockers.remove(expected)
        }
        #expect(CheckpointRestoreBlocker.remoteTarget.description == "Checkpoints are not available for remote worktrees yet.")
        #expect(CheckpointCoordinationSnapshot.scopeDescription(repositoryName: "Alas", workspaceName: "Development") == "Only Alas's selected worktree is in scope")
        #expect(CheckpointCoordinationSnapshot.clear.scopeDescription == "This repository only")
        #expect(CheckpointRestoreBlocker.allCases.map(\.description) == [
            "Checkpoints are not available for remote worktrees yet.",
            "An interrupted checkpoint restore needs recovery.",
            "The worktree identity no longer matches this checkpoint.",
            "HEAD has changed since this checkpoint was captured.",
            "Finish the current Git operation before restoring.",
            "The Git index is locked.",
            "Another Git mutation is active.",
            "Save or discard unsaved edits in selected files before restoring.",
            "Stop active terminal and agent sessions before restoring.",
            "The checkpoint is unavailable or has missing or corrupt data.",
        ])
    }

    @Test func dirtyBufferOnlyBlocksSelectedGroupAndSessionBlocksAll() async throws {
        let repo = try await CheckpointTestRepository.make()
        defer { repo.remove() }
        try repo.write("saved", to: "file.txt")
        let service = WorktreeCheckpointService(store: .init(root: repo.root.appendingPathComponent(".git/checkpoints")))
        let checkpoint = try await service.createManual(target: repo.target, label: "Saved")
        let coordination = CheckpointCoordinationSnapshot(dirtyEditorPaths: ["file.txt"], activeTerminalCount: 0, activeACPCount: 0, otherGitMutationActive: false, scopeDescription: "This repository only")
        #expect(try await service.restorePreview(target: repo.target, id: checkpoint.id, coordination: coordination).blocker == .dirtyEditorBuffer)
        #expect(try await service.restorePreview(target: repo.target, id: checkpoint.id, coordination: coordination, selectedGroupIDs: []).blocker == nil)
        let active = CheckpointCoordinationSnapshot(dirtyEditorPaths: [], activeTerminalCount: 1, activeACPCount: 0, otherGitMutationActive: false, scopeDescription: "This repository only")
        #expect(try await service.restorePreview(target: repo.target, id: checkpoint.id, coordination: active).blocker == .activeSession)
        try await repo.commitAll("advance HEAD")
        #expect(try await service.restorePreview(target: repo.target, id: checkpoint.id, coordination: active).blocker == .changedHEAD)
    }

    @Test func cleanCurrentPathRestoresSavedDeletionAndCleanCheckpointRemovesLaterChanges() async throws {
        let repo = try await CheckpointTestRepository.make()
        defer { repo.remove() }
        try repo.write("original", to: "file.txt")
        try await repo.commitAll("baseline")
        let service = WorktreeCheckpointService(store: .init(root: repo.root.appendingPathComponent(".git/checkpoints")))
        let clean = try await service.createManual(target: repo.target, label: "Clean")
        try await repo.git(["rm", "file.txt"])
        let deleted = try await service.createManual(target: repo.target, label: "Deleted")
        try await repo.git(["restore", "--source=HEAD", "--staged", "--worktree", "file.txt"])
        let preview = try await service.restorePreview(target: repo.target, id: deleted.id, coordination: .clear)
        #expect(preview.groups.count == 1)
        #expect(preview.groups.first?.effects.map(\.description) == ["index: clean -> staged deletion", "working tree: clean -> removed"])
        try repo.write("later", to: "file.txt")
        try repo.write("untracked", to: "new.txt")
        let cleanPreview = try await service.restorePreview(target: repo.target, id: clean.id, coordination: .clear)
        #expect(cleanPreview.groups.map(\.primaryPath) == ["file.txt", "new.txt"])
        #expect(cleanPreview.groups.first?.effects.last?.description == "working tree: modified -> checkpoint contents")
        #expect(cleanPreview.groups.last?.effects.last?.description == "untracked file will be removed")
    }

    @Test func realGitMarkersLocksAndInterruptedJournalBlockBeforeMutation() async throws {
        let repo = try await CheckpointTestRepository.make()
        defer { repo.remove() }
        let store = WorktreeCheckpointStore(root: repo.root.appendingPathComponent(".git/checkpoints"))
        let service = WorktreeCheckpointService(store: store)
        let checkpoint = try await service.createManual(target: repo.target, label: "Clean")
        try repo.write("locked", to: ".git/index.lock")
        #expect(try await service.restorePreview(target: repo.target, id: checkpoint.id, coordination: .clear).blocker == .indexLock)
        try repo.write("merging", to: ".git/MERGE_HEAD")
        #expect(try await service.restorePreview(target: repo.target, id: checkpoint.id, coordination: .clear).blocker == .gitOperation)
        try await store.writeJournal(.init(lineageID: repo.target.lineageID, checkpointID: checkpoint.id, recoveryCheckpointID: checkpoint.id,
                                          phase: .prepared, stagingRoot: "unused", selectedPaths: [], expectedFingerprint: "unused", expectedIndexChecksum: "unused"))
        #expect(try await service.restorePreview(target: repo.target, id: checkpoint.id, coordination: .clear).blocker == .interruptedRestore)
        #expect(try repo.disk(".git/index.lock") == Data("locked".utf8))
    }

    @Test func missingPayloadKeepsHigherPriorityBlockersAndDeselection() async throws {
        let repo = try await CheckpointTestRepository.make()
        defer { repo.remove() }
        try repo.write("saved", to: "file.txt")
        let root = repo.root.appendingPathComponent(".git/checkpoints")
        let service = WorktreeCheckpointService(store: .init(root: root))
        let checkpoint = try await service.createManual(target: repo.target, label: "Saved")
        let blob = root.appendingPathComponent(repo.target.lineageID).appendingPathComponent("blobs").appendingPathComponent(CheckpointBlobReference.make(for: Data("saved".utf8)).sha256)
        try FileManager.default.removeItem(at: blob)
        let coordination = CheckpointCoordinationSnapshot(dirtyEditorPaths: ["file.txt"], activeTerminalCount: 0, activeACPCount: 0, otherGitMutationActive: false, scopeDescription: "This repository only")
        #expect(try await service.restorePreview(target: repo.target, id: checkpoint.id, coordination: coordination).blocker == .dirtyEditorBuffer)
        #expect(try await service.restorePreview(target: repo.target, id: checkpoint.id, coordination: coordination, selectedGroupIDs: []).blocker == .corruptCheckpoint)
        try await repo.commitAll("advance")
        #expect(try await service.restorePreview(target: repo.target, id: checkpoint.id, coordination: .clear).blocker == .changedHEAD)
    }
}
