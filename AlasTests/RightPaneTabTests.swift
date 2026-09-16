import Testing
@testable import Alas

struct RightPaneTabTests {
    @Test func allFourTabsAreAlwaysAvailable() {
        #expect(RightPaneTab.available() == [.changes, .files, .agent, .run])
    }

    @Test func runTabIsAvailable() {
        #expect(RightPaneTab.available().contains(.run))
    }
}