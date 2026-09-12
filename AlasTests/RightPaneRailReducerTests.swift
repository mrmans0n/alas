import Testing
@testable import Alas

/// Covers `RightPaneRailModel.apply` — the transition from a resolved rail
/// action to the pane's `(activeTab, rightPaneVisible)` pair. This is the step
/// a remount used to silently undo, so it is worth pinning down directly.
struct RightPaneRailReducerTests {
    @Test func collapseHidesTheBodyAndKeepsTheActiveTab() {
        let outcome = RightPaneRailModel.apply(.collapse, currentTab: .files, currentVisible: true)
        #expect(outcome.tab == .files)
        #expect(outcome.visible == false)
    }

    @Test func expandShowsTheBodyOnTheTappedTab() {
        let outcome = RightPaneRailModel.apply(.expand(.run), currentTab: .changes, currentVisible: false)
        #expect(outcome.tab == .run)
        #expect(outcome.visible == true)
    }

    @Test func expandOnTheAlreadyActiveTabJustShowsTheBody() {
        let outcome = RightPaneRailModel.apply(.expand(.agent), currentTab: .agent, currentVisible: false)
        #expect(outcome.tab == .agent)
        #expect(outcome.visible == true)
    }

    @Test func selectSwitchesTabsWithoutTouchingVisibility() {
        let outcome = RightPaneRailModel.apply(.select(.agent), currentTab: .changes, currentVisible: true)
        #expect(outcome.tab == .agent)
        #expect(outcome.visible == true)
    }

    /// The reopened-tab regression in one assertion: resolving a tap on a
    /// non-active tab while collapsed, then applying it, must land on the
    /// tapped tab — not fall back to Changes.
    @Test func tappingACollapsedRailTabReopensOnThatTab() {
        for tapped in [RightPaneTab.changes, .files, .agent, .run] {
            let action = RightPaneRailAction.resolve(tapped: tapped, active: .changes, collapsed: true)
            let outcome = RightPaneRailModel.apply(action, currentTab: .changes, currentVisible: false)
            #expect(outcome.tab == tapped)
            #expect(outcome.visible == true)
        }
    }
}
