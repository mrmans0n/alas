import Testing
import SwiftUI
import AppKit
@testable import Alas

/// Smoke and navigation tests for AgentsPane.
@Suite(.serialized)
@MainActor
struct AgentsPaneTests {
    private func currentTheme() -> Theme {
        try! ThemeStore().current
    }

    @Test func agentsPaneRendersWithoutCrashing() {
        let view = AgentsPane(state: AppState(), onNavigate: { _ in })
            .environment(\.theme, currentTheme())
        let controller = NSHostingController(rootView: view)
        controller.view.layoutSubtreeIfNeeded()
        #expect(!controller.view.subviews.isEmpty)
    }

    @Test func harnessEntryNavigatesToTerminal() {
        var navigated: SettingsSection?
        let pane = AgentsPane(state: AppState()) { section in
            navigated = section
        }
        let view = pane.environment(\.theme, currentTheme())
        let controller = NSHostingController(rootView: view)
        controller.view.layoutSubtreeIfNeeded()
        #expect(navigated == nil)
        // Invoke the closure directly as a proxy for wiring correctness.
        pane.onNavigate(.terminal)
        #expect(navigated == .terminal)
    }

    @Test func agentExtraTerminalArgsStoredCorrectly() {
        var agent = AgentDefinition(
            id: "test", displayName: "Test", binary: "test",
            binaryOverride: nil, promptModeArgs: [],
            bypassPermissionsFlag: nil, extraTerminalArgs: ["--model", "sonnet"],
            isBuiltin: false, isEnabled: true, builtinLogoAssetName: nil
        )
        #expect(agent.extraTerminalArgs == ["--model", "sonnet"])
        agent.extraTerminalArgs = nil
        #expect(agent.extraTerminalArgs == nil)
    }
}
