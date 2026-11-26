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
    /// The latest ping round trip of each online host.
    private(set) var roundTrips: [UUID: Duration] = [:]
    private var sessionLists: [UUID: [RemoteSessionSummary]] = [:]
    /// Counts each host's arrivals online, so a link that dropped and came back between two
    /// looks still reads as new: the host forgot whatever the old socket held.
    private var onlineCounts: [UUID: Int] = [:]
    /// Hosts whose list arrived on the live connection, not from the cache.
    private var listedLive: Set<UUID> = []
    /// What each host's hello advertised, for this connection.
    private var capabilities: [UUID: Set<String>] = [:]
    /// The icons of the Macs each host relays, by their `serverId`, from its hello.
    private var rosterIcons: [UUID: [String: PeerIcon]] = [:]

    @ObservationIgnored private var connections: [UUID: PhoneConnection] = [:]
    /// Forgotten hosts still to be told to stop pushing, and their connections.
    @ObservationIgnored private var pendingUnregister: [PairedHost]
    @ObservationIgnored private var unregisterConnections: [UUID: PhoneConnection] = [:]
    @ObservationIgnored private var listeners: [UUID: [UUID: @MainActor (PhoneServerMessage) -> Void]] = [:]
    @ObservationIgnored private var deviceListeners: [UUID: [UUID: @MainActor (DeviceLinkEvent) -> Void]] = [:]
    /// Holders per session per host. The host keeps one follow per socket, so
    /// only the last holder's release may unsubscribe.
    @ObservationIgnored private var subscriptions: [UUID: [String: Int]] = [:]
    @ObservationIgnored private var runTrackers: [UUID: PhoneRunTracker] = [:]
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
        pendingUnregister = store.loadPendingUnregister()
        for host in hosts {
            sessionLists[host.id] = listCache.load(host.id)
        }
        attachConnections()
    }

    func state(of id: UUID) -> PhoneConnection.State {
        states[id] ?? (connections[id] == nil ? .unauthorized : .idle)
    }

    @ObservationIgnored private var hostRequestSeq = 0

    /// A fresh id for a host-protocol request, unique for the app's life.
    func nextHostRequestId() -> Int {
        hostRequestSeq += 1
        return hostRequestSeq
    }

    func onlineCount(of id: UUID) -> Int { onlineCounts[id] ?? 0 }

    /// Whether the host's hello on this connection advertised `capability`.
    func supports(_ capability: String, on id: UUID) -> Bool {
        capabilities[id]?.contains(capability) == true
    }

    func verifiedDeviceOrigin(of id: UUID) -> URL? {
        guard state(of: id) == .online, supports(PeerDeviceCapability.v1, on: id) else { return nil }
        return connections[id]?.verifiedHTTPSOrigin
    }

    func sessions(of id: UUID) -> [RemoteSessionSummary] {
        sessionLists[id] ?? []
    }

    /// The host's sessions, only while its list came from the live connection.
    func freshSessions(of id: UUID) -> [RemoteSessionSummary]? {
        listedLive.contains(id) ? sessions(of: id) : nil
    }

    var sessionSources: [RemoteSessionCatalog.Source] {
        hosts.map { host in
            RemoteSessionCatalog.Source(id: host.id, serverId: host.serverId, name: host.name, icon: host.icon,
                                        relayedIcons: rosterIcons[host.id] ?? [:],
                                        isLive: freshSessions(of: host.id) != nil,
                                        sessions: sessions(of: host.id))
        }
    }

    /// Keeps a host's name and icon current with what its hello reports, so a
    /// rename on the Mac shows here without pairing again, and keeps the icons
    /// of the Macs it relays.
    private func adoptIdentity(name: String, icon: PeerIcon?, peers: [RemoteHelloPeer], of id: UUID) {
        let relayed = Dictionary(peers.compactMap { peer in peer.icon.map { (peer.serverId, $0) } },
                                 uniquingKeysWith: { first, _ in first })
        if rosterIcons[id] != relayed { rosterIcons[id] = relayed }
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
        var host = hosts[index]
        if !name.isEmpty { host.name = name }
        if let icon { host.icon = icon }
        guard host != hosts[index] else { return }
        hosts[index] = host
        store.save(hosts)
    }

    func pair(origins: [String], code: String) async throws(RemotePairingError) {
        let result = try await pairingClient.pair(origins: origins, code: code, deviceName: RemotePairingClient.iosDeviceName, client: "ios")
        var allOrigins = [result.origin]
        for origin in origins where !allOrigins.contains(origin) {
            allOrigins.append(origin)
        }
        let name = result.name ?? URL(string: result.origin)?.host() ?? "Machine"
        let host: PairedHost
        // Pairing again with a Mac already on the list refreshes its record
        // instead of adding a second one, so screens holding its id keep it.
        if let serverId = result.serverId, let index = hosts.firstIndex(where: { $0.serverId == serverId }) {
            hosts[index].name = name
            hosts[index].icon = result.icon ?? hosts[index].icon
            hosts[index].origins = allOrigins
            hosts[index].lastOrigin = result.origin
            // A reply without a key must not drop an existing pin.
            hosts[index].publicKey = result.publicKey ?? hosts[index].publicKey
            host = hosts[index]
            connections[host.id]?.disconnect()
        } else {
            host = PairedHost(id: UUID(), name: name, serverId: result.serverId, origins: allOrigins,
                              lastOrigin: result.origin, publicKey: result.publicKey, icon: result.icon, addedAt: .now)
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
        // Online or not, the host may hold this phone's relay token: keep its
        // token until it is told to drop it, or it pushes forever.
        let pushes = registrar?.relayToken != nil
        if pushes, let host = hosts.first(where: { $0.id == id }) {
            pendingUnregister.append(host)
            store.savePendingUnregister(pendingUnregister)
        }
        connections.removeValue(forKey: id)?.disconnect()
        hosts.removeAll { $0.id == id }
        states[id] = nil
        roundTrips[id] = nil
        listedLive.remove(id)
        capabilities[id] = nil
        sessionLists[id] = nil
        // Released after the access ends, as in `addListener`.
        let handlers = (listeners.removeValue(forKey: id), deviceListeners.removeValue(forKey: id))
        withExtendedLifetime(handlers) {}
        subscriptions[id] = nil
        runTracker(for: id).forget()
        runTrackers[id] = nil
        store.save(hosts)
        if pushes { unregisterPending() } else { store.deleteToken(for: id) }
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
        unregisterPending()
    }

    func disconnectAll() {
        for connection in connections.values {
            connection.disconnect()
        }
        for connection in unregisterConnections.values {
            connection.disconnect()
        }
        unregisterConnections = [:]
    }

    /// Connects each forgotten host still owed an unregister. Retried on every
    /// `connectAll()` until the host hears it or refuses this phone.
    private func unregisterPending() {
        for host in pendingUnregister where unregisterConnections[host.id] == nil {
            guard let token = store.token(for: host.id) else {
                dropPendingUnregister(host.id)
                continue
            }
            let id = host.id
            let connection = PhoneConnection(
                origins: host.origins, lastOrigin: host.lastOrigin, token: token,
                expectedServerId: host.serverId, expectedPublicKey: host.publicKey
            ) { [weak self] event in
                guard let self else { return }
                switch event {
                case .hello(_, _, _, _, _, let capabilities, _, _):
                    self.capabilities[id] = Set(capabilities)
                case .stateChanged(.online):
                    guard self.capabilities[id]?.contains(PushRelayCapability.v1) == true else { return dropPendingUnregister(id) }
                    unregisterConnections[id]?.send(.pushRegistration(relayURL: PushRegistrar.relayURL, relayToken: nil))
                    // The host handles a connection's messages in order, so the reply to this one
                    // proves it applied the unregister. Without it the entry stays for the next try.
                    unregisterConnections[id]?.send(.listAgents)
                case .message(.agentList):
                    dropPendingUnregister(id)
                case .stateChanged(.idle), .stateChanged(.connecting), .stateChanged(.offline):
                    break
                case .stateChanged:
                    // Refused or not the Mac it was: it will never hear this, nor push with this pairing.
                    dropPendingUnregister(id)
                default:
                    break
                }
            }
            unregisterConnections[id] = connection
            connection.connect()
        }
    }

    private func dropPendingUnregister(_ id: UUID) {
        unregisterConnections.removeValue(forKey: id)?.disconnect()
        capabilities[id] = nil
        guard pendingUnregister.contains(where: { $0.id == id }) else { return }
        pendingUnregister.removeAll { $0.id == id }
        store.savePendingUnregister(pendingUnregister)
        store.deleteToken(for: id)
    }

    func send(_ message: PhoneClientMessage, to id: UUID) {
        connections[id]?.send(message)
    }

    func followRun(_ runID: String, on hostID: UUID, openConsole: @escaping PhoneRunTracker.OpenConsole) {
        AppDelegate.prepareRunNotifications()
        runTracker(for: hostID).follow(runID, openConsole: supports(PeerConsoleCapability.phoneV1, on: hostID) ? openConsole : nil)
    }

    private func runTracker(for hostID: UUID) -> PhoneRunTracker {
        if let tracker = runTrackers[hostID] { return tracker }
        let key = "pendingRuns.\(hostID.uuidString)"
        let tracker = PhoneRunTracker(
            pending: Set(UserDefaults.standard.stringArray(forKey: key) ?? []),
            nextRequestID: { [weak self] in
                guard let self, state(of: hostID) == .online else { return nil }
                return nextHostRequestId()
            },
            send: { [weak self] in self?.send($0, to: hostID) },
            save: { UserDefaults.standard.set($0.isEmpty ? nil : Array($0), forKey: key) },
            notify: { AppDelegate.postRunResult(hostID: hostID, runID: $0, name: $1, exitCode: $2) }
        )
        runTrackers[hostID] = tracker
        return tracker
    }

    func addListener(_ id: UUID, _ handler: @escaping @MainActor (PhoneServerMessage) -> Void) -> ListenerToken {
        let key = UUID()
        listeners[id, default: [:]][key] = handler
        return ListenerToken { [weak self] in
            // Released only once the access to `listeners` has ended: the handler can hold the last
            // reference to something owning another token, whose deinit edits `listeners` too.
            let handler = self?.listeners[id]?.removeValue(forKey: key)
            withExtendedLifetime(handler) {}
        }
    }

    enum DeviceLinkEvent {
        case connectionChanged
        case message(PeerDeviceEvent)
    }

    func addDeviceListener(_ id: UUID, _ handler: @escaping @MainActor (DeviceLinkEvent) -> Void) -> ListenerToken {
        let key = UUID()
        deviceListeners[id, default: [:]][key] = handler
        return ListenerToken { [weak self] in
            // Released after the access ends, as in `addListener`.
            let handler = self?.deviceListeners[id]?.removeValue(forKey: key)
            withExtendedLifetime(handler) {}
        }
    }

    private func notifyDeviceListeners(_ event: DeviceLinkEvent, on id: UUID) {
        guard let listeners = deviceListeners[id] else { return }
        for handler in listeners.values { handler(event) }
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
        guard let registrar, let token = registrar.relayToken, capabilities[id]?.contains(PushRelayCapability.v1) == true else { return }
        send(.pushRegistration(relayURL: PushRegistrar.relayURL, relayToken: token, kinds: registrar.kinds.sorted()), to: id)
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
        let connection = PhoneConnection(
            origins: host.origins, lastOrigin: host.lastOrigin, token: token,
            expectedServerId: host.serverId, expectedPublicKey: host.publicKey,
            config: .init(pingInterval: 10)
        ) { [weak self] event in
            self?.handle(event, from: id)
        }
        connection.acknowledge([PeerDeviceCapability.v1])
        return connection
    }

    private func handle(_ event: PhoneConnection.Event, from id: UUID) {
        switch event {
        case .stateChanged(let state):
            states[id] = state
            if state != .online {
                roundTrips[id] = nil
                listedLive.remove(id)
                runTrackers[id]?.disconnect()
            }
            if state == .online {
                onlineCounts[id, default: 0] += 1
                send(.listSessions, to: id)
                sendPushRegistration(to: id)
                if supports(HostProtocolCapability.runsScriptsV1, on: id) { runTracker(for: id).refresh() }
            }
            // Do not depend on a SwiftUI render between losing one socket and adopting the next.
            notifyDeviceListeners(.connectionChanged, on: id)
        case .hello(_, let name, let icon, _, _, let capabilities, _, let peers):
            // Arrives just before `.online`, while `send` is still a no-op;
            // the state change above asks for the list and registers push.
            self.capabilities[id] = Set(capabilities)
            adoptIdentity(name: name, icon: icon, peers: peers, of: id)
        case .originChanged(let origin):
            guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
            hosts[index].lastOrigin = origin
            store.save(hosts)
        case .roundTrip(let roundTrip):
            roundTrips[id] = roundTrip
        case .message(let message):
            switch message {
            case .device(let event):
                if verifiedDeviceOrigin(of: id) != nil { notifyDeviceListeners(.message(event), on: id) }
                return
            case .sessionList(let sessions):
                sessionLists[id] = sessions
                listedLive.insert(id)
                if let registrar { Task { await registrar.reconcile() } }
                let cache = listCache
                cacheSeq += 1
                let seq = cacheSeq
                Task.detached { await cache.save(sessions, for: id, seq: seq) }
            case .sessionCreated(let session), .worktreeSessionCreated(let session):
                // Listed now, as the web client does: the host's refreshed list can lag, and until
                // then the new session's screen would read an unlisted session as ended.
                var sessions = sessionLists[id] ?? []
                sessions.removeAll { $0.id == session.id }
                sessions.append(session)
                sessionLists[id] = sessions
            case .hello(_, _, let name, let icon, _, let peers, let offeredCapabilities, _):
                // A re-broadcast hello on a live socket: the host's state changed.
                adoptIdentity(name: name, icon: icon, peers: peers, of: id)
                let hadDevices = supports(PeerDeviceCapability.v1, on: id)
                capabilities[id] = Set(offeredCapabilities)
                if hadDevices != supports(PeerDeviceCapability.v1, on: id) {
                    notifyDeviceListeners(.connectionChanged, on: id)
                }
                send(.listSessions, to: id)
            default:
                break
            }
            runTrackers[id]?.receive(message)
            for handler in (listeners[id] ?? [:]).values {
                handler(message)
            }
        }
    }
}
