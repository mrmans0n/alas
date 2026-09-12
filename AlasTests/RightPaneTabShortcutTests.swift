import Testing
import Foundation
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

    /// A narrow window makes `ThreePaneSizing` auto-collapse the pane while
    /// `rightPaneVisible` stays true. Resolving from that preference instead
    /// of the effective collapsed state would close a pane the user already
    /// sees as closed; resolving from the effective state reopens it instead.
    @Test func autoCollapsedPaneResolvesFromTheEffectiveState() {
        let fromEffectiveState = outcome(tapped: .changes, active: .changes, visible: false)
        #expect(fromEffectiveState.tab == .changes)
        #expect(fromEffectiveState.visible == true)

        let fromPreferenceAlone = outcome(tapped: .changes, active: .changes, visible: true)
        #expect(fromPreferenceAlone.visible == false)
    }

    /// An older config may already have bound ⌘⌃1–4 to something else — legal
    /// before these actions existed. The new action must start unbound rather
    /// than silently claiming a chord the user already assigned.
    @Test func anExistingOverrideOnARailChordKeepsItsBinding() throws {
        var config = AppConfig.defaults
        config.shortcutOverrides[ShortcutAction.searchFiles.rawValue] =
            ShortcutAction.rightPaneChangesTab.defaultBinding

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)

        #expect(decoded.shortcutOverrides[ShortcutAction.searchFiles.rawValue]
            == ShortcutAction.rightPaneChangesTab.defaultBinding)
        // Present as an explicit nil: claimed, so deliberately unbound.
        let railOverride = try #require(
            decoded.shortcutOverrides[ShortcutAction.rightPaneChangesTab.rawValue]
        )
        #expect(railOverride == nil)
    }

    /// A rail chord nobody else claimed must keep its default — the migration
    /// only unbinds on a real collision.
    @Test func anUnclaimedRailChordKeepsItsDefault() throws {
        let data = try JSONEncoder().encode(AppConfig.defaults)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)

        for action in [ShortcutAction.rightPaneChangesTab, .rightPaneFilesTab,
                       .rightPaneAgentTab, .rightPaneRunTab] {
            #expect(decoded.shortcutOverrides[action.rawValue] == nil)
        }
    }
}
