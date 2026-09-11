import Testing
@testable import Alas

struct RightPaneTabTests {
    @Test func agentTabRequiresPreviewFlag() {
        #expect(RightPaneTab.available(agentTabEnabled: false, runTabEnabled: false) == [.changes, .files])
        #expect(RightPaneTab.available(agentTabEnabled: true, runTabEnabled: false) == [.changes, .files, .agent])
        #expect(RightPaneTab.visible(.agent, agentTabEnabled: false, runTabEnabled: false) == .changes)
        #expect(RightPaneTab.visible(.agent, agentTabEnabled: true, runTabEnabled: false) == .agent)
    }

    @Test func disablingRunOnlyFallsBackFromRun() {
        #expect(RightPaneTab.visible(.run, agentTabEnabled: true, runTabEnabled: false) == .changes)
    }
}
