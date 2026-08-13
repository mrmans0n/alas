import Foundation
import Observation

/// Payload for `.alasOpenAgentLauncher`. A nil `mode` means "start on the
/// user's configured default"; `isLocked` hides the surface picker so the
/// dialog can only launch on `mode`.
struct AgentLauncherRequest: Sendable {
    var mode: AppConfig.LauncherMode?
    var isLocked: Bool = false

    /// Open on the configured default surface, picker visible.
    static let picker = AgentLauncherRequest(mode: nil, isLocked: false)

    /// Open on `mode` with the picker hidden.
    static func locked(_ mode: AppConfig.LauncherMode) -> AgentLauncherRequest {
        AgentLauncherRequest(mode: mode, isLocked: true)
    }
}

@Observable
@MainActor
final class AgentLauncherModel {
    /// Which launch surface the dialog is currently targeting. Flipping
    /// this swaps which agent list is shown (terminal-capable vs.
    /// ACP-capable) and what Enter does.
    var mode: AppConfig.LauncherMode = .terminal {
        didSet { selectedIndex = 0
        scrollToSelectionTick &+= 1 }
    }
    /// When true the dialog was opened for one specific surface ("New Agent
    /// in Chat" and friends): the segmented picker is hidden and ⇥ no longer
    /// swaps modes.
    private(set) var isModeLocked: Bool = false
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
        guard rowCount > 0 else { selectedIndex = 0
        return }
        selectedIndex = max(0, clampedIndex(rowCount: rowCount) - 1)
        scrollToSelectionTick &+= 1
    }

    func moveSelectionDown(rowCount: Int) {
        guard rowCount > 0 else { selectedIndex = 0
        return }
        selectedIndex = min(rowCount - 1, clampedIndex(rowCount: rowCount) + 1)
        scrollToSelectionTick &+= 1
    }

    func selectedAgent(in rows: [AgentDefinition]) -> AgentDefinition? {
        rows.indices.contains(selectedIndex) ? rows[selectedIndex] : nil
    }

    /// Reset query + selection. Mode is preserved across opens via
    /// `prepareForOpen(defaultMode:locked:)`.
    func reset() {
        query = ""
        selectedIndex = 0
        scrollToSelectionTick = 0
        isModeLocked = false
    }

    /// Called when the launcher opens. Resets the search and clamps the
    /// mode to the requested surface (or the user's configured default).
    /// `locked` pins the dialog to that surface for this open.
    func prepareForOpen(defaultMode: AppConfig.LauncherMode, locked: Bool = false) {
        query = ""
        selectedIndex = 0
        mode = defaultMode
        scrollToSelectionTick = 0
        isModeLocked = locked
    }

    /// Cycle between terminal and ACP modes. `reverse` walks the other way
    /// (for shift-tab) — currently we only have two modes so it's the same
    /// flip either way, but the flag keeps the call site honest if more
    /// modes get added. No-op while the mode is locked.
    func toggleMode(reverse: Bool = false) {
        guard !isModeLocked else { return }
        let cycle = AppConfig.LauncherMode.allCases
        let i = cycle.firstIndex(of: mode) ?? 0
        let step = reverse ? -1 : 1
        mode = cycle[(i + step + cycle.count) % cycle.count]
    }

    /// Direct segment selection from the picker. Ignored while locked.
    func selectMode(_ newMode: AppConfig.LauncherMode) {
        guard !isModeLocked else { return }
        mode = newMode
    }

    private func clampedIndex(rowCount: Int) -> Int {
        guard rowCount > 0 else { return 0 }
        return min(max(0, selectedIndex), rowCount - 1)
    }
}
