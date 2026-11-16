import Foundation

/// Reconciles session reports without changing the connection's wire IDs.
public enum RemoteSessionCatalog {
    public enum HostID: Hashable, Sendable {
        case server(String)
        case pairing(UUID)
    }

    public struct Source: Sendable {
        public let id: UUID
        public let serverId: String?
        public let name: String
        public let isLive: Bool
        public let sessions: [RemoteSessionSummary]

        public init(id: UUID, serverId: String?, name: String, isLive: Bool, sessions: [RemoteSessionSummary]) {
            self.id = id
            self.serverId = serverId
            self.name = name
            self.isLive = isLive
            self.sessions = sessions
        }

        fileprivate var ownerID: HostID {
            serverId.flatMap { $0.isEmpty ? nil : .server($0) } ?? .pairing(id)
        }
    }

    public struct Route: Equatable, Sendable {
        public let hostID: UUID
        public let sessionId: String
    }

    public struct SessionID: Hashable, Sendable {
        public let owner: HostID
        public let sessionId: String
    }

    public struct AttentionEntry: Identifiable, Equatable, Sendable {
        public let id: SessionID
        public let route: Route
        public let hostName: String
        public let title: String
    }

    public struct Host: Identifiable, Equatable, Sendable {
        public let id: HostID
        public let name: String
        public let sections: [RemoteRepoSection]
        fileprivate let routes: [String: Route]

        public var worktreeCount: Int { sections.reduce(0) { $0 + $1.worktrees.count } }

        public func route(for sessionID: String) -> Route? { routes[sessionID] }
    }

    public static func hosts(from sources: [Source]) -> [Host] {
        let ordered = sources.sorted { $0.id.uuidString < $1.id.uuidString }
        let liveOwners = Set(sources.filter(\.isLive).map(\.ownerID))
        var names: [HostID: String] = [:]
        var reports: [HostID: [String: Report]] = [:]
        for source in ordered where names[source.ownerID] == nil {
            names[source.ownerID] = source.name
        }
        for source in ordered {
            for session in source.sessions {
                let serverId = session.serverId.flatMap { $0.isEmpty ? nil : $0 }
                let owner = serverId.map(HostID.server) ?? source.ownerID
                // A live owner's complete list supersedes relays, including
                // sessions that have disappeared from the owner's list.
                if serverId != nil, liveOwners.contains(owner) { continue }
                let nativeID = serverId.flatMap {
                    RemoteFederatedSessionID.parse(session.id, peers: [$0])?.sessionId
                } ?? session.id
                let report = Report(source: source, session: session, nativeID: nativeID, isDirect: serverId == nil)
                if let current = reports[owner]?[nativeID], !report.isPreferred(to: current) { continue }
                reports[owner, default: [:]][nativeID] = report
                if names[owner] == nil { names[owner] = session.serverName ?? "Mac" }
            }
        }
        return names.map { owner, name in
            let selected = (reports[owner] ?? [:]).values.sorted { $0.nativeID < $1.nativeID }
            return Host(id: owner, name: name,
                        sections: RemoteSessionDirectory.sections(selected.map(\.normalized), localHostName: name),
                        routes: Dictionary(uniqueKeysWithValues: selected.map {
                            ($0.nativeID, Route(hostID: $0.source.id, sessionId: $0.session.id))
                        }))
        }.sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.id.sortKey < $1.id.sortKey : comparison == .orderedAscending
        }
    }

    /// Select the owner's current report before filtering for pending requests.
    public static func attentionEntries(from sources: [Source]) -> [AttentionEntry] {
        hosts(from: sources).flatMap { host in
            host.sections.flatMap(\.worktrees).flatMap(\.activeSessions).compactMap { session in
                guard session.status == "awaitingPermission" || session.status == "awaitingInput",
                      let route = host.route(for: session.id) else { return nil }
                return AttentionEntry(id: SessionID(owner: host.id, sessionId: session.id),
                                      route: route, hostName: host.name, title: session.title)
            }
        }
    }

    private struct Report {
        let source: Source
        let session: RemoteSessionSummary
        let nativeID: String
        let isDirect: Bool

        func isPreferred(to other: Report) -> Bool {
            if source.isLive != other.source.isLive { return source.isLive }
            if isDirect != other.isDirect { return isDirect }
            if source.id != other.source.id { return source.id.uuidString < other.source.id.uuidString }
            return session.updatedAt > other.session.updatedAt
        }

        // Display IDs belong to the owner; transport IDs remain in `routes`.
        var normalized: RemoteSessionSummary {
            RemoteSessionSummary(id: nativeID, title: session.title, agentId: session.agentId,
                                 status: session.status, canDrive: session.canDrive, isActive: session.isActive,
                                 tabIndex: session.tabIndex, projectId: session.projectId,
                                 worktreeId: session.worktreeId, updatedAt: session.updatedAt, worktree: session.worktree)
        }
    }
}

private extension RemoteSessionCatalog.HostID {
    var sortKey: String {
        switch self {
        case .server(let id): "server:\(id)"
        case .pairing(let id): "pairing:\(id.uuidString)"
        }
    }
}
