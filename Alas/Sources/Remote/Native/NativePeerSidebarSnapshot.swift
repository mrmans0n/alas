import Foundation

enum NativePeerState: Equatable {
    case online
    case connecting
    case offline
    case tokenRevoked
    case identityUnproven
    case identityMismatch
    case incompatible
    case idle
    case unavailable

    init(wireState: String) {
        switch wireState {
        case "online": self = .online
        case "connecting": self = .connecting
        case "offline": self = .offline
        case "unauthorized": self = .tokenRevoked
        case "unverified", "identityUnproven": self = .identityUnproven
        case "identityMismatch": self = .identityMismatch
        case "incompatible": self = .incompatible
        case "idle": self = .idle
        default: self = .unavailable
        }
    }

    var carriesSessions: Bool { self == .online }

    var label: String {
        switch self {
        case .online: "Online"
        case .connecting: "Connecting"
        case .offline: "Offline"
        case .tokenRevoked: "Token revoked"
        case .identityUnproven: "Identity unproven"
        case .identityMismatch: "Identity mismatch"
        case .incompatible: "Incompatible"
        case .idle: "Not connected"
        case .unavailable: "Unavailable"
        }
    }
}

struct NativePeerGroup: Identifiable, Equatable {
    let serverId: String
    let name: String
    let state: NativePeerState
    let sessions: [RemoteSessionSummary]
    let attentionCount: Int

    var id: String { serverId }

    /// The peer's sessions folded into the same repo → worktree shape the
    /// local sidebar uses, so a peer reads like another Mac's workspace tree
    /// rather than a flat list of chats.
    var repos: [NativePeerRepoGroup] { NativePeerRepoGroup.build(sessions: sessions) }
}

struct NativePeerRepoGroup: Identifiable, Equatable {
    /// Rows the peer sent without worktree metadata land here.
    static let unassignedName = "Other sessions"
    private static let unassignedKey = "unassigned"

    let id: String
    let name: String
    let worktrees: [NativePeerWorktreeGroup]

    var attentionCount: Int { worktrees.reduce(0) { $0 + $1.attentionCount } }

    /// The project identity to group on. `projectName` is a display label a
    /// peer could reuse across two distinct projects (or after a rename), so
    /// grouping on it merges unrelated repos — group on `projectId` instead,
    /// falling back to a shared sentinel only for sessions with no project
    /// metadata at all.
    private static func repoKey(for session: RemoteSessionSummary) -> String {
        session.projectId.map { "id:\($0)" } ?? unassignedKey
    }

    /// Groups sessions by project, then by worktree. Repos and worktrees keep
    /// the order of their most recently updated session, which is the order
    /// `sessions` already arrives in.
    static func build(sessions: [RemoteSessionSummary]) -> [NativePeerRepoGroup] {
        var repoOrder: [String] = []
        var repoNames: [String: String] = [:]
        var worktreeOrder: [String: [String]] = [:]
        var buckets: [String: [String: [RemoteSessionSummary]]] = [:]
        for session in sessions {
            let repo = repoKey(for: session)
            // Worktree keys are namespaced by repo identity too, so a
            // worktree id or path that happens to repeat across two
            // differently-identified projects still can't merge sessions.
            let key = "\(repo)\u{1F}\(NativePeerWorktreeGroup.key(for: session))"
            if buckets[repo] == nil {
                repoOrder.append(repo)
                buckets[repo] = [:]
                repoNames[repo] = session.worktree?.projectName ?? unassignedName
            }
            if buckets[repo]?[key] == nil {
                worktreeOrder[repo, default: []].append(key)
            }
            buckets[repo]?[key, default: []].append(session)
        }
        return repoOrder.map { repo in
            NativePeerRepoGroup(
                id: repo,
                name: repoNames[repo] ?? unassignedName,
                worktrees: (worktreeOrder[repo] ?? []).compactMap { key in
                    guard let rows = buckets[repo]?[key], !rows.isEmpty else { return nil }
                    return NativePeerWorktreeGroup(id: key, sessions: rows)
                }
            )
        }
    }
}

struct NativePeerWorktreeGroup: Identifiable, Equatable {
    let id: String
    /// Most recently updated first.
    let sessions: [RemoteSessionSummary]

    static let waitingStatuses: Set<String> = ["awaitingPermission", "awaitingInput"]

    static func key(for session: RemoteSessionSummary) -> String {
        if let worktreeId = session.worktreeId, !worktreeId.isEmpty { return "id:\(worktreeId)" }
        if let path = session.worktree?.path, !path.isEmpty { return "path:\(path)" }
        return "session:\(session.id)"
    }

    var worktree: RemoteWorktreeSummary? { sessions.lazy.compactMap(\.worktree).first }
    /// The session a click on the row opens.
    var primarySession: RemoteSessionSummary { sessions[0] }
    var updatedAt: Int64 { sessions.map(\.updatedAt).max() ?? 0 }
    var attentionCount: Int { sessions.count { Self.waitingStatuses.contains($0.status) } }

    var title: String {
        if let branch = worktree?.branch, !branch.isEmpty { return branch }
        if let name = worktree?.worktreeName, !name.isEmpty { return name }
        return primarySession.title
    }

    /// Mirrors `WorktreeRowView.StatusPresentation`: waiting outranks
    /// streaming, and an idle worktree draws no chip.
    var status: WorktreeRowView.StatusPresentation? {
        if sessions.contains(where: { $0.status == "awaitingPermission" }) {
            return .init(note: "needs permission", colorToken: "mod", pulses: false)
        }
        if sessions.contains(where: { $0.status == "awaitingInput" }) {
            return .init(note: "needs input", colorToken: "mod", pulses: false)
        }
        if sessions.contains(where: { $0.status == "streaming" }) {
            return .init(note: "running", colorToken: "add", pulses: true)
        }
        return nil
    }
}

struct NativePeerSidebarSnapshot: Equatable {
    let groups: [NativePeerGroup]
    let attentionRows: [RemoteSessionSummary]

    var attentionCount: Int { attentionRows.count }

    static func build(
        peers: [RemoteHelloPeer], rows: [RemoteSessionSummary], enabled: Bool
    ) -> Self {
        guard enabled else { return .init(groups: [], attentionRows: []) }

        var uniqueRows: [String: [String: RemoteSessionSummary]] = [:]
        for row in rows {
            guard let owner = row.serverId,
                  !owner.isEmpty,
                  row.id.hasPrefix(owner + ":"),
                  row.id.count > owner.count + 1 else { continue }
            if let previous = uniqueRows[owner]?[row.id], previous.updatedAt > row.updatedAt {
                continue
            }
            uniqueRows[owner, default: [:]][row.id] = row
        }

        let waitingStatuses: Set<String> = ["awaitingPermission", "awaitingInput"]
        let groups = peers.map { peer -> NativePeerGroup in
            let state = NativePeerState(wireState: peer.state)
            let sessions = state.carriesSessions
                ? (uniqueRows[peer.serverId]?.values.sorted {
                    if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                    return $0.id < $1.id
                } ?? [])
                : []
            return NativePeerGroup(
                serverId: peer.serverId,
                name: peer.name,
                state: state,
                sessions: sessions,
                attentionCount: sessions.count { waitingStatuses.contains($0.status) }
            )
        }.sorted { ($0.name, $0.serverId) < ($1.name, $1.serverId) }
        let attentionRows = groups.flatMap(\.sessions).filter { waitingStatuses.contains($0.status) }
        return .init(groups: groups, attentionRows: attentionRows)
    }
}
