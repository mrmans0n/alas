import Foundation
import AlasRemoteKit

/// What `HostPeerDelegation` needs of the Remote server to reach a Mac over
/// that Mac's own link, kept apart so its tests drive it with a fake.
@MainActor
public protocol PeerDeviceRoutes: AnyObject {
    /// See `RemoteServer.route(toDevice:acknowledging:)`.
    func route(toDevice deviceId: String, acknowledging capability: String) -> Int?
    @discardableResult
    func send(_ message: RemoteServerMessage, toDevice deviceId: String, acknowledging capability: String) -> Bool
    var onAcknowledgedCapabilitiesChange: (@MainActor (_ deviceId: String) -> Void)? { get set }
    var onPeerHostReply: (@MainActor (_ deviceId: String, _ route: Int?, HostServerMessage) -> Void)? { get set }
}

extension RemoteServer: PeerDeviceRoutes {}

/// What lets agents on a headless host delegate to paired Macs: one host
/// channel per peer that serves it, and the client the coordinator asks.
/// Nothing else drives the channels on a host, where the app has its session
/// list, so they follow the links here.
///
/// A peer this host added is reached over its outbound link. A Mac that
/// paired here inbound-only is reached over that Mac's own link, through
/// `routes`, once it acknowledges `HostProtocolCapability.delegationReverseV1`
/// there.
@MainActor
public final class HostPeerDelegation {
    public let client: PeerDelegationClient
    let channels: PeerHostChannels
    /// Channels to the Macs reached over their own links.
    let reverseChannels: PeerHostChannels
    private let links: RemotePeerManager
    private let routes: (any PeerDeviceRoutes)?
    /// The peers whose channels are subscribed, to tell one that just became so.
    private var subscribed: Set<String> = []
    /// The socket each open reverse route was on at the last reconcile: a
    /// newer one has no subscription of this host's, so its channel starts over.
    private var openRoutes: [String: Int] = [:]

    private static let reverse = HostProtocolCapability.delegationReverseV1
    /// What an acknowledged reverse route stands for.
    private static let reverseServes: Set<String> = [
        HostProtocolCapability.v1, HostProtocolCapability.eventsV1, HostProtocolCapability.delegationV1,
    ]

    public init(links: RemotePeerManager, routes: (any PeerDeviceRoutes)? = nil) {
        let channels = PeerHostChannels(links: links)
        let reverseChannels = PeerHostChannels(
            supports: { [weak links, weak routes] serverId, capability in
                guard Self.reverseServes.contains(capability), let links, let routes else { return false }
                return Self.route(serverId, links: links, routes: routes) != nil
            },
            send: { [weak links, weak routes] serverId, message in
                guard let links, let routes,
                      let deviceId = links.provenInboundOnlyPeers.first(where: { $0.peer.serverId == serverId })?.deviceId
                else { return }
                routes.send(.peerHost(message), toDevice: deviceId, acknowledging: Self.reverse)
            }
        )
        self.links = links
        self.routes = routes
        self.channels = channels
        self.reverseChannels = reverseChannels
        client = PeerDelegationClient(
            links: links,
            reverseRoutes: { [weak links, weak routes] in
                guard let links else { return [] }
                return links.provenInboundOnlyPeers.map { peer, deviceId in
                    PeerReverseRoute(
                        peer: FederatedPeerInfo(serverId: peer.serverId, name: peer.name),
                        isOpen: routes?.route(toDevice: deviceId, acknowledging: Self.reverse) != nil
                    )
                }
            },
            channel: { [weak channels, weak reverseChannels] in channels?.channel(for: $0) ?? reverseChannels?.channel(for: $0) }
        )
        follow(channels)
        follow(reverseChannels)
        // Any frame too, as the app retries on each session list: a channel
        // whose snapshot failed connects again without waiting for the link
        // to change.
        links.onFederationEvent = { [weak self] _ in self?.reconcile() }
        routes?.onAcknowledgedCapabilitiesChange = { [weak self] _ in self?.reconcile() }
        routes?.onPeerHostReply = { [weak self, weak routes] deviceId, route, message in
            // A reply from any other device answers nothing this host asked,
            // and one from an older socket of the device belongs to a channel
            // since replaced, whose request ids the current one reuses.
            guard let self, let peer = self.links.provenInboundOnlyPeers.first(where: { $0.deviceId == deviceId })?.peer,
                  let route, route == routes?.route(toDevice: deviceId, acknowledging: Self.reverse)
            else { return }
            reverseChannels.receive(serverId: peer.serverId, message)
        }
    }

    /// The socket `serverId`'s reverse route is on, if it is open.
    private static func route(_ serverId: String, links: RemotePeerManager, routes: any PeerDeviceRoutes) -> Int? {
        links.provenInboundOnlyPeers.first { $0.peer.serverId == serverId }
            .flatMap { routes.route(toDevice: $0.deviceId, acknowledging: reverse) }
    }

    /// Tells the client of each channel's outbox news and availability.
    private func follow(_ channels: PeerHostChannels) {
        channels.onChannelMade = { [weak client] serverId, channel in
            channel.onDelegationOutboxChanged = { client?.onOutboxChanged?(serverId) }
        }
        channels.onChannelChanged = { [weak self] serverId, channel in
            guard let self else { return }
            if !channel.isSubscribed {
                subscribed.remove(serverId)
            } else if subscribed.insert(serverId).inserted {
                client.onAvailabilityChanged?(serverId)
            }
        }
        channels.onChannelDropped = { [weak client] in client?.onAvailabilityChanged?($0) }
    }

    private func reconcile() {
        channels.peersChanged(online: Set(links.sessionCarryingPeers.map(\.serverId)))
        guard let routes else { return }
        var open: [String: Int] = [:]
        for (peer, deviceId) in links.provenInboundOnlyPeers {
            open[peer.serverId] = routes.route(toDevice: deviceId, acknowledging: Self.reverse)
        }
        let moved = Set(open.filter { serverId, socket in openRoutes[serverId].map { $0 != socket } ?? false }.keys)
        openRoutes = open
        if !moved.isEmpty {
            reverseChannels.peersChanged(online: Set(open.keys).subtracting(moved))
        }
        reverseChannels.peersChanged(online: Set(open.keys))
    }

    /// Ends every channel. The links and the server are the owner's to stop.
    public func stop() {
        links.onFederationEvent = nil
        routes?.onAcknowledgedCapabilitiesChange = nil
        routes?.onPeerHostReply = nil
        channels.stop()
        reverseChannels.stop()
    }
}
