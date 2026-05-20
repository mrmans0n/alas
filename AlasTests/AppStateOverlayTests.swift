import Foundation
import Testing
@testable import Alas

@MainActor
struct AppStateOverlayTests {
    private struct MemoryStore: PersistenceStoreProtocol {
        func write<T: Encodable>(_: T, to _: URL) throws {}
        func readIfExists<T: Decodable>(_: T.Type, from _: URL) throws -> T? { nil }
    }

    @Test func openingSearchClosesAgentLauncher() {
        let state = AppState(store: MemoryStore())
        state.isAgentLauncherOpen = true
        state.agentLauncher.query = "codex"
        state.agentLauncher.selectedIndex = 2

        state.openSearchOverlay()

        #expect(state.isSearchOpen)
        #expect(!state.isRepoSelectorOpen)
        #expect(!state.isAgentLauncherOpen)
        #expect(state.agentLauncher.query == "")
        #expect(state.agentLauncher.selectedIndex == 0)
    }

    @Test func openingRepoSelectorClosesAgentLauncher() {
        let state = AppState(store: MemoryStore())
        state.isAgentLauncherOpen = true
        state.agentLauncher.query = "codex"
        state.agentLauncher.selectedIndex = 2

        state.toggleRepoSelectorOverlay()

        #expect(state.isRepoSelectorOpen)
        #expect(!state.isSearchOpen)
        #expect(!state.isAgentLauncherOpen)
        #expect(state.agentLauncher.query == "")
        #expect(state.agentLauncher.selectedIndex == 0)
    }

    @Test func togglingRepoSelectorClosedLeavesAgentLauncherClosed() {
        let state = AppState(store: MemoryStore())
        state.isRepoSelectorOpen = true
        state.isAgentLauncherOpen = true
        state.agentLauncher.query = "codex"

        state.toggleRepoSelectorOverlay()

        #expect(!state.isRepoSelectorOpen)
        #expect(!state.isAgentLauncherOpen)
        #expect(state.agentLauncher.query == "")
    }
}
