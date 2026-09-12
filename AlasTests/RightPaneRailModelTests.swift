import Testing
@testable import Alas

struct RightPaneRailModelTests {
    @Test func tappingTheActiveTabWhileExpandedCollapsesThePane() {
        #expect(RightPaneRailAction.resolve(tapped: .changes, active: .changes, collapsed: false) == .collapse)
        #expect(RightPaneRailAction.resolve(tapped: .run, active: .run, collapsed: false) == .collapse)
    }

    @Test func tappingAnInactiveTabWhileExpandedSwitchesTabs() {
        #expect(RightPaneRailAction.resolve(tapped: .files, active: .changes, collapsed: false) == .select(.files))
        #expect(RightPaneRailAction.resolve(tapped: .agent, active: .run, collapsed: false) == .select(.agent))
    }

    @Test func tappingAnyTabWhileCollapsedExpandsOnThatTab() {
        #expect(RightPaneRailAction.resolve(tapped: .changes, active: .changes, collapsed: true) == .expand(.changes))
        #expect(RightPaneRailAction.resolve(tapped: .files, active: .changes, collapsed: true) == .expand(.files))
    }

    @Test func changesBadgeCountsChangesAndHidesAtZero() {
        #expect(RightPaneRailModel.badge(for: .changes, changesCount: 12, activeAgentCount: 0, activeRunCount: 0) == .count(12))
        #expect(RightPaneRailModel.badge(for: .changes, changesCount: 0, activeAgentCount: 0, activeRunCount: 0) == .none)
    }

    @Test func filesNeverBadges() {
        #expect(RightPaneRailModel.badge(for: .files, changesCount: 12, activeAgentCount: 4, activeRunCount: 2) == .none)
    }

    @Test func agentBadgeCountsActiveRowsAndHidesAtZero() {
        #expect(RightPaneRailModel.badge(for: .agent, changesCount: 0, activeAgentCount: 2, activeRunCount: 0) == .count(2))
        #expect(RightPaneRailModel.badge(for: .agent, changesCount: 0, activeAgentCount: 0, activeRunCount: 0) == .none)
    }

    @Test func runBadgeIsALiveDotRatherThanACount() {
        #expect(RightPaneRailModel.badge(for: .run, changesCount: 0, activeAgentCount: 0, activeRunCount: 1) == .liveDot)
        #expect(RightPaneRailModel.badge(for: .run, changesCount: 0, activeAgentCount: 0, activeRunCount: 3) == .liveDot)
        #expect(RightPaneRailModel.badge(for: .run, changesCount: 0, activeAgentCount: 0, activeRunCount: 0) == .none)
    }

    @Test func badgeTextCapsAtNinetyNine() {
        #expect(RightPaneRailBadge.count(7).displayText == "7")
        #expect(RightPaneRailBadge.count(99).displayText == "99")
        #expect(RightPaneRailBadge.count(100).displayText == "99+")
        #expect(RightPaneRailBadge.liveDot.displayText == nil)
        #expect(RightPaneRailBadge.none.displayText == nil)
    }

    @Test func collapsedActiveTabRendersAsItsOwnState() {
        #expect(RightPaneRailModel.tabState(for: .changes, active: .changes, collapsed: false) == .active)
        #expect(RightPaneRailModel.tabState(for: .changes, active: .changes, collapsed: true) == .activeCollapsed)
        #expect(RightPaneRailModel.tabState(for: .files, active: .changes, collapsed: true) == .inactive)
        #expect(RightPaneRailModel.tabState(for: .files, active: .changes, collapsed: false) == .inactive)
    }
}
