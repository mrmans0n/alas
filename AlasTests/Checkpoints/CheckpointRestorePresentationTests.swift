import AppKit
import Testing
import SwiftUI
@testable import Alas

@MainActor
@Suite("Checkpoint restore presentation")
struct CheckpointRestorePresentationTests {
    @Test func restoreSheetStartsSelectedAndCountsPhysicalPathsSeparatelyFromGroups() throws {
        let renameID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let directID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        let preview = makePreview(groups: [
            makeGroup(id: renameID, primaryPath: "New.swift", memberPaths: ["Old.swift", "New.swift"], renameSource: "Old.swift"),
            makeGroup(id: directID, primaryPath: "Image.png", memberPaths: ["Image.png"])
        ])
        let model = RestoreCheckpointSheetModel(preview: preview)

        #expect(model.selectedGroupIDs == Set([renameID, directID]))
        #expect(RestoreCheckpointSheetModel.selectedPathCount(preview: preview, selectedGroupIDs: model.selectedGroupIDs) == 3)
        #expect(RestoreCheckpointSheetModel.confirmationSummary(preview: preview, selectedGroupIDs: model.selectedGroupIDs) == "2 file groups, 3 physical paths")

        model.toggle(preview.groups[0])

        #expect(model.selectedGroupIDs == Set([directID]))
        #expect(RestoreCheckpointSheetModel.selectedPathCount(preview: preview, selectedGroupIDs: model.selectedGroupIDs) == 1)
        #expect(RestoreCheckpointSheetModel.title(for: preview.groups[0]) == "Old.swift → New.swift")
    }

    @Test func zeroSelectionDisablesRestoreAndRefreshesCanKeepCurrentSelection() throws {
        let groupID = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
        let preview = makePreview(groups: [makeGroup(id: groupID, primaryPath: "File.swift")])
        let model = RestoreCheckpointSheetModel(preview: preview)

        model.toggle(preview.groups[0])

        #expect(model.selectedGroupIDs.isEmpty)
        #expect(!RestoreCheckpointSheetModel.canRestore(preview: preview, selectedGroupIDs: model.selectedGroupIDs, inFlight: false))
        #expect(!RestoreCheckpointSheetModel.canRestore(preview: preview, selectedGroupIDs: [groupID], inFlight: true))
        #expect(RestoreCheckpointSheetModel.canRestore(preview: preview, selectedGroupIDs: [groupID], inFlight: false))
    }

    @Test func effectLinesKeepIndexAndWorkingTreeEffectsVisibleForTheSamePath() throws {
        let blob = CheckpointBlobReference(sha256: String(repeating: "a", count: 64), byteCount: 5)
        let before = CheckpointFileState.regular(blob: blob, executable: false)
        let after = CheckpointFileState.absent
        let group = makeGroup(
            primaryPath: "File.swift",
            effects: [
                .init(relativePath: "File.swift", layer: .index, head: before, before: before, after: after, removesUntrackedFile: false),
                .init(relativePath: "File.swift", layer: .worktree, head: before, before: before, after: after, removesUntrackedFile: false)
            ]
        )

        let lines = RestoreCheckpointSheetModel.effectLines(for: group)

        #expect(lines.contains("File.swift · index: clean -> staged deletion"))
        #expect(lines.contains("File.swift · working tree: clean -> removed"))
    }

    @Test func blockerMessagesCoverEveryRestoreBlocker() {
        for blocker in CheckpointRestoreBlocker.allCases {
            #expect(RestoreCheckpointSheetModel.blockerMessage(blocker) == blocker.description)
        }
        #expect(RestoreCheckpointSheetModel.blockerMessage(nil) == nil)
        #expect(CheckpointRestoreBlocker.changedHEAD.description == "HEAD has changed since this checkpoint was captured.")
        #expect(CheckpointRestoreBlocker.lineageMismatch.description == "The worktree identity no longer matches this checkpoint.")
        #expect(CheckpointRestoreBlocker.activeSession.description == "Stop active terminal and agent sessions before restoring.")
        #expect(CheckpointRestoreBlocker.dirtyEditorBuffer.description == "Save or discard unsaved edits in selected files before restoring.")
        #expect(CheckpointRestoreBlocker.gitOperation.description == "Finish the current Git operation before restoring.")
        #expect(CheckpointRestoreBlocker.indexLock.description == "The Git index is locked.")
        #expect(CheckpointRestoreErrorPresentation.message(CheckpointRestoreError.stalePreview) == "Refresh the restore preview before trying again.")
        #expect(CheckpointRestoreBlocker.corruptCheckpoint.description == "The checkpoint is unavailable or has missing or corrupt data.")
    }

    @Test func recoveryCardNamesPhasePathsAndDoesNotRecoverOnAppear() throws {
        let operationID = UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!
        let journal = CheckpointRestoreJournal(
            id: operationID,
            lineageID: "lineage",
            checkpointID: UUID(),
            recoveryCheckpointID: UUID(),
            phase: .applyingFiles,
            stagingRoot: "/tmp/staging",
            selectedPaths: ["b.swift", "a.swift"],
            expectedFingerprint: "fingerprint",
            expectedIndexChecksum: "checksum"
        )
        var recovered = false

        _ = NSHostingView(rootView: CheckpointRecoveryCard(
            journal: journal,
            inFlight: false,
            error: nil,
            status: nil,
            onRecover: { recovered = true }
        ))

        #expect(CheckpointRecoveryPresentation.operationSuffix(operationID) == "dddddddd")
        #expect(CheckpointRecoveryPresentation.phase(.applyingFiles) == "Applying files")
        #expect(CheckpointRecoveryPresentation.affectedPathsSummary(journal.selectedPaths) == "2 paths")
        #expect(CheckpointRecoveryPresentation.affectedPathsText(journal.selectedPaths) == "a.swift\nb.swift")
        #expect(CheckpointRecoveryPresentation.recoverButtonTitle == "Recover pre-restore state")
        #expect(recovered == false)
    }

    private func makePreview(
        groups: [CheckpointRestoreGroup],
        blocker: CheckpointRestoreBlocker? = nil,
        selectedGroupIDs: Set<UUID>? = nil
    ) -> CheckpointRestorePreview {
        .init(
            id: UUID(),
            checkpointID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            checkpointLabel: "Before edit",
            currentFingerprint: "fingerprint",
            groups: groups,
            blocker: blocker,
            scopeDescription: "This repository only",
            selectedGroupIDs: selectedGroupIDs ?? Set(groups.map(\.id))
        )
    }

    private func makeGroup(
        id: UUID = UUID(),
        primaryPath: String,
        memberPaths: [String]? = nil,
        renameSource: String? = nil,
        effects: [CheckpointRestoreEffect] = []
    ) -> CheckpointRestoreGroup {
        .init(
            id: id,
            primaryPath: primaryPath,
            memberPaths: memberPaths ?? [primaryPath],
            renameSource: renameSource,
            effects: effects
        )
    }
}
