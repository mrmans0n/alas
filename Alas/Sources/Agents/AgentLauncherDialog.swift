import SwiftUI

struct AgentLauncherDialog: View {
    @Bindable var appState: AppState
    let selectedWorktree: () -> Worktree?
    @Environment(\.theme) private var theme
    @FocusState private var inputFocused: Bool
    @State private var chatAgent: AgentDefinition?
    @State private var discoveryModel: ACPSessionDiscoveryModel?
    @State private var selectedSessionIndex = 0
    @State private var loadingMore = false

    var body: some View {
        Group {
            if appState.isAgentLauncherOpen {
                ZStack {
                    Color.black.opacity(0.42)
                        .ignoresSafeArea()
                        .onTapGesture { close() }

                    VStack(spacing: 0) {
                        inputRow
                        if showsModePicker {
                            modePicker
                        }
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
                .onChange(of: appState.agentLauncher.query) {
                    selectedSessionIndex = 0
                }
            }
        }
        .onChange(of: appState.isAgentLauncherOpen) { _, isOpen in
            if isOpen {
                requestInputFocus()
            } else {
                resetSessionBrowser()
            }
        }
    }

    private var rows: [AgentDefinition] {
        appState.agentLauncher.rows(enabledAgents: appState.agentRegistry.enabled())
    }

    /// Hidden while browsing an agent's sessions, and while the launcher is
    /// pinned to one surface (opened from "New Agent in Chat"/"in Terminal").
    private var showsModePicker: Bool {
        chatAgent == nil && !appState.agentLauncher.isModeLocked
    }

    private var inputRow: some View {
        HStack(spacing: 8) {
            if let chatAgent {
                Button {
                    backToAgents()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("Back to agents")
                AgentLogoView(agent: chatAgent).frame(width: 16, height: 16)
            } else {
                Icon(name: "sparkle", size: 12, color: theme.color("fg-faint"))
            }
            TextField(placeholder, text: Bindable(appState.agentLauncher).query)
                .textFieldStyle(.plain)
                .focused($inputFocused)
                .font(.system(size: 14))
                .foregroundColor(theme.color("fg"))
                // Intercept tab BEFORE the TextField hands it to the
                // system focus traversal. Without this the key would
                // bounce out of the search field instead of toggling
                // mode. Still swallowed while the mode is locked — the
                // alternative is focus escaping the field on ⇥.
                .onKeyPress(.tab) {
                    appState.agentLauncher.toggleMode()
                    return .handled
                }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var placeholder: String {
        switch appState.agentLauncher.mode {
        case .terminal: return "Launch agent in terminal…"
        case .acp:
            if let chatAgent { return "Search \(chatAgent.displayName) sessions…" }
            return "Launch ACP chat session…"
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
            appState.agentLauncher.selectMode(mode)
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

    @ViewBuilder
    private var rowList: some View {
        if let chatAgent {
            sessionRowList(agent: chatAgent)
        } else {
            agentRowList
        }
    }

    private var agentRowList: some View {
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
                            // Data-based id, not the row position: a positional
                            // id freezes LazyVStack rows against query filtering.
                            .id(agent.id)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(minHeight: 180, maxHeight: 320)
            .onChange(of: appState.agentLauncher.scrollToSelectionTick) { _, _ in
                let index = appState.agentLauncher.selectedIndex
                if agents.indices.contains(index) {
                    proxy.scrollTo(agents[index].id, anchor: .center)
                }
            }
        }
    }

    private func sessionRowList(agent: AgentDefinition) -> some View {
        let discovered = filteredDiscoveredSessions
        let capabilities = discoveryModel?.capabilities
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                AgentSessionLauncherRow(
                    title: "New chat",
                    detail: "Start a new \(agent.displayName) session",
                    systemImage: "plus",
                    isSelected: selectedSessionIndex == 0,
                    isEnabled: true,
                    onTap: launchNewChat
                )

                sessionDiscoveryState(agent: agent, discovered: discovered, capabilities: capabilities)
            }
            .padding(.vertical, 4)
        }
        .frame(minHeight: 180, maxHeight: 320)
    }

    @ViewBuilder
    private func sessionDiscoveryState(
        agent: AgentDefinition,
        discovered: [ACPDiscoveredSession],
        capabilities: ACPSessionDiscoveryCapabilities?
    ) -> some View {
        switch discoveryModel?.phase ?? .idle {
        case .idle, .loading:
            launcherStatusRow("Loading agent sessions…", progress: true)
        case .unsupported:
            launcherStatusRow("This agent does not expose session history.")
        case .failed(let message):
            HStack(spacing: 8) {
                Text(message).lineLimit(2)
                Spacer()
                Button("Retry") { startDiscovery(for: agent) }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.color("accent"))
            }
            .font(.system(size: 11))
            .foregroundStyle(theme.color("fg-faint"))
            .padding(.horizontal, 14)
            .frame(minHeight: 38)
        case .ready:
            if discovered.isEmpty {
                launcherStatusRow("No agent sessions for this worktree.")
            } else {
                ForEach(Array(discovered.enumerated()), id: \.element.id) { index, item in
                    let canOpen = item.isAlreadyInAlas
                        || (capabilities?.canOpenRemoteSession == true && item.isCompatibleWithAlas)
                    AgentSessionLauncherRow(
                        title: item.title,
                        detail: sessionDetail(item, canOpen: canOpen),
                        systemImage: item.isAlreadyInAlas ? "checkmark.circle" : "clock",
                        isSelected: selectedSessionIndex == index + 1,
                        isEnabled: canOpen,
                        onTap: { openDiscoveredSession(item) }
                    )
                    .onHover { hovering in
                        if hovering { selectedSessionIndex = index + 1 }
                    }
                }
            }
            if discoveryModel?.canLoadMore == true {
                Button {
                    loadMoreSessions()
                } label: {
                    HStack(spacing: 7) {
                        if loadingMore { ProgressView().controlSize(.small) }
                        Text(loadingMore ? "Loading…" : "Load more")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.color("accent"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                }
                .buttonStyle(.plain)
                .disabled(loadingMore)
            }
            if let paginationError = discoveryModel?.paginationError {
                launcherStatusRow(paginationError)
            }
        }
    }

    private func launcherStatusRow(_ text: String, progress: Bool = false) -> some View {
        HStack(spacing: 8) {
            if progress { ProgressView().controlSize(.small) }
            Text(text)
        }
        .font(.system(size: 11))
        .foregroundStyle(theme.color("fg-faint"))
        .padding(.horizontal, 14)
        .frame(minHeight: 38)
    }

    private var filteredDiscoveredSessions: [ACPDiscoveredSession] {
        guard let sessions = discoveryModel?.sessions else { return [] }
        let query = appState.agentLauncher.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sessions }
        return sessions.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    private func sessionDetail(_ session: ACPDiscoveredSession, canOpen: Bool) -> String {
        if session.isAlreadyInAlas { return "Already in Alas" }
        if !session.isCompatibleWithAlas { return "Uses unsupported additional folders" }
        if !canOpen { return "Browsing only" }
        if let updatedAt = session.updatedAt {
            return updatedAt.formatted(.relative(presentation: .named))
        }
        return "Agent history"
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
            label(chatAgent == nil ? "↵ select" : "↵ open")
            if showsModePicker { label("⇥ swap mode") }
            label(chatAgent == nil ? "esc close" : "esc back")
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
        if chatAgent != nil {
            return handleSessionKey(press)
        }
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

    private func handleSessionKey(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .escape, .leftArrow:
            backToAgents()
            return .handled
        case .upArrow:
            selectedSessionIndex = max(0, selectedSessionIndex - 1)
            return .handled
        case .downArrow:
            selectedSessionIndex = min(filteredDiscoveredSessions.count, selectedSessionIndex + 1)
            return .handled
        case .return:
            if selectedSessionIndex == 0 {
                launchNewChat()
            } else {
                let index = selectedSessionIndex - 1
                if filteredDiscoveredSessions.indices.contains(index) {
                    openDiscoveredSession(filteredDiscoveredSessions[index])
                }
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
            Task { @MainActor in
                _ = try? await appState.openAgentTerminalTabPreparingRemoteZmxIfNeeded(for: worktree, agentId: agent.id)
            }
        case .acp:
            beginSessionBrowser(for: agent)
            return
        }
        close()
    }

    private func beginSessionBrowser(for agent: AgentDefinition) {
        guard let worktree = selectedWorktree(),
              appState.acpManager(for: worktree) != nil
        else {
            appState.openNewACPSession(agentID: agent.id)
            close()
            return
        }
        chatAgent = agent
        appState.agentLauncher.query = ""
        selectedSessionIndex = 0
        startDiscovery(for: agent)
        requestInputFocus()
    }

    private func startDiscovery(for agent: AgentDefinition) {
        guard let worktree = selectedWorktree(),
              let manager = appState.acpManager(for: worktree)
        else { return }
        let prior = discoveryModel
        let model = ACPSessionDiscoveryModel()
        discoveryModel = model
        Task {
            await prior?.stop()
            await model.start(manager: manager, agentId: agent.id)
        }
    }

    private func loadMoreSessions() {
        guard let discoveryModel, !loadingMore else { return }
        loadingMore = true
        Task {
            defer { loadingMore = false }
            try? await discoveryModel.loadMore()
        }
    }

    private func launchNewChat() {
        guard let chatAgent else { return }
        appState.openNewACPSession(agentID: chatAgent.id)
        close()
    }

    private func openDiscoveredSession(_ session: ACPDiscoveredSession) {
        guard let capabilities = discoveryModel?.capabilities else { return }
        Task {
            guard await appState.openDiscoveredACPSession(
                session,
                capabilities: capabilities
            ) else { return }
            close()
        }
    }

    private func backToAgents() {
        resetSessionBrowser()
        appState.agentLauncher.query = ""
        requestInputFocus()
    }

    private func close() {
        resetSessionBrowser()
        appState.agentLauncher.reset()
        appState.isAgentLauncherOpen = false
    }

    private func resetSessionBrowser() {
        let prior = discoveryModel
        discoveryModel = nil
        chatAgent = nil
        selectedSessionIndex = 0
        loadingMore = false
        Task { await prior?.stop() }
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

private struct AgentSessionLauncherRow: View {
    let title: String
    let detail: String
    let systemImage: String
    let isSelected: Bool
    let isEnabled: Bool
    let onTap: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 12))
                    .foregroundStyle(isEnabled ? theme.color("fg-muted") : theme.color("fg-faint"))
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(isEnabled ? theme.color("fg") : theme.color("fg-faint"))
                        .lineLimit(1)
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.color("fg-faint"))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(isSelected ? theme.color("bg-3") : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
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
