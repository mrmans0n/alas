import SwiftUI

struct AgentLauncherDialog: View {
    @Bindable var appState: AppState
    let selectedWorktree: () -> Worktree?
    @Environment(\.theme) private var theme
    @FocusState private var inputFocused: Bool

    var body: some View {
        if appState.isAgentLauncherOpen {
            ZStack {
                Color.black.opacity(0.42)
                    .ignoresSafeArea()
                    .onTapGesture { close() }

                VStack(spacing: 0) {
                    inputRow
                    modePicker
                    Divider().background(theme.color("line"))
                    rowList
                    footer
                }
                .frame(width: 460)
                .frame(maxHeight: 420)
                .background(theme.color("bg-1").opacity(0.92))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(theme.color("line"), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.5), radius: 30, x: 0, y: 20)
                .padding(.top, 70)
                .frame(maxHeight: .infinity, alignment: .top)
                .onTapGesture { }
                .onKeyPress { press in handleKey(press) }
            }
            .transition(.opacity.combined(with: .offset(y: -6)))
            .onAppear {
                requestInputFocus()
            }
            .onChange(of: appState.isAgentLauncherOpen) { _, isOpen in
                if isOpen { requestInputFocus() }
            }
        }
    }

    private var rows: [AgentDefinition] {
        appState.agentLauncher.rows(enabledAgents: appState.agentRegistry.enabled())
    }

    private var inputRow: some View {
        HStack(spacing: 8) {
            Icon(name: "sparkle", size: 12, color: theme.color("fg-faint"))
            TextField(placeholder, text: Bindable(appState.agentLauncher).query)
                .textFieldStyle(.plain)
                .focused($inputFocused)
                .font(.system(size: 14))
                .foregroundColor(theme.color("fg"))
                // Intercept tab BEFORE the TextField hands it to the
                // system focus traversal. Without this the key would
                // bounce out of the search field instead of toggling
                // mode.
                .onKeyPress(.tab) {
                    toggleMode(reverse: false)
                    return .handled
                }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// Cycle between terminal and ACP modes. `reverse` walks the other
    /// way (for shift-tab) — currently we only have two modes so it's
    /// the same flip either way, but the flag keeps the call site honest
    /// if more modes get added.
    private func toggleMode(reverse: Bool) {
        let cycle = AppConfig.LauncherMode.allCases
        let i = cycle.firstIndex(of: appState.agentLauncher.mode) ?? 0
        let step = reverse ? -1 : 1
        let next = (i + step + cycle.count) % cycle.count
        appState.agentLauncher.mode = cycle[next]
    }

    private var placeholder: String {
        switch appState.agentLauncher.mode {
        case .terminal: return "Launch agent in terminal…"
        case .acp:      return "Launch ACP chat session…"
        }
    }

    /// Segmented control: terminal vs ACP chat. Styled to match the
    /// existing right-pane tab bar (rounded inset, soft pill on the
    /// active segment).
    private var modePicker: some View {
        HStack(spacing: 0) {
            HStack(spacing: 2) {
                segment(.terminal, icon: "terminal", label: "Terminal")
                segment(.acp,      icon: "sparkle",  label: "Chat")
            }
            .padding(2)
            .background(theme.color("seg-container-bg"))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(theme.color("line"), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private func segment(_ mode: AppConfig.LauncherMode,
                         icon: String,
                         label: String) -> some View {
        let isOn = appState.agentLauncher.mode == mode
        return Button {
            appState.agentLauncher.mode = mode
        } label: {
            HStack(spacing: 5) {
                Icon(name: icon, size: 11,
                     color: isOn ? theme.color("fg") : theme.color("fg-muted"))
                Text(label)
                    .font(.system(size: 11.5, weight: isOn ? .semibold : .medium))
                    .foregroundColor(isOn ? theme.color("fg") : theme.color("fg-muted"))
            }
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(
                ZStack {
                    if isOn {
                        RoundedRectangle(cornerRadius: 4).fill(theme.color("bg-3"))
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.white.opacity(0.04), lineWidth: 1)
                            .blendMode(.plusLighter)
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .shadow(color: isOn ? Color.black.opacity(0.25) : .clear,
                    radius: 1, x: 0, y: 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var rowList: some View {
        let agents = rows
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if agents.isEmpty {
                        emptyState
                    } else {
                        ForEach(Array(agents.enumerated()), id: \.element.id) { idx, agent in
                            AgentLauncherRow(
                                agent: agent,
                                isSelected: idx == appState.agentLauncher.selectedIndex,
                                onTap: {
                                    appState.agentLauncher.selectedIndex = idx
                                    launch(agent)
                                },
                                onHover: { appState.agentLauncher.selectedIndex = idx }
                            )
                            .id(idx)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(minHeight: 180, maxHeight: 320)
            .onChange(of: appState.agentLauncher.scrollToSelectionTick) { _, _ in
                proxy.scrollTo(appState.agentLauncher.selectedIndex, anchor: .center)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Text(emptyTitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.color("fg-dim"))
            if appState.agentLauncher.mode == .acp,
               appState.agentLauncher.query.isEmpty {
                Text("Enable an ACP-capable agent in Settings → Agents.")
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("fg-faint"))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 160)
    }

    private var emptyTitle: String {
        switch appState.agentLauncher.mode {
        case .terminal: return "No enabled agents"
        case .acp:      return "No ACP-capable agents enabled"
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            label("↑↓ navigate")
            label("↵ launch")
            label("⇥ swap mode")
            label("esc close")
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(theme.color("bg-2").opacity(0.5))
        .overlay(
            Rectangle().fill(theme.color("line-soft")).frame(height: 0.5),
            alignment: .top
        )
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(theme.color("fg-faint"))
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .escape:
            close()
            return .handled
        case .upArrow:
            appState.agentLauncher.moveSelectionUp(rowCount: rows.count)
            return .handled
        case .downArrow:
            appState.agentLauncher.moveSelectionDown(rowCount: rows.count)
            return .handled
        case .return:
            if let agent = appState.agentLauncher.selectedAgent(in: rows) {
                launch(agent)
            }
            return .handled
        default:
            return .ignored
        }
    }

    private func launch(_ agent: AgentDefinition) {
        switch appState.agentLauncher.mode {
        case .terminal:
            guard let worktree = selectedWorktree() else { close()
            return }
            _ = try? appState.openAgentTerminalTab(for: worktree, agentId: agent.id)
        case .acp:
            appState.openNewACPSession(agentID: agent.id)
        }
        close()
    }

    private func close() {
        appState.agentLauncher.reset()
        appState.isAgentLauncherOpen = false
    }

    private func requestInputFocus() {
        inputFocused = false
        DispatchQueue.main.async {
            inputFocused = true
            DispatchQueue.main.async {
                inputFocused = true
            }
        }
    }
}

private struct AgentLauncherRow: View {
    let agent: AgentDefinition
    let isSelected: Bool
    let onTap: () -> Void
    let onHover: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            AgentLogoView(agent: agent)
            Text(agent.displayName)
                .font(.system(size: 13))
                .foregroundColor(theme.color("fg"))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(isSelected ? theme.color("bg-3") : .clear)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .onHover { hovering in if hovering { onHover() } }
    }
}
