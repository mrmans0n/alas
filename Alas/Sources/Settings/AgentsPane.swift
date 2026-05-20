import SwiftUI

struct AgentsPane: View {
    @Bindable var state: AppState
    @Environment(\.theme) var theme
    var onNavigate: (SettingsSection) -> Void = { _ in }

    @State private var editing: EditTarget?

    /// The sheet's content depends on what was clicked: existing agent (by
    /// id) or a brand-new custom (`.new`).
    enum EditTarget: Identifiable {
        case existing(String)
        case new
        var id: String {
            switch self {
            case .existing(let id): return id
            case .new: return "__new__"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Agents").font(.system(size: 18, weight: .semibold))
                Text("CLI agents Alas can detect, launch on worktree create, and use for AI commit messages.")
                    .font(.system(size: 12.5)).foregroundColor(theme.color("fg-dim"))
                    .padding(.bottom, 12)

                SettingsGroup(title: "Worktree auto-launch") {
                    SettingsRow(
                        name: "Default agent",
                        desc: "Launched in the new worktree's terminal after the create script runs."
                    ) {
                        autoLaunchPicker
                    }
                    SettingsRow(
                        name: "Bypass permissions",
                        desc: "Append the agent's --bypass-permissions flag when auto-launching."
                    ) {
                        AlasToggle(on: state.bind(\.agents.worktreeAutoLaunch.useBypassPermissions))
                            .disabled(!autoLaunchSupportsBypass)
                            .opacity(autoLaunchSupportsBypass ? 1 : 0.4)
                    }
                }

                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("AVAILABLE AGENTS")
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(0.6)
                            .foregroundColor(theme.color("fg-dim"))
                        Spacer()
                        AlasButton(title: "Add custom agent", style: .subtle) {
                            editing = .new
                        }
                    }
                    .padding(.bottom, 14)
                    cardGrid
                }
                .padding(.vertical, 18)

                SettingsGroup(title: "Harness") {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Terminal / Harness")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(theme.color("fg"))
                            Text("Configure harness notifications and install hooks.")
                                .font(.system(size: 11.5))
                                .foregroundColor(theme.color("fg-dim"))
                                .lineLimit(2)
                        }
                        .frame(width: 240, alignment: .leading)
                        .padding(.top, 4)
                        VStack(alignment: .leading, spacing: 6) {
                            AlasButton(title: "Open Terminal Settings", style: .subtle) {
                                onNavigate(.terminal)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 10)
                    .overlay(Divider().opacity(0.5), alignment: .top)
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 24)
        }
        .sheet(item: $editing) { target in
            AgentEditView(
                state: state,
                target: target,
                onDismiss: { editing = nil }
            )
        }
    }

    private var autoLaunchPicker: some View {
        Picker("", selection: Binding(
            get: { state.config.agents.worktreeAutoLaunch.agentId ?? "none" },
            set: { newValue in
                state.config.agents.worktreeAutoLaunch.agentId =
                    (newValue == "none") ? nil : newValue
                state.saveConfig()
            }
        )) {
            Text("None").tag("none")
            ForEach(state.agentRegistry.enabled()) { agent in
                Text(agent.displayName).tag(agent.id)
            }
        }
        .pickerStyle(.menu)
        .frame(width: 240)
    }

    private var autoLaunchSupportsBypass: Bool {
        guard let id = state.config.agents.worktreeAutoLaunch.agentId,
              let agent = state.agent(id: id) else { return false }
        return agent.bypassPermissionsFlag != nil
    }

    private var cardGrid: some View {
        let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(state.agentRegistry.agents) { agent in
                AgentCard(
                    agent: agent,
                    installed: installedIds.contains(agent.id),
                    onTap: { editing = .existing(agent.id) },
                    onToggle: { isOn in toggleEnabled(agent: agent, isOn: isOn) }
                )
            }
        }
    }

    private var installedIds: Set<String> {
        Set(state.agentRegistry.installed().map(\.id))
    }

    private func toggleEnabled(agent: AgentDefinition, isOn: Bool) {
        if agent.isBuiltin {
            var entry = state.config.agents.builtinState[agent.id]
                ?? BuiltinAgentState(isEnabled: true, binaryOverride: nil)
            entry.isEnabled = isOn
            state.config.agents.builtinState[agent.id] = entry
        } else if let idx = state.config.agents.custom.firstIndex(where: { $0.id == agent.id }) {
            state.config.agents.custom[idx].isEnabled = isOn
        }
        state.saveConfig()
        state.rescanAgents()
    }
}

private struct AgentCard: View {
    let agent: AgentDefinition
    let installed: Bool
    let onTap: () -> Void
    let onToggle: (Bool) -> Void
    @Environment(\.theme) var theme

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    logo
                    Text(agent.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.color("fg"))
                    statusPill
                    Spacer(minLength: 0)
                    AlasToggle(on: Binding(
                        get: { agent.isEnabled },
                        set: { onToggle($0) }
                    ))
                    .disabled(!installed)
                    .opacity(installed ? 1 : 0.4)
                }
                Text(agent.resolvedBinary)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.color("fg-dim"))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.color("bg-2"))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(theme.color("line-soft"), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var logo: some View {
        if let asset = agent.builtinLogoAssetName, NSImage(named: asset) != nil {
            Image(asset)
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
        } else {
            Icon(name: "sparkle", size: 14, color: theme.color("fg-muted"))
                .frame(width: 16, height: 16)
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        if !agent.isBuiltin {
            pill(text: "custom", fg: theme.color("accent"))
        } else if installed {
            pill(text: "installed", fg: theme.color("add"))
        } else {
            pill(text: "missing", fg: theme.color("warn"))
        }
    }

    private func pill(text: String, fg: Color) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundColor(fg)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(fg.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
