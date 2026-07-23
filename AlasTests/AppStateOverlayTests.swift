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

    @Test func openingAgentLauncherWithExplicitTerminalModeOverridesDefault() {
        let state = AppState(store: MemoryStore())
        state.config.agents.defaultLauncherMode = .acp
        state.isSearchOpen = true
        state.isRepoSelectorOpen = true
        state.agentLauncher.query = "codex"
        state.agentLauncher.selectedIndex = 4

        state.openAgentLauncherOverlay(mode: .terminal)

        #expect(state.isAgentLauncherOpen)
        #expect(!state.isSearchOpen)
        #expect(!state.isRepoSelectorOpen)
        #expect(state.agentLauncher.mode == .terminal)
        #expect(state.agentLauncher.query == "")
        #expect(state.agentLauncher.selectedIndex == 0)
        #expect(state.config.agents.defaultLauncherMode == .acp)
    }

    @Test func openingAgentLauncherWithExplicitChatModeOverridesDefault() {
        let state = AppState(store: MemoryStore())
        state.config.agents.defaultLauncherMode = .terminal

        state.openAgentLauncherOverlay(mode: .acp)

        #expect(state.isAgentLauncherOpen)
        #expect(state.agentLauncher.mode == .acp)
        #expect(state.config.agents.defaultLauncherMode == .terminal)
    }

    @Test func openingAgentLauncherWithoutModeUsesConfiguredDefault() {
        let state = AppState(store: MemoryStore())
        state.config.agents.defaultLauncherMode = .acp

        state.openAgentLauncherOverlay(mode: nil)

        #expect(state.isAgentLauncherOpen)
        #expect(state.agentLauncher.mode == .acp)
    }

    @Test func toggleAgentLauncherClosedOpensUsingConfiguredDefault() {
        let state = AppState(store: MemoryStore())
        state.config.agents.defaultLauncherMode = .acp

        state.toggleAgentLauncherOverlay(canOpen: true)

        #expect(state.isAgentLauncherOpen)
        #expect(state.agentLauncher.mode == .acp)
    }

    @Test func toggleAgentLauncherOpenClosesAndResets() {
        let state = AppState(store: MemoryStore())
        state.isAgentLauncherOpen = true
        state.agentLauncher.mode = .acp
        state.agentLauncher.query = "claude"
        state.agentLauncher.selectedIndex = 3

        state.toggleAgentLauncherOverlay(canOpen: true)

        #expect(!state.isAgentLauncherOpen)
        #expect(state.agentLauncher.query == "")
        #expect(state.agentLauncher.selectedIndex == 0)
    }

    @Test func openingRunScriptPaletteWhileOpenKeepsLoadedScripts() {
        let state = AppState(store: MemoryStore())
        let script = RunScript(
            scope: .repo,
            fileName: "build.sh",
            fileURL: URL(fileURLWithPath: "/tmp/build.sh"),
            displayName: "Build",
            onExit: .keep,
            cwd: nil,
            isExecutable: true
        )
        state.runScriptPalette.load(environment: RunScriptPaletteEnvironment(
            scripts: { [script] },
            isRunning: { _ in false },
            run: { _ in },
            restart: { _ in },
            edit: { _ in },
            newScript: { _ in }
        ))
        state.runScriptPalette.query = "b"
        state.isRunScriptPaletteOpen = true

        state.openRunScriptPaletteOverlay()

        #expect(state.isRunScriptPaletteOpen)
        #expect(state.runScriptPalette.scripts == [script])
        #expect(state.runScriptPalette.query == "b")
    }
}
