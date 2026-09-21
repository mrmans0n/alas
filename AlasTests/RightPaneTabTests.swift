import Testing
@testable import Alas

struct RightPaneTabTests {
    @Test func fourTabsAreAlwaysAvailable() {
        #expect(RightPaneTab.available() == [.changes, .files, .agent, .run])
    }

    @Test func runTabIsAvailable() {
        #expect(RightPaneTab.available().contains(.run))
    }

    /// Schedules ship behind a preview flag, so the rail must not offer the
    /// tab until it is switched on.
    @Test func schedulesTabAppearsOnlyWhenItsFlagIsOn() {
        #expect(!RightPaneTab.available(schedulesEnabled: false).contains(.schedules))
        #expect(RightPaneTab.available(schedulesEnabled: true) == [.changes, .files, .agent, .run, .schedules])
    }
}
