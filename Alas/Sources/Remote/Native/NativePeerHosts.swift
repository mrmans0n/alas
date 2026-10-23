import Foundation

/// Paired Macs' worktrees, followed over the host channel of each online
/// peer that serves it (`host.v1` and `host.events.v1`). Peers without it
/// keep the session-derived grouping.
@MainActor
final class NativePeerHosts {
    /// Visible worktrees by peer `serverId`. A key exists only for a peer
    /// whose channel holds a snapshot.
    private(set) var worktrees: [String: [PeerHostWorktree]] = [:]
    var onChange: (@MainActor () -> Void)?

    private let send: @MainActor (_ serverId: String, HostClientMessage) -> Void
    private let supports: @MainActor (_ serverId: String, _ capability: String) -> Bool
    let confirm: @MainActor (PeerWorktreeRemoval.Confirmation, _ peerName: String) async -> Bool
    let showError: @MainActor (_ title: String, _ message: String) -> Void
    private let timeout: Duration
    private var channels: [String: PeerHostChannel] = [:]

    init(
        send: @escaping @MainActor (_ serverId: String, HostClientMessage) -> Void,
        supports: @escaping @MainActor (_ serverId: String, _ capability: String) -> Bool,
        confirm: @escaping @MainActor (PeerWorktreeRemoval.Confirmation, _ peerName: String) async -> Bool = { _, _ in false },
        showError: @escaping @MainActor (_ title: String, _ message: String) -> Void = { _, _ in },
        timeout: Duration = PeerHostChannel.defaultTimeout
    ) {
        self.send = send
        self.supports = supports
        self.confirm = confirm
        self.showError = showError
        self.timeout = timeout
    }

    /// Reconciles with the peers whose links currently carry sessions. A
    /// channel that is not subscribed, because its snapshot or resync
    /// failed, connects again here.
    func peersChanged(online: Set<String>) {
        for (serverId, channel) in channels where !online.contains(serverId) || !servesHostChannel(serverId) {
            channels[serverId] = nil
            channel.disconnect() // its onChange drops `worktrees[serverId]`
        }
        for serverId in online where servesHostChannel(serverId) {
            let channel = channels[serverId] ?? makeChannel(serverId)
            guard !channel.isSubscribed, !channel.isConnecting else { continue }
            // ponytail: unthrottled retry, once per refresh (each session-list or
            // availability change); add a failure counter with backoff if a peer
            // that keeps refusing the snapshot or subscribe shows up.
            Task { await channel.connect() }
        }
    }

    func receive(serverId: String, _ message: HostServerMessage) {
        channels[serverId]?.receive(message)
    }

    func stop() {
        let stopped = channels.values
        channels = [:]
        worktrees = [:]
        for channel in stopped {
            channel.onChange = nil
            channel.disconnect()
        }
    }

    /// Whether `serverId`'s worktrees can be read over its host channel.
    func canRead(serverId: String) -> Bool {
        channels[serverId]?.isSubscribed == true && supports(serverId, HostProtocolCapability.worktreesReadV1)
    }

    /// The reply a session in `worktree` would get for `read`. Nil when the
    /// host cannot be read, refused, or did not answer in time.
    func read(_ read: HostWorktreeRead, in worktree: PeerHostWorktree, serverId: String) async -> RemoteServerMessage? {
        guard canRead(serverId: serverId), let channel = channels[serverId] else { return nil }
        let ref = WorktreeRef(projectID: worktree.snapshot.worktree.projectId, path: worktree.snapshot.worktree.path.path)
        guard case .worktreeRead(let reply) = await channel.request(.readWorktree(worktree: ref, read: read)) else { return nil }
        return reply
    }

    private func servesHostChannel(_ serverId: String) -> Bool {
        supports(serverId, HostProtocolCapability.v1) && supports(serverId, HostProtocolCapability.eventsV1)
    }

    private func makeChannel(_ serverId: String) -> PeerHostChannel {
        let channel = PeerHostChannel(timeout: timeout) { [weak self] in self?.send(serverId, $0) }
        channel.onChange = { [weak self, weak channel] in
            guard let self, let channel else { return }
            worktrees[serverId] = channel.state?.visibleWorktrees()
            onChange?()
        }
        channels[serverId] = channel
        return channel
    }
}
