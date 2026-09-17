import SwiftUI

struct ProjectAgentSettingsView: View {
    @Binding var scripts: ProjectStartupScripts
    let agents: [AgentDefinition]
    let globalAgentID: String?
    let globalUseBypass: Bool
    /// Display name of the repo's `.alas/config.json` default agent, when it
    /// is installed and enabled. Drives the `.global` caption.
    var repoDefaultAgentName: String? = nil
    @Environment(\.theme) private var theme

    private var enabledAgents: [AgentDefinition] { agents.filter(\.isEnabled) }
    private var globalName: String {
        guard let globalAgentID else { return "None" }
        return agents.first { $0.id == globalAgentID }?.displayName ?? globalAgentID
    }
    private var selectedAgent: AgentDefinition? {
        agents.first { $0.id == scripts.worktreeAgentId }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DialogField(label: "Default agent") {
                Picker("Default agent", selection: $scripts.agentSelection) {
                    Text("Use global setting · \(globalName)").tag(ProjectAgentSelection.global)
                    Text("None").tag(ProjectAgentSelection.none)
                    ForEach(enabledAgents) { agent in
                        Text(agent.displayName).tag(ProjectAgentSelection.agent(agent.id))
                    }
                    if case .agent(let id) = scripts.agentSelection,
                       !enabledAgents.contains(where: { $0.id == id }) {
                        Text("\(selectedAgent?.displayName ?? id) (unavailable)")
                            .tag(ProjectAgentSelection.agent(id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                if scripts.agentSelection == .global {
                    if let repoDefaultAgentName {
                        Text("Repo default: \(repoDefaultAgentName) (from .alas/config.json). Falls back to Settings > Agents.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(theme.color("fg-dim"))
                    } else {
                        Text("Follows Settings > Agents. Currently \(globalName).")
                            .font(.system(size: 11.5))
                            .foregroundStyle(theme.color("fg-dim"))
                    }
                } else if case .agent = scripts.agentSelection, selectedAgent?.isEnabled != true {
                    Text("This agent is unavailable. Enable or install it in Settings > Agents, or choose another agent.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.color("fg-dim"))
                }
            }
            Text("Used for new worktrees and preselected when starting a new agent session in this repository. You can choose a different agent when launching.")
                .font(.system(size: 12))
                .foregroundStyle(theme.color("fg-dim"))
                .fixedSize(horizontal: false, vertical: true)
            if scripts.agentSelection != .none {
                Divider()
                if scripts.agentSelection == .global {
                    Text("Bypass permissions: \(globalUseBypass ? "on" : "off") · inherited from global settings")
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.color("fg-dim"))
                } else {
                    Toggle("Bypass permissions", isOn: $scripts.worktreeAgentUseBypassPermissions)
                        .toggleStyle(.checkbox)
                        .disabled(selectedAgent?.bypassPermissionsFlag == nil)
                    Text("Applies when the selected agent supports bypassing permissions.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.color("fg-dim"))
                }
            }
        }
    }
}
