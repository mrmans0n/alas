import Testing
@testable import Alas

@MainActor
struct AppStateOverlayFocusTests {
    @Test func keyboardOverlayFlagTracksSearchAndRepoSelector() {
        let state = AppState()

        #expect(!state.isKeyboardOverlayOpen)

        state.openSearchOverlay()
        #expect(state.isSearchOpen)
        #expect(!state.isRepoSelectorOpen)
        #expect(!state.isAgentLauncherOpen)
        #expect(state.isKeyboardOverlayOpen)

        state.toggleRepoSelectorOverlay()
        #expect(!state.isSearchOpen)
        #expect(state.isRepoSelectorOpen)
        #expect(!state.isAgentLauncherOpen)
        #expect(state.isKeyboardOverlayOpen)

        state.toggleRepoSelectorOverlay()
        #expect(!state.isSearchOpen)
        #expect(!state.isRepoSelectorOpen)
        #expect(!state.isAgentLauncherOpen)
        #expect(!state.isKeyboardOverlayOpen)
    }

    @Test func agentLauncherOverlayAlsoBlocksPaneFocus() {
        let state = AppState()

        state.openSearchOverlay()
        state.openAgentLauncherOverlay(.picker)

        #expect(!state.isSearchOpen)
        #expect(!state.isRepoSelectorOpen)
        #expect(state.isAgentLauncherOpen)
        #expect(state.isKeyboardOverlayOpen)

        // How AgentLauncherDialog.close() dismisses itself.
        state.agentLauncher.reset()
        state.isAgentLauncherOpen = false

        #expect(!state.isSearchOpen)
        #expect(!state.isRepoSelectorOpen)
        #expect(!state.isAgentLauncherOpen)
        #expect(!state.isKeyboardOverlayOpen)
    }
}
