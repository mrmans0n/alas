import Foundation
import os
import AlasFoundation
import AlasAgents
import AlasACP

private let logger = Logger(subsystem: "io.nlopez.alas", category: "RemotePush")

/// Pings each paired phone's push relay when a session starts or stops
/// waiting on its owner: this host's own sessions, from the host's events,
/// and its peers' sessions, from the federation's peer lists. What to push
/// is `RemotePushPlanner`'s call; this only gathers statuses and posts.
@MainActor
final class RemotePushNotifier {
    private typealias Key = RemotePushPlanner.Key

    private let pairing: RemotePairingService
    private let host: AlasHost?
    private let federation: FederatedSessionsProvider?
    private let serverId: String
    private var planner = RemotePushPlanner(current: [:])
    private var local: [Key: String] = [:]
    /// Each peer's statuses, by its `serverId`, kept while the peer is away.
    private var peers: [String: [Key: String]] = [:]
    private var subscription: HostSubscription?
    private let urlSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10
        return URLSession(configuration: config)
    }()

    init(pairing: RemotePairingService, host: AlasHost?, federation: FederatedSessionsProvider?, serverId: String) {
        self.pairing = pairing
        self.host = host
        self.federation = federation
        self.serverId = serverId
    }

    /// Seeds the planner with every session's current status, so waits that
    /// already exist page nobody, then follows changes.
    func start() {
        local = localStatuses()
        peers = peerStatuses()
        planner = RemotePushPlanner(current: merged)
        federation?.onPeerRowsChanged = { [weak self] in self?.peersChanged() }
        guard let host else { return }
        let subscription = host.subscribe()
        self.subscription = subscription
        Task { @MainActor [weak self] in
            while let events = await subscription.next() {
                guard let self else { return }
                let touchesSessions = events.contains {
                    switch $0 {
                    case .sessionChanged, .sessionRemoved, .resync: true
                    default: false
                    }
                }
                guard touchesSessions else { continue }
                local = localStatuses()
                apply()
            }
        }
    }

    func stop() {
        subscription?.cancel()
        subscription = nil
        federation?.onPeerRowsChanged = nil
    }

    private var merged: [Key: String] {
        peers.values.reduce(local) { $0.merging($1) { current, _ in current } }
    }

    /// This host's sessions, by the id its remote session list shows them under.
    private func localStatuses() -> [Key: String] {
        var statuses: [Key: String] = [:]
        for session in host?.sessions.list() ?? [] {
            let key = Key(originServerId: serverId, sessionId: session.id)
            statuses[key] = session.streamingState.map(RemoteSessionGateway.stateString) ?? RemotePushPlanner.noRunnerStatus
        }
        return statuses
    }

    /// Each peer's rows by origin, for the peers whose list has arrived.
    private func peerStatuses() -> [String: [Key: String]] {
        (federation?.peerRows ?? [:]).mapValues { rows in
            var statuses: [Key: String] = [:]
            for row in rows {
                guard let peer = row.serverId,
                      let origin = RemoteFederatedSessionID.parse(row.id, peers: [peer]) else { continue }
                statuses[Key(originServerId: origin.serverId, sessionId: origin.sessionId)] = row.status
            }
            return statuses
        }
    }

    private func peersChanged() {
        // ponytail: a peer that goes away keeps its last statuses, so a
        // dropped link neither clears its alerts nor re-pages on return.
        // A forgotten peer's waits are never cleared from here.
        for (peer, statuses) in peerStatuses() {
            // A peer's first list since start describes waits from before.
            if peers[peer] == nil { planner.baseline(statuses) }
            peers[peer] = statuses
        }
        apply()
    }

    private func apply() {
        let before = planner
        let actions = planner.update(merged)
        let relays = pairing.pushRelays
        guard !actions.isEmpty, !relays.isEmpty else { return }
        for action in actions {
            let body: [String: String]
            switch action {
            case .attention(let key, let status):
                body = Self.body(kind: "attention", key: key, status: status)
            case .clear(let key):
                // The relay wants a waiting status; send the one last pushed.
                body = Self.body(kind: "clear", key: key, status: before.status(of: key) ?? "awaitingInput")
            }
            for (deviceID, relay) in relays { post(body, to: relay, deviceID: deviceID) }
        }
    }

    private static func body(kind: String, key: Key, status: String) -> [String: String] {
        [
            "kind": kind,
            "collapseId": RemotePushID.collapseId(originServerId: key.originServerId, sessionId: key.sessionId),
            "serverId": key.originServerId,
            "sessionId": key.sessionId,
            "status": status,
        ]
    }

    private func post(_ body: [String: String], to relay: RemotePushRelay, deviceID: String) {
        var request = URLRequest(url: relay.url.appendingPathComponent("push"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(body.merging(["relayToken": relay.token]) { $1 })
        Task { @MainActor [urlSession, weak pairing] in
            do {
                let (_, response) = try await urlSession.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 410 {
                    // Unless the phone registered again meanwhile.
                    if pairing?.device(id: deviceID)?.pushRelay == relay { pairing?.setPushRelay(nil, for: deviceID) }
                } else if status != 204 {
                    logger.error("Push relay answered \(status, privacy: .public)")
                }
            } catch {
                logger.error("Push relay unreachable: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
