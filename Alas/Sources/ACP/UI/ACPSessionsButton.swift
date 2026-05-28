import SwiftUI

/// Single icon-only popover button in the ACP toolbar. Absorbs the
/// surfaces that used to be hosted inline on the toolbar:
///   * recent sessions list (its original responsibility)
///   * current session title with double-click-to-rename
///   * disconnected indicator + Reconnect action
///
/// A small red badge appears on the icon while the current session is
/// disconnected; the at-a-glance signal that used to live as inline
/// text next to the title.
struct ACPSessionsButton: View {
    @ObservedObject var session: ACPSession
    @ObservedObject var manager: ACPSessionManager
    let state: AppState
    let worktree: Worktree
    let agentLookup: (String) -> AgentDefinition?
    @Environment(\.theme) private var theme
    @State private var open = false

    var body: some View {
        Button {
            manager.refreshRecent()
            open.toggle()
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.color("fg-muted"))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(theme.color("bg-3").opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(theme.color("line"), lineWidth: 0.5))
                if session.disconnected {
                    Circle()
                        .fill(theme.color("del"))
                        .frame(width: 6, height: 6)
                        .overlay(Circle().strokeBorder(theme.color("bg-2"), lineWidth: 1))
                        .offset(x: 3, y: -3)
                }
            }
        }
        .buttonStyle(.plain)
        .help("Session menu")
        .popover(isPresented: $open, arrowEdge: .top) {
            SessionsPopover(
                session: session,
                manager: manager,
                state: state,
                worktree: worktree,
                agentLookup: agentLookup,
                onPick: { open = false }
            )
        }
    }
}

private struct SessionsPopover: View {
    @ObservedObject var session: ACPSession
    @ObservedObject var manager: ACPSessionManager
    let state: AppState
    let worktree: Worktree
    let agentLookup: (String) -> AgentDefinition?
    let onPick: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            currentSessionHeader
            if session.disconnected {
                disconnectedBanner
            }
            Divider().background(theme.color("line"))
            recentsHeader
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
        .frame(maxHeight: 420)
        .background(theme.color("bg-1"))
    }

    @ViewBuilder
    private var currentSessionHeader: some View {
        HStack(spacing: 6) {
            EditableSessionTitle(session: session, manager: manager)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(theme.color("bg-2").opacity(0.4))
    }

    @ViewBuilder
    private var disconnectedBanner: some View {
        HStack(spacing: 8) {
            Circle().fill(theme.color("del")).frame(width: 6, height: 6)
            Text("Disconnected")
                .font(.system(size: 11))
                .foregroundStyle(theme.color("del"))
            Spacer()
            Button("Reconnect") { reconnect() }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.color("accent"))
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(theme.color("del").opacity(0.10))
    }

    private var recentsHeader: some View {
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
        let isCurrent = row.id == session.id
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

    private func reconnect() {
        Task {
            await manager.detach(sessionId: session.id)
            await manager.attach(to: session.id, freshlyCreated: false)
            await MainActor.run { session.disconnected = false }
        }
    }
}

/// Editable session title. Double-click toggles to a TextField; ⏎ /
/// blur commits + persists. Lifted out of ACPToolbar so the popover
/// can own session naming.
private struct EditableSessionTitle: View {
    @ObservedObject var session: ACPSession
    let manager: ACPSessionManager
    @Environment(\.theme) private var theme
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var displayTitle: String {
        let t = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || t == "New session" ? "New session" : t
    }

    var body: some View {
        if editing {
            TextField("Session title", text: $draft, onCommit: commit)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.color("fg"))
                .focused($focused)
                .frame(minWidth: 120, maxWidth: .infinity)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(theme.color("bg-0").opacity(0.7))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(theme.color("accent").opacity(0.6), lineWidth: 0.75))
                .onAppear {
                    draft = session.title
                    focused = true
                }
                .onSubmit(commit)
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { commit() }
                }
                .onExitCommand { editing = false }
        } else {
            Text(displayTitle)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.color("fg"))
                .lineLimit(1)
                .truncationMode(.tail)
                .help("Double-click to rename: \(displayTitle)")
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { editing = true }
                .contextMenu {
                    Button("Rename…") { editing = true }
                }
        }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            session.title = trimmed
            manager.persist(session)
        }
        editing = false
    }
}
