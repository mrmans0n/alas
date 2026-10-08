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
    var consoles: [PeerConsoleSummary] = []
    let attentionCount: Int

    var id: String { serverId }

    /// The peer's sessions and consoles folded into the same repo → worktree
    /// shape the local sidebar uses, so a peer reads like another Mac's
    /// workspace tree rather than a flat list of chats.
    func repos(ordering: AppConfig.WorktreeSortMode) -> [NativePeerRepoGroup] {
        NativePeerRepoGroup.build(sessions: sessions, consoles: consoles, ordering: ordering)
    }
}

struct NativePeerRepoGroup: Identifiable, Equatable {
    /// Rows the peer sent without worktree metadata land here.
    static let unassignedName = "Other sessions"
    private static let unassignedKey = "unassigned"

    let id: String
    let name: String
    let worktrees: [NativePeerWorktreeGroup]

    var attentionCount: Int { worktrees.reduce(0) { $0 + $1.attentionCount } }

    /// The peer's project id, or nil for the "Other sessions" bucket.
    var projectId: String? {
        id.hasPrefix("id:") ? String(id.dropFirst(3)) : nil
    }

    /// The project identity to group on. `projectName` is a display label a
    /// peer could reuse across two distinct projects (or after a rename), so
    /// grouping on it merges unrelated repos — group on `projectId` instead,
    /// falling back to a shared sentinel only for sessions with no project
    /// metadata at all.
    private static func repoKey(projectId: String?) -> String {
        // A console in a workspace checkout reports an empty id.
        guard let projectId, !projectId.isEmpty else { return unassignedKey }
        return "id:\(projectId)"
    }

    /// Groups sessions and consoles by project, then by worktree. Repos keep
    /// the order of their most recently updated session, which is the order
    /// `sessions` already arrives in; repos with only consoles have no
    /// recency to go by and follow in the order the peer listed them.
    /// Worktrees follow the local sidebar's rule: the main worktree is pinned
    /// first, the rest are sorted by `ordering`. `.manual` has no peer-side
    /// order to follow, so it keeps arrival order.
    static func build(
        sessions: [RemoteSessionSummary],
        consoles: [PeerConsoleSummary] = [],
        ordering: AppConfig.WorktreeSortMode = .lastUpdateDesc
    ) -> [NativePeerRepoGroup] {
        var repoOrder: [String] = []
        var repoNames: [String: String] = [:]
        var worktreeOrder: [String: [String]] = [:]
        var sessionBuckets: [String: [RemoteSessionSummary]] = [:]
        var consoleBuckets: [String: [PeerConsoleSummary]] = [:]
        // Worktree keys are namespaced by repo identity too, so a worktree id
        // or path that happens to repeat across two differently-identified
        // projects still can't merge rows.
        func place(repo: String, worktreeKey: String, name: @autoclosure () -> String) -> String {
            let key = "\(repo)\u{1F}\(worktreeKey)"
            if repoNames[repo] == nil {
                repoOrder.append(repo)
                repoNames[repo] = name()
            }
            if sessionBuckets[key] == nil, consoleBuckets[key] == nil {
                worktreeOrder[repo, default: []].append(key)
            }
            return key
        }
        for session in sessions {
            let key = place(
                repo: repoKey(projectId: session.projectId),
                worktreeKey: NativePeerWorktreeGroup.key(for: session),
                name: session.worktree?.projectName ?? unassignedName
            )
            sessionBuckets[key, default: []].append(session)
        }
        for console in consoles {
            let key = place(
                repo: repoKey(projectId: console.projectId),
                worktreeKey: NativePeerWorktreeGroup.key(for: console),
                name: console.worktree?.projectName ?? console.projectName ?? unassignedName
            )
            consoleBuckets[key, default: []].append(console)
        }
        return repoOrder.map { repo in
            NativePeerRepoGroup(
                id: repo,
                name: repoNames[repo] ?? unassignedName,
                worktrees: NativePeerWorktreeGroup.sorted(
                    (worktreeOrder[repo] ?? []).map { key in
                        NativePeerWorktreeGroup(
                            id: key,
                            sessions: sessionBuckets[key] ?? [],
                            consoles: consoleBuckets[key] ?? []
                        )
                    },
                    ordering: ordering
                )
            )
        }
    }
}

struct NativePeerWorktreeGroup: Identifiable, Equatable {
    let id: String
    /// Most recently updated first.
    let sessions: [RemoteSessionSummary]
    /// In the order the peer listed them, which is creation order.
    var consoles: [PeerConsoleSummary] = []

    static let waitingStatuses: Set<String> = ["awaitingPermission", "awaitingInput"]

    static func key(for session: RemoteSessionSummary) -> String {
        if let worktreeId = session.worktreeId, !worktreeId.isEmpty { return "id:\(worktreeId)" }
        if let path = session.worktree?.path, !path.isEmpty { return "path:\(path)" }
        return "session:\(session.id)"
    }

    /// Must agree with `key(for: RemoteSessionSummary)` so a console joins
    /// its worktree's session row instead of drawing a second one.
    static func key(for console: PeerConsoleSummary) -> String {
        if let worktreeId = console.worktreeId, !worktreeId.isEmpty { return "id:\(worktreeId)" }
        if let path = console.worktree?.path, !path.isEmpty { return "path:\(path)" }
        return "console:\(console.consoleId)"
    }

    /// Sessions' summaries come first: only they carry git metrics.
    var worktree: RemoteWorktreeSummary? {
        sessions.lazy.compactMap(\.worktree).first ?? consoles.lazy.compactMap(\.worktree).first
    }
    var isMain: Bool { worktree?.isMain == true }

    /// Main first, then `ordering` over the rest — the same shape as
    /// `ProjectsManager.sortedWorktrees`. Ties fall back to the id.
    static func sorted(_ groups: [NativePeerWorktreeGroup], ordering: AppConfig.WorktreeSortMode) -> [NativePeerWorktreeGroup] {
        let main = groups.filter(\.isMain)
        let others = groups.filter { !$0.isMain }
        func by<K: Comparable>(_ key: @escaping (NativePeerWorktreeGroup) -> K, descending: Bool = false) -> [NativePeerWorktreeGroup] {
            others.sorted { l, r in
                let (lk, rk) = (key(l), key(r))
                if lk != rk { return descending ? lk > rk : lk < rk }
                return l.id < r.id
            }
        }
        let sortedOthers: [NativePeerWorktreeGroup]
        switch ordering {
        case .manual: sortedOthers = others
        // A peer that predates `createdAt` sends none; keep arrival order
        // rather than letting the id tie-break reshuffle the list.
        case .creationDesc, .creationAsc:
            sortedOthers = others.allSatisfy({ $0.worktree?.createdAt != nil })
                ? by({ $0.worktree?.createdAt ?? 0 }, descending: ordering == .creationDesc)
                : others
        case .lastUpdateDesc: sortedOthers = by({ $0.worktree?.lastActivity ?? Double($0.updatedAt) }, descending: true)
        case .lastUpdateAsc: sortedOthers = by { $0.worktree?.lastActivity ?? Double($0.updatedAt) }
        case .branchAsc: sortedOthers = by { $0.title.localizedLowercase }
        }
        return main + sortedOthers
    }
    /// The session a click on the row opens. Nil for a worktree that only
    /// has consoles; the click opens `consoles.first` instead.
    var primarySession: RemoteSessionSummary? { sessions.first }
    var updatedAt: Int64 { sessions.map(\.updatedAt).max() ?? 0 }
    var attentionCount: Int { sessions.count { Self.waitingStatuses.contains($0.status) } }

    var title: String {
        if let branch = worktree?.branch, !branch.isEmpty { return branch }
        if let name = worktree?.worktreeName, !name.isEmpty { return name }
        if let primarySession { return primarySession.title }
        if let name = consoles.first?.worktreeName, !name.isEmpty { return name }
        return consoles.first?.title ?? ""
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

    /// `consoles` is keyed by peer `serverId`; like sessions, they are only
    /// shown for peers whose link is online.
    static func build(
        peers: [RemoteHelloPeer],
        rows: [RemoteSessionSummary],
        consoles: [String: [PeerConsoleSummary]] = [:]
    ) -> Self {
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
                consoles: state.carriesSessions ? consoles[peer.serverId] ?? [] : [],
                attentionCount: sessions.count { waitingStatuses.contains($0.status) }
            )
        }.sorted { ($0.name, $0.serverId) < ($1.name, $1.serverId) }
        let attentionRows = groups.flatMap(\.sessions).filter { waitingStatuses.contains($0.status) }
        return .init(groups: groups, attentionRows: attentionRows)
    }
}
