import AlasCore
import Foundation

/// An inbox entry for a paired host that runs an older alas-host than this
/// Mac's Alas and can update itself from here.
struct HostUpdateReminder: Identifiable, Equatable {
    let serverId: String
    let name: String
    let hostVersion: String
    var icon: PeerIcon = .laptop

    var id: String { serverId }
}

enum HostUpdateReminderPolicy {
    static let dismissalsDefaultsKey = "hostUpdateReminderDismissals"
    static let appVersion = BuildIdentity.current().version

    struct Peer {
        let serverId: String
        let name: String
        let hostVersion: String?
        /// Online and serving `host.update.v1`.
        let canUpdate: Bool
        var icon: PeerIcon = .laptop
    }

    /// The hosts older than `appVersion` that can update from here. A host
    /// dismissed at its version stays hidden until it reports another one.
    static func reminders(peers: [Peer], appVersion: SemanticVersion, dismissed: [String: String]) -> [HostUpdateReminder] {
        peers.compactMap { peer in
            guard peer.canUpdate, let version = peer.hostVersion, dismissed[peer.serverId] != version,
                  let parsed = SemanticVersion(parsing: version), parsed < appVersion else { return nil }
            return HostUpdateReminder(serverId: peer.serverId, name: peer.name, hostVersion: version, icon: peer.icon)
        }
    }

    static func loadDismissals(defaults: UserDefaults = .standard) -> [String: String] {
        defaults.dictionary(forKey: dismissalsDefaultsKey) as? [String: String] ?? [:]
    }

    static func saveDismissals(_ dismissals: [String: String], defaults: UserDefaults = .standard) {
        defaults.set(dismissals, forKey: dismissalsDefaultsKey)
    }
}

@MainActor
enum PeerHostUpdate {
    static let reconnectTimeoutMessage = """
        The host disconnected during its update but did not reconnect with a usable host channel. \
        The update could not be confirmed. On that machine, run `alas-host restart` and check \
        the host logs if it stays offline. On macOS, also check for a blocked security prompt.
        """

    static func perform(
        channel: PeerHostChannel,
        reconnectedChannel: @MainActor () -> PeerHostChannel?,
        restartTimeout: Duration = .seconds(90),
        sleep: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @MainActor () -> ContinuousClock.Instant = { .now }
    ) async -> String? {
        // Homebrew may download a whole release; the SSH update allows it as long.
        let response = await channel.request(.updateHost, timeout: .seconds(900))
        switch response {
        case .done:
            // An unchanged installation answers without restarting.
            return nil
        case .failure(let error):
            guard error == .failed(message: FederatedSessionsProvider.peerUnavailableMessage) else {
                return PeerWorktreeRemoval.message(for: error)
            }
        default:
            return "The host returned an unexpected response to its update request."
        }

        // A dropped request alone cannot confirm an upgrade. Require the same
        // peer's replacement channel to finish its snapshot and subscription.
        let deadline = now() + restartTimeout
        while !Task.isCancelled {
            if let replacement = reconnectedChannel(), replacement !== channel,
               replacement.state != nil, replacement.isSubscribed {
                return nil
            }
            let remaining = deadline - now()
            guard remaining > .zero else { break }
            do {
                try await sleep(min(.milliseconds(250), remaining))
            } catch {
                return "Waiting for the host to reconnect was cancelled. The update could not be confirmed."
            }
        }
        return reconnectTimeoutMessage
    }
}

extension AppState {
    var hostUpdateReminders: [HostUpdateReminder] {
        HostUpdateReminderPolicy.reminders(
            peers: remotePeers.peers.map { peer in
                HostUpdateReminderPolicy.Peer(
                    serverId: peer.serverId, name: peer.name,
                    hostVersion: remotePeers.hostVersions[peer.serverId],
                    canUpdate: canUpdateHostOverPeer(peerId: peer.id, serverId: peer.serverId),
                    icon: peer.icon ?? .laptop
                )
            },
            appVersion: HostUpdateReminderPolicy.appVersion,
            dismissed: hostUpdateDismissals
        )
    }

    /// Whether the peer is an online host that updates itself through Homebrew.
    func canUpdateHostOverPeer(peerId: String, serverId: String) -> Bool {
        remotePeers.states[peerId] == .online
            && remotePeers.peerSupports(HostProtocolCapability.updateV1, serverId: serverId)
    }

    func dismissHostUpdateReminder(_ reminder: HostUpdateReminder) {
        hostUpdateDismissals[reminder.serverId] = reminder.hostVersion
        HostUpdateReminderPolicy.saveDismissals(hostUpdateDismissals)
    }

    /// Asks the host to upgrade itself. A restarted host must reconnect with a
    /// usable channel before the update is confirmed.
    func updateHostOverPeer(serverId: String) async -> String? {
        guard !hostUpdatesInFlight.contains(serverId) else {
            return "An update for this host is already in progress."
        }
        guard let peer = remotePeers.peers.first(where: { $0.serverId == serverId }),
              remotePeers.carriesSessions(peerId: peer.id),
              let channel = nativePeerSessions?.hosts?.channel(for: serverId) else {
            return FederatedSessionsProvider.peerUnavailableMessage
        }
        hostUpdatesInFlight.insert(serverId)
        defer { hostUpdatesInFlight.remove(serverId) }
        return await PeerHostUpdate.perform(channel: channel, reconnectedChannel: {
            guard self.remotePeers.peers.contains(where: { $0.id == peer.id && $0.serverId == serverId }),
                  self.remotePeers.carriesSessions(peerId: peer.id) else { return nil }
            return self.nativePeerSessions?.hosts?.channel(for: serverId)
        })
    }

    func updateHost(from reminder: HostUpdateReminder) {
        Task { @MainActor in
            if let message = await updateHostOverPeer(serverId: reminder.serverId) {
                showFileActionError(title: "Couldn't update \(reminder.name)", message: message)
            }
        }
    }
}
