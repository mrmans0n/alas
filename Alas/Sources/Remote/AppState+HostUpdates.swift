import AlasCore
import Foundation

/// An inbox entry for a paired host that runs an older alas-host than this
/// Mac's Alas and can update itself from here.
struct HostUpdateReminder: Identifiable, Equatable {
    let serverId: String
    let name: String
    let hostVersion: String

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
    }

    /// The hosts older than `appVersion` that can update from here. A host
    /// dismissed at its version stays hidden until it reports another one.
    static func reminders(peers: [Peer], appVersion: SemanticVersion, dismissed: [String: String]) -> [HostUpdateReminder] {
        peers.compactMap { peer in
            guard peer.canUpdate, let version = peer.hostVersion, dismissed[peer.serverId] != version,
                  let parsed = SemanticVersion(parsing: version), parsed < appVersion else { return nil }
            return HostUpdateReminder(serverId: peer.serverId, name: peer.name, hostVersion: version)
        }
    }

    static func loadDismissals(defaults: UserDefaults = .standard) -> [String: String] {
        defaults.dictionary(forKey: dismissalsDefaultsKey) as? [String: String] ?? [:]
    }

    static func saveDismissals(_ dismissals: [String: String], defaults: UserDefaults = .standard) {
        defaults.set(dismissals, forKey: dismissalsDefaultsKey)
    }
}

extension AppState {
    var hostUpdateReminders: [HostUpdateReminder] {
        HostUpdateReminderPolicy.reminders(
            peers: remotePeers.peers.map { peer in
                HostUpdateReminderPolicy.Peer(
                    serverId: peer.serverId, name: peer.name,
                    hostVersion: remotePeers.hostVersions[peer.serverId],
                    canUpdate: canUpdateHostOverPeer(peerId: peer.id, serverId: peer.serverId)
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

    /// Asks the host to upgrade itself and restart; nil once it did, or a
    /// message saying why it couldn't.
    func updateHostOverPeer(serverId: String) async -> String? {
        guard let channel = nativePeerSessions?.hosts?.channel(for: serverId) else {
            return FederatedSessionsProvider.peerUnavailableMessage
        }
        hostUpdatesInFlight.insert(serverId)
        defer { hostUpdatesInFlight.remove(serverId) }
        // Homebrew may download a whole release; the SSH update allows it as long.
        let response = await channel.request(.updateHost, timeout: .seconds(900))
        // A host the upgrade replaced restarts, dropping the connection
        // before it answers; it comes back online on the new version.
        guard case .failure(let error) = response,
              error != .failed(message: FederatedSessionsProvider.peerUnavailableMessage) else { return nil }
        return PeerWorktreeRemoval.message(for: error)
    }

    func updateHost(from reminder: HostUpdateReminder) {
        Task { @MainActor in
            if let message = await updateHostOverPeer(serverId: reminder.serverId) {
                showFileActionError(title: "Couldn't update \(reminder.name)", message: message)
            }
        }
    }
}
