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
        let filtered: [AgentDefinition]
        if trimmed.isEmpty {
            filtered = agents
        } else {
            filtered = agents.filter {
                $0.displayName.localizedCaseInsensitiveContains(trimmed)
                    || $0.id.localizedCaseInsensitiveContains(trimmed)
            }
        }
        if filtered.isEmpty {
            selectedIndex = 0
        } else {
            selectedIndex = min(max(0, selectedIndex), filtered.count - 1)
        }
        return filtered
    }

    func moveSelectionUp(in rows: [AgentDefinition]) {
        guard !rows.isEmpty else {
            selectedIndex = 0
            return
        }
        let clampedIndex = min(max(0, selectedIndex), rows.count - 1)
        selectedIndex = max(0, clampedIndex - 1)
        scrollToSelectionTick += 1
    }

    func moveSelectionDown(in rows: [AgentDefinition]) {
        guard !rows.isEmpty else {
            selectedIndex = 0
            return
        }
        let clampedIndex = min(max(0, selectedIndex), rows.count - 1)
        selectedIndex = min(rows.count - 1, clampedIndex + 1)
        scrollToSelectionTick += 1
    }

    func selectedAgent(in rows: [AgentDefinition]) -> AgentDefinition? {
        rows.indices.contains(selectedIndex) ? rows[selectedIndex] : nil
    }

    func reset() {
        query = ""
        selectedIndex = 0
        scrollToSelectionTick = 0
    }
}
