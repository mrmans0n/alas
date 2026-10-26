import SwiftUI

/// The selected peer worktree's tabs, drawn in the local tab bar's strip:
/// a peer marker, then one item per host tab in the host's order.
struct NativePeerTabBar: View {
    @Bindable var client: NativePeerSessions
    let selection: NativePeerWorktreeSelection
    let agentLookup: (String) -> AgentDefinition?
    let sidebarHidden: Bool
    let onRevealSidebar: () -> Void
    let onCloseSession: (String) -> Void
    /// Closes a console tab, which ends the console on the peer.
    let onCloseConsole: (_ consoleId: String, _ peerName: String) -> Void
    let onRenameSession: (RemoteSessionSummary) -> Void
    let onCopySessionMarkdown: (RemoteSessionSummary) -> Void
    let onSaveSessionMarkdown: (RemoteSessionSummary) -> Void
    let onArchiveSession: (RemoteSessionSummary) -> Void

    private var peer: NativePeerGroup? {
        client.snapshot.groups.first { $0.serverId == selection.serverId }
    }

    private var rows: [NativePeerTabRow] {
        peer?.repos(ordering: .manual).lazy.flatMap(\.worktrees)
            .first { $0.id == selection.worktreeId }?.tabRows ?? []
    }

    var body: some View {
        let rows = rows
        let selectedTab = client.selectedTab
        let canCloseSessions = client.canCloseSessionTabs(on: selection.serverId)
        let canCloseConsoles = client.consoles?.canTerminate(serverId: selection.serverId) == true
        TabStrip(
            activeId: selectedTab,
            isEmpty: rows.isEmpty,
            sidebarHidden: sidebarHidden,
            onRevealSidebar: onRevealSidebar
        ) {
            if let peer {
                NativePeerTabMarker(peer: peer)
            }
        } tabs: {
            ForEach(rows) { row in
                TabItemView(item: item(for: row), active: row.id == selectedTab) {
                    client.selectTab(row.id, in: selection)
                } trailing: {
                    switch row {
                    case .session(let session) where canCloseSessions:
                        if client.closingSessionIds.contains(session.id) {
                            ProgressView()
                                .controlSize(.mini)
                                .frame(width: 20, height: 20)
                                .help("Closing on \(peer?.name ?? "peer")…")
                        } else {
                            TabCloseButton(dirtyLookup: { false }) { onCloseSession(session.id) }
                        }
                    case .console(let console) where canCloseConsoles:
                        if let peer {
                            TabCloseButton(dirtyLookup: { false }) {
                                onCloseConsole(console.consoleId, peer.name)
                            }
                        }
                    default:
                        EmptyView()
                    }
                }
                .contextMenu {
                    if case .session(let session) = row {
                        Button("Rename…") { onRenameSession(session) }
                            .disabled(peer?.state.carriesSessions != true)
                        // Only the selected tab's transcript is here, and
                        // only once every older page has loaded.
                        let exportable = client.canExportTranscript(of: session.id)
                        Button("Copy Session as Markdown") { onCopySessionMarkdown(session) }
                            .disabled(!exportable)
                        Button("Save Session as Markdown…") { onSaveSessionMarkdown(session) }
                            .disabled(!exportable)
                        Divider()
                        Button("Archive Session…") { onArchiveSession(session) }
                            .disabled(client.hosts?.canArchiveSessions(serverId: selection.serverId) != true)
                    }
                }
                .id(row.id)
            }
        } trailing: {
            if let target = client.newSessionTarget(in: selection) {
                ToolbarIconButton(iconName: "plus", tooltip: "New session on \(target.peer.name)") {
                    client.beginNewSession(in: selection)
                }
                .padding(.horizontal, 8)
            }
        }
    }

    private func item(for row: NativePeerTabRow) -> TabItem {
        switch row {
        case .session(let session):
            let agent = session.agentId.isEmpty || session.agentId == "none"
                ? nil
                : agentLookup(session.agentId) ?? AgentBuiltins.entry(id: session.agentId)
            return TabItem(
                title: session.title,
                iconName: "sparkle",
                activityState: session.tabActivityState,
                agent: agent
            )
        case .console(let console):
            return TabItem(title: console.title, iconName: "terminal")
        }
    }
}

extension RemoteSessionSummary {
    /// The icon tint a local tab gives the same state. Idle is nil, as for a
    /// local agent session tab, so the active tab keeps its accent.
    var tabActivityState: ActivityState? {
        switch status {
        case "streaming": .busy
        case "awaitingPermission": .permissionRequest
        case "awaitingInput": .awaitingInput
        default: nil
        }
    }
}

/// The peer a worktree's tabs live on, ahead of its first tab.
private struct NativePeerTabMarker: View {
    let peer: NativePeerGroup
    @Environment(\.theme) private var theme

    var body: some View {
        let tint = theme.color(peer.state.presenceColorToken)
        let summary = Self.summary(for: peer)
        HStack(spacing: 5) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(theme.color("fg-muted"))
            Text(peer.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.color("fg-dim"))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 120, alignment: .leading)
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(tint.opacity(0.12)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.25), lineWidth: 1))
        .padding(.horizontal, 8)
        .frame(height: 34)
        .overlay(alignment: .trailing) {
            Rectangle().fill(theme.color("line")).frame(width: 1, height: 16)
        }
        .help("On \(summary)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Peer \(summary)")
    }

    /// Name, state, then any running or waiting sessions on the peer.
    private static func summary(for peer: NativePeerGroup) -> String {
        let running = peer.sessions.count { $0.isActive && $0.status == "streaming" }
        return [
            peer.name,
            peer.state.label,
            running > 0 ? "\(running) running" : nil,
            peer.attentionCount > 0 ? "\(peer.attentionCount) waiting" : nil,
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }
}
