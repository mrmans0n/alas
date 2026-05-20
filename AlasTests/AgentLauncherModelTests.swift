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
            isBuiltin: false,
            isEnabled: true,
            builtinLogoAssetName: nil
        )
    }

    @Test func rowsFilterByDisplayName() {
        let model = AgentLauncherModel()
        model.query = "cla"
        let rows = model.rows(agents: [
            agent("claude", "Claude Code"),
            agent("codex", "Codex"),
        ])
        #expect(rows.map(\.id) == ["claude"])
    }

    @Test func rowsFilterById() {
        let model = AgentLauncherModel()
        model.query = "gpt"
        let rows = model.rows(agents: [
            agent("claude", "Claude Code"),
            agent("gpt-cli", "OpenAI CLI"),
        ])
        #expect(rows.map(\.id) == ["gpt-cli"])
    }

    @Test func rowsDoesNotMutateSelection() {
        let model = AgentLauncherModel()
        model.selectedIndex = 3
        let rows = model.rows(agents: [agent("codex", "Codex")])
        #expect(rows.map(\.id) == ["codex"])
        #expect(model.selectedIndex == 3)
    }

    @Test func selectionClampsWhenRowsShrink() {
        let model = AgentLauncherModel()
        model.selectedIndex = 3
        let rows = model.rows(agents: [agent("codex", "Codex")])
        model.clampSelection(in: rows)
        #expect(rows.map(\.id) == ["codex"])
        #expect(model.selectedIndex == 0)
    }

    @Test func moveSelectionStaysInsideBounds() {
        let model = AgentLauncherModel()
        let rows = [
            agent("claude", "Claude Code"),
            agent("codex", "Codex"),
        ]
        model.moveSelectionDown(in: rows)
        model.moveSelectionDown(in: rows)
        #expect(model.selectedIndex == 1)
        model.moveSelectionUp(in: rows)
        model.moveSelectionUp(in: rows)
        #expect(model.selectedIndex == 0)
    }

    @Test func moveSelectionUpClampsOutOfRangeSelection() {
        let model = AgentLauncherModel()
        model.selectedIndex = 3
        model.moveSelectionUp(in: [agent("codex", "Codex")])
        #expect(model.selectedIndex == 0)
    }

    @Test func moveSelectionDownClampsNegativeSelection() {
        let model = AgentLauncherModel()
        model.selectedIndex = -3
        model.moveSelectionDown(in: [agent("codex", "Codex")])
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
}
