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

    @Test func summaryKeepsEachChangeScopeDistinct() {
        let summary = WorktreeCheckpointSummary(
            id: UUID(), kind: .manual, label: "Before edit", createdAt: .now, byteCount: 0,
            stagedFileCount: 2, unstagedFileCount: 3, untrackedFileCount: 4, unavailableReason: nil
        )
        #expect(CheckpointPresentation.summary(summary) == "2 staged, 3 unstaged, 4 untracked")
    }

    @Test func labelsAndFooterDescribeTheCheckpointPolicy() {
        #expect(CheckpointPresentation.kind(.manual) == "Manual")
        #expect(CheckpointPresentation.kind(.recovery) == "Recovery")
        let footer = CheckpointPresentation.footer(storageUsage: 0)
        #expect(footer.contains("20 manual"))
        #expect(footer.contains("5 recovery"))
        #expect(footer.contains("2 GiB"))
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
        var model = CreateCheckpointSheetModel()
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
