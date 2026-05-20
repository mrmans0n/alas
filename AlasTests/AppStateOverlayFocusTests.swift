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
        state.toggleAgentLauncherOverlay(canOpen: true)

        #expect(!state.isSearchOpen)
        #expect(!state.isRepoSelectorOpen)
        #expect(state.isAgentLauncherOpen)
        #expect(state.isKeyboardOverlayOpen)

        state.toggleAgentLauncherOverlay(canOpen: true)

        #expect(!state.isSearchOpen)
        #expect(!state.isRepoSelectorOpen)
        #expect(!state.isAgentLauncherOpen)
        #expect(!state.isKeyboardOverlayOpen)
    }
}
