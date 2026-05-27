import Foundation
import Observation

@Observable
@MainActor
final class AgentLauncherModel {
    /// Which launch surface the dialog is currently targeting. Flipping
    /// this swaps which agent list is shown (terminal-capable vs.
    /// ACP-capable) and what Enter does.
    var mode: AppConfig.LauncherMode = .terminal {
        didSet { selectedIndex = 0; scrollToSelectionTick &+= 1 }
    }
    var query: String = "" {
        didSet { selectedIndex = 0 }
    }
    var selectedIndex: Int = 0
    var scrollToSelectionTick: Int = 0

    /// Agents visible for the current `mode` after applying the fuzzy
    /// query. Terminal mode shows every enabled agent; ACP mode shows
    /// only the subset for which `ACPLaunchCatalog` has a launch spec.
    func rows(enabledAgents: [AgentDefinition]) -> [AgentDefinition] {
        let pool: [AgentDefinition]
        switch mode {
        case .terminal:
            pool = enabledAgents
        case .acp:
            let acpIds = Set(ACPLaunchCatalog.specs.map(\.agentID))
            pool = enabledAgents.filter { acpIds.contains($0.id) }
        }
        return filtered(pool)
    }

    private func filtered(_ agents: [AgentDefinition]) -> [AgentDefinition] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return agents }
        return agents.filter {
            $0.displayName.localizedCaseInsensitiveContains(trimmed)
                || $0.id.localizedCaseInsensitiveContains(trimmed)
        }
    }

    func moveSelectionUp(rowCount: Int) {
        guard rowCount > 0 else { selectedIndex = 0; return }
        selectedIndex = max(0, clampedIndex(rowCount: rowCount) - 1)
        scrollToSelectionTick &+= 1
    }

    func moveSelectionDown(rowCount: Int) {
        guard rowCount > 0 else { selectedIndex = 0; return }
        selectedIndex = min(rowCount - 1, clampedIndex(rowCount: rowCount) + 1)
        scrollToSelectionTick &+= 1
    }

    func selectedAgent(in rows: [AgentDefinition]) -> AgentDefinition? {
        rows.indices.contains(selectedIndex) ? rows[selectedIndex] : nil
    }

    /// Reset query + selection. Mode is preserved across opens via
    /// `prepareForOpen(defaultMode:)`.
    func reset() {
        query = ""
        selectedIndex = 0
        scrollToSelectionTick = 0
    }

    /// Called when the launcher opens. Resets the search and clamps the
    /// mode to the user's configured default.
    func prepareForOpen(defaultMode: AppConfig.LauncherMode) {
        query = ""
        selectedIndex = 0
        mode = defaultMode
        scrollToSelectionTick = 0
    }

    private func clampedIndex(rowCount: Int) -> Int {
        guard rowCount > 0 else { return 0 }
        return min(max(0, selectedIndex), rowCount - 1)
    }
}
