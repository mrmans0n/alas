import Testing
@testable import Alas

struct RightPaneTabTests {
    @Test func agentTabIsAlwaysAvailable() {
        #expect(RightPaneTab.available(runTabEnabled: false) == [.changes, .files, .agent])
        #expect(RightPaneTab.visible(.agent, runTabEnabled: false) == .agent)
    }

    @Test func disablingRunOnlyFallsBackFromRun() {
        #expect(RightPaneTab.visible(.run, runTabEnabled: false) == .changes)
    }
}
