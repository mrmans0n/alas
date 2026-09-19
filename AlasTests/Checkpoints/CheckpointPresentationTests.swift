import Foundation
import Testing
@testable import Alas

@Suite("Checkpoint presentation")
struct CheckpointPresentationTests {
    @Test func compactDateOmitsTodayAndIncludesOlderDate() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        #expect(CheckpointPresentation.compactDate(now, now: now).contains("/") == false)
        #expect(CheckpointPresentation.compactDate(now.addingTimeInterval(-86_400), now: now).contains("/") == true)
    }

    @Test func byteFormattingUsesBinaryUnits() {
        #expect(CheckpointPresentation.bytes(1_536) == "1.5 KiB")
        #expect(CheckpointPresentation.bytes(2 * 1_073_741_824) == "2 GiB")
    }

    @Test func summaryOmitsZeroCountsAndUsesCompactSeparators() {
        let summary = WorktreeCheckpointSummary(
            id: UUID(), kind: .manual, label: "Before edit", createdAt: .now, byteCount: 0,
            stagedFileCount: 2, unstagedFileCount: 0, untrackedFileCount: 4, unavailableReason: nil
        )
        #expect(CheckpointPresentation.summary(summary) == "2 staged · 4 untracked")
        #expect(CheckpointPresentation.statusLine(summary).contains(CheckpointPresentation.summary(summary)))
        let clean = WorktreeCheckpointSummary(
            id: summary.id, kind: .manual, label: summary.label, createdAt: summary.createdAt, byteCount: summary.byteCount,
            stagedFileCount: 0, unstagedFileCount: 0, untrackedFileCount: 0, unavailableReason: nil
        )
        #expect(CheckpointPresentation.summary(clean) == "Clean")
        let unavailable = WorktreeCheckpointSummary(
            id: summary.id, kind: .manual, label: summary.label, createdAt: summary.createdAt, byteCount: summary.byteCount,
            stagedFileCount: 0, unstagedFileCount: 0, untrackedFileCount: 0, unavailableReason: "Checkpoint data is missing."
        )
        #expect(CheckpointPresentation.statusLine(unavailable) == "Checkpoint data is missing.")
    }

    @Test func footerKeepsRetentionDetailsOutOfTheVisibleCopy() {
        #expect(CheckpointPresentation.kind(.manual) == "Manual")
        #expect(CheckpointPresentation.kind(.recovery) == "Recovery")
        #expect(CheckpointPresentation.footer(storageUsage: 0) == "0 B used")
        #expect(CheckpointPresentation.retentionHelp.contains("50 automatic"))
        #expect(CheckpointPresentation.retentionHelp.contains("2 GiB"))
    }

    @Test func automaticLabelsUseACompactPromptExcerpt() {
        #expect(AutomaticCheckpointLabel.make(
            prompt: "  Replace\n the sidebar  ",
            hasAttachments: false
        ) == "Before: Replace the sidebar")
        #expect(AutomaticCheckpointLabel.make(
            prompt: " ",
            hasAttachments: true
        ) == "Before request with attachments")
        let long = AutomaticCheckpointLabel.make(
            prompt: String(repeating: "word ", count: 50),
            hasAttachments: false
        )
        #expect(long.count <= 120)
        #expect(long.hasSuffix("…"))
    }

    @Test func remoteReasonAndRowIDsAreStable() {
        #expect(CheckpointPresentation.remoteReason == "Checkpoints are not available for remote worktrees yet.")
        let id = UUID()
        #expect(CheckpointPresentation.rowID(checkpointID: id) == CheckpointPresentation.rowID(checkpointID: id))
        let groupID = UUID()
        #expect(CheckpointPresentation.groupRowID(checkpointID: id, groupID: groupID)
                == CheckpointPresentation.groupRowID(checkpointID: id, groupID: groupID))
    }

    @Test func createModelNormalizesAndCapsLabels() {
        let model = CreateCheckpointSheetModel()
        model.label = "   "
        #expect(model.canSubmit == false)
        model.label = "  Before edit  "
        #expect(model.canSubmit)
        model.label = String(repeating: "x", count: 121)
        #expect(model.label.count == 120)
        #expect(model.unsavedBuffersMessage.contains("not captured"))
    }

    @Test func exclusionsRenderEveryPathAndReason() {
        let exclusions = [
            CheckpointExclusion(relativePath: ".env", reason: .likelySecret),
            CheckpointExclusion(relativePath: "build/output", reason: .ignoredByPolicy)
        ]
        let text = CreateCheckpointSheetModel.exclusionsText(exclusions)
        #expect(text.contains(".env"))
        #expect(text.contains("likely secret"))
        #expect(text.contains("build/output"))
        #expect(text.contains("ignored by policy"))
    }
}
