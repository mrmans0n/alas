import Testing
@testable import Alas

@MainActor
struct AgentLauncherModelTests {
    private func agent(_ id: String, _ name: String) -> AgentDefinition {
        AgentDefinition(
            id: id,
            displayName: name,
            binary: id,
            binaryOverride: nil,
            promptModeArgs: [],
            bypassPermissionsFlag: nil,
            extraTerminalArgs: nil,
            isBuiltin: false,
            isEnabled: true,
            builtinLogoAssetName: nil
        )
    }

    @Test func rowsFilterByDisplayName() {
        let model = AgentLauncherModel()
        model.query = "cla"
        let rows = model.rows(enabledAgents: [
            agent("claude", "Claude Code"),
            agent("codex", "Codex"),
        ])
        #expect(rows.map(\.id) == ["claude"])
    }

    @Test func rowsFilterById() {
        let model = AgentLauncherModel()
        model.query = "gpt"
        let rows = model.rows(enabledAgents: [
            agent("claude", "Claude Code"),
            agent("gpt-cli", "OpenAI CLI"),
        ])
        #expect(rows.map(\.id) == ["gpt-cli"])
    }

    @Test func moveSelectionStaysInsideBounds() {
        let model = AgentLauncherModel()
        model.moveSelectionDown(rowCount: 2)
        model.moveSelectionDown(rowCount: 2)
        #expect(model.selectedIndex == 1)
        model.moveSelectionUp(rowCount: 2)
        model.moveSelectionUp(rowCount: 2)
        #expect(model.selectedIndex == 0)
    }

    @Test func moveSelectionUpClampsOutOfRangeSelection() {
        let model = AgentLauncherModel()
        model.selectedIndex = 3
        model.moveSelectionUp(rowCount: 1)
        #expect(model.selectedIndex == 0)
    }

    @Test func moveSelectionDownClampsNegativeSelection() {
        let model = AgentLauncherModel()
        model.selectedIndex = -3
        model.moveSelectionDown(rowCount: 1)
        #expect(model.selectedIndex == 0)
    }

    @Test func selectedAgentReturnsNilForEmptyRows() {
        let model = AgentLauncherModel()
        #expect(model.selectedAgent(in: []) == nil)
    }

    @Test func resetClearsLauncherState() {
        let model = AgentLauncherModel()
        model.query = "cod"
        model.selectedIndex = 2
        model.scrollToSelectionTick = 4

        model.reset()

        #expect(model.query == "")
        #expect(model.selectedIndex == 0)
        #expect(model.scrollToSelectionTick == 0)
    }

    @Test func acpModeFiltersToAgentsWithLaunchSpec() {
        let model = AgentLauncherModel()
        model.mode = .acp
        // Custom "made-up" agent has no ACPLaunchSpec, so it must be
        // excluded; claude has one, so it stays.
        let enabled = [
            agent("claude", "Claude Code"),
            agent("madeup", "Made Up Agent"),
        ]
        let ids = model.rows(enabledAgents: enabled).map(\.id)
        #expect(ids.contains("claude"))
        #expect(!ids.contains("madeup"))
    }

    @Test func prepareForOpenAppliesDefaultMode() {
        let model = AgentLauncherModel()
        model.query = "x"
        model.selectedIndex = 5
        model.mode = .terminal

        model.prepareForOpen(defaultMode: .acp)

        #expect(model.mode == .acp)
        #expect(model.query == "")
        #expect(model.selectedIndex == 0)
        #expect(!model.isModeLocked)
    }

    @Test func toggleModeSwapsSurfaceWhenUnlocked() {
        let model = AgentLauncherModel()
        model.prepareForOpen(defaultMode: .terminal)

        model.toggleMode()
        #expect(model.mode == .acp)

        model.toggleMode(reverse: true)
        #expect(model.mode == .terminal)
    }

    @Test func lockedLauncherIgnoresModeChanges() {
        let model = AgentLauncherModel()
        model.prepareForOpen(defaultMode: .acp, locked: true)

        #expect(model.isModeLocked)

        model.toggleMode()
        #expect(model.mode == .acp)

        model.selectMode(.terminal)
        #expect(model.mode == .acp)
    }

    @Test func everyPrepareForOpenBumpsTheOpenTick() {
        let model = AgentLauncherModel()
        let initial = model.openTick

        model.prepareForOpen(defaultMode: .acp)
        let afterFirst = model.openTick
        #expect(afterFirst != initial)

        // Re-opening on another surface while already open must still signal
        // the dialog, so it can tear down the ACP session browser.
        model.prepareForOpen(defaultMode: .terminal, locked: true)
        #expect(model.openTick != afterFirst)
    }

    @Test func resetClearsModeLock() {
        let model = AgentLauncherModel()
        model.prepareForOpen(defaultMode: .terminal, locked: true)

        model.reset()

        #expect(!model.isModeLocked)
    }

    @Test func reopeningUnlockedClearsPriorLock() {
        let model = AgentLauncherModel()
        model.prepareForOpen(defaultMode: .acp, locked: true)

        model.prepareForOpen(defaultMode: .terminal)

        #expect(!model.isModeLocked)
        #expect(model.mode == .terminal)
    }
}
