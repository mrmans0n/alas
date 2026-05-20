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

    @Test func selectionClampsWhenRowsShrink() {
        let model = AgentLauncherModel()
        model.selectedIndex = 3
        let rows = model.rows(agents: [agent("codex", "Codex")])
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

    @Test func selectedAgentReturnsNilForEmptyRows() {
        let model = AgentLauncherModel()
        #expect(model.selectedAgent(in: []) == nil)
    }
}
