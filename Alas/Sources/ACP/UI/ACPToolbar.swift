import SwiftUI

struct ACPToolbar: View {
    @ObservedObject var session: ACPSession
    let manager: ACPSessionManager
    let agentLookup: (String) -> AgentDefinition?
    let state: AppState
    let worktree: Worktree
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            ACPRecentSessionsButton(
                manager: manager,
                state: state,
                worktree: worktree,
                currentSessionId: session.id,
                agentLookup: agentLookup
            )
            leftCluster
                .layoutPriority(1)
            Spacer(minLength: 8)
            rightCluster
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(
            LinearGradient(
                colors: [theme.color("bg-2").opacity(0.55), theme.color("bg-2").opacity(0.35)],
                startPoint: .top, endPoint: .bottom
            )
        )
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.color("line")).frame(height: 0.5)
        }
    }

    // MARK: - Left: rename-on-double-click session title

    @ViewBuilder
    private var leftCluster: some View {
        HStack(spacing: 8) {
            EditableSessionTitle(session: session, manager: manager)
            if session.disconnected {
                Text("·").foregroundStyle(theme.color("fg-faint"))
                Text("disconnected")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.color("del"))
                Button("Reconnect") { reconnect() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.color("accent"))
            }
        }
    }

    // MARK: - Right cluster

    // Cancel + auto-run both live in the composer footer now; the
    // toolbar's right side is intentionally empty so the title +
    // recent-sessions chip have room to breathe.
    @ViewBuilder
    private var rightCluster: some View {
        EmptyView()
    }

    // MARK: - Actions

    private func reconnect() {
        Task {
            await manager.detach(sessionId: session.id)
            await manager.attach(to: session.id, freshlyCreated: false)
            await MainActor.run { session.disconnected = false }
        }
    }
}

/// Small pulsing dot used as the "agent online" indicator. Lives in the
/// composer footer (left of the agent logo).
struct ACPPulseDot: View {
    let color: Color
    @State private var pulse = false
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .overlay(Circle().stroke(color.opacity(0.20), lineWidth: 2))
            .shadow(color: color.opacity(0.55), radius: 4)
            .opacity(pulse ? 0.55 : 1.0)
            .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
    }
}

/// Editable session title. Double-click toggles to a TextField; ⏎ /
/// blur commits + persists.
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
                .frame(minWidth: 120, maxWidth: 360)
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
                .layoutPriority(1)
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
