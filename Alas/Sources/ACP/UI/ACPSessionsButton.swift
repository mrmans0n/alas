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
    @Environment(\.designScale) private var scale
    @ObservedObject var session: ACPSession
    @ObservedObject var manager: ACPSessionManager
    let state: AppState
    let worktree: Worktree
    var owner: SessionOwnerID? = nil
    let agentLookup: (String) -> AgentDefinition?
    @Environment(\.theme) private var theme
    @State private var open = false
    @State private var hovering = false

    /// Lit while the pointer is over the button or its popover is up, so the
    /// trigger stays visibly tied to the surface it opened.
    private var isLit: Bool { hovering || open }

    var body: some View {
        Button {
            manager.refreshRecent()
            open.toggle()
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(scale.metaFont)
                    .foregroundStyle(theme.color(isLit ? "fg" : "fg-muted"))
                    .padding(.horizontal, scale.space[2]).padding(.vertical, scale.space[1])
                    .background(theme.color("bg-3").opacity(isLit ? 1 : 0.5))
                    .clipShape(RoundedRectangle(cornerRadius: scale.radius.small))
                    .overlay(RoundedRectangle(cornerRadius: scale.radius.small).strokeBorder(theme.color("line"), lineWidth: 0.5))
                if session.agentState == .disconnected {
                    Circle()
                        .fill(theme.color("del"))
                        .frame(width: 6, height: 6)
                        .overlay(Circle().strokeBorder(theme.color("bg-2"), lineWidth: 1))
                        .offset(x: 3, y: -3)
                }
            }
        }
        .buttonStyle(.toolbarControl)
        .onHover { hovering = $0 }
        .help("Session menu")
        .popover(isPresented: $open, arrowEdge: .top) {
            SessionsPopover(
                session: session,
                manager: manager,
                state: state,
                worktree: worktree,
                owner: owner,
                agentLookup: agentLookup,
                onPick: { open = false }
            )
        }
    }
}

private struct SessionsPopover: View {
    @Environment(\.designScale) private var scale
    @ObservedObject var session: ACPSession
    @ObservedObject var manager: ACPSessionManager
    let state: AppState
    let worktree: Worktree
    let owner: SessionOwnerID?
    let agentLookup: (String) -> AgentDefinition?
    let onPick: () -> Void
    @Environment(\.theme) private var theme
    @State private var delegatedSessions: [ACPOrchestrationSessionSummary] = []
    @State private var mergingFork = false

    var body: some View {
        VStack(spacing: 0) {
            currentSessionHeader
            if session.forkRecord?.phase == .ready {
                HStack(spacing: scale.space[3]) {
                    Button("Merge back") { mergeFork(archive: false) }
                    Button("Merge back and archive") { mergeFork(archive: true) }
                }
                .buttonStyle(.plain)
                .font(scale.meta.font(weight: .medium))
                .foregroundStyle(theme.color("accent"))
                .padding(.horizontal, scale.space[3]).padding(.vertical, scale.space[2])
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(mergingFork || session.hydrationState != .ready || manager.isMirror(sessionId: session.id))
                .help("Send a conversation digest to the source chat after the fork's pending turns finish")
            }
            if session.agentState == .disconnected {
                disconnectedBanner
            }
            Divider().background(theme.color("line"))
            recentsHeader
            if manager.recent.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: scale.space[0]) {
                        ForEach(manager.recent, id: \.id) { row in
                            sessionRow(row)
                        }
                    }
                    .padding(.vertical, scale.space[1])
                }
            }
            if !delegatedSessions.isEmpty {
                Divider().background(theme.color("line"))
                delegatedHeader
                ForEach(delegatedSessions, id: \.sessionId) { summary in
                    delegatedRow(summary)
                }
            }
        }
        .frame(width: 320)
        .frame(maxHeight: 420)
        .background(theme.color("bg-1"))
        .task(id: session.id) {
            delegatedSessions = await state.delegatedSessionSummaries(for: session.id)
        }
    }

    @ViewBuilder
    private var currentSessionHeader: some View {
        HStack(spacing: scale.space[2]) {
            EditableSessionTitle(session: session, manager: manager)
            Spacer()
        }
        .padding(.horizontal, scale.space[3]).padding(.vertical, scale.space[2])
        .background(theme.color("bg-2").opacity(0.4))
    }

    @ViewBuilder
    private var disconnectedBanner: some View {
        HStack(spacing: scale.space[2]) {
            Circle().fill(theme.color("del")).frame(width: 6, height: 6)
            Text("Disconnected")
                .font(scale.metaFont)
                .foregroundStyle(theme.color("del"))
            Spacer()
            Button("Reconnect") { reconnect() }
                .buttonStyle(.plain)
                .font(scale.meta.font(weight: .semibold))
                .foregroundStyle(theme.color("accent"))
        }
        .padding(.horizontal, scale.space[3]).padding(.vertical, scale.space[2])
        .background(theme.color("del").opacity(0.10))
    }

    private var recentsHeader: some View {
        HStack {
            Text("Recent sessions")
                .font(scale.caption.font(weight: .semibold))
                .tracking(0.5)
                .textCase(.uppercase)
                .foregroundStyle(theme.color("fg-faint"))
            Spacer()
        }
        .padding(.horizontal, scale.space[3]).padding(.vertical, scale.space[2])
        .background(theme.color("bg-2").opacity(0.4))
    }

    private var emptyState: some View {
        Text("No recent sessions for this worktree.")
            .font(scale.metaFont)
            .foregroundStyle(theme.color("fg-faint"))
            .padding(.horizontal, scale.space[3]).padding(.vertical, scale.space[4])
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var delegatedHeader: some View {
        HStack {
            Text("Delegated sessions")
                .font(scale.caption.font(weight: .semibold))
                .tracking(0.5)
                .textCase(.uppercase)
                .foregroundStyle(theme.color("fg-faint"))
            Spacer()
        }
        .padding(.horizontal, scale.space[3]).padding(.vertical, scale.space[2])
        .background(theme.color("bg-2").opacity(0.4))
    }

    private func delegatedRow(_ summary: ACPOrchestrationSessionSummary) -> some View {
        Button {
            Task {
                await state.openDelegatedACPSession(summary)
                onPick()
            }
        } label: {
            HStack(spacing: scale.space[2]) {
                Image(systemName: summary.relationship == "parent" ? "arrow.up.left" : "arrow.down.right")
                    .font(scale.caption.font(weight: .semibold))
                    .foregroundStyle(theme.color("fg-faint"))
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: scale.space[0]) {
                    Text(summary.relationship == "parent" ? "Delegated by parent" : summary.role.map { "Child session · \($0)" } ?? "Child session")
                        .font(scale.metaFont)
                        .foregroundStyle(theme.color("fg"))
                        .lineLimit(1)
                    Text(ACPDelegatedSessionsPolicy.statusLabel(for: summary.state))
                        .font(scale.caption.font(weight: .regular))
                        .foregroundStyle(summary.state == "failed" ? theme.color("del") : theme.color("fg-faint"))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, scale.space[2]).padding(.vertical, scale.space[2])
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, scale.space[2])
        .help(summary.failure ?? ACPDelegatedSessionsPolicy.statusLabel(for: summary.state))
    }

    @ViewBuilder
    private func sessionRow(_ row: ACPSessionRow) -> some View {
        let isCurrent = row.id == session.id
        Button {
            if !isCurrent {
                Task {
                    if let owner {
                        await state.openExistingACPSession(sessionId: row.id, owner: owner)
                    } else {
                        await state.openExistingACPSession(sessionId: row.id)
                    }
                    onPick()
                }
                return
            }
            onPick()
        } label: {
            HStack(spacing: scale.space[2]) {
                if let agent = agentLookup(row.agentId) {
                    AgentLogoView(agent: agent).frame(width: 14, height: 14)
                } else {
                    Circle().fill(theme.color("fg-faint")).frame(width: 6, height: 6)
                }
                VStack(alignment: .leading, spacing: scale.space[0]) {
                    Text(row.title.isEmpty || row.title == "New session" ? "New session" : row.title)
                        .font(scale.meta.font(weight: isCurrent ? .semibold : .regular))
                        .foregroundStyle(theme.color("fg"))
                        .lineLimit(1)
                    Text(relativeTime(epochSeconds: row.lastOpenedAt))
                        .font(scale.caption.font(weight: .regular, design: .monospaced))
                        .foregroundStyle(theme.color("fg-faint"))
                }
                Spacer(minLength: 0)
                if isCurrent {
                    Text("now")
                        .font(scale.caption.font(weight: .semibold))
                        .tracking(0.4)
                        .textCase(.uppercase)
                        .foregroundStyle(theme.color("accent"))
                }
            }
            .padding(.horizontal, scale.space[2]).padding(.vertical, scale.space[2])
            .background(isCurrent ? theme.color("accent").opacity(theme.darkMode ? 0.10 : 0.18) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: scale.radius.small))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, scale.space[2])
    }

    private func relativeTime(epochSeconds: Int64) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: Date(timeIntervalSince1970: TimeInterval(epochSeconds)), relativeTo: Date())
    }

    private func reconnect() {
        Task {
            await manager.reconnectNow(to: session.id)
        }
    }

    private func mergeFork(archive: Bool) {
        mergingFork = true
        Task { @MainActor in
            defer { mergingFork = false }
            do {
                try await state.mergeACPForkBack(
                    worktree: worktree, owner: owner, forkSessionID: session.id, archive: archive
                )
                onPick()
            } catch {
                session.lastError = error.localizedDescription
            }
        }
    }
}

/// Editable session title. Double-click toggles to a TextField; ⏎ /
/// blur commits + persists. Lifted out of ACPToolbar so the popover
/// can own session naming.
private struct EditableSessionTitle: View {
    @Environment(\.designScale) private var scale
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
                .font(scale.meta.font(weight: .semibold))
                .foregroundStyle(theme.color("fg"))
                .focused($focused)
                .frame(minWidth: 120, maxWidth: .infinity)
                .padding(.horizontal, scale.space[2]).padding(.vertical, scale.space[0])
                .background(theme.color("bg-0").opacity(0.7))
                .clipShape(RoundedRectangle(cornerRadius: scale.radius.small))
                .overlay(RoundedRectangle(cornerRadius: scale.radius.small).strokeBorder(theme.color("accent").opacity(0.6), lineWidth: 0.75))
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
                .font(scale.meta.font(weight: .semibold))
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
            manager.renameSession(id: session.id, title: trimmed, source: .manual)
        }
        editing = false
    }
}
