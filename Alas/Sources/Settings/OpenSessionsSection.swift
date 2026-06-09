import SwiftUI

/// Settings › Terminal "Open sessions" section: lists this window's tracked
/// zmx sessions and orphaned/other `alas-*` sessions, with per-row kill and a
/// "Kill all idle" bulk action. Loads on appear, after any kill, and on the
/// Refresh button — no background polling.
struct OpenSessionsSection: View {
    @Bindable var state: AppState
    @Environment(\.theme) var theme

    @State private var snapshot: OpenSessionsSnapshot = .empty
    @State private var isLoading = false
    @State private var loadTask: Task<Void, Never>? = nil
    @State private var confirmKillRow: OpenSessionRow? = nil
    @State private var confirmKillAllIdle = false

    private var idleCount: Int { snapshot.orphaned.filter(\.isIdle).count }

    var body: some View {
        SettingsGroup(title: "Open sessions") {
            header

            if !state.terminal.zmxClient.isAvailable {
                note("Persistent sessions are disabled.")
            } else if snapshot.isEmpty {
                note(isLoading ? "Loading…" : "No open sessions.")
            } else {
                if !snapshot.active.isEmpty {
                    subsectionLabel("Active in this window")
                    ForEach(snapshot.active) { row in
                        OpenSessionRowView(row: row, onKill: { kill(row) })
                    }
                }
                if !snapshot.orphaned.isEmpty {
                    subsectionLabel("Other / orphaned")
                    ForEach(snapshot.orphaned) { row in
                        OpenSessionRowView(row: row, onKill: { kill(row) })
                    }
                }
            }
        }
        .onAppear { reload() }
        .alert("Kill this session?", isPresented: Binding(
            get: { confirmKillRow != nil },
            set: { if !$0 { confirmKillRow = nil } }
        ), presenting: confirmKillRow) { row in
            Button("Cancel", role: .cancel) { confirmKillRow = nil }
            Button("Kill", role: .destructive) {
                performKill(row)
                confirmKillRow = nil
            }
        } message: { row in
            if case .active = row.kind {
                Text("This terminal tab and the process running in it will be terminated.")
            } else {
                Text("This session has clients attached and may belong to another Alas window.")
            }
        }
        .alert("Kill all idle sessions?", isPresented: $confirmKillAllIdle) {
            Button("Cancel", role: .cancel) { }
            Button("Kill \(idleCount)", role: .destructive) {
                state.terminal.killIdleOrphans(snapshot)
                reload(delay: 0.4)
            }
        } message: {
            Text("Kills \(idleCount) idle session\(idleCount == 1 ? "" : "s") with nothing attached.")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: SettingsRowLayout.columnSpacing) {
            Text("Long-running zmx sessions. Idle ones can be killed to reclaim resources.")
                .font(.system(size: 11.5))
                .foregroundColor(theme.color("fg-dim"))
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                if idleCount > 0 {
                    AlasButton(title: "Kill all idle", style: .subtle) { confirmKillAllIdle = true }
                }
                AlasButton(title: "Refresh", icon: "arrow.clockwise") { reload() }
                    .disabled(isLoading)
            }
        }
        .padding(.bottom, 8)
    }

    private func subsectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.5)
            .foregroundColor(theme.color("fg-dim"))
            .padding(.top, 12)
            .padding(.bottom, 2)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(theme.color("fg-dim"))
            .padding(.vertical, 10)
    }

    // MARK: actions

    /// Active tabs honor the "confirm before closing terminal tabs" setting;
    /// in-use orphans always confirm (they may belong to another window);
    /// idle orphans kill immediately.
    private func kill(_ row: OpenSessionRow) {
        switch row.kind {
        case .active:
            if state.config.terminal.confirmCloseTabs { confirmKillRow = row }
            else { performKill(row) }
        case .orphanInUse:
            confirmKillRow = row
        case .orphanIdle:
            performKill(row)
        }
    }

    private func performKill(_ row: OpenSessionRow) {
        switch row.kind {
        case let .active(leafId, worktreeId):
            state.terminal.closeSession(id: leafId, worktreeId: worktreeId)
        case .orphanIdle, .orphanInUse:
            state.terminal.killOrphanSession(name: row.name)
        }
        reload(delay: 0.4)
    }

    private func reload(delay: TimeInterval = 0) {
        loadTask?.cancel()
        isLoading = true
        loadTask = Task {
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            let snap = await state.terminal.loadOpenSessions()
            guard !Task.isCancelled else { return }
            snapshot = snap
            isLoading = false
        }
    }
}

/// One row in the open-sessions list: a title (working-dir leaf or session
/// name), a subtitle (full path · command · age), an orphan-state badge, and
/// a Kill button.
private struct OpenSessionRowView: View {
    let row: OpenSessionRow
    let onKill: () -> Void
    @Environment(\.theme) var theme

    private var title: String {
        if let dir = row.startDir, !dir.isEmpty {
            return (dir as NSString).lastPathComponent
        }
        return row.name
    }

    private var subtitleParts: [String] {
        var parts: [String] = []
        if let dir = row.startDir, !dir.isEmpty { parts.append(dir) }
        if let cmd = row.cmd, !cmd.isEmpty { parts.append(cmd) }
        if let age = relativeAge(createdEpoch: row.created, now: Date()) { parts.append(age) }
        return parts
    }

    var body: some View {
        HStack(alignment: .top, spacing: SettingsRowLayout.columnSpacing) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(theme.color("fg"))
                    badge
                }
                if !subtitleParts.isEmpty {
                    Text(subtitleParts.joined(separator: " · "))
                        .font(.system(size: 11))
                        .foregroundColor(theme.color("fg-dim"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
            AlasButton(title: "Kill", style: .subtle, action: onKill)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .overlay(Divider().opacity(0.5), alignment: .top)
    }

    @ViewBuilder private var badge: some View {
        switch row.kind {
        case .active:
            EmptyView()
        case .orphanIdle:
            badgeLabel("idle", color: theme.color("fg-muted"))
        case .orphanInUse:
            badgeLabel("in use", color: theme.color("accent"))
        }
    }

    private func badgeLabel(_ text: String, color: Color) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.5)
            .foregroundColor(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(color.opacity(0.5), lineWidth: 0.5))
    }
}
