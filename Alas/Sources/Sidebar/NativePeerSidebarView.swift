import SwiftUI

struct NativePeerSessionRowPresentation {
    let detail: String

    init(row: RemoteSessionSummary) {
        let status = switch row.status {
        case "awaitingPermission": "Needs permission"
        case "awaitingInput": "Needs input"
        case "streaming": "Streaming"
        case "idle": "Idle"
        default: row.status
        }
        detail = [row.agentId, row.worktree?.worktreeName, status]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

/// App-scoped peer groups live beside the workspace tree, never inside a
/// worktree's Agents list.
///
/// Laid out after E1's peers section: a hairline-topped "PEERS" caption, one
/// header per Mac, and beneath each online Mac the same repo → worktree rows
/// the local tree draws, so a peer's work reads in the sidebar's own grammar.
struct NativePeerSidebarView: View {
    @Bindable var client: NativePeerSessions
    /// Resolves a repo tile for a peer's project name. Peers do not send icon
    /// metadata, so the caller can match a local project of the same name.
    var icon: (String) -> ProjectIcon = { _ in .default() }
    var onAddPeer: (() -> Void)?
    @Environment(\.theme) private var theme
    @State private var expandedPeerIDs: Set<String> = []
    /// Peer ids this view has already decided an expansion state for. Lets a
    /// peer that pairs after the section first appears still default open,
    /// without re-expanding one the user explicitly collapsed earlier.
    @State private var knownPeerIDs: Set<String> = []
    @State private var collapsedRepoIDs: Set<String> = []
    @State private var headerHovering = false
    @State private var plusHovering = false

    var body: some View {
        // The section header — and its "pair a peer" affordance — stays
        // visible even with zero peers: that empty state is exactly when a
        // way to add one is needed. Only the peer rows below it depend on
        // there being any groups to show.
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader
            ForEach(client.snapshot.groups) { group in
                peerGroup(group)
            }
        }
        .onAppear { expandNewPeers() }
        .onChange(of: client.snapshot.groups.map(\.id)) { expandNewPeers() }
    }

    /// Default-expands any peer id seen for the first time — covering both
    /// the section's initial appearance and a peer pairing later — while
    /// leaving already-known peers' expansion state (including an explicit
    /// collapse) untouched.
    private func expandNewPeers() {
        let currentIDs = Set(client.snapshot.groups.map(\.id))
        let newIDs = currentIDs.subtracting(knownPeerIDs)
        guard !newIDs.isEmpty else { return }
        expandedPeerIDs.formUnion(newIDs)
        knownPeerIDs.formUnion(newIDs)
    }

    private var sectionHeader: some View {
        HStack(spacing: 6) {
            Text("Peers")
                .textCase(.uppercase)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundColor(theme.color("fg-faint"))
            Spacer(minLength: 0)
            if let onAddPeer {
                Button(action: onAddPeer) {
                    Icon(name: "plus", size: 11,
                         color: plusHovering ? theme.color("fg") : theme.color("fg-faint"))
                        .frame(width: 19, height: 19)
                        .background(plusHovering ? theme.color("bg-4") : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .onHover { plusHovering = $0 }
                .help("Pair a peer…")
                .opacity(headerHovering ? 1 : 0)
                .allowsHitTesting(headerHovering)
            }
        }
        .frame(minHeight: 19)
        .padding(.leading, 7)
        .padding(.trailing, 5)
        .padding(.top, 10)
        .padding(.bottom, 2)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(theme.color("line"))
                .frame(height: 1)
        }
        .padding(.top, 6)
        .contentShape(Rectangle())
        .onHover { headerHovering = $0 }
    }

    @ViewBuilder
    private func peerGroup(_ group: NativePeerGroup) -> some View {
        let online = group.state.carriesSessions
        let expanded = online && expandedPeerIDs.contains(group.id)
        let repos = group.repos
        VStack(alignment: .leading, spacing: 0) {
            NativePeerHeaderRow(
                group: group,
                repoCount: repos.count,
                expanded: expanded,
                onToggle: {
                    guard online else { return }
                    if expandedPeerIDs.contains(group.id) { expandedPeerIDs.remove(group.id) }
                    else { expandedPeerIDs.insert(group.id) }
                }
            )
            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(repos) { repo in
                        repoGroup(repo, peer: group)
                    }
                }
                // Puts each repo's chevron under the peer's tile, one level
                // in, the way worktrees sit under their repo.
                .padding(.leading, 19)
            }
        }
    }

    @ViewBuilder
    private func repoGroup(_ repo: NativePeerRepoGroup, peer: NativePeerGroup) -> some View {
        let key = "\(peer.id)\u{1F}\(repo.id)"
        let collapsed = collapsedRepoIDs.contains(key)
        VStack(alignment: .leading, spacing: 0) {
            NativePeerRepoHeaderRow(
                repo: repo,
                icon: repo.name == NativePeerRepoGroup.unassignedName ? nil : icon(repo.name),
                collapsed: collapsed,
                onToggle: {
                    if collapsed { collapsedRepoIDs.remove(key) }
                    else { collapsedRepoIDs.insert(key) }
                }
            )
            if !collapsed {
                VStack(spacing: 1) {
                    ForEach(repo.worktrees) { worktree in
                        NativePeerWorktreeRow(
                            worktree: worktree,
                            peerName: peer.name,
                            selectedSessionId: client.selectedSessionId,
                            onSelect: { client.select($0) }
                        )
                    }
                }
                .padding(.leading, RepoGroupView.worktreeIndent)
                .padding(.trailing, 6)
            }
        }
    }
}

/// One Mac. Shaped like `RepoGroupView`'s header — chevron, 19pt tile, 12.5pt
/// semibold name, trailing count — with a laptop tile and a presence dot in
/// place of the project icon.
private struct NativePeerHeaderRow: View {
    let group: NativePeerGroup
    let repoCount: Int
    let expanded: Bool
    let onToggle: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    private var online: Bool { group.state.carriesSessions }

    var body: some View {
        HStack(spacing: 7) {
            Group {
                if online {
                    Icon(name: expanded ? "chev-down" : "chev-right", size: 10, color: theme.color("fg-faint"))
                } else {
                    Color.clear
                }
            }
            .frame(width: 12, height: 14)
            HStack(spacing: 7) {
                tile
                Text(group.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .tracking(-0.12)
                    .foregroundColor(theme.color("fg"))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .opacity(online ? 1 : 0.5)
            Spacer(minLength: 0)
            trailing
        }
        .padding(5)
        .background(hovering && online ? theme.color("bg-3").opacity(0.55) : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(theme.color("line").opacity(hovering && online ? 0.75 : 0), lineWidth: 0.75)
        }
        .padding(.top, 3)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onToggle)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(online ? .isButton : [])
    }

    private var tile: some View {
        Image(systemName: "laptopcomputer")
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(theme.color("fg-muted"))
            .frame(width: 19, height: 19)
            .background(theme.color("bg-4"), in: RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(theme.color("line"), lineWidth: 1)
            }
            // E1 rings the dot in the sidebar color. The sidebar here is a
            // translucent material, so punch a real gap out of the tile
            // instead of painting one.
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .frame(width: 10, height: 10)
                    .offset(x: 4, y: 4)
                    .blendMode(.destinationOut)
            }
            .compositingGroup()
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(theme.color(presenceColorToken))
                    .frame(width: 6, height: 6)
                    .offset(x: 2, y: 2)
            }
            .accessibilityHidden(true)
    }

    private var presenceColorToken: String {
        switch group.state {
        case .online: "add"
        case .connecting: "mod"
        case .tokenRevoked, .identityMismatch, .incompatible: "del"
        case .offline, .identityUnproven, .idle, .unavailable: "fg-faint"
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if online {
            HStack(spacing: 6) {
                if group.attentionCount > 0 {
                    NativePeerAttentionCount(count: group.attentionCount)
                }
                Text("\(repoCount)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.color("fg-faint"))
                    .monospacedDigit()
            }
            .padding(.trailing, 3)
        } else {
            Text(group.state.label.lowercased())
                .font(.system(size: 10))
                .foregroundColor(theme.color("fg-faint"))
                .lineLimit(1)
                .padding(.trailing, 3)
        }
    }

    private var accessibilityLabel: String {
        var parts = [group.name, group.state.label]
        if group.attentionCount > 0 { parts.append("\(group.attentionCount) need attention") }
        return parts.joined(separator: ", ")
    }
}

/// A peer's repo. The same header `RepoGroupView` draws, minus the actions a
/// remote project cannot take here.
private struct NativePeerRepoHeaderRow: View {
    let repo: NativePeerRepoGroup
    let icon: ProjectIcon?
    let collapsed: Bool
    let onToggle: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            Icon(name: collapsed ? "chev-right" : "chev-down", size: 10, color: theme.color("fg-faint"))
                .frame(width: 12, height: 14)
            if let icon {
                ProjectIconView(icon: icon, fallbackName: repo.name, size: .repoHeader)
            } else {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundColor(theme.color("fg-muted"))
                    .frame(width: 19, height: 19)
                    .background(theme.color("bg-4"), in: RoundedRectangle(cornerRadius: 5))
                    .accessibilityHidden(true)
            }
            Text(repo.name)
                .font(.system(size: 12.5, weight: .semibold))
                .tracking(-0.12)
                .foregroundColor(theme.color("fg"))
                .lineLimit(1)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                if collapsed, repo.attentionCount > 0 {
                    NativePeerAttentionCount(count: repo.attentionCount)
                }
                Text("\(repo.worktrees.count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.color("fg-faint"))
                    .monospacedDigit()
            }
            .padding(.trailing, 3)
        }
        .padding(5)
        .background(hovering ? theme.color("bg-3").opacity(0.55) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(theme.color("line").opacity(hovering ? 0.75 : 0), lineWidth: 0.75)
        }
        .padding(.top, 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onToggle)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(repo.name), \(repo.worktrees.count) worktrees")
        .accessibilityAddTraits(.isButton)
    }
}

/// A peer worktree, drawn with `WorktreeRowView`'s two-line metrics: branch
/// and agent tiles on line 1, status chip, diff and age on line 2.
private struct NativePeerWorktreeRow: View {
    let worktree: NativePeerWorktreeGroup
    let peerName: String
    let selectedSessionId: String?
    let onSelect: (String) -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    private var isSelected: Bool {
        guard let selectedSessionId else { return false }
        return worktree.sessions.contains { $0.id == selectedSessionId }
    }

    var body: some View {
        let status = worktree.status
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                Icon(name: "branch", size: 12,
                     color: theme.color(status?.pulses == true ? "add" : "fg-faint"))
                Text(worktree.title)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.color("fg"))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                agentBadges
            }
            .frame(minHeight: HarnessSessionBadge.diameter)
            secondLine(status: status)
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 9)
                    .fill(theme.color("accent-soft"))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(theme.color("accent").opacity(0.5), lineWidth: 0.5)
                    )
            } else if hovering {
                RoundedRectangle(cornerRadius: 9)
                    .fill(theme.color("bg-3").opacity(0.55))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(theme.color("line").opacity(0.75), lineWidth: 0.75)
                    )
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { onSelect(worktree.primarySession.id) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }

    private func secondLine(status: WorktreeRowView.StatusPresentation?) -> some View {
        HStack(spacing: 7) {
            if let status {
                HStack(spacing: 5) {
                    StatusDot(color: theme.color(status.colorToken), pulses: status.pulses)
                    Text(status.note)
                        .foregroundColor(theme.color(status.colorToken))
                }
                .fixedSize()
            } else if worktree.sessions.count == 1 {
                // Nothing to report, so the chat's own title fills the slot a
                // status chip would take.
                Text(worktree.primarySession.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if let summary = worktree.worktree, summary.metricsAvailable,
               let additionTicks = WorktreeRowView.diffBarAdditionCount(
                   added: summary.addedLines, deleted: summary.deletedLines
               ) {
                HStack(spacing: 5) {
                    HStack(spacing: 1.5) {
                        ForEach(0..<5) { tick in
                            RoundedRectangle(cornerRadius: 1)
                                .fill(theme.color(tick < additionTicks ? "add" : "del"))
                                .frame(width: 2, height: 7)
                        }
                    }
                    .accessibilityHidden(true)
                    if summary.addedLines > 0 {
                        Text("+\(summary.addedLines)").foregroundColor(theme.color("add"))
                    }
                    if summary.deletedLines > 0 {
                        Text("−\(summary.deletedLines)").foregroundColor(theme.color("del"))
                    }
                }
                .font(.system(size: 10, design: .monospaced))
                .fixedSize()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(summary.addedLines) lines added, \(summary.deletedLines) lines deleted")
            }
            Spacer(minLength: 0)
            if worktree.updatedAt > 0 {
                Text(Self.relative(worktree.updatedAt))
                    .monospacedDigit()
                    .fixedSize()
            }
        }
        .font(.system(size: 10))
        .foregroundColor(theme.color("fg-dim"))
        .padding(.leading, 19)
    }

    private var agentBadges: some View {
        let visible = WorktreeRowView.visibleHarnessSessionCount(for: worktree.sessions.count)
        return HStack(spacing: 4) {
            ForEach(worktree.sessions.prefix(visible), id: \.id) { session in
                NativePeerAgentBadge(
                    session: session,
                    isSelected: session.id == selectedSessionId,
                    onActivate: { onSelect(session.id) }
                )
            }
            if worktree.sessions.count > visible {
                let hidden = Array(worktree.sessions.dropFirst(visible))
                Menu {
                    ForEach(hidden, id: \.id) { session in
                        Button {
                            onSelect(session.id)
                        } label: {
                            Label {
                                Text(session.title)
                            } icon: {
                                if let agent = AgentKind(rawValue: session.agentId) {
                                    Image(agent.logoAssetName)
                                } else {
                                    Image(systemName: "sparkles")
                                }
                            }
                        }
                        .badge(Self.overflowBadgeText(for: session).map(Text.init))
                    }
                } label: {
                    Text("+\(hidden.count)")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.color("fg-dim"))
                        .frame(width: HarnessSessionBadge.diameter, height: HarnessSessionBadge.diameter)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                // Same aggregate surface `HarnessSessionOverflowBadge` uses
                // locally, so a hidden session needing attention still shows
                // through the collapsed chip. Unlike the local, active-only
                // harness collection, a peer's hidden sessions can all be
                // idle history, which draws no chrome at all.
                .modifier(OptionalBadgeChrome(
                    surface: Self.overflowSurface(for: hidden),
                    isSelected: hidden.contains { $0.id == selectedSessionId }
                ))
                .accessibilityLabel("\(hidden.count) more sessions")
            }
        }
    }

    private var accessibilityLabel: String {
        let detail = NativePeerSessionRowPresentation(row: worktree.primarySession).detail
        return "\(worktree.title), \(detail), \(peerName) peer session"
    }

    /// The overflow chip's aggregate surface: mixed when the hidden sessions
    /// span both running and waiting, otherwise whichever of the two they
    /// share. Nil — no chrome at all — when every hidden session is idle:
    /// unlike the active-only local harness collection
    /// `HarnessSessionBadgeSurface.init(sessions:)` mirrors, a peer's hidden
    /// sessions can be idle history with nothing pending.
    private static func overflowSurface(for sessions: [RemoteSessionSummary]) -> HarnessSessionBadgeSurface? {
        let hasRunning = sessions.contains { $0.status == "streaming" }
        let hasWaiting = sessions.contains { NativePeerWorktreeGroup.waitingStatuses.contains($0.status) }
        switch (hasRunning, hasWaiting) {
        case (true, true): return .mixed
        case (true, false): return .running
        case (false, true): return .awaiting
        case (false, false): return nil
        }
    }

    /// A hidden session's own badge in the overflow menu, so a waiting
    /// session doesn't read as indistinguishable from an idle one once it
    /// falls past the visible-badge limit.
    private static func overflowBadgeText(for session: RemoteSessionSummary) -> String? {
        if NativePeerWorktreeGroup.waitingStatuses.contains(session.status) { return "Waiting" }
        if session.status == "streaming" { return "Running" }
        return nil
    }

    private static func relative(_ seconds: Int64) -> String {
        relativeDateFormatter.localizedString(
            for: Date(timeIntervalSince1970: TimeInterval(seconds)),
            relativeTo: Date()
        )
    }

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

/// E1's agent tile for one peer session. A working session gets the filled
/// running/waiting chip the local rows use; an idle one shows the bare logo
/// (E1's `.agent.bare`) so only live work carries color.
private struct NativePeerAgentBadge: View {
    let session: RemoteSessionSummary
    let isSelected: Bool
    let onActivate: () -> Void
    @Environment(\.theme) private var theme

    private var agent: AgentKind? { AgentKind(rawValue: session.agentId) }

    private var surface: HarnessSessionBadgeSurface? {
        if NativePeerWorktreeGroup.waitingStatuses.contains(session.status) { return .awaiting }
        if session.status == "streaming" { return .running }
        return nil
    }

    var body: some View {
        Button(action: onActivate) {
            Group {
                if let agent {
                    Image(agent.logoAssetName)
                        .resizable()
                        .renderingMode(.original)
                        .scaledToFit()
                } else {
                    Image(systemName: "sparkles")
                        .resizable()
                        .scaledToFit()
                        .foregroundColor(theme.color("fg-muted"))
                }
            }
            .frame(width: HarnessSessionBadge.logoSize, height: HarnessSessionBadge.logoSize)
            .frame(width: HarnessSessionBadge.diameter, height: HarnessSessionBadge.diameter)
            .modifier(OptionalBadgeChrome(surface: surface, isSelected: isSelected))
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .accessibilityLabel(tooltip)
    }

    private var tooltip: String {
        let name = agent?.displayName ?? session.agentId
        return "\(name) · \(session.title) · \(NativePeerSessionRowPresentation(row: session).detail)"
    }
}

private struct OptionalBadgeChrome: ViewModifier {
    let surface: HarnessSessionBadgeSurface?
    let isSelected: Bool

    func body(content: Content) -> some View {
        if let surface {
            content.modifier(HarnessSessionBadgeChrome(surface: surface, isSelected: isSelected))
        } else {
            content
        }
    }
}

/// E1's `.need`: an orange dot and the number of sessions waiting on you.
private struct NativePeerAttentionCount: View {
    let count: Int
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(theme.color("mod"))
                .frame(width: 5, height: 5)
            Text("\(count)")
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
        }
        .foregroundColor(theme.color("mod"))
        .help("\(count) waiting on you")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) need attention")
    }
}
