import Foundation

/// What lets agents on a headless host delegate over its outbound peer links:
/// one host channel per peer that serves it, and the client the coordinator
/// asks. Nothing else drives the channels on a host, where the app has its
/// session list, so they follow the links here.
@MainActor
public final class HostPeerDelegation {
    public let client: PeerDelegationClient
    let channels: PeerHostChannels
    private let links: RemotePeerManager
    /// The peers whose channels are subscribed, to tell one that just became so.
    private var subscribed: Set<String> = []

    public init(links: RemotePeerManager) {
        let channels = PeerHostChannels(links: links)
        self.links = links
        self.channels = channels
        client = PeerDelegationClient(links: links, channel: { [weak channels] in channels?.channel(for: $0) })
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
        // Any frame too, as the app retries on each session list: a channel
        // whose snapshot failed connects again without waiting for the link
        // to change.
        links.onFederationEvent = { [weak self] _ in self?.reconcile() }
    }

    private func reconcile() {
        channels.peersChanged(online: Set(links.sessionCarryingPeers.map(\.serverId)))
    }

    /// Ends every channel. The links are the owner's to disconnect.
    public func stop() {
        links.onFederationEvent = nil
        channels.stop()
    }
}
