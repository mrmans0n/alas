import SwiftUI

struct AgentsPane: View {
    @Bindable var state: AppState
    @Environment(\.theme) var theme
    var onNavigate: (SettingsSection) -> Void = { _ in }

    @State private var editing: EditTarget?
    @State private var piAdapterState: PiMCPAdapterInspector.State = .unknown

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
                .padding(.bottom, 18)

                SettingsGroup(title: "Worktree auto-launch") {
                    SettingsRow(
                        name: "Default agent",
                        desc: "Launched in the new worktree's terminal after the create script runs."
                    ) {
                        autoLaunchPicker
                    }
                    SettingsRow(
                        name: "Bypass permissions",
                        desc: "Append the agent's --bypass-permissions flag when auto-launching. Only applied when the selected agent supports it."
                    ) {
                        AlasToggle(on: state.bind(\.agents.worktreeAutoLaunch.useBypassPermissions))
                    }
                }

                SettingsGroup(title: "Harness") {
                    SettingsRow(name: "Expose Alas tools to agents",
                                desc: "Give chat agents an MCP server with Alas actions: open files, manage worktrees, and open reviews. Applies to newly connected sessions.") {
                        AlasToggle(on: state.bind(\.harness.exposeAlasMCP))
                    }
                    SettingsRow(
                        name: "Terminal / Harness",
                        desc: "Configure harness notifications and install hooks."
                    ) {
                        AlasButton(title: "Open Terminal Settings", style: .subtle) {
                            onNavigate(.terminal)
                        }
                    }
                    if piAdapterState != .installed {
                        SettingsRow(name: "Pi MCP adapter",
                                    desc: "Pi reaches MCP servers through the pi-mcp-adapter extension.") {
                            AlasButton(title: "Install pi-mcp-adapter", style: .subtle) {
                                Task {
                                    _ = await state.installPiMCPAdapter()
                                    piAdapterState = PiMCPAdapterInspector.state()
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 24)
        }
        .onAppear { piAdapterState = PiMCPAdapterInspector.state() }
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
                Label {
                    Text(agent.displayName)
                } icon: {
                    Image(nsImage: AgentLogoView.menuImage(for: agent, size: 14))
                }
                .tag(agent.id)
            }
        }
        .pickerStyle(.menu)
        .settingsDropdownFrame()
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
                    AgentLogoView(agent: agent)
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
