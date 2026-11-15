import AlasRemoteKit
import Foundation
import Observation

/// Removes a listener added with `HostHub.addListener`, on `cancel()` or
/// when released, so a forgotten token cannot keep its handler alive.
@MainActor
final class ListenerToken {
    private var onCancel: (@MainActor () -> Void)?

    init(onCancel: @escaping @MainActor () -> Void) {
        self.onCancel = onCancel
    }

    func cancel() {
        onCancel?()
        onCancel = nil
    }

    isolated deinit {
        cancel()
    }
}

/// Paired hosts and one live connection to each. The app's scene phase
/// drives `connectAll()` / `disconnectAll()`; session lists survive both so
/// screens never blank while a host reconnects.
@MainActor @Observable
final class HostHub {
    private(set) var hosts: [PairedHost]
    private var states: [UUID: PhoneConnection.State] = [:]
    private var sessionLists: [UUID: [RemoteSessionSummary]] = [:]
    /// Hosts whose list arrived on the live connection, not from the cache.
    @ObservationIgnored private var listedLive: Set<UUID> = []
    /// What each host's hello advertised, for this connection.
    @ObservationIgnored private var capabilities: [UUID: Set<String>] = [:]

    @ObservationIgnored private var connections: [UUID: PhoneConnection] = [:]
    @ObservationIgnored private var listeners: [UUID: [UUID: @MainActor (PhoneServerMessage) -> Void]] = [:]
    /// Holders per session per host. The host keeps one follow per socket, so
    /// only the last holder's release may unsubscribe.
    @ObservationIgnored private var subscriptions: [UUID: [String: Int]] = [:]
    @ObservationIgnored private let store: HostStore
    @ObservationIgnored var registrar: PushRegistrar? {
        didSet { registrar?.onTokenChange = { [weak self] in self?.sendPushRegistrationToOnlineHosts() } }
    }
    @ObservationIgnored private let listCache = SessionListCache()
    /// Stamps cache writes in main-actor order; see `SessionListCache.newest`.
    @ObservationIgnored private var cacheSeq = 0
    /// One client for the app's life: each default client owns a URLSession.
    @ObservationIgnored private let pairingClient = RemotePairingClient()

    init(store: HostStore = HostStore()) {
        self.store = store
        store.migrateIfNeeded()
        hosts = store.load()
        for host in hosts {
            sessionLists[host.id] = listCache.load(host.id)
        }
        attachConnections()
    }

    func state(of id: UUID) -> PhoneConnection.State {
        states[id] ?? (connections[id] == nil ? .unauthorized : .idle)
    }

    func sessions(of id: UUID) -> [RemoteSessionSummary] {
        sessionLists[id] ?? []
    }

    /// The host's sessions, only while its list came from the live connection.
    func freshSessions(of id: UUID) -> [RemoteSessionSummary]? {
        listedLive.contains(id) ? sessions(of: id) : nil
    }

    func pair(origins: [String], code: String) async throws(RemotePairingError) {
        let result = try await pairingClient.pair(origins: origins, code: code, deviceName: "Alas for iOS")
        var allOrigins = [result.origin]
        for origin in origins where !allOrigins.contains(origin) {
            allOrigins.append(origin)
        }
        let name = result.name ?? URL(string: result.origin)?.host() ?? "Mac"
        let host: PairedHost
        // Pairing again with a Mac already on the list refreshes its record
        // instead of adding a second one, so screens holding its id keep it.
        if let serverId = result.serverId, let index = hosts.firstIndex(where: { $0.serverId == serverId }) {
            hosts[index].name = name
            hosts[index].origins = allOrigins
            hosts[index].lastOrigin = result.origin
            // A reply without a key must not drop an existing pin.
            hosts[index].publicKey = result.publicKey ?? hosts[index].publicKey
            host = hosts[index]
            connections[host.id]?.disconnect()
        } else {
            host = PairedHost(id: UUID(), name: name, serverId: result.serverId, origins: allOrigins,
                              lastOrigin: result.origin, publicKey: result.publicKey, addedAt: .now)
            hosts.append(host)
        }
        store.save(hosts)
        store.setToken(result.token, for: host.id)
        states[host.id] = nil
        let connection = makeConnection(for: host, token: result.token)
        connections[host.id] = connection
        connection.connect()
        registrar?.start()
    }

    func forget(_ id: UUID) {
        if state(of: id) == .online, registrar?.relayToken != nil, capabilities[id]?.contains(PushRelayCapability.v1) == true {
            send(.pushRegistration(relayURL: PushRegistrar.relayURL, relayToken: nil), to: id)
        }
        connections.removeValue(forKey: id)?.disconnect()
        hosts.removeAll { $0.id == id }
        states[id] = nil
        listedLive.remove(id)
        capabilities[id] = nil
        sessionLists[id] = nil
        listeners[id] = nil
        subscriptions[id] = nil
        store.save(hosts)
        store.deleteToken(for: id)
        let cache = listCache
        cacheSeq += 1
        let seq = cacheSeq
        Task.detached { await cache.delete(id, seq: seq) }
    }

    func connectAll() {
        attachConnections()
        for connection in connections.values {
            connection.connect()
        }
    }

    func disconnectAll() {
        for connection in connections.values {
            connection.disconnect()
        }
    }

    func send(_ message: PhoneClientMessage, to id: UUID) {
        connections[id]?.send(message)
    }

    func addListener(_ id: UUID, _ handler: @escaping @MainActor (PhoneServerMessage) -> Void) -> ListenerToken {
        let key = UUID()
        listeners[id, default: [:]][key] = handler
        return ListenerToken { [weak self] in
            self?.listeners[id]?[key] = nil
        }
    }

    /// Follows `sessionId` until the token is released. Every holder asks for
    /// its own snapshot; `.unsubscribe` goes out only when the last one lets go,
    /// so a covered screen closing cannot freeze a visible one.
    func subscribe(_ sessionId: String, on id: UUID) -> ListenerToken {
        subscriptions[id, default: [:]][sessionId, default: 0] += 1
        send(.subscribe(sessionId: sessionId), to: id)
        return ListenerToken { [weak self] in
            guard let self, let count = subscriptions[id]?[sessionId] else { return }
            if count > 1 {
                subscriptions[id]?[sessionId] = count - 1
            } else {
                subscriptions[id]?[sessionId] = nil
                send(.unsubscribe(sessionId: sessionId), to: id)
            }
        }
    }

    private func sendPushRegistration(to id: UUID) {
        guard let token = registrar?.relayToken, capabilities[id]?.contains(PushRelayCapability.v1) == true else { return }
        send(.pushRegistration(relayURL: PushRegistrar.relayURL, relayToken: token), to: id)
    }

    private func sendPushRegistrationToOnlineHosts() {
        for host in hosts where state(of: host.id) == .online { sendPushRegistration(to: host.id) }
    }

    /// Creates the connection of any host that lacks one. Retried on every
    /// `connectAll()`, so a token the Keychain could not read earlier (before
    /// first unlock) is picked up. A host whose token stays unreadable reads
    /// as unauthorized, which offers "Pair again".
    private func attachConnections() {
        for host in hosts where connections[host.id] == nil {
            if let token = store.token(for: host.id) {
                connections[host.id] = makeConnection(for: host, token: token)
            }
        }
    }

    private func makeConnection(for host: PairedHost, token: String) -> PhoneConnection {
        let id = host.id
        return PhoneConnection(
            origins: host.origins, lastOrigin: host.lastOrigin, token: token,
            expectedServerId: host.serverId, expectedPublicKey: host.publicKey
        ) { [weak self] event in
            self?.handle(event, from: id)
        }
    }

    private func handle(_ event: PhoneConnection.Event, from id: UUID) {
        switch event {
        case .stateChanged(let state):
            states[id] = state
            if state != .online { listedLive.remove(id) }
            if state == .online {
                send(.listSessions, to: id)
                sendPushRegistration(to: id)
            }
        case .hello(_, _, _, _, let capabilities, _):
            // Arrives just before `.online`, while `send` is still a no-op;
            // the state change above asks for the list and registers push.
            self.capabilities[id] = Set(capabilities)
        case .originChanged(let origin):
            guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
            hosts[index].lastOrigin = origin
            store.save(hosts)
        case .message(let message):
            switch message {
            case .sessionList(let sessions):
                sessionLists[id] = sessions
                listedLive.insert(id)
                if let registrar { Task { await registrar.reconcile() } }
                let cache = listCache
                cacheSeq += 1
                let seq = cacheSeq
                Task.detached { await cache.save(sessions, for: id, seq: seq) }
            case .hello:
                // A re-broadcast hello on a live socket: the host's state changed.
                send(.listSessions, to: id)
            default:
                break
            }
            for handler in (listeners[id] ?? [:]).values {
                handler(message)
            }
        }
    }
}
