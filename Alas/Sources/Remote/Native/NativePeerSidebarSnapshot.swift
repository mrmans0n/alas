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
