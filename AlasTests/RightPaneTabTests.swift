import Testing
@testable import Alas

struct RightPaneTabTests {
    @Test func fiveTabsAreAlwaysAvailable() {
        #expect(RightPaneTab.available() == [.changes, .files, .agent, .run, .schedules])
    }

    @Test func runTabIsAvailable() {
        #expect(RightPaneTab.available().contains(.run))
    }
}
