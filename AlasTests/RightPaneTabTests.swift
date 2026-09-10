import Testing
@testable import Alas

struct RightPaneTabTests {
    @Test func runTabIsUnavailableUntilPreviewIsEnabled() {
        #expect(RightPaneTab.available(runTabEnabled: false) == [.changes, .files])
        #expect(RightPaneTab.available(runTabEnabled: true) == [.changes, .files, .run])
    }

    @Test func hidingRunTabMovesItsSelectionToChanges() {
        #expect(RightPaneTab.visible(.run, runTabEnabled: false) == .changes)
        #expect(RightPaneTab.visible(.files, runTabEnabled: false) == .files)
    }
}
