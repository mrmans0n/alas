import Testing
@testable import Alas

/// `AppState.acceptsRightPaneTabShortcut` is the gate the ⌘⌃1-4 rail
/// shortcuts and the "Right Sidebar: ..." menu items both check before
/// acting. The rail's pure reducer is covered elsewhere (see
/// `RightPaneTabShortcutTests`); this pins the available-tabs set.
@MainActor
struct AppStateRightPaneRailAcceptanceTests {
    @Test func shortcutsAreLiveForBuiltInTabs() {
        let state = AppState()

        #expect(state.acceptsRightPaneTabShortcut(.changes))
        #expect(state.acceptsRightPaneTabShortcut(.files))
        #expect(state.acceptsRightPaneTabShortcut(.agent))
    }

    @Test func runTabShortcutIsAlwaysLive() {
        let state = AppState()

        #expect(state.acceptsRightPaneTabShortcut(.run))
        #expect(state.acceptsRightPaneTabShortcut(.agent))
    }

    /// The Schedules shortcut must stay inert until its preview flag is on,
    /// so the chord does nothing rather than opening a gated tab.
    @Test func schedulesTabShortcutFollowsItsPreviewFlag() {
        let state = AppState()

        state.config.schedulesEnabled = false
        #expect(!state.acceptsRightPaneTabShortcut(.schedules))

        state.config.schedulesEnabled = true
        #expect(state.acceptsRightPaneTabShortcut(.schedules))
    }
}
