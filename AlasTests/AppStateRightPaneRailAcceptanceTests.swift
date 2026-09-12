import Testing
@testable import Alas

/// `AppState.acceptsRightPaneTabShortcut` is the gate the ⌘⌃1-4 rail
/// shortcuts and the "Right Sidebar: ..." menu items both check before
/// acting. The rail's pure reducer is covered elsewhere (see
/// `RightPaneTabShortcutTests`); this pins the flag gate itself, which had
/// no direct coverage — only the flag-off default was exercised indirectly.
@MainActor
struct AppStateRightPaneRailAcceptanceTests {
    @Test func shortcutsAreLiveWhenTheRailIsEnabled() {
        let state = AppState()
        state.config.rightPaneRailEnabled = true

        #expect(state.acceptsRightPaneTabShortcut(.changes))
        #expect(state.acceptsRightPaneTabShortcut(.files))
    }

    @Test func shortcutsAreInertWhenTheRailIsDisabled() {
        // With the rail off, a hidden pane has no mounted `RightPaneState`
        // to target, and mounting one resets the active tab — so the
        // shortcut must be a no-op rather than acting on a pane the user
        // can't see change.
        let state = AppState()
        state.config.rightPaneRailEnabled = false

        #expect(!state.acceptsRightPaneTabShortcut(.changes))
        #expect(!state.acceptsRightPaneTabShortcut(.files))
    }

    @Test func shortcutsRespectTheRunTabPreviewFlagWhenTheRailIsEnabled() {
        let state = AppState()
        state.config.rightPaneRailEnabled = true
        state.config.runTabEnabled = false

        #expect(state.acceptsRightPaneTabShortcut(.agent))
        #expect(!state.acceptsRightPaneTabShortcut(.run))

        state.config.runTabEnabled = true

        #expect(state.acceptsRightPaneTabShortcut(.run))
    }
}
