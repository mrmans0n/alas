import Testing
@testable import Alas

/// The keyboard path into the rail (`AppState.activateRightPaneTab`) routes
/// through the same `resolve` + `apply` pair the rail's click handler uses.
/// These pin that composition end to end, so a change to either half that
/// broke the keyboard's "open on this tab / collapse when already showing"
/// contract fails here rather than only under a live keypress.
struct RightPaneTabShortcutTests {
    private func outcome(
        tapped: RightPaneTab,
        active: RightPaneTab,
        visible: Bool
    ) -> RightPaneRailOutcome {
        RightPaneRailModel.apply(
            RightPaneRailAction.resolve(tapped: tapped, active: active, collapsed: !visible),
            currentTab: active,
            currentVisible: visible
        )
    }

    @Test func shortcutForAHiddenPaneOpensItOnThatTab() {
        let result = outcome(tapped: .run, active: .changes, visible: false)
        #expect(result.tab == .run)
        #expect(result.visible == true)
    }

    @Test func shortcutForTheShowingTabCollapsesThePane() {
        let result = outcome(tapped: .files, active: .files, visible: true)
        #expect(result.tab == .files)
        #expect(result.visible == false)
    }

    @Test func shortcutForAnotherTabSwitchesWithoutClosing() {
        let result = outcome(tapped: .agent, active: .changes, visible: true)
        #expect(result.tab == .agent)
        #expect(result.visible == true)
    }

    /// Re-pressing the same shortcut twice should land back where it started:
    /// collapse, then reopen on the very tab it collapsed from.
    @Test func pressingTheSameShortcutTwiceRoundTrips() {
        let collapsed = outcome(tapped: .changes, active: .changes, visible: true)
        #expect(collapsed.visible == false)

        let reopened = outcome(tapped: .changes, active: collapsed.tab, visible: collapsed.visible)
        #expect(reopened.tab == .changes)
        #expect(reopened.visible == true)
    }

    /// Every shortcut maps to a fixed tab identity, not a rail position, so
    /// the same key means the same tab whether or not the Agent/Run previews
    /// are adding entries to the rail.
    @Test func eachTabHasItsOwnDistinctDefaultBinding() {
        let bindings: [ShortcutBinding] = [
            ShortcutAction.rightPaneChangesTab.defaultBinding,
            ShortcutAction.rightPaneFilesTab.defaultBinding,
            ShortcutAction.rightPaneAgentTab.defaultBinding,
            ShortcutAction.rightPaneRunTab.defaultBinding,
        ]
        #expect(Set(bindings).count == 4)
        for binding in bindings {
            #expect(binding.modifiers == [.command, .control])
        }
        #expect(bindings.map(\.key) == ["1", "2", "3", "4"])
    }

    /// Cmd+digit is the center tab switcher and Cmd+Option+digit selects a
    /// Space; neither family may be reused here.
    @Test func tabBindingsAvoidTheReservedAndSpacesDigitFamilies() {
        let tabBindings = [
            ShortcutAction.rightPaneChangesTab.defaultBinding,
            ShortcutAction.rightPaneFilesTab.defaultBinding,
            ShortcutAction.rightPaneAgentTab.defaultBinding,
            ShortcutAction.rightPaneRunTab.defaultBinding,
        ]
        for binding in tabBindings {
            #expect(!ShortcutAction.reservedBindings.contains(binding))
            #expect(binding.modifiers != [.command, .option])
        }
    }

    /// The rail toggle keeps its own binding — the tab shortcuts are additive.
    @Test func toggleRightPaneKeepsItsBinding() {
        let toggle = ShortcutAction.toggleRightPane.defaultBinding
        #expect(toggle.key == "b")
        #expect(toggle.modifiers == [.command, .option])
    }
}
