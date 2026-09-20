import Testing
@testable import Alas

struct RightPaneTabTests {
    @Test func allFiveTabsAreAlwaysAvailable() {
        #expect(RightPaneTab.available() == [.changes, .files, .agent, .run, .schedules])
    }

    @Test func runTabIsAvailable() {
        #expect(RightPaneTab.available().contains(.run))
    }

    @Test func schedulesTabIsAvailable() {
        #expect(RightPaneTab.available().contains(.schedules))
    }
}
