import AlasCore
import SwiftUI

/// What the spaces pager's hover card says about one paired Mac.
struct PeerHoverCardModel {
    struct Row {
        let title: String
        let branch: String?
        let isWaiting: Bool
    }

    struct Counts {
        let waiting: Int
        let working: Int
        let terminals: Int
        let worktrees: Int
    }

    let name: String
    let icon: PeerIcon
    let state: NativePeerState
    let subtitle: String?
    let connection: PeerConnectionKind?
    /// The latest ping round trip; nil until the first ping comes back.
    let roundTrip: Duration?
    /// Nil while the Mac is not online.
    let counts: Counts?
    let rowsTitle: String
    let rows: [Row]
    let facts: [(label: String, value: String)]
    /// The ⌥⌘ digit that switches to this Mac's page.
    let shortcut: Int?

    var chipText: String {
        guard state.carriesSessions else { return state.label }
        return [state.label, connection?.label, roundTrip?.roundTripLabel]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

extension AppState {
    /// The hover card of the paired Mac `serverId`, or nil when it has no page.
    func peerHoverCard(serverId: String) -> PeerHoverCardModel? {
        guard let page = nativePeerSessions?.peerPages.first(where: { $0.serverId == serverId }) else { return nil }
        let group = nativePeerSessions?.snapshot.groups.first { $0.serverId == serverId }
        // Only reach for the lazy manager when a server is up, as `peerIcon(serverId:)` does.
        let peer = remoteServer == nil ? nil : remotePeers.peers.first { $0.serverId == serverId }
        let hostVersion = remoteServer == nil ? nil : remotePeers.hostVersions[serverId]
        let origin = peer?.lastOrigin ?? peer?.origins.first

        var counts: PeerHoverCardModel.Counts?
        var rowsTitle = ""
        var rows: [PeerHoverCardModel.Row] = []
        if page.state.carriesSessions, let group {
            let waitingStatuses: Set<String> = ["awaitingPermission", "awaitingInput"]
            let waiting = group.sessions.filter { waitingStatuses.contains($0.status) }
            let working = group.sessions.filter { $0.status == "streaming" }
            counts = .init(
                waiting: waiting.count, working: working.count, terminals: group.consoles.count,
                worktrees: group.repos(ordering: .manual).reduce(0) { $0 + $1.worktrees.count }
            )
            rowsTitle = waiting.isEmpty ? "Working" : "Waiting on you"
            rows = (waiting.isEmpty ? working : waiting).prefix(3).map {
                .init(title: $0.title, branch: $0.worktree?.branch, isWaiting: !waiting.isEmpty)
            }
        }

        var facts: [(label: String, value: String)] = []
        if let peer {
            let access = remotePeers.agentAccess(of: peer)
            facts.append(("Agents", access.map(Self.agentAccessLabel) ?? "Off"))
            if let scope = peer.tokenScope, scope != .full { facts.append(("Access", "Delegation only")) }
            facts.append(("Identity", peer.isVerified ? "Verified key" : "Unverified"))
        }
        if hostUpdateReminders.contains(where: { $0.serverId == serverId }) {
            facts.append(("Update", "Available"))
        }
        if !page.state.carriesSessions, let seen = lastSeen(of: peer, serverId: serverId) {
            facts.append(("Last here", seen.formatted(.relative(presentation: .named))))
        }
        if let peer { facts.append(("Paired", peer.addedAt.formatted(date: .abbreviated, time: .omitted))) }

        let index = sidebarPages.firstIndex(of: .peer(serverId: serverId)).map { $0 + 1 }
        return PeerHoverCardModel(
            name: page.name,
            icon: page.icon,
            state: page.state,
            subtitle: hostVersion.map { "alas-host \($0)" } ?? origin.flatMap { URL(string: $0)?.host },
            connection: PeerConnectionKind.of(origin: origin),
            roundTrip: remoteServer == nil ? nil : remotePeers.roundTrips[serverId],
            counts: counts,
            rowsTitle: rowsTitle,
            rows: rows,
            facts: facts,
            shortcut: index.flatMap { $0 <= 9 ? $0 : nil }
        )
    }

    private func lastSeen(of peer: RemotePeer?, serverId: String) -> Date? {
        remotePairing.devices
            .filter { $0.id == peer?.localDeviceId || $0.peerServerId == serverId }
            .compactMap(\.lastSeenAt)
            .max()
    }

    private static func agentAccessLabel(_ access: RemoteDeviceAgentAccess) -> String {
        switch access {
        case .off: "Off"
        case .ask: "Ask for approval"
        case .autoRun: "Allow auto-run"
        }
    }
}

/// The spaces pager's hover card for a paired Mac: what it is doing and how
/// this Mac reaches it. Read-only, like `AgentBadgePopover`, whose chrome it
/// shares.
struct PeerHoverCard: View {
    let model: PeerHoverCardModel

    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: scale.space[2]) {
            header
            chip
            if let counts = model.counts {
                stats(counts)
                if !model.rows.isEmpty { rows }
            } else {
                Text(model.state.unavailableDetail(peerName: model.name))
                    .font(scale.metaFont)
                    .foregroundStyle(theme.color("fg-dim"))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Rectangle()
                .fill(theme.color("line"))
                .frame(height: 0.5) // design-literal: hairline
            facts
            hint
        }
        .padding(scale.space[3])
        .frame(width: AgentBadgePopover.width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: scale.radius.medium)
                .fill(theme.color("bg-1"))
        )
        .overlay(
            RoundedRectangle(cornerRadius: scale.radius.medium)
                .strokeBorder(theme.color("line"), lineWidth: 0.5) // design-literal: hairline border
        )
    }

    private var header: some View {
        HStack(spacing: scale.space[2]) {
            PeerIconTile(icon: model.icon, side: 26)
                .opacity(model.state.carriesSessions ? 1 : 0.6)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.name)
                    .font(scale.titleFont)
                    .foregroundStyle(theme.color("fg"))
                    .lineLimit(1)
                if let subtitle = model.subtitle {
                    Text(subtitle)
                        .font(scale.caption.font(design: .monospaced))
                        .foregroundStyle(theme.color("fg-dim"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private var chip: some View {
        HStack(spacing: scale.space[1]) {
            dot(model.state.presenceColorToken)
            Text(model.chipText)
                .font(scale.captionFont)
                .foregroundStyle(theme.color("fg-dim"))
        }
        .padding(.horizontal, scale.space[2])
        .padding(.vertical, scale.space[0])
        .background(Capsule().fill(theme.color("bg-3")))
    }

    private func stats(_ counts: PeerHoverCardModel.Counts) -> some View {
        HStack(spacing: 0) {
            stat(counts.waiting, "waiting", highlight: counts.waiting > 0)
            stat(counts.working, "working")
            stat(counts.terminals, counts.terminals == 1 ? "terminal" : "terminals")
            stat(counts.worktrees, counts.worktrees == 1 ? "worktree" : "worktrees")
        }
    }

    private func stat(_ value: Int, _ label: String, highlight: Bool = false) -> some View {
        VStack(spacing: 0) {
            Text("\(value)")
                .font(scale.bodyFont.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(theme.color(highlight ? "mod" : "fg"))
            Text(label)
                .font(scale.captionFont)
                .foregroundStyle(theme.color("fg-muted"))
        }
        .frame(maxWidth: .infinity)
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: scale.space[1]) {
            Text(model.rowsTitle.uppercased())
                .font(scale.captionFont)
                .foregroundStyle(theme.color("fg-muted"))
            ForEach(Array(model.rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: scale.space[1]) {
                    dot(row.isWaiting ? "mod" : "add")
                    Text(row.title)
                        .font(scale.metaFont)
                        .foregroundStyle(theme.color("fg"))
                        .lineLimit(1)
                    Spacer(minLength: scale.space[2])
                    if let branch = row.branch {
                        Text(branch)
                            .font(scale.caption.font(design: .monospaced))
                            .foregroundStyle(theme.color("fg-dim"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
    }

    private var facts: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(model.facts, id: \.label) { fact in
                HStack {
                    Text(fact.label)
                        .foregroundStyle(theme.color("fg-dim"))
                    Spacer(minLength: scale.space[2])
                    Text(fact.value)
                        .foregroundStyle(theme.color("fg"))
                        .lineLimit(1)
                }
                .font(scale.captionFont)
            }
        }
    }

    private var hint: some View {
        HStack {
            if let shortcut = model.shortcut {
                Text("⌥⌘\(shortcut) switch")
            }
            Spacer(minLength: 0)
            Text("Right-click to edit")
        }
        .font(scale.captionFont)
        .foregroundStyle(theme.color("fg-faint"))
    }

    private func dot(_ token: String) -> some View {
        Circle()
            .fill(theme.color(token))
            .frame(width: 6, height: 6) // design-literal: status dot, as the sidebar's HarnessPill
    }
}
