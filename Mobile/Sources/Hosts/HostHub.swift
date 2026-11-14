import AlasRemoteKit
import Foundation
import Observation

/// Removes a listener added with `HostHub.addListener`, on `cancel()` or
/// when released, so a forgotten token cannot keep its handler alive.
@MainActor
final class ListenerToken {
    private var onCancel: (@MainActor () -> Void)?

    fileprivate init(onCancel: @escaping @MainActor () -> Void) {
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

    @ObservationIgnored private var connections: [UUID: PhoneConnection] = [:]
    @ObservationIgnored private var listeners: [UUID: [UUID: @MainActor (PhoneServerMessage) -> Void]] = [:]
    @ObservationIgnored private let store: HostStore
    /// One client for the app's life: each default client owns a URLSession.
    @ObservationIgnored private let pairingClient = RemotePairingClient()

    init(store: HostStore = HostStore()) {
        self.store = store
        hosts = store.load()
        attachConnections()
    }

    func state(of id: UUID) -> PhoneConnection.State {
        states[id] ?? (connections[id] == nil ? .unauthorized : .idle)
    }

    func sessions(of id: UUID) -> [RemoteSessionSummary] {
        sessionLists[id] ?? []
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
    }

    func forget(_ id: UUID) {
        connections.removeValue(forKey: id)?.disconnect()
        hosts.removeAll { $0.id == id }
        states[id] = nil
        sessionLists[id] = nil
        listeners[id] = nil
        store.save(hosts)
        store.deleteToken(for: id)
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
            if state == .online { send(.listSessions, to: id) }
        case .hello:
            // Arrives just before `.online`, while `send` is still a no-op;
            // the state change above asks for the list.
            break
        case .originChanged(let origin):
            guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
            hosts[index].lastOrigin = origin
            store.save(hosts)
        case .message(let message):
            switch message {
            case .sessionList(let sessions):
                sessionLists[id] = sessions
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
