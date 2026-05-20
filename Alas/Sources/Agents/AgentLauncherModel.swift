import Foundation
import Observation

@Observable
@MainActor
final class AgentLauncherModel {
    var query: String = "" {
        didSet { selectedIndex = 0 }
    }
    var selectedIndex: Int = 0
    var scrollToSelectionTick: Int = 0

    func rows(agents: [AgentDefinition]) -> [AgentDefinition] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return agents
        }

        return agents.filter {
            $0.displayName.localizedCaseInsensitiveContains(trimmed)
                || $0.id.localizedCaseInsensitiveContains(trimmed)
        }
    }

    func clampSelection(in rows: [AgentDefinition]) {
        selectedIndex = clampedIndex(in: rows)
    }

    func moveSelectionUp(in rows: [AgentDefinition]) {
        guard !rows.isEmpty else {
            selectedIndex = 0
            return
        }
        selectedIndex = max(0, clampedIndex(in: rows) - 1)
        scrollToSelectionTick &+= 1
    }

    func moveSelectionDown(in rows: [AgentDefinition]) {
        guard !rows.isEmpty else {
            selectedIndex = 0
            return
        }
        selectedIndex = min(rows.count - 1, clampedIndex(in: rows) + 1)
        scrollToSelectionTick &+= 1
    }

    func selectedAgent(in rows: [AgentDefinition]) -> AgentDefinition? {
        rows.indices.contains(selectedIndex) ? rows[selectedIndex] : nil
    }

    func reset() {
        query = ""
        selectedIndex = 0
        scrollToSelectionTick = 0
    }

    private func clampedIndex(in rows: [AgentDefinition]) -> Int {
        guard !rows.isEmpty else { return 0 }
        return min(max(0, selectedIndex), rows.count - 1)
    }
}
