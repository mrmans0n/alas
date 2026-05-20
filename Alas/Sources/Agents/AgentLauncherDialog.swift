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
                appState.agentLauncher.reset()
                requestInputFocus()
            }
            .onChange(of: appState.isAgentLauncherOpen) { _, isOpen in
                if isOpen { requestInputFocus() }
            }
        }
    }

    private var inputRow: some View {
        HStack(spacing: 8) {
            Icon(name: "sparkle", size: 12, color: theme.color("fg-faint"))
            TextField("Launch agent…", text: Bindable(appState.agentLauncher).query)
                .textFieldStyle(.plain)
                .focused($inputFocused)
                .font(.system(size: 14))
                .foregroundColor(theme.color("fg"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var rowList: some View {
        let rows = appState.agentLauncher.rows(agents: appState.agentRegistry.enabled())
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if rows.isEmpty {
                        emptyState
                    } else {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { idx, agent in
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
            .frame(minHeight: 180, maxHeight: 340)
            .onChange(of: appState.agentLauncher.scrollToSelectionTick) { _, _ in
                proxy.scrollTo(appState.agentLauncher.selectedIndex, anchor: .center)
            }
        }
    }

    private var emptyState: some View {
        Text("No enabled agents")
            .font(.system(size: 12))
            .foregroundColor(theme.color("fg-dim"))
            .frame(maxWidth: .infinity, minHeight: 160)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            label("↑↓ navigate")
            label("↵ launch")
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
        let rows = appState.agentLauncher.rows(agents: appState.agentRegistry.enabled())
        switch press.key {
        case .escape:
            close()
            return .handled
        case .upArrow:
            appState.agentLauncher.moveSelectionUp(in: rows)
            return .handled
        case .downArrow:
            appState.agentLauncher.moveSelectionDown(in: rows)
            return .handled
        case .return:
            appState.agentLauncher.clampSelection(in: rows)
            if let agent = appState.agentLauncher.selectedAgent(in: rows) {
                launch(agent)
            }
            return .handled
        default:
            return .ignored
        }
    }

    private func launch(_ agent: AgentDefinition) {
        guard let worktree = selectedWorktree() else {
            close()
            return
        }
        _ = try? appState.openAgentTerminalTab(for: worktree, agentId: agent.id)
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
            logo
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
        .onTapGesture(perform: onTap)
        .onHover { hovering in
            if hovering { onHover() }
        }
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
}
