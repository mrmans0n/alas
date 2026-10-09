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
        let canClose = client.canCloseSessionTabs(on: selection.serverId)
        TabStrip(
            activeId: selectedTab,
            isEmpty: rows.isEmpty,
            sidebarHidden: sidebarHidden,
            onRevealSidebar: onRevealSidebar
        ) {
            if let peer {
                NativePeerTabMarker(name: peer.name, state: peer.state)
            }
        } tabs: {
            ForEach(rows) { row in
                TabItemView(item: item(for: row), active: row.id == selectedTab) {
                    client.selectTab(row.id, in: selection)
                } trailing: {
                    if canClose, case .session(let session) = row {
                        if client.closingSessionIds.contains(session.id) {
                            ProgressView()
                                .controlSize(.mini)
                                .frame(width: 20, height: 20)
                                .help("Closing on \(peer?.name ?? "peer")…")
                        } else {
                            TabCloseButton(dirtyLookup: { false }) { onCloseSession(session.id) }
                        }
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
    let name: String
    let state: NativePeerState
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(theme.color("fg-muted"))
            Text(name)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(theme.color("fg-dim"))
                .lineLimit(1)
                .frame(maxWidth: 160, alignment: .leading)
            Circle()
                .fill(theme.color(state.presenceColorToken))
                .frame(width: 6, height: 6)
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .overlay(alignment: .trailing) {
            Rectangle().fill(theme.color("line")).frame(width: 1, height: 16)
        }
        .help("On \(name) · \(state.label)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Peer \(name), \(state.label)")
    }
}
