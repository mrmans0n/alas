import AppKit
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
    let onNewTerminal: () -> Void
    let enabledAgents: [AgentDefinition]
    let onLaunchAgent: (String) -> Void
    let onRevealRightSidebar: () -> Void
    let rightSidebarHidden: Bool
    let onRevealSidebar: () -> Void
    let sidebarHidden: Bool
    let onMove: (TabID, TabID) -> Void
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
                    tab: tab,
                    active: tab.id == activeId,
                    showClose: tabs.count > 1,
                    harnessInfo: harnessLookup(tab.id),
                    dirty: dirtyLookup(tab.id),
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
                onLaunchAgent: onLaunchAgent
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
    let tab: Tab
    let active: Bool
    let showClose: Bool
    let harnessInfo: (agent: AgentKind, state: ActivityState)?
    let dirty: Bool
    let onActivate: () -> Void
    let onClose: () -> Void
    @Environment(\.theme) var theme
    @State private var hoveringClose = false

    var body: some View {
        HStack(spacing: 6) {
            Icon(name: tab.iconName, size: 11,
                 color: iconColor)
                .modifier(TabActivityPulse(activityState: harnessInfo?.state))
            Text(tab.title)
                .font(.system(size: 11.5))
                .foregroundColor(active ? theme.color("fg") : theme.color("fg-dim"))
                .lineLimit(1)
            if case .editor(let state) = tab, state.isExternal {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(theme.color("fg-faint"))
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
    let onLaunchAgent: (String) -> Void
    @Environment(\.theme) var theme

    var body: some View {
        Menu {
            if agents.isEmpty {
                Text("No enabled agents")
            } else {
                ForEach(agents) { agent in
                    Button {
                        onLaunchAgent(agent.id)
                    } label: {
                        Label {
                            Text(agent.displayName)
                        } icon: {
                            // SwiftUI Menu renders items as NSMenuItems and ignores
                            // SwiftUI frame sizing on custom icon views; it draws the
                            // backing NSImage at its native pixel size. Hand it an
                            // NSImage copy whose .size is clamped to 16pt.
                            Image(nsImage: menuIconImage(for: agent))
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
        .help(agents.isEmpty ? "No enabled agents" : "Launch agent")
    }

    private func menuIconImage(for agent: AgentDefinition) -> NSImage {
        if let asset = agent.builtinLogoAssetName,
           let source = NSImage(named: asset) {
            let copy = source.copy() as? NSImage ?? source
            copy.size = NSSize(width: 16, height: 16)
            return copy
        }
        let fallback = NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil)
            ?? NSImage()
        fallback.size = NSSize(width: 16, height: 16)
        return fallback
    }
}
