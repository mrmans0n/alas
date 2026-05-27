import SwiftUI

/// Compact button on the toolbar that opens a popover listing recent
/// ACP sessions for this worktree. Click a row to reopen that session
/// in a new tab. Replaces the per-tab history sidebar we dropped in
/// the Flow redesign.
struct ACPRecentSessionsButton: View {
    @ObservedObject var manager: ACPSessionManager
    let state: AppState
    let worktree: Worktree
    let currentSessionId: ACPSession.ID
    let agentLookup: (String) -> AgentDefinition?
    @Environment(\.theme) private var theme
    @State private var open = false

    var body: some View {
        Button {
            manager.refreshRecent()
            open.toggle()
        } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 12))
                .foregroundStyle(theme.color("fg-muted"))
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(theme.color("bg-3").opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(theme.color("line"), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help("Recent sessions")
        .popover(isPresented: $open, arrowEdge: .top) {
            RecentSessionsPanel(
                manager: manager,
                state: state,
                worktree: worktree,
                currentSessionId: currentSessionId,
                agentLookup: agentLookup,
                onPick: { open = false }
            )
        }
    }
}

private struct RecentSessionsPanel: View {
    @ObservedObject var manager: ACPSessionManager
    let state: AppState
    let worktree: Worktree
    let currentSessionId: ACPSession.ID
    let agentLookup: (String) -> AgentDefinition?
    let onPick: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(theme.color("line"))
            if manager.recent.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(manager.recent, id: \.id) { row in
                            sessionRow(row)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(width: 320)
        .frame(maxHeight: 360)
        .background(theme.color("bg-1"))
    }

    private var header: some View {
        HStack {
            Text("Recent sessions")
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.5)
                .textCase(.uppercase)
                .foregroundStyle(theme.color("fg-faint"))
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(theme.color("bg-2").opacity(0.4))
    }

    private var emptyState: some View {
        Text("No recent sessions for this worktree.")
            .font(.system(size: 11))
            .foregroundStyle(theme.color("fg-faint"))
            .padding(.horizontal, 12).padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func sessionRow(_ row: ACPSessionRow) -> some View {
        let isCurrent = row.id == currentSessionId
        Button {
            if !isCurrent {
                state.openExistingACPSession(sessionId: row.id)
            }
            onPick()
        } label: {
            HStack(spacing: 8) {
                if let agent = agentLookup(row.agentId) {
                    AgentLogoView(agent: agent).frame(width: 14, height: 14)
                } else {
                    Circle().fill(theme.color("fg-faint")).frame(width: 6, height: 6)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title.isEmpty || row.title == "New session" ? "New session" : row.title)
                        .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                        .foregroundStyle(theme.color("fg"))
                        .lineLimit(1)
                    Text(relativeTime(epochSeconds: row.lastOpenedAt))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(theme.color("fg-faint"))
                }
                Spacer(minLength: 0)
                if isCurrent {
                    Text("now")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.4)
                        .textCase(.uppercase)
                        .foregroundStyle(theme.color("accent"))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(isCurrent ? theme.color("accent").opacity(0.10) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
    }

    private func relativeTime(epochSeconds: Int64) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: Date(timeIntervalSince1970: TimeInterval(epochSeconds)), relativeTo: Date())
    }
}
