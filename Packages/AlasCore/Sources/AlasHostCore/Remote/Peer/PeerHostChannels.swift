import Foundation

/// One `PeerHostChannel` per paired Mac that serves the host channel
/// (`host.v1` and `host.events.v1`). There must be one per link: a second
/// subscribe on a connection replaces the first.
///
/// Owns creation, lookup, reconciliation with the online peers and the
/// transport. What a client derives from a channel's state is up to the
/// owner, which hears of each channel through `onChannelMade` and
/// `onChannelChanged`.
@MainActor
public final class PeerHostChannels {
    private let timeout: Duration
    private let supports: @MainActor (_ serverId: String, _ capability: String) -> Bool
    private let send: @MainActor (_ serverId: String, HostClientMessage) -> Void
    private var channels: [String: PeerHostChannel] = [:]

    /// Told of each channel as it is made, to set the rest of its callbacks.
    public var onChannelMade: (@MainActor (_ serverId: String, PeerHostChannel) -> Void)?
    /// Told when a channel's state changed, including when it was dropped and
    /// disconnected, which is why the channel is passed: it is no longer
    /// found by `channel(for:)` then.
    public var onChannelChanged: (@MainActor (_ serverId: String, PeerHostChannel) -> Void)?
    /// Told of a channel dropped by `peersChanged`, after it disconnected.
    public var onChannelDropped: (@MainActor (_ serverId: String) -> Void)?

    public init(
        timeout: Duration = PeerHostChannel.defaultTimeout,
        supports: @escaping @MainActor (_ serverId: String, _ capability: String) -> Bool,
        send: @escaping @MainActor (_ serverId: String, HostClientMessage) -> Void
    ) {
        self.timeout = timeout
        self.supports = supports
        self.send = send
    }

    /// Channels over `links`: requests go out on the peer's link, and the
    /// link's host messages come back here, so no owner can forget to route
    /// them.
    public convenience init(links: RemotePeerManager, timeout: Duration = PeerHostChannel.defaultTimeout) {
        self.init(
            timeout: timeout,
            supports: { [weak links] serverId, capability in links?.peerSupports(capability, serverId: serverId) == true },
            send: { [weak links] serverId, message in links?.sendToPeer(.host(message), serverId: serverId) }
        )
        links.onHostMessage = { [weak self] serverId, message in self?.receive(serverId: serverId, message) }
    }

    /// Whether `serverId` serves the host channel.
    public func serves(_ serverId: String) -> Bool {
        supports(serverId, HostProtocolCapability.v1) && supports(serverId, HostProtocolCapability.eventsV1)
    }

    /// The peer's channel, if one exists.
    public func channel(for serverId: String) -> PeerHostChannel? {
        channels[serverId]
    }

    /// Reconciles with the peers whose links currently carry sessions. A
    /// channel that is not subscribed, because its snapshot or resync
    /// failed, connects again here.
    public func peersChanged(online: Set<String>) {
        for (serverId, channel) in channels where !online.contains(serverId) || !serves(serverId) {
            channels[serverId] = nil
            channel.disconnect() // its onChange tells the owner it has no state
            onChannelDropped?(serverId)
        }
        for serverId in online where serves(serverId) {
            let channel = channels[serverId] ?? makeChannel(serverId)
            guard !channel.isSubscribed, !channel.isConnecting else { continue }
            // ponytail: unthrottled retry, once per refresh (each session-list or
            // availability change); add a failure counter with backoff if a peer
            // that keeps refusing the snapshot or subscribe shows up.
            Task { await channel.connect() }
        }
    }

    public func receive(serverId: String, _ message: HostServerMessage) {
        channels[serverId]?.receive(message)
    }

    /// Disconnects every channel without telling the owner of its change.
    public func stop() {
        let stopped = channels.values
        channels = [:]
        for channel in stopped {
            channel.onChange = nil
            channel.disconnect()
        }
    }

    private func makeChannel(_ serverId: String) -> PeerHostChannel {
        let channel = PeerHostChannel(timeout: timeout) { [weak self] in self?.send(serverId, $0) }
        channel.onChange = { [weak self, weak channel] in
            guard let self, let channel else { return }
            onChannelChanged?(serverId, channel)
        }
        onChannelMade?(serverId, channel)
        channels[serverId] = channel
        return channel
    }
}
