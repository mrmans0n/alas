import SwiftUI

struct TabBarView: View {
    let tabs: [Tab]
    let activeId: TabID?
    let harnessLookup: (TabID) -> (agent: AgentKind, state: ActivityState)?
    let dirtyLookup: (TabID) -> Bool
    let onActivate: (TabID) -> Void
    let onClose: (TabID) -> Void
    let onCloseOthers: (TabID) -> Void
    let onCloseAll: () -> Void
    let onCloseToLeft: (TabID) -> Void
    let onCloseToRight: (TabID) -> Void
    let onCopyPath: (TabID) -> Void
    let onCopyRelativePath: (TabID) -> Void
    let onRenameTerminal: (TabID) -> Void
    let onRenameACPSession: (TabID) -> Void
    let onCopyACPSession: (TabID) -> Void
    let onExportACPSession: (TabID) -> Void
    let onNewTerminal: () -> Void
    let enabledAgents: [AgentDefinition]
    let onLaunchAgent: (String) -> Void
    let onLaunchACPSession: (String) -> Void
    let acpAgents: [AgentDefinition]
    let onRevealRightSidebar: () -> Void
    let rightSidebarHidden: Bool
    let onRevealSidebar: () -> Void
    let sidebarHidden: Bool
    let onMove: (TabID, TabID) -> Void
    let titleLookup: (TabID) -> String?
    let transcriptLookup: (TabID) -> ACPTranscript?
    var acpAgentLookup: (TabID) -> AgentDefinition? = { _ in nil }
    @Environment(\.theme) var theme

    private var isTerminalActive: Bool {
        guard let activeId, let active = tabs.first(where: { $0.id == activeId }) else { return false }
        if case .terminal = active { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 0) {
            if sidebarHidden {
                TrafficLights()
                    .padding(.leading, 12)
                    .padding(.trailing, 10)
                ToolbarIconButton(iconName: "sidebar.left", tooltip: "Show sidebar", action: onRevealSidebar)
                    .padding(.trailing, 8)
            }
            ForEach(Array(tabs.enumerated()), id: \.element.id) { idx, tab in
                TabButton(
                    titleLookup: titleLookup,
                    tab: tab,
                    active: tab.id == activeId,
                    showClose: true,
                    harnessInfo: harnessLookup(tab.id),
                    dirty: dirtyLookup(tab.id),
                    transcript: transcriptLookup(tab.id),
                    acpAgent: acpAgentLookup(tab.id),
                    onActivate: { onActivate(tab.id) },
                    onClose: { onClose(tab.id) }
                )
                .draggable(tab.id)
                .dropDestination(for: TabID.self) { ids, _ in
                    guard let draggedId = ids.first, draggedId != tab.id else { return false }
                    onMove(draggedId, tab.id)
                    return true
                }
                .contextMenu {
                    if case .terminal = tab {
                        Button("Rename…") { onRenameTerminal(tab.id) }
                        Divider()
                    }
                    if case .acpSession = tab {
                        Button("Rename…") { onRenameACPSession(tab.id) }
                        Button("Copy Session as Markdown") { onCopyACPSession(tab.id) }
                        Button("Save Session as Markdown…") { onExportACPSession(tab.id) }
                        Divider()
                    }
                    Button("Close") { onClose(tab.id) }
                    Button("Close Other Tabs") { onCloseOthers(tab.id) }
                        .disabled(tabs.count <= 1)
                    Button("Close All Tabs") { onCloseAll() }
                    Button("Close Tabs to the Left") { onCloseToLeft(tab.id) }
                        .disabled(idx == 0)
                    Button("Close Tabs to the Right") { onCloseToRight(tab.id) }
                        .disabled(idx == tabs.count - 1)
                    Divider()
                    if tab.relativeFilePath != nil {
                        Button("Copy Path") { onCopyPath(tab.id) }
                        Button("Copy Relative Path") { onCopyRelativePath(tab.id) }
                    }
                }
            }
            Spacer()
            if isTerminalActive {
                ToolbarIconButton(iconName: "split", tooltip: "Split Right (⌘D)") {
                    NotificationCenter.default.post(name: .alasSplitRight, object: nil)
                }
                ToolbarIconButton(iconName: "split-down", tooltip: "Split Down (⇧⌘D)") {
                    NotificationCenter.default.post(name: .alasSplitDown, object: nil)
                }
            }
            Button(action: onNewTerminal) {
                Icon(name: "plus", size: 13)
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New terminal")
            .padding(.leading, 8)
            .padding(.trailing, 2)
            AgentSparkleMenu(
                agents: enabledAgents,
                acpAgents: acpAgents,
                onLaunchAgent: onLaunchAgent,
                onLaunchACPSession: onLaunchACPSession
            )
            .padding(.trailing, rightSidebarHidden ? 2 : 8)
            if rightSidebarHidden {
                ToolbarIconButton(iconName: "sidebar.right", tooltip: "Show right sidebar", action: onRevealRightSidebar)
                    .padding(.trailing, 8)
            }
        }
        .frame(height: 34)
        .background(theme.color("bg-2"))
        .overlay(Divider().opacity(0.5), alignment: .bottom)
        .windowDragHandle()
    }
}

private struct TabButton: View {
    let titleLookup: (TabID) -> String?
    let tab: Tab
    let active: Bool
    let showClose: Bool
    let harnessInfo: (agent: AgentKind, state: ActivityState)?
    let dirty: Bool
    let transcript: ACPTranscript?
    let acpAgent: AgentDefinition?
    let onActivate: () -> Void
    let onClose: () -> Void
    @Environment(\.theme) var theme
    @State private var hoveringClose = false

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 3) {
                Icon(name: tab.iconName, size: 11,
                     color: iconColor)
                    .modifier(TabActivityPulse(activityState: harnessInfo?.state))
                    .frame(width: 12, height: 12)
                if case .acpSession = tab, let acpAgent {
                    AgentLogoView(agent: acpAgent, size: 12)
                        .frame(width: 12, height: 12)
                }
            }
            let displayTitle = titleLookup(tab.id) ?? tab.title
            Text(displayTitle)
                .font(.system(size: 11.5))
                .foregroundColor(active ? theme.color("fg") : theme.color("fg-dim"))
                .lineLimit(1)
            if case .editor(let state) = tab, state.isExternal {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(theme.color("fg-faint"))
            }
            if let transcript {
                TabPlanProgressChip(transcript: transcript)
            }
            if showClose {
                Button(action: onClose) {
                    ZStack {
                        ZStack {
                            if dirty && !hoveringClose {
                                Circle()
                                    .fill(theme.color("fg"))
                                    .frame(width: 7, height: 7)
                            } else {
                                Icon(name: "x", size: 9,
                                     color: hoveringClose ? theme.color("fg") : theme.color("fg-faint"))
                                    .background(hoveringClose ? theme.color("bg-4") : .clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                            }
                        }
                        .frame(width: 14, height: 14)
                    }
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hoveringClose = $0 }
                .help(dirty ? "Unsaved changes — click to close" : "Close")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(active ? theme.color("bg-1") : .clear)
        .overlay(
            Rectangle()
                .fill(active ? theme.color("accent") : .clear)
                .frame(height: 2),
            alignment: .bottom
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onActivate)
    }

    private var iconColor: Color {
        if let info = harnessInfo {
            return stateColor(info.state)
        }
        return active ? theme.color("accent") : theme.color("fg-faint")
    }

    private func stateColor(_ s: ActivityState) -> Color {
        switch s {
        case .busy:          return theme.color("add")
        case .awaitingInput: return theme.color("mod")
        case .permissionRequest: return theme.color("mod")
        case .idle:          return theme.color("fg-faint")
        }
    }
}

private struct ToolbarIconButton: View {
    let iconName: String
    let tooltip: String
    let action: () -> Void
    @Environment(\.theme) var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Icon(name: iconName, size: 13,
                 color: hovering ? theme.color("fg") : theme.color("fg-faint"))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tooltip)
    }
}

private struct AgentSparkleMenu: View {
    let agents: [AgentDefinition]
    let acpAgents: [AgentDefinition]
    let onLaunchAgent: (String) -> Void
    let onLaunchACPSession: (String) -> Void
    @Environment(\.theme) var theme

    var body: some View {
        Menu {
            if agents.isEmpty && acpAgents.isEmpty {
                Text("No enabled agents")
            } else {
                if !agents.isEmpty {
                    Section("Terminal") {
                        ForEach(agents) { agent in
                            Button {
                                onLaunchAgent(agent.id)
                            } label: {
                                Label {
                                    Text(agent.displayName)
                                } icon: {
                                    Image(nsImage: AgentLogoView.menuImage(for: agent))
                                }
                            }
                        }
                    }
                }
                if !acpAgents.isEmpty {
                    Section("ACP session") {
                        ForEach(acpAgents) { agent in
                            Button {
                                onLaunchACPSession(agent.id)
                            } label: {
                                Label {
                                    Text(agent.displayName)
                                } icon: {
                                    Image(nsImage: AgentLogoView.menuImage(for: agent))
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            Icon(name: "sparkle", size: 13, color: theme.color("fg-faint"))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help((agents.isEmpty && acpAgents.isEmpty) ? "No enabled agents" : "Launch agent")
    }
}

/// Observes `ACPTranscript` directly so SwiftUI invalidates when plan
/// items change — `ACPSession` does not forward `transcript.objectWillChange`.
private struct TabPlanProgressChip: View {
    @ObservedObject var transcript: ACPTranscript
    @Environment(\.theme) private var theme

    var body: some View {
        if let items = transcript.currentPlan, !items.isEmpty {
            let done = items.filter { $0.status == "completed" }.count
            Text("\(done) / \(items.count)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(theme.color("accent"))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(theme.color("accent").opacity(0.12))
                .clipShape(Capsule())
        }
    }
}
