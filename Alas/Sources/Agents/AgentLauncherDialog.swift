import SwiftUI

/// A ⌘⇥-style switcher: a centered, content-width panel with a horizontal
/// strip of large agent icons. ⌘⌥T shows Terminal/Chat picker above the
/// strip; ⌘⌥⇧T and ⌘⌥⇧C lock the mode and show a static label instead.
/// Selecting an agent in Chat mode drops a vertical session list under a
/// shrunk, dimmed strip rather than replacing the panel — ←→ keeps roaming
/// between agents from inside that second stage.
struct AgentLauncherDialog: View {
    @Bindable var appState: AppState
    let selectedWorktree: () -> Worktree?
    var selectedWorkspaceCheckout: () -> WorkspaceCheckout? = { nil }
    @Environment(\.theme) private var theme
    @FocusState private var inputFocused: Bool
    @State private var chatAgent: AgentDefinition?
    @State private var discoveryModel: ACPSessionDiscoveryModel?
    @State private var discoveryOwner: SessionOwnerID?
    @State private var selectedSessionIndex = 0
    @State private var loadingMore = false
    @State private var deletionRequest: ACPSessionDeletionRequest?
    @State private var deletionError: String?

    private let agentTileSize: CGFloat = 64
    private let sessionStageTileSize: CGFloat = 36
    private let tileOuterPadding: CGFloat = 8   // matches AgentSwitcherTile's own padding
    private let tileSpacing: CGFloat = 10       // matches the strip HStack's spacing
    private let stripHorizontalInset: CGFloat = 20
    private let minVisibleTileCount = 3
    private let maxPanelWidth: CGFloat = 620

    var body: some View {
        Group {
            if appState.isAgentLauncherOpen {
                ZStack {
                    Color.black.opacity(0.42)
                        .ignoresSafeArea()
                        .onTapGesture { close() }

                    VStack(spacing: 0) {
                        header
                        agentStrip
                        captionArea
                        if let chatAgent {
                            Divider()
                                .background(theme.color("line"))
                                .padding(.horizontal, 18)
                                .padding(.top, 10)
                            sessionRowList(agent: chatAgent)
                        }
                        hintLine
                            .padding(.top, 10)
                            .padding(.bottom, 16)
                    }
                    .frame(width: panelWidth)
                    .background(hiddenQueryField)
                    // Theme tint over a real system material, not a flat
                    // fill — gives the panel the same frosted-glass read as
                    // the actual ⌘⇥ switcher instead of a solid card.
                    .background(theme.color("bg-1").opacity(0.78))
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(theme.color("line"), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.5), radius: 30, x: 0, y: 20)
                    .overlay(alignment: .topLeading) {
                        if chatAgent != nil {
                            backButton.padding(10)
                        }
                    }
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
            if !isOpen { resetSessionBrowser() }
        }
        // Fires on every open request, including one that arrives while the
        // launcher is already visible (⌘⌥⇧T while browsing an agent's
        // sessions). That case never flips `isAgentLauncherOpen`, so without
        // this the session browser would outlive the surface it belongs to
        // and ↵ would still start a chat under a Terminal lock.
        .onChange(of: appState.agentLauncher.openTick) { _, _ in
            resetSessionBrowser()
            requestInputFocus()
        }
        .task(id: selectedAgentAvailabilityTaskID) {
            guard appState.isAgentLauncherOpen else { return }
            await loadSelectedAgentAvailability()
        }
        .confirmationDialog(
            deletionRequest?.title ?? "Delete session history?",
            isPresented: Binding(
                get: { deletionRequest != nil },
                set: { if !$0 { deletionRequest = nil } }
            ),
            presenting: deletionRequest
        ) { request in
            switch request.kind {
            case .localOnly:
                Button("Remove from Alas", role: .destructive) {
                    performDeletion(request)
                }
            case .agentHistory:
                Button("Delete agent-side history", role: .destructive) {
                    performDeletion(request)
                }
                if request.session.localSessionId != nil {
                    Button("Delete agent-side history and remove from Alas", role: .destructive) {
                        performDeletion(request, removeLocalHistory: true)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text(request.message)
        }
    }

    private var preferredAgentID: String? {
        selectedWorktree().flatMap {
            appState.defaultAgentID(projectId: $0.projectId, worktreeRoot: $0.path)
        }
    }

    private var rows: [AgentDefinition] {
        let availableAgents = selectedAgentAvailability?.agents ?? appState.agentRegistry.enabled()
        return appState.agentLauncher.rows(
            enabledAgents: availableAgents,
            preferredAgentID: preferredAgentID
        )
    }

    /// The current mode's agent count, ignoring the live query. Used only
    /// for sizing — `rows` can't be used here because its query also
    /// drives the session-search field once `chatAgent` is set, and the
    /// panel must not resize while someone types a session search.
    private var agentPoolCount: Int {
        let availableAgents = selectedAgentAvailability?.agents ?? appState.agentRegistry.enabled()
        return appState.agentLauncher.pool(enabledAgents: availableAgents).count
    }

    /// One fixed width for the whole panel, shared by both the agent strip
    /// and the session list beneath it, so entering/leaving Chat mode's
    /// session browser never resizes the dialog. Wide enough for at least
    /// `minVisibleTileCount` full-size tiles, capped at `maxPanelWidth`.
    private var panelWidth: CGFloat {
        min(max(stripWidth(count: agentPoolCount), stripWidth(count: minVisibleTileCount)), maxPanelWidth)
    }

    private func stripWidth(count: Int) -> CGFloat {
        guard count > 0 else { return stripWidth(count: 1) }
        let tileOuter = agentTileSize + tileOuterPadding * 2
        let tiles = CGFloat(count) * tileOuter
        let gaps = CGFloat(count - 1) * tileSpacing
        return tiles + gaps + stripHorizontalInset * 2
    }

    private var selectedAgentAvailability: AgentAvailabilityState? {
        if let checkout = selectedWorkspaceCheckout() {
            return appState.agentAvailability(
                worktreePath: URL(fileURLWithPath: checkout.rootPath),
                executionTarget: checkout.executionLocation.agentExecutionTarget
            )
        }
        return selectedWorktree().map { appState.agentAvailability(for: $0) }
    }

    private var selectedAgentAvailabilityTaskID: String {
        guard appState.isAgentLauncherOpen else { return "closed" }
        if let checkout = selectedWorkspaceCheckout() {
            let root = URL(fileURLWithPath: checkout.rootPath)
            let generation = appState.agentAvailabilityGeneration(
                worktreePath: root,
                executionTarget: checkout.executionLocation.agentExecutionTarget
            )
            return "\(checkout.executionLocation.identityComponent)\u{0000}\(root.path)\u{0000}\(generation)"
        }
        guard let worktree = selectedWorktree() else { return "no-worktree" }
        return "\(worktree.id)\u{0000}\(appState.agentExecutionTarget(for: worktree))\u{0000}\(appState.agentAvailabilityGeneration(for: worktree))"
    }

    private func loadSelectedAgentAvailability(force: Bool = false) async {
        if let checkout = selectedWorkspaceCheckout() {
            await appState.loadAgentAvailability(
                worktreePath: URL(fileURLWithPath: checkout.rootPath),
                executionTarget: checkout.executionLocation.agentExecutionTarget,
                force: force
            )
            return
        }
        guard let worktree = selectedWorktree() else { return }
        await appState.loadAgentAvailability(for: worktree, force: force)
    }

    /// Hidden while browsing an agent's sessions, and while the launcher is
    /// pinned to one surface (opened from "New Agent in Chat"/"in Terminal").
    private var showsModePicker: Bool {
        chatAgent == nil && !appState.agentLauncher.isModeLocked
    }

    /// Zero-size focused text field: there is no visible search box in the
    /// switcher layout, but keystrokes still need a first responder. Typed
    /// text surfaces in `captionArea`; ⇥ still swaps mode from here so the
    /// intercept happens before SwiftUI hands the key to focus traversal.
    private var hiddenQueryField: some View {
        TextField("", text: Bindable(appState.agentLauncher).query)
            .textFieldStyle(.plain)
            .focused($inputFocused)
            .frame(width: 0, height: 0)
            .opacity(0.01)
            .accessibilityHidden(true)
            .onKeyPress(.tab) {
                if showsModePicker { appState.agentLauncher.toggleMode() }
                return .handled
            }
    }

    @ViewBuilder
    private var header: some View {
        if chatAgent == nil {
            if appState.agentLauncher.isModeLocked {
                lockedModeLabel
            } else {
                modePicker
            }
        }
    }

    private var lockedModeLabel: some View {
        HStack(spacing: 6) {
            Icon(
                name: appState.agentLauncher.mode == .terminal ? "terminal" : "sparkle",
                size: 11,
                color: theme.color("fg-muted")
            )
            Text(appState.agentLauncher.mode == .terminal ? "Terminal" : "Chat")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(theme.color("fg-muted"))
        }
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    /// Segmented control: terminal vs ACP chat. Styled to match the
    /// existing right-pane tab bar (rounded inset, soft pill on the
    /// active segment).
    private var modePicker: some View {
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
        .padding(.top, 18)
        .padding(.bottom, 12)
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

    /// Single source of truth for what the horizontal strip (and the
    /// caption beneath it) should show: SSH availability is still loading,
    /// failed to load, resolved to no agents, or resolved to a pickable list.
    private enum AgentStripState {
        case loading
        case failed(String)
        case empty
        case list([AgentDefinition])
    }

    private var agentStripState: AgentStripState {
        if let availability = selectedAgentAvailability {
            if case .loading = availability { return .loading }
            if case .failed(let message) = availability { return .failed(message) }
        }
        let agents = stageAgents
        return agents.isEmpty ? .empty : .list(agents)
    }

    /// Agents to render in the strip and to roam between with ←→. Stage 1
    /// uses the query-filtered `rows` (typing narrows the strip). Stage 2
    /// must not: its query field is reused to search sessions instead, so
    /// filtering agents by it too could empty the strip — and break
    /// `moveToNeighborAgent` — while a session search still matches
    /// sessions just fine.
    private var stageAgents: [AgentDefinition] {
        guard chatAgent != nil else { return rows }
        let availableAgents = selectedAgentAvailability?.agents ?? appState.agentRegistry.enabled()
        return appState.agentLauncher.orderedPool(enabledAgents: availableAgents, preferredAgentID: preferredAgentID)
    }

    @ViewBuilder
    private var agentStrip: some View {
        switch agentStripState {
        case .loading:
            stripStatus("Checking agents on SSH host…", progress: true)
        case .failed(let message):
            stripFailedStatus(message)
        case .empty:
            stripEmptyState
        case .list(let agents):
            agentTileScroller(agents)
        }
    }

    private func agentTileScroller(_ agents: [AgentDefinition]) -> some View {
        let tileSize = chatAgent == nil ? agentTileSize : sessionStageTileSize
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(agents.enumerated()), id: \.element.id) { idx, agent in
                        // Derived from `chatAgent.id`, not `selectedIndex`,
                        // while browsing sessions: entering/switching agents
                        // clears `query`, whose `didSet` resets
                        // `selectedIndex` to 0 — that would highlight the
                        // first tile instead of the active agent.
                        let isSelected = chatAgent.map { $0.id == agent.id } ?? (idx == appState.agentLauncher.selectedIndex)
                        AgentSwitcherTile(
                            label: agent.displayName,
                            size: tileSize,
                            isSelected: isSelected,
                            isDimmed: chatAgent != nil && chatAgent?.id != agent.id,
                            onTap: {
                                if chatAgent == nil {
                                    appState.agentLauncher.selectedIndex = idx
                                    launch(agent)
                                } else if agent.id != chatAgent?.id {
                                    switchChatAgent(to: agent)
                                }
                            },
                            onHover: {
                                if chatAgent == nil { appState.agentLauncher.selectedIndex = idx }
                            }
                        ) {
                            switcherLogo(for: agent, size: tileSize)
                        }
                        .id(agent.id)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 4)
                // `minWidth` (not just the ScrollView's own frame) so a
                // strip narrower than the panel centers instead of hugging
                // the leading edge — a horizontal ScrollView otherwise
                // sizes its content to its own intrinsic width regardless
                // of how wide the viewport around it is.
                .frame(minWidth: panelWidth, alignment: .center)
            }
            .frame(width: panelWidth)
            .onChange(of: appState.agentLauncher.scrollToSelectionTick) { _, _ in
                let index = appState.agentLauncher.selectedIndex
                if agents.indices.contains(index) {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(agents[index].id, anchor: .center)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func switcherLogo(for agent: AgentDefinition, size: CGFloat) -> some View {
        switch AgentLogoPresentation.resolve(for: agent) {
        case .asset:
            AgentLogoView(agent: agent, size: size)
        case .fallbackSymbol:
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(theme.color("bg-2"))
                .frame(width: size, height: size)
                .overlay(
                    Icon(name: "sparkle", size: size * 0.42, color: theme.color("fg-muted"))
                )
        }
    }

    private func stripStatus(_ text: String, progress: Bool = false) -> some View {
        HStack(spacing: 8) {
            if progress { ProgressView().controlSize(.small) }
            Text(text)
        }
        .font(.system(size: 12))
        .foregroundStyle(theme.color("fg-faint"))
        .frame(maxWidth: .infinity, minHeight: 88)
    }

    private func stripFailedStatus(_ message: String) -> some View {
        VStack(spacing: 6) {
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(theme.color("fg-faint"))
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Button("Retry") {
                Task { await loadSelectedAgentAvailability(force: true) }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(theme.color("accent"))
        }
        .frame(maxWidth: .infinity, minHeight: 88)
        .padding(.horizontal, 20)
    }

    private var stripEmptyState: some View {
        VStack(spacing: 4) {
            Text(emptyTitle)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.color("fg-dim"))
            if appState.agentLauncher.mode == .acp,
               appState.agentLauncher.query.isEmpty {
                Text("Enable an ACP-capable agent in Settings → Agents.")
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("fg-faint"))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 88)
    }

    /// Query-aware: a genuinely empty agent list ("No enabled agents") reads
    /// very differently from a query that just matched nothing ("No agents
    /// match") — the latter needs to tell the user their filter, not the
    /// registry, is why the strip is empty.
    private var emptyTitle: String {
        // `agentPoolCount`, not query emptiness: a genuinely empty mode
        // pool needs the actionable "enable an agent" message regardless
        // of what's typed, since clearing the query can't reveal an agent
        // that was never in the pool to begin with.
        guard agentPoolCount == 0 else { return "No agents match" }
        switch appState.agentLauncher.mode {
        case .terminal: return "No enabled agents"
        case .acp:      return "No ACP-capable agents enabled"
        }
    }

    /// Below the strip: the selected agent's name (or the live query, while
    /// typing) plus a status line. Also shown over the empty strip state
    /// while a query is active — the query field itself is invisible, so
    /// without this the user's typed text (and the reason the strip is
    /// empty) would disappear entirely. Skipped for loading/failed, which
    /// already carry their own inline status text, and for a genuinely
    /// empty (no query) agent list, which needs no caption above it.
    @ViewBuilder
    private var captionArea: some View {
        if let chatAgent {
            sessionCaption(for: chatAgent)
        } else if case .list = agentStripState {
            stage1Caption
        } else if case .empty = agentStripState, !appState.agentLauncher.query.isEmpty {
            stage1Caption
        }
    }

    private var stage1Caption: some View {
        VStack(spacing: 3) {
            Text(stage1Title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(
                    appState.agentLauncher.query.isEmpty ? theme.color("fg") : theme.color("accent")
                )
                .lineLimit(1)
            if let subtitle = stage1Subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("fg-faint"))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 2)
    }

    private var stage1Title: String {
        let query = appState.agentLauncher.query
        if !query.isEmpty { return query }
        return appState.agentLauncher.selectedAgent(in: rows)?.displayName ?? ""
    }

    private var stage1Subtitle: String? {
        guard appState.agentLauncher.query.isEmpty,
              let agent = appState.agentLauncher.selectedAgent(in: rows)
        else { return nil }
        if agent.id == preferredAgentID { return "Default for this worktree" }
        switch appState.agentLauncher.mode {
        case .terminal: return "Terminal"
        case .acp: return "Chat"
        }
    }

    private func sessionCaption(for agent: AgentDefinition) -> some View {
        let query = appState.agentLauncher.query
        return VStack(spacing: 3) {
            Text(query.isEmpty ? agent.displayName : query)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(query.isEmpty ? theme.color("fg") : theme.color("accent"))
                .lineLimit(1)
            Text(sessionCaptionSubtitle)
                .font(.system(size: 11))
                .foregroundColor(theme.color("fg-faint"))
                .lineLimit(1)
        }
        .padding(.horizontal, 20)
        .padding(.top, 2)
    }

    private var sessionCaptionSubtitle: String {
        switch discoveryModel?.phase ?? .idle {
        case .idle, .loading:
            return "Loading sessions…"
        case .unsupported:
            return "No session history available"
        case .failed:
            return "Couldn't load sessions"
        case .ready:
            let count = filteredDiscoveredSessions.count
            return count == 1 ? "1 session" : "\(count) sessions"
        }
    }

    private var backButton: some View {
        Button(action: backToAgents) {
            Image(systemName: "chevron.left")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.color("fg-muted"))
                .frame(width: 22, height: 22)
                .background(Circle().fill(theme.color("bg-2")))
        }
        .buttonStyle(.plain)
        .help("Back to agents")
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
                    .contextMenu {
                        if item.localSessionId != nil {
                            Button("Remove from Alas…", role: .destructive) {
                                deletionRequest = .init(
                                    kind: .localOnly,
                                    agentName: agent.displayName,
                                    session: item
                                )
                            }
                        }
                        if capabilities?.canDelete == true,
                           discoveryModel?.remotelyDeletedSessionIds.contains(item.remoteSessionId) != true {
                            Button("Delete agent-side history…", role: .destructive) {
                                deletionRequest = .init(
                                    kind: .agentHistory,
                                    agentName: agent.displayName,
                                    session: item
                                )
                            }
                        }
                    }
                    .disabled(discoveryModel?.deletingSessionIds.contains(item.remoteSessionId) == true)
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
            if let deletionError {
                launcherStatusRow(deletionError)
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

    private var hintLine: some View {
        Text(hintText)
            .font(.system(size: 11))
            .foregroundColor(theme.color("fg-faint"))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
    }

    private var hintText: String {
        if chatAgent != nil {
            return "↑↓ pick session  ·  ←→ change agent  ·  ↵ open  ·  esc back"
        }
        var parts = ["←→ navigate", "↵ select"]
        if showsModePicker { parts.append("⇥ swap mode") }
        parts.append("esc close")
        return parts.joined(separator: "  ·  ")
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        if chatAgent != nil {
            return handleSessionKey(press)
        }
        switch press.key {
        case .escape:
            close()
            return .handled
        case .leftArrow:
            appState.agentLauncher.moveSelectionUp(rowCount: rows.count)
            return .handled
        case .rightArrow:
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
        case .escape:
            backToAgents()
            return .handled
        case .leftArrow:
            moveToNeighborAgent(reverse: true)
            return .handled
        case .rightArrow:
            moveToNeighborAgent(reverse: false)
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
                if let checkout = selectedWorkspaceCheckout() {
                    _ = try? await appState.openWorkspaceCheckoutAgentTerminalTab(
                        checkout,
                        focusedMemberWorktree: worktree,
                        agentId: agent.id
                    )
                } else {
                    _ = try? await appState.openAgentTerminalTabPreparingRemoteZmxIfNeeded(for: worktree, agentId: agent.id)
                }
            }
        case .acp:
            beginSessionBrowser(for: agent)
            return
        }
        close()
    }

    private func beginSessionBrowser(for agent: AgentDefinition) {
        if let checkout = selectedWorkspaceCheckout() {
            Task { @MainActor in
                guard case let .ready(manager) = await appState.workspaceACPManager(for: checkout) else {
                    _ = await appState.openWorkspaceCheckoutACPSession(checkout: checkout, agentID: agent.id)
                    close()
                    return
                }
                chatAgent = agent
                appState.agentLauncher.query = ""
                selectedSessionIndex = 0
                startDiscovery(for: agent, manager: manager)
                requestInputFocus()
            }
            return
        }
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

    /// Roams to a neighbouring agent from inside the session browser (←→).
    /// The ACP manager is per-worktree, not per-agent, so whatever manager
    /// got us into the session browser already covers every other agent —
    /// no need for `beginSessionBrowser`'s "no manager yet" fallback, which
    /// would otherwise auto-launch a chat and close the dialog underfoot.
    private func moveToNeighborAgent(reverse: Bool) {
        guard let chatAgent else { return }
        let agents = stageAgents
        guard let currentIndex = agents.firstIndex(where: { $0.id == chatAgent.id }) else { return }
        let newIndex = currentIndex + (reverse ? -1 : 1)
        guard agents.indices.contains(newIndex) else { return }
        switchChatAgent(to: agents[newIndex])
    }

    private func switchChatAgent(to agent: AgentDefinition) {
        guard let manager = selectedACPManagerForLauncher() else { return }
        chatAgent = agent
        appState.agentLauncher.query = ""
        selectedSessionIndex = 0
        // Per-agent state: a deletion failure (or pending confirmation) for
        // the agent we're leaving must not bleed into the next agent's
        // session list.
        deletionRequest = nil
        deletionError = nil
        startDiscovery(for: agent, manager: manager)
        requestInputFocus()
    }

    private func startDiscovery(for agent: AgentDefinition) {
        guard let worktree = selectedWorktree(),
              let manager = appState.acpManager(for: worktree)
        else { return }
        startDiscovery(for: agent, manager: manager)
    }

    private func startDiscovery(for agent: AgentDefinition, manager: ACPSessionManager) {
        let prior = discoveryModel
        let model = ACPSessionDiscoveryModel()
        discoveryModel = model
        discoveryOwner = manager.owner
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
        let owner = discoveryOwner
        Task { @MainActor in
            if let owner {
                _ = appState.openNewACPSession(agentID: chatAgent.id, owner: owner)
            } else {
                appState.openNewACPSession(agentID: chatAgent.id)
            }
        }
        close()
    }

    private func openDiscoveredSession(_ session: ACPDiscoveredSession) {
        guard let capabilities = discoveryModel?.capabilities,
              let owner = discoveryOwner
        else { return }
        Task {
            let opened = await appState.openDiscoveredACPSession(
                session,
                owner: owner,
                capabilities: capabilities
            )
            guard opened else { return }
            close()
        }
    }

    private func performDeletion(
        _ request: ACPSessionDeletionRequest,
        removeLocalHistory: Bool = false
    ) {
        guard let manager = selectedACPManagerForLauncher(),
              let discoveryModel
        else { return }
        deletionRequest = nil
        deletionError = nil
        Task {
            do {
                switch request.kind {
                case .localOnly:
                    try await discoveryModel.removeLocalHistory(for: request.session, manager: manager)
                case .agentHistory:
                    try await discoveryModel.deleteAgentHistory(
                        for: request.session,
                        removeLocalHistory: removeLocalHistory,
                        manager: manager
                    )
                }
            } catch {
                guard self.discoveryModel === discoveryModel else { return }
                deletionError = error.localizedDescription
            }
        }
    }

    private func selectedACPManagerForLauncher() -> ACPSessionManager? {
        if let discoveryOwner {
            return appState.acpManager(for: discoveryOwner)
        }
        guard let worktree = selectedWorktree() else { return nil }
        return appState.acpManager(for: worktree)
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
        discoveryOwner = nil
        chatAgent = nil
        selectedSessionIndex = 0
        loadingMore = false
        deletionRequest = nil
        deletionError = nil
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

struct ACPSessionDeletionRequest: Identifiable {
    enum Kind { case localOnly, agentHistory }

    let kind: Kind
    let agentName: String
    let session: ACPDiscoveredSession

    var id: String { "\(session.remoteSessionId)-\(kind)" }

    var title: String {
        switch kind {
        case .localOnly:
            return "Remove \(agentName) session “\(session.title)” from Alas?"
        case .agentHistory:
            return "Delete \(agentName) history for “\(session.title)”?"
        }
    }

    var message: String {
        switch kind {
        case .localOnly:
            return "Only Alas’s local record will be removed. The session remains in \(agentName)’s history."
        case .agentHistory:
            let localCopy = session.localSessionId == nil
                ? ""
                : " Choosing only agent-side history keeps Alas’s local record."
            return "This asks \(agentName) to delete session “\(session.title)”. The adapter controls whether deletion is soft or permanent, and no undo is available.\(localCopy)"
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

/// A single icon tile in the horizontal switcher strip. `logo` is injected
/// so the fallback (no vendor asset) can be wrapped in its own rounded chip
/// while real vendor artwork renders edge-to-edge.
private struct AgentSwitcherTile<Logo: View>: View {
    let label: String
    let size: CGFloat
    let isSelected: Bool
    let isDimmed: Bool
    let onTap: () -> Void
    let onHover: () -> Void
    @ViewBuilder let logo: () -> Logo
    @Environment(\.theme) private var theme

    var body: some View {
        logo()
            .frame(width: size, height: size)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? theme.color("bg-3") : .clear)
            )
            .opacity(isDimmed ? 0.4 : 1)
            .contentShape(Rectangle())
            .onTapGesture { onTap() }
            .onHover { hovering in if hovering { onHover() } }
            // The logo alone (an image, or a bare sparkle glyph for
            // fallback agents) isn't distinguishable to VoiceOver, and a
            // tap-gesture view isn't announced as activatable on its own.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(.default, onTap)
    }
}
