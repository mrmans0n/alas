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

/// User-controlled collapse state, retained outside the lazy rows.
@MainActor
@Observable
final class NativePeerSidebarModel {
    var collapsedRepoIDs: Set<String> = []
    /// The peer worktree whose rename sheet is open. Held here, not on a
    /// lazy row, so the sheet survives its row scrolling away.
    var renamingBranch: NativePeerBranchRename?
    /// Told how much content a collapse is about to remove. Set by the visible
    /// list's scroll view.
    @ObservationIgnored var willShrinkContent: ((CGFloat) -> Void)?

    func toggleRepo(_ key: String, worktrees: [NativePeerWorktreeGroup]) {
        guard !collapsedRepoIDs.contains(key) else {
            collapsedRepoIDs.remove(key)
            return
        }
        willShrinkContent?(worktrees.reduce(0) {
            $0 + ($1.updatedAt > 0 || $1.status != nil ? 43 : 41) // design-literal: comfortable row height estimate
        })
        collapsedRepoIDs.insert(key)
    }
}

struct NativePeerBranchRename: Identifiable {
    let worktree: PeerHostWorktree
    let serverId: String
    let peerName: String
    var id: String { "\(serverId)\u{1F}\(worktree.snapshot.worktree.id)" }
}

/// One paired Mac's page in the sidebar pager: its repos at the root, each
/// with its worktrees, in the grammar the local tree uses. The page's header
/// names the Mac, so no row here does.
struct NativePeerSidebarView: View {
    @Bindable var client: NativePeerSessions
    @Bindable var model: NativePeerSidebarModel
    let serverId: String
    /// The sidebar's worktree filter.
    var filter: String = ""
    /// The filter's keyboard highlight.
    var highlightedWorktreeId: String?
    /// Resolves a repo tile for a peer's project name. Peers do not send icon
    /// metadata, so the caller can match a local project of the same name.
    var icon: (String) -> ProjectIcon = { _ in .default() }
    /// Opens this Mac's sheet in Settings › Remote.
    var onEdit: () -> Void = {}
    /// The local sidebar's worktree ordering, applied to every peer's worktrees.
    var worktreeOrdering: AppConfig.WorktreeSortMode = .lastUpdateDesc
    /// Offers "Delete Worktree, Keep Branch…" under the local rule
    /// (`config.worktrees.deleteBranchOnRemove` on this Mac).
    var showKeepBranchOption: Bool = false
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale

    /// The worktree ids the filter leaves, in display order, for its
    /// keyboard navigation.
    static func filteredWorktreeIds(
        _ client: NativePeerSessions, serverId: String, filter: String, ordering: AppConfig.WorktreeSortMode
    ) -> [String] {
        guard let group = client.snapshot.groups.first(where: { $0.serverId == serverId }),
              group.state.carriesSessions else { return [] }
        return NativePeerRepoGroup.filtered(group.repos(ordering: ordering), query: filter).flatMap(\.worktrees).map(\.id)
    }

    /// Every header and row is its own element, so a lazy stack around the
    /// page mounts only the rows on screen.
    var body: some View {
        if let group = client.snapshot.groups.first(where: { $0.serverId == serverId }) {
            if group.state.carriesSessions {
                let filtering = WorktreeSidebarFilter.isActive(filter)
                let repos = NativePeerRepoGroup.filtered(group.repos(ordering: worktreeOrdering), query: filter)
                if repos.isEmpty {
                    NativePeerSpaceMessage(
                        title: filtering ? "No matching worktrees" : "No projects yet",
                        detail: filtering ? nil : "Projects added on \(group.name) show here."
                    )
                }
                ForEach(repos) { repo in
                    repoGroup(repo, peer: group, filtering: filtering)
                }
            } else {
                NativePeerSpaceUnavailable(group: group, onEdit: onEdit)
            }
        }
    }

    @ViewBuilder
    private func repoGroup(_ repo: NativePeerRepoGroup, peer: NativePeerGroup, filtering: Bool) -> some View {
        let key = "\(peer.id)\u{1F}\(repo.id)"
        // A filter shows its matches even inside a collapsed repo.
        let collapsed = !filtering && model.collapsedRepoIDs.contains(key)
        NativePeerRepoHeaderRow(
            repo: repo,
            icon: repo.name == NativePeerRepoGroup.unassignedName ? nil : icon(repo.name),
            collapsed: collapsed,
            peerName: peer.name,
            onNewSession: peer.state.carriesSessions && repo.projectId != nil
                ? { client.beginNewSession(peer: peer, repo: repo) }
                : nil,
            onToggle: { model.toggleRepo(key, worktrees: repo.worktrees) }
        )
        .equatable()
        .contextMenu { repoMenu(repo, peer: peer) }
        if !collapsed {
            ForEach(Array(repo.worktrees.enumerated()), id: \.element.id) { index, worktree in
                let selection = NativePeerWorktreeSelection(serverId: peer.serverId, worktreeId: worktree.id)
                let isSelected = client.selectedWorktree == selection
                NativePeerWorktreeRow(
                    worktree: worktree,
                    peerName: peer.name,
                    isSelected: isSelected,
                    isHighlighted: worktree.id == highlightedWorktreeId,
                    selectedTab: isSelected ? client.selectedTab : nil,
                    onSelect: { client.selectWorktree(selection) },
                    onSelectTab: { client.selectTab($0, in: selection) }
                )
                .equatable()
                .contextMenu { worktreeMenu(worktree, peer: peer) }
                .id(worktree.id)
                .padding(.top, index == 0 ? 0 : 1)
                .padding(.leading, RepoGroupView.worktreeIndent)
                .padding(.trailing, scale.space[1])
            }
            if !filtering, let hosts = client.hosts, let projectId = repo.projectId {
                let archived = (hosts.archivedWorktrees[peer.serverId] ?? []).filter {
                    // A Machine checkout's archived rows sit with its local project, like its live ones.
                    ($0.project.linkedProjectId ?? $0.project.id) == projectId
                }
                ForEach(archived, id: \.snapshot.worktree.id) { worktree in
                    NativePeerArchivedWorktreeRow(worktree: worktree)
                        .contextMenu { archivedWorktreeMenu(worktree, hosts: hosts, peer: peer) }
                        .padding(.top, 1) // design-literal: 1pt gap between sibling rows, as in the local list
                        .padding(.leading, RepoGroupView.worktreeIndent)
                        .padding(.trailing, scale.space[1])
                }
            }
        }
    }

    /// The project's gg mode, as Settings sets a local one's.
    @ViewBuilder
    private func repoMenu(_ repo: NativePeerRepoGroup, peer: NativePeerGroup) -> some View {
        if let hosts = client.hosts, let projectId = repo.projectId,
           let mode = hosts.ggMode(projectId: projectId, serverId: peer.serverId) {
            Picker(WorktreeRowView.ggModeMenuTitle, selection: Binding(
                get: { mode },
                set: { hosts.setGGMode($0, projectId: projectId, serverId: peer.serverId) }
            )) {
                Text("Off").tag(GGProjectMode.off)
                Text("Auto").tag(GGProjectMode.auto)
                Text("On").tag(GGProjectMode.on)
            }
        }
    }

    @ViewBuilder
    private func archivedWorktreeMenu(_ worktree: PeerHostWorktree, hosts: NativePeerHosts, peer: NativePeerGroup) -> some View {
        let checkout = worktree.snapshot.worktree
        Button("Copy Path") { Clipboard.copyPath(checkout.path.path) }
        if !checkout.branch.isEmpty {
            Button("Copy Branch Name") { Clipboard.copy(checkout.branch) }
        }
        if hosts.canUnarchive(serverId: peer.serverId) {
            Divider()
            Button("Unarchive") { hosts.unarchive(worktree, serverId: peer.serverId) }
        }
    }

    /// "New Terminal" for a host that opens shells, then the local row's
    /// Archive and Delete items, for a host that serves them.
    @ViewBuilder
    private func worktreeMenu(_ worktree: NativePeerWorktreeGroup, peer: NativePeerGroup) -> some View {
        let controls = worktree.host.flatMap { client.hosts?.controls(for: $0, serverId: peer.serverId) } ?? .hidden
        if let consoles = client.consoles, consoles.canOpen(serverId: peer.serverId) {
            let worktreeId = worktree.peerWorktreeId
            Button("New Terminal") {
                if let worktreeId { consoles.openTerminal(serverId: peer.serverId, worktreeId: worktreeId) }
            }
            .disabled(worktreeId == nil)
            // Everything below needs the summary, which a host record implies.
            if worktree.worktree != nil { Divider() }
        }
        // Paths on the host Mac, copied as their real paths.
        if let summary = worktree.worktree {
            Button("Copy Path") { Clipboard.copyPath(summary.path) }
            // Folder-project rows have no branch.
            if !summary.branch.isEmpty {
                Button("Copy Branch Name") { Clipboard.copy(summary.branch) }
            }
        }
        if let host = worktree.host, let hosts = client.hosts, hosts.canRenameBranch(host, serverId: peer.serverId) {
            Button("Rename Branch…") {
                model.renamingBranch = NativePeerBranchRename(worktree: host, serverId: peer.serverId, peerName: peer.name)
            }
        }
        if let host = worktree.host, let hosts = client.hosts {
            if controls != .hidden {
                Divider()
                let disabled = controls != .available
                let delete = { (keepBranch: Bool) in
                    hosts.delete(
                        host, keepBranch: keepBranch,
                        deleteBranchIfMerged: AppState.resolveDeleteBranchIfMerged(
                            globalDeleteOnRemove: showKeepBranchOption, keepBranch: keepBranch
                        ),
                        serverId: peer.serverId, peerName: peer.name
                    )
                }
                Button("Archive") { hosts.archive(host, serverId: peer.serverId, peerName: peer.name) }
                    .disabled(disabled)
                Button("Delete Worktree…", role: .destructive) { delete(false) }
                    .disabled(disabled)
                if showKeepBranchOption {
                    Button("Delete Worktree, Keep Branch…", role: .destructive) { delete(true) }
                        .disabled(disabled)
                }
                if case .disabled(let reason) = controls {
                    Text(reason)
                }
            }
        }
    }
}

/// Pinned above a peer's page: which Mac this is, whether it is reachable,
/// and how much of its work waits on you. Reads only `NativePeerPage`, so
/// streamed session updates do not redraw it.
struct NativePeerSpaceHeader: View {
    static let height: CGFloat = 44 // design-literal: tile plus two text lines and padding

    let peer: NativePeerPage
    /// Nil while the peer is offline: its inventory is not known.
    let worktreeCount: Int?
    let onEdit: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale

    var body: some View {
        HStack(spacing: scale.space[2]) {
            PeerIconTile(icon: peer.icon, presenceToken: peer.state.presenceColorToken, side: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(peer.name)
                    .font(scale.titleFont)
                    .foregroundColor(theme.color("fg"))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(scale.metaFont)
                    .foregroundColor(theme.color("fg-dim"))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if peer.attentionCount > 0 {
                NativePeerAttentionCount(count: peer.attentionCount)
            }
        }
        .padding(.horizontal, scale.space[3])
        .frame(height: Self.height)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.color("line")).frame(height: 1)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Edit…", action: onEdit)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(peer.name)
        .accessibilityValue(peer.accessibilityValue)
    }

    private var subtitle: String {
        guard peer.state.carriesSessions, let worktreeCount else { return peer.state.label }
        return "\(peer.state.label) · \(worktreeCount) \(worktreeCount == 1 ? "worktree" : "worktrees")"
    }
}

/// A peer page whose Mac is not reachable: its worktrees are unknown until
/// it is, so the page explains why instead of listing nothing.
private struct NativePeerSpaceUnavailable: View {
    let group: NativePeerGroup
    let onEdit: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale

    var body: some View {
        VStack(spacing: scale.space[2]) {
            PeerIconView(icon: group.icon, size: 30)
                .foregroundColor(theme.color("fg-faint"))
            Text(group.state.label)
                .font(scale.emphasisFont)
                .foregroundColor(theme.color("fg"))
            Text(group.state.unavailableDetail(peerName: group.name))
                .font(scale.metaFont)
                .foregroundColor(theme.color("fg-dim"))
                .multilineTextAlignment(.center)
            Button("Edit \(group.name)…", action: onEdit)
                .controlSize(.small)
                .padding(.top, scale.space[1])
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, scale.space[4])
        .padding(.top, scale.space[5])
    }
}

/// A one- or two-line note where a peer page has no rows to show.
private struct NativePeerSpaceMessage: View {
    let title: String
    let detail: String?
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale

    var body: some View {
        VStack(spacing: scale.space[1]) {
            Text(title)
                .font(scale.emphasisFont)
                .foregroundColor(theme.color("fg-dim"))
            if let detail {
                Text(detail)
                    .font(scale.metaFont)
                    .foregroundColor(theme.color("fg-faint"))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, scale.space[4])
        .padding(.top, scale.space[5])
    }
}

/// A peer's repo. The same header `RepoGroupView` draws, minus the actions a
/// remote project cannot take here.
private struct NativePeerRepoHeaderRow: View, Equatable {
    /// `onNewSession` follows from the repo's id: this row only draws for an
    /// online peer, and only the "Other sessions" bucket has no action.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.repo.id == rhs.repo.id && lhs.repo.name == rhs.repo.name
            && lhs.repo.worktrees.count == rhs.repo.worktrees.count
            && lhs.repo.attentionCount == rhs.repo.attentionCount
            && lhs.icon == rhs.icon && lhs.collapsed == rhs.collapsed && lhs.peerName == rhs.peerName
    }

    let repo: NativePeerRepoGroup
    let icon: ProjectIcon?
    let collapsed: Bool
    let peerName: String
    /// Nil hides the "+": the "Other sessions" bucket and offline peers.
    let onNewSession: (() -> Void)?
    let onToggle: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale
    @State private var hovering = false

    var body: some View {
        HStack(spacing: scale.space[2]) {
            HStack(spacing: scale.space[2]) {
                Icon(name: collapsed ? "chev-right" : "chev-down", size: 10, color: theme.color("fg-faint"))
                    .frame(width: 12, height: 14)
                if let icon {
                    ProjectIconView(icon: icon, fallbackName: repo.name, size: .repoHeader)
                } else {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(scale.glyph.font(weight: .medium))
                        .foregroundColor(theme.color("fg-muted"))
                        .frame(width: 19, height: 19) // design-literal: icon tile
                        .background(theme.color("bg-4"), in: RoundedRectangle(cornerRadius: scale.radius.small))
                        .accessibilityHidden(true)
                }
                Text(repo.name)
                    .font(scale.titleFont)
                    .foregroundColor(theme.color("fg"))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggle)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(repo.name), \(repo.worktrees.count) worktrees")
            .accessibilityAddTraits(.isButton)
            HStack(spacing: 6) {
                if collapsed, repo.attentionCount > 0 {
                    NativePeerAttentionCount(count: repo.attentionCount)
                }
                if let onNewSession {
                    SidebarHeaderCountPlusButton(
                        count: repo.worktrees.count,
                        rowHovering: hovering,
                        help: "New session in \(repo.name) on \(peerName)",
                        action: onNewSession
                    )
                } else {
                    Text("\(repo.worktrees.count)")
                        .font(scale.captionFont)
                        .foregroundColor(theme.color("fg-faint"))
                        .monospacedDigit()
                }
            }
            .padding(.trailing, scale.space[1])
        }
        .padding(.horizontal, scale.space[1])
        .padding(.vertical, scale.space[2])
        .background(hovering ? theme.sidebarHoverFill : .clear, in: RoundedRectangle(cornerRadius: scale.radius.medium))
        .overlay {
            RoundedRectangle(cornerRadius: scale.radius.medium)
                .strokeBorder(theme.color("line").opacity(hovering ? 0.75 : 0), lineWidth: 0.75)
        }
        .padding(.top, 1) // design-literal: 1pt gap above a repo header, as in the local list
        .contentShape(Rectangle())
        .sidebarHover { hovering = $0 }
    }
}

/// A peer worktree, drawn with `WorktreeRowView`'s two-line metrics: branch
/// plus agent and console tiles on line 1, status chip, diff and age on line 2.
private struct NativePeerWorktreeRow: View, Equatable {
    /// The closures only name the worktree, which `worktree` already identifies.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.worktree == rhs.worktree && lhs.peerName == rhs.peerName && lhs.isSelected == rhs.isSelected
            && lhs.isHighlighted == rhs.isHighlighted && lhs.selectedTab == rhs.selectedTab
    }

    let worktree: NativePeerWorktreeGroup
    let peerName: String
    let isSelected: Bool
    /// The sidebar filter's keyboard highlight, drawn as a hover is.
    var isHighlighted = false
    /// The worktree's selected tab; nil unless `isSelected`.
    let selectedTab: NativePeerTab?
    let onSelect: () -> Void
    let onSelectTab: (NativePeerTab) -> Void
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale
    @State private var hovering = false

    /// Width of the slot that holds the branch icon; the second line starts
    /// where the name does, as in the local row.
    private static let glyphSlotWidth: CGFloat = 12
    private var textInset: CGFloat { Self.glyphSlotWidth + scale.space[2] }

    var body: some View {
        let status = worktree.status
        VStack(alignment: .leading, spacing: scale.space[0]) {
            HStack(spacing: scale.space[2]) {
                Icon(name: "branch", size: Self.glyphSlotWidth,
                     color: theme.color(status == NativePeerWorktreeGroup.running ? "add" : "fg-faint"))
                Text(worktree.title)
                    .font(isSelected ? scale.emphasisFont : scale.bodyFont)
                    .foregroundColor(theme.color("fg"))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                agentBadges
            }
            .frame(minHeight: HarnessSessionBadge.diameter)
            secondLine(status: status)
        }
        .padding(.horizontal, scale.space[2])
        .padding(.vertical, scale.space[1])
        .frame(maxWidth: .infinity, minHeight: scale.sidebarRowMinHeight, alignment: .leading)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: scale.radius.medium)
                    .fill(theme.color("accent-soft"))
                    .overlay(
                        RoundedRectangle(cornerRadius: scale.radius.medium)
                            .strokeBorder(theme.color("accent").opacity(0.5), lineWidth: 0.5)
                    )
            } else if hovering || isHighlighted {
                RoundedRectangle(cornerRadius: scale.radius.medium)
                    .fill(theme.sidebarHoverFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: scale.radius.medium)
                            .strokeBorder(theme.color("line").opacity(0.75), lineWidth: 0.75)
                    )
            }
        }
        .contentShape(Rectangle())
        .sidebarHover { hovering = $0 }
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private func secondLine(status: WorktreeRowView.StatusPresentation?) -> some View {
        if status != nil {
            // Everything a row knows stays on screen: narrow sidebars drop the
            // time before the status word is cut short.
            ViewThatFits(in: .horizontal) {
                secondLineContents(status: status, showsTime: true)
                secondLineContents(status: status, showsTime: false)
            }
            .font(scale.metaFont)
            .foregroundColor(theme.color("fg-dim"))
            .padding(.leading, textInset)
        } else {
            secondLineContents(status: nil, showsTime: true)
                .font(scale.metaFont)
                .foregroundColor(theme.color("fg-dim"))
                .padding(.leading, textInset)
        }
    }

    private func secondLineContents(
        status: WorktreeRowView.StatusPresentation?,
        showsTime: Bool
    ) -> some View {
        HStack(spacing: scale.space[2]) {
            if let status {
                HStack(spacing: 5) {
                    StatusDot(color: theme.color(status.colorToken), pulses: status.pulses)
                    // A host's failure carries git's message, which can be long.
                    Text(status.note)
                        .foregroundColor(theme.color(status.colorToken))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .layoutPriority(1)
                .help(status.note)
            } else if worktree.sessions.count == 1, let session = worktree.sessions.first {
                // Nothing to report, so the chat's own title fills the slot a
                // status chip would take.
                Text(session.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else if worktree.sessions.isEmpty, worktree.consoles.count == 1 {
                Text(worktree.consoles[0].title)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if let summary = worktree.worktree, summary.metricsAvailable,
               summary.addedLines > 0 || summary.deletedLines > 0 {
                HStack(spacing: 5) {
                    if summary.addedLines > 0 {
                        Text("+" + WorktreeRowPresentation.compactCount(summary.addedLines)).foregroundColor(theme.color("add"))
                    }
                    if summary.deletedLines > 0 {
                        Text("−" + WorktreeRowPresentation.compactCount(summary.deletedLines)).foregroundColor(theme.color("del"))
                    }
                }
                .monospacedDigit()
                .fixedSize()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(summary.addedLines) lines added, \(summary.deletedLines) lines deleted")
            }
            Spacer(minLength: 0)
            if showsTime, worktree.updatedAt > 0 {
                // Keeps aging on its own: a row only re-renders when its data changes.
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(Self.relative(worktree.updatedAt, now: context.date))
                        .monospacedDigit()
                        .fixedSize()
                }
            }
        }
    }

    /// The worktree's tabs in the host's order, sharing the visible-badge limit.
    private var agentBadges: some View {
        let badges = worktree.tabRows
        let visible = WorktreeRowView.visibleHarnessSessionCount(for: badges.count)
        return HStack(spacing: 4) {
            ForEach(badges.prefix(visible)) { badge in
                switch badge {
                case .session(let session):
                    NativePeerAgentBadge(
                        session: session,
                        onActivate: { onSelectTab(badge.id) }
                    )
                case .console(let console):
                    NativePeerConsoleBadge(
                        console: console,
                        isSelected: badge.id == selectedTab,
                        onActivate: { onSelectTab(badge.id) }
                    )
                }
            }
            if badges.count > visible {
                let hiddenBadges = Array(badges.dropFirst(visible))
                let hidden = hiddenBadges.compactMap {
                    if case .session(let session) = $0 { session } else { nil }
                }
                Menu {
                    ForEach(hiddenBadges) { badge in
                        switch badge {
                        case .session(let session):
                            Button {
                                onSelectTab(badge.id)
                            } label: {
                                Label {
                                    Text(session.title)
                                } icon: {
                                    if let agent = AgentKind(rawValue: session.agentId) {
                                        Image(nsImage: AgentLogoView.menuImage(for: agent, size: 14))
                                    } else {
                                        Image(systemName: "sparkles")
                                    }
                                }
                            }
                            .badge(Self.overflowBadgeText(for: session).map(Text.init))
                        case .console(let console):
                            Button {
                                onSelectTab(badge.id)
                            } label: {
                                Label(console.title, systemImage: Icon.symbol(for: "terminal"))
                            }
                        }
                    }
                } label: {
                    Text("+\(hiddenBadges.count)")
                        .font(scale.glyph.font(weight: .medium, design: .monospaced))
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
                .modifier(OptionalBadgeChrome(surface: Self.overflowSurface(for: hidden)))
                .accessibilityLabel("\(hiddenBadges.count) more")
            }
        }
    }

    private var accessibilityLabel: String {
        var parts = [worktree.title]
        if let session = worktree.sessions.first {
            parts.append(NativePeerSessionRowPresentation(row: session).detail)
        }
        if !worktree.consoles.isEmpty {
            parts.append(worktree.consoles.count == 1 ? "1 console" : "\(worktree.consoles.count) consoles")
        }
        parts.append("\(peerName) peer worktree")
        return parts.joined(separator: ", ")
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

    private static func relative(_ seconds: Int64, now: Date) -> String {
        relativeDateFormatter.localizedString(
            for: Date(timeIntervalSince1970: TimeInterval(seconds)),
            relativeTo: now
        )
    }

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

/// An archived peer worktree, dimmed under an archive icon as an archived
/// Workspace checkout is. Only its menu acts on it.
private struct NativePeerArchivedWorktreeRow: View {
    let worktree: PeerHostWorktree
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale

    var body: some View {
        let title = worktree.snapshot.worktree.title
        HStack(spacing: scale.space[2]) {
            Icon(name: "archivebox", size: 12, color: theme.color("fg-faint"))
            Text(title)
                .font(scale.bodyFont)
                .foregroundColor(theme.color("fg-dim"))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, scale.space[2])
        .frame(minHeight: 28) // design-literal: single-line archived row
        .contentShape(Rectangle())
        .help("\(title) is archived on the host")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), archived")
    }
}

/// E1's agent tile for one peer session. A working session gets the filled
/// running/waiting chip the local rows use; an idle one shows the bare logo
/// (E1's `.agent.bare`) so only live work carries color.
private struct NativePeerAgentBadge: View {
    let session: RemoteSessionSummary
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
            .modifier(OptionalBadgeChrome(surface: surface))
        }
        .buttonStyle(.plain)
        .agentBadgePopover { AgentBadgePopoverModel(peer: session) }
        .accessibilityLabel(tooltip)
    }

    private var tooltip: String {
        let name = agent?.displayName ?? session.agentId
        return "\(name) · \(session.title) · \(NativePeerSessionRowPresentation(row: session).detail)"
    }
}

/// E1's `.need`: an orange dot and the number of sessions waiting on you.
private struct NativePeerAttentionCount: View {
    let count: Int
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(theme.color("mod"))
                .frame(width: 5, height: 5)
            Text("\(count)")
                .font(scale.captionFont)
                .monospacedDigit()
        }
        .foregroundColor(theme.color("mod"))
        .help("\(count) waiting on you")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) need attention")
    }
}

/// A console on a peer's worktree, drawn with the terminal symbol local
/// terminal tabs use. Opens in the center pane on tap.
private struct NativePeerConsoleBadge: View {
    let console: PeerConsoleSummary
    let isSelected: Bool
    let onActivate: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: onActivate) {
            Image(systemName: Icon.symbol(for: "terminal"))
                .resizable()
                .scaledToFit()
                .foregroundColor(theme.color(isSelected ? "fg" : "fg-muted"))
                .frame(width: HarnessSessionBadge.logoSize, height: HarnessSessionBadge.logoSize)
                .frame(width: HarnessSessionBadge.diameter, height: HarnessSessionBadge.diameter)
        }
        .buttonStyle(.plain)
        .help("Console · \(console.title)")
        .accessibilityLabel("Console \(console.title)")
    }
}
