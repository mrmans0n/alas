import Foundation

/// Decisions for the row that stands for a child running on another Mac.
/// The child has no session here, so its row can only open the session in the
/// peer view, and that works only while the Mac is connected and lists it.
enum ACPPeerChildPolicy {
    enum Destination: Equatable {
        case open(federatedSessionID: String)
        /// Stay where we are and say why the session cannot be opened.
        case explain(String)
    }

    static func label(macName: String) -> String {
        "on \(macName)"
    }

    static let maxMenuItems = 10

    struct Child: Equatable {
        let childSessionId: String
        let serverId: String
        let macName: String
        let agentId: String
        let phase: ACPDelegationPhase
    }

    struct MenuItem: Equatable {
        let childSessionId: String
        let title: String
    }

    /// One toolbar control for one Mac.
    struct Menu: Equatable {
        let serverId: String
        let title: String
        let items: [MenuItem]
    }

    static func shortID(_ id: String) -> String {
        String(id.prefix(8))
    }

    static func phaseLabel(_ phase: ACPDelegationPhase) -> String {
        switch phase {
        case .creatingWorktree: "Creating worktree"
        case .starting: "Starting"
        case .ready: "Started"
        case .failed: "Failed"
        case .closed: "Closed"
        }
    }

    /// One menu per Mac, in the order the Macs first appear. `children` are
    /// oldest first. Within a menu the newest come first, failed and closed
    /// ones sink below the rest, and at most `maxMenuItems` are listed. The
    /// title counts every child of that Mac when there is more than one.
    static func menus(for children: [Child]) -> [Menu] {
        var order: [String] = []
        var byMac: [String: [Child]] = [:]
        for child in children {
            if byMac[child.serverId] == nil { order.append(child.serverId) }
            byMac[child.serverId, default: []].append(child)
        }
        return order.map { serverId in
            let all = byMac[serverId] ?? []
            let newestFirst = Array(all.reversed())
            func ended(_ child: Child) -> Bool { child.phase == .failed || child.phase == .closed }
            let sorted = newestFirst.filter { !ended($0) } + newestFirst.filter(ended)
            let name = label(macName: all[0].macName)
            return Menu(
                serverId: serverId,
                title: all.count > 1 ? "\(name) (\(all.count))" : name,
                items: sorted.prefix(maxMenuItems).map {
                    MenuItem(
                        childSessionId: $0.childSessionId,
                        title: "\($0.agentId) \(shortID($0.childSessionId)) · \(phaseLabel($0.phase))")
                })
        }
    }

    static func destination(
        macName: String, serverId: String, childSessionId: String,
        macIsConnected: Bool, sessionIsListed: Bool
    ) -> Destination {
        guard macIsConnected else {
            return .explain("\(macName) is not connected right now. Open this session once it is back.")
        }
        guard sessionIsListed else {
            return .explain("\(macName) has not listed this session yet. Try again in a moment.")
        }
        return .open(federatedSessionID: RemoteFederatedSessionID.compose(serverId: serverId, sessionId: childSessionId))
    }

    /// Body of the notification for a child blocked on a person.
    static func blockedNotificationBody(macName: String, agentId: String, childSessionId: String) -> String {
        "\(agentId) \(shortID(childSessionId)) on \(macName) is waiting for a permission, answer or plan."
    }
}
