import SwiftUI
import Testing
@testable import Alas

struct FileTreeRowIndentationTests {
    @Test func filesTabRowsUseOneIndentStepPerDepth() {
        #expect(FileTreeListView.rowLeadingPadding(depth: 0) == 12)
        #expect(FileTreeListView.rowLeadingPadding(depth: 1) == 26)
        #expect(FileTreeListView.messageLeadingPadding(depth: 1) == 26)
    }

    @Test func workingTreeRowsIndentAfterAFixedStageColumn() {
        #expect(WorkingTreeSectionView.treeIndent(depth: 0) == 0)
        #expect(WorkingTreeSectionView.treeIndent(depth: 1) == 14)
        #expect(WorkingTreeSectionView.rowLeadingInset(showsStageChip: true) + 3 == FileTreeListView.rowLeadingPadding(depth: 0))
        #expect(WorkingTreeSectionView.rowLeadingInset(showsStageChip: false) == FileTreeListView.rowLeadingPadding(depth: 0))
    }
}
