import SwiftUI
import Testing
@testable import Alas

struct FileTreeRowIndentationTests {
    @Test func filesTabRowsUseOneIndentStepPerDepth() {
        #expect(FilesTabView.rowLeadingPadding(depth: 0) == 12)
        #expect(FilesTabView.rowLeadingPadding(depth: 1) == 26)
        #expect(FilesTabView.messageLeadingPadding(depth: 1) == 26)
    }

    @Test func workingTreeRowsUseOneIndentStepPerDepth() {
        #expect(WorkingTreeSectionView.directoryRowLeadingPadding(depth: 0) == 12)
        #expect(WorkingTreeSectionView.directoryRowLeadingPadding(depth: 1) == 26)
        #expect(ChangedRow.rowLeadingPadding(depth: 0) == 12)
        #expect(ChangedRow.rowLeadingPadding(depth: 1) == 26)
    }
}
