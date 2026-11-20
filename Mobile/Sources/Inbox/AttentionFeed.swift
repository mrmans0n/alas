import AlasRemoteKit
import Foundation
import Observation

/// The open items of each online Mac's attention inbox: run failures, conflicts, failed agents and
/// the like. Agent waits are not here; the Inbox lists those as sessions.
@MainActor @Observable
final class AttentionFeed {
    struct Entry: Identifiable, Equatable {
        let hostID: UUID
        let hostName: String
        let item: RemoteAttentionItem
        var id: UUID { item.id }
        var route: SessionRoute? { item.sessionID.map { SessionRoute(hostID: hostID, sessionId: $0) } }
    }

    private let hub: HostHub
    private var items: [UUID: [RemoteAttentionItem]] = [:]
    /// The latest list request per host; an older answer is dropped.
    @ObservationIgnored private var requests: [UUID: Int] = [:]
    @ObservationIgnored private var listeners: [UUID: ListenerToken] = [:]

    init(hub: HostHub) {
        self.hub = hub
    }

    /// Items from the hosts online now, newest first.
    var entries: [Entry] {
        hub.hosts.filter { hub.state(of: $0.id) == .online }.flatMap { host in
            (items[host.id] ?? []).map { Entry(hostID: host.id, hostName: host.name, item: $0) }
        }
        .sorted { $0.item.occurredAt > $1.item.occurredAt }
    }

    /// Asks every online host that serves it for its items again.
    func refresh() {
        for host in hub.hosts where hub.state(of: host.id) == .online
            && hub.supports(HostProtocolCapability.attentionPhoneV1, on: host.id) {
            if listeners[host.id] == nil {
                let hostID = host.id
                listeners[hostID] = hub.addListener(hostID) { [weak self] in self?.receive($0, from: hostID) }
            }
            let id = hub.nextHostRequestId()
            requests[host.id] = id
            hub.send(.host(RemoteAttentionRequest.list(id: id)), to: host.id)
        }
    }

    /// Dismisses on the Mac too; the item leaves here at once. A dismissal that never arrives is
    /// undone by the next refresh.
    func dismiss(_ entry: Entry) {
        items[entry.hostID]?.removeAll { $0.id == entry.id }
        hub.send(.host(RemoteAttentionRequest.dismiss(id: hub.nextHostRequestId(), eventIDs: [entry.id])), to: entry.hostID)
        // Asked after the dismissal, so an answer already on its way can't bring the item back.
        refresh()
    }

    private func receive(_ message: PhoneServerMessage, from hostID: UUID) {
        guard case .host(let reply) = message, let id = requests[hostID],
              let found = RemoteAttentionRequest.items(replying: id, in: reply) else { return }
        items[hostID] = found
    }
}
