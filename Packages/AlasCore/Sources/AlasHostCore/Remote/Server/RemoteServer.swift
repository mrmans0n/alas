import Foundation
#if canImport(Network)
import Network
#endif
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasAgents

/// In-process HTTP + WebSocket server. Listens on a loopback TCP port, serves
/// the static web client and `POST /pair` over HTTP, and upgrades authorized
/// `/ws` requests to a session gateway and ticketed `/ws/device-media` requests
/// to a binary video stream.
///
/// `@MainActor`-confined for its public surface (start/stop/port and the
/// connection table); listener and connection callbacks arrive on the
/// serial `queue` and hop back to MainActor before touching state.
@MainActor
public final class RemoteServer {
    private var listener: (any TCPListener)?
    private let queue = DispatchQueue(label: "io.alas.remote.server")
    private var connections: [ObjectIdentifier: RemoteConnection] = [:]
    /// Maps each authenticated connection to the device it logged in as, so a
    /// revoked device's live sockets can be closed. Populated via the
    /// connection's `onAuthenticated` hop (MainActor), never by reading
    /// queue-confined connection state cross-queue.
    private var connectionDevice: [ObjectIdentifier: String] = [:]
    private struct DeviceControlLink {
        let pairingID: String
        let host: PeerDeviceHost
        let id: UUID
    }
    private struct DeviceMediaLink {
        let host: PeerDeviceHost
        let session: PeerDeviceHost.MediaSession
    }
    private var deviceControlLinks: [ObjectIdentifier: DeviceControlLink] = [:]
    private var deviceMediaLinks: [ObjectIdentifier: DeviceMediaLink] = [:]
    private var advertisedPeerDevices = false
    /// What each authenticated socket's `helloAck` said its client serves
    /// back, and when it said so, which orders a device's sockets.
    private var acknowledged: [ObjectIdentifier: (order: Int, capabilities: Set<String>)] = [:]
    private var acknowledgements = 0
    /// How often the sockets of paired Alas instances are pinged. One that
    /// sent nothing between two pings is closed, so a peer that vanished
    /// without closing is gone within twice this, and so are its routes.
    public var livenessInterval: Duration = .seconds(20)
    private var livenessTask: Task<Void, Never>?
    private var pushNotifier: RemotePushNotifier?
    /// Cap on simultaneous sockets. An unauthenticated peer can open a socket
    /// (auth only happens at WS upgrade), so bound the count defensively.
    private let maxConnections = 64

    nonisolated public let pairing: RemotePairingService
    private let assets: RemoteWebAssets
    private let host: AlasHost?
    /// The app's windows, which each gateway takes tab requests to.
    @_spi(AppHost) public weak var presenter: RemoteSessionPresenter?
    /// Test hook run on each gateway as a connection makes it.
    @_spi(Testing) public var configureGateway: (@MainActor (RemoteSessionGateway) -> Void)?
    private var accessPolicy: RemoteAccessPolicy
    private var originPolicy: RemoteOriginPolicy
    private let identityProvider: @MainActor () -> RemoteServerIdentity
    private let diagnosticsProvider: @MainActor (UInt16?) -> RemoteDiagnosticsSnapshot
    /// Signs peer identity challenges — on `/pair`, so a record can be pinned
    /// to key material the peer had to possess, and on the socket, so every
    /// later connection has to prove possession again. Nil means this server
    /// has no identity key: pairing still works, but the resulting record
    /// stays unverified and phase 3 will not carry sessions over it.
    private let signer: (any RemoteIdentitySigning)?
    public var approvalCoordinator: RemotePairingApprovalCoordinator?
    public var approvalEnabled: @MainActor () -> Bool = { false }

    public var pairingApprovalVersion: Int? {
        guard approvalCoordinator != nil, approvalEnabled(),
              let signer = signer as? any ApprovalSigning,
              let key = Data(base64Encoded: signer.publicKey), key.count == 32,
              key.base64EncodedString() == signer.publicKey else { return nil }
        return 1
    }

    public func diagnosticsSnapshot() -> RemoteDiagnosticsSnapshot {
        var snapshot = diagnosticsProvider(port)
        snapshot.pairingApprovalVersion = pairingApprovalVersion
        return snapshot
    }
    /// Peer-session routing handed to every gateway this server creates.
    /// Nil means clients see local sessions only. Read once per accepted
    /// connection, so setting it affects sockets opened from then on; the
    /// app sets it before `start()`.
    public var federation: FederatedSessionsProvider?
    public private(set) var port: UInt16?
    /// Set once we've already retried on an OS-assigned port after a fixed-port
    /// bind failure, so we don't loop.
    private var didFallback = false
    public private(set) var loopbackOnly = false
    /// Invoked on the main actor when the bound port changes — set when the
    /// listener becomes ready, nil when it fails/cancels. Lets observers (the
    /// Settings pane via AppState) react, since `port` itself isn't observable.
    public var onPortChange: ((UInt16?) -> Void)?
    /// Invoked on the main actor whenever authenticated remote socket counts
    /// change. AppState snapshots this so Settings observes live disconnects.
    public var onConnectionDeviceCountsChange: (([String: Int]) -> Void)?
    /// Fired on the main actor when what a device's open sockets acknowledged
    /// may have changed: one acknowledged something, or one of its sockets closed.
    public var onAcknowledgedCapabilitiesChange: (@MainActor (_ deviceId: String) -> Void)?
    /// Takes a device's answers to requests sent it as `RemoteServerMessage.peerHost`,
    /// with the route `route(toDevice:acknowledging:)` gave the socket it came
    /// on, nil for one that acknowledged nothing.
    public var onPeerHostReply: (@MainActor (_ deviceId: String, _ route: Int?, HostServerMessage) -> Void)?
    /// Fired on the main actor after another Alas instance paired here.
    public var onPeerPaired: (@MainActor (RemotePeerPairingRequest) -> Void)?
    /// See `RemoteHTTPResponder.pairsBackWithPeers`. Off only on alas-host.
    public var pairsBackWithPeers = true
    /// See `RemoteHTTPResponder.admitsInboundOnlyPeer`.
    public var admitsInboundOnlyPeer: (@MainActor (RemotePeerAdvertisement) -> Bool)?
    public var onApprovedPeerPaired: (@MainActor (RemotePeerPairingRequest, String, ApprovalPeer) -> Void)?
    /// Bonjour advertisement applied to the live listener, and to any listener
    /// `start()` creates later (a port-fallback restart must keep advertising).
    /// Nil means not discoverable.
    public private(set) var advertisement: RemoteBonjourAdvertisement?

    /// Callers with app state should pass a diagnostics closure; the default is
    /// a safe empty fallback for contexts that do not have app state available.
    public init(
        pairing: RemotePairingService,
        assets: RemoteWebAssets,
        host: AlasHost?,
        accessPolicy: RemoteAccessPolicy = .loopback,
        originPolicy: RemoteOriginPolicy = .loopback,
        diagnostics: @escaping @MainActor (UInt16?) -> RemoteDiagnosticsSnapshot = { port in
            RemoteDiagnosticsSnapshot(
                appName: "Alas",
                port: port,
                addresses: [],
                usesPlainHTTP: true,
                pairedDeviceCount: 0
            )
        },
        identity: @escaping @MainActor () -> RemoteServerIdentity = {
            RemoteServerIdentity(serverId: "", name: "Alas")
        },
        signer: (any RemoteIdentitySigning)? = nil
    ) {
        self.pairing = pairing
        self.assets = assets
        self.host = host
        self.accessPolicy = accessPolicy
        self.originPolicy = originPolicy
        self.diagnosticsProvider = diagnostics
        self.identityProvider = identity
        self.signer = signer
    }

    /// Starts listening on the given port (0 = OS-assigned). A non-zero port that
    /// is already in use surfaces asynchronously as `.failed`; we then retry once
    /// on an OS-assigned port so the server still starts (the Address/QR use the
    /// actual bound port, so pairing still works). Throws only on invalid params.
    /// `loopbackOnly` binds 127.0.0.1 so only a local proxy (Tailscale Serve)
    /// can reach the server; a fallback restart keeps the same bind.
    public func start(port desired: UInt16 = 0, loopbackOnly: Bool = false) throws {
        stop()
        if desired != 0 { didFallback = false }
        self.loopbackOnly = loopbackOnly
        let listener = try TCP.listener(host: loopbackOnly ? .loopbackV4 : .any, port: desired)
        let onState: @Sendable (TCPListenerState) -> Void = { [weak self, weak listener] state in
            guard let listener else { return }
            switch state {
            case .ready(let assigned):
                Task { @MainActor in
                    // Ignore events from a superseded listener (e.g. the old one's
                    // late `.cancelled` after a port-fallback) so they can't wipe
                    // the live port/address.
                    guard let self, self.listener === listener else { return }
                    self.port = assigned
                    self.onPortChange?(assigned)
                    self.refreshPeerDevicePolicy()
                }
            case .failed:
                Task { @MainActor in
                    guard let self, self.listener === listener else { return }
                    if desired != 0 && !self.didFallback {
                        self.didFallback = true
                        try? self.start(port: 0, loopbackOnly: loopbackOnly)   // preferred port taken — fall back to OS-assigned
                    } else {
                        self.port = nil
                        self.onPortChange?(nil)
                        self.refreshPeerDevicePolicy()
                    }
                }
            case .cancelled:
                Task { @MainActor in
                    guard let self, self.listener === listener else { return }
                    self.port = nil
                    self.onPortChange?(nil)
                    self.refreshPeerDevicePolicy()
                }
            }
        }
        self.listener = listener
        setService(advertisement)
        listener.start(queue: queue, onState: onState) { [weak self, weak listener] stream in
            guard let listener else {
                stream.cancel()
                return
            }
            Task { @MainActor in
                guard let self, self.listener === listener else {
                    stream.cancel()
                    return
                }
                self.accept(stream)
            }
        }
        let serverId = identityProvider().serverId
        if !serverId.isEmpty {
            let notifier = RemotePushNotifier(pairing: pairing, host: host, federation: federation, serverId: serverId)
            notifier.start()
            pushNotifier = notifier
        }
        let interval = livenessInterval
        livenessTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                self?.probeConnections()
            }
        }
    }

    /// Probe Alas peers and active device links. Browsers are left alone:
    /// a suspended tab cannot answer, and nothing routes through it.
    public func probeConnections() {
        for (oid, deviceId) in connectionDevice
        where deviceControlLinks[oid] != nil || pairing.device(id: deviceId)?.kind == .alasInstance {
            connections[oid]?.probe()
        }
        for oid in deviceMediaLinks.keys { connections[oid]?.probe() }
    }

    public func stop() {
        livenessTask?.cancel()
        livenessTask = nil
        pushNotifier?.stop()
        pushNotifier = nil
        listener?.cancel()
        listener = nil
        port = nil
        // Deterministically close in-flight sockets rather than relying on ARC
        // to drop the connections when the table clears. `cancel()` only
        // queues teardown on the connection's queue, and the table clear below
        // drops the last strong reference in this same turn — so the queued
        // teardown can lose the race and the socket would die without ever
        // sending a FIN, leaving a peer whose link was open looking online
        // indefinitely. Force-close the socket first; teardown still runs on
        // the queue and is harmless on an already-cancelled connection.
        for conn in connections.values { conn.forceClose() }
        for conn in connections.values { conn.cancel() }
        for link in deviceControlLinks.values { link.host.disconnect(link.id) }
        deviceControlLinks.removeAll()
        deviceMediaLinks.removeAll()
        advertisedPeerDevices = false
        let acknowledging = Set(acknowledged.keys.compactMap { connectionDevice[$0] })
        connections.removeAll()
        connectionDevice.removeAll()
        acknowledged.removeAll()
        onConnectionDeviceCountsChange?([:])
        for deviceId in acknowledging { onAcknowledgedCapabilitiesChange?(deviceId) }
    }

    /// The newest open socket of `deviceId` whose `helloAck` acknowledged
    /// `capability`, as a number that changes whenever a newer one takes
    /// over; nil when there is none.
    public func route(toDevice deviceId: String, acknowledging capability: String) -> Int? {
        acknowledged.filter { connectionDevice[$0.key] == deviceId && $0.value.capabilities.contains(capability) }
            .map(\.value.order).max()
    }

    /// Sends `message` on the socket `route(toDevice:acknowledging:)` names,
    /// past its gateway's filters, which cover what clients ask for and not
    /// what this server asks of them. False when there is no such socket.
    @discardableResult
    public func send(_ message: RemoteServerMessage, toDevice deviceId: String, acknowledging capability: String) -> Bool {
        guard let order = route(toDevice: deviceId, acknowledging: capability),
              let oid = acknowledged.first(where: { $0.value.order == order })?.key,
              let conn = connections[oid] else { return false }
        conn.sendMessage(message)
        return true
    }

    /// Registers (or, with nil, withdraws) this listener's Bonjour service.
    /// `NWListener.service` may be reassigned on a running listener, so this
    /// never restarts the server or touches live connections. Only Apple's
    /// Network framework advertises; elsewhere peers pair by address.
    public func advertise(_ advertisement: RemoteBonjourAdvertisement?) {
        guard self.advertisement != advertisement else { return }
        self.advertisement = advertisement
        setService(advertisement)
    }

    private func setService(_ advertisement: RemoteBonjourAdvertisement?) {
        #if canImport(Network)
        (listener as? NetworkTCPListener)?.listener.service = advertisement?.service
        #endif
    }

    /// Immediately closes every live connection authenticated as `deviceId`.
    /// `cancel()` tears the connection down, whose `onClose` clears both maps.
    public func disconnectDevice(_ deviceId: String) {
        for (oid, link) in deviceControlLinks where link.pairingID == deviceId {
            connections[oid]?.cancel()
            closeDeviceLink(oid)
        }
        for (oid, did) in connectionDevice where did == deviceId {
            connections[oid]?.cancel()
        }
    }

    /// Pushes a fresh `hello` to every authenticated connection after the
    /// advertised identity or peer list changes.
    public func broadcastHello() {
        for (oid, conn) in connections where connectionDevice[oid] != nil {
            conn.sendHello()
        }
    }

    public func connectedDeviceCounts() -> [String: Int] {
        var counts: [String: Int] = [:]
        for deviceId in connectionDevice.values {
            counts[deviceId, default: 0] += 1
        }
        return counts
    }

    /// Replaces both policies at once. Unauthenticated sockets hold a copy
    /// of them; each gets the new pair in one step, so a request not yet
    /// checked meets neither stale nor half-updated rules. Not by closing
    /// them: the refresh can land just after a client wrote its request
    /// (Tailscale's status, read as the host starts, races the first
    /// `/pair`), and closing would drop that request.
    public func updatePolicies(access: RemoteAccessPolicy, origin: RemoteOriginPolicy) {
        accessPolicy = access
        originPolicy = origin
        for (oid, conn) in connections where connectionDevice[oid] == nil {
            conn.updatePolicies(access: access, origin: origin)
        }
    }

    /// Open sockets that have not authenticated as a device.
    @_spi(Testing) public var unauthenticatedConnectionCount: Int {
        connections.keys.filter { connectionDevice[$0] == nil }.count
    }

    /// Call after a serving-policy change, including Serve starting or
    /// exiting. Device access and capability advertisement share that gate.
    public func refreshPeerDevicePolicy() {
        let activeHost = servingDeviceHost
        presenter?.peerDeviceHost?.refresh()
        for (oid, link) in deviceControlLinks where link.host !== activeHost { closeDeviceLink(oid) }
        let available = activeHost != nil
        guard advertisedPeerDevices != available else { return }
        advertisedPeerDevices = available
        broadcastHello()
    }

    private var servingDeviceHost: PeerDeviceHost? {
        guard loopbackOnly, port != nil, let host = presenter?.peerDeviceHost, host.isEligible else { return nil }
        return host
    }

    private func nativeFullDevice(_ pairingID: String) -> RemoteDevice? {
        guard let device = pairing.device(id: pairingID), device.scope == .full,
              device.kind == .alasInstance || device.kind == .phone else { return nil }
        return device
    }

    private func hello(identity: RemoteServerIdentity, pairingID: String) -> RemoteServerMessage {
        let current = pairing.device(id: pairingID)?.scope == .full ? identity : identity.withoutPeers
        let capability = PeerDeviceCapability.v1
        let advertise = servingDeviceHost != nil && nativeFullDevice(pairingID) != nil
        if !current.consoleCapabilities.contains(capability), current.hostCapabilities.contains(capability) == advertise {
            return .hello(current)
        }
        var capabilities = current.hostCapabilities.filter { $0 != capability }
        if advertise { capabilities.append(capability) }
        return .hello(RemoteServerIdentity(
            serverId: current.serverId, name: current.name, peers: current.peers,
            consoleCapabilities: current.consoleCapabilities.filter { $0 != capability },
            hostCapabilities: capabilities, hostVersion: current.hostVersion
        ))
    }

    private func handleDeviceRequest(_ request: PeerDeviceRequest, channel: RemoteGatewayChannel) -> Bool {
        guard let socket = channel.socket, connections[socket]?.isOpenForDeviceMedia == true,
              let host = servingDeviceHost, let device = nativeFullDevice(channel.deviceId) else { return false }
        if let link = deviceControlLinks[socket], link.host === host {
            host.handle(request, from: link.id)
        } else {
            closeDeviceLink(socket)
            let id = host.connect(pairingID: device.id, name: device.name, authorized: { [weak self, weak host] in
                guard let self, let host else { return false }
                return self.connections[socket]?.isOpenForDeviceMedia == true &&
                    self.servingDeviceHost === host && self.nativeFullDevice(device.id) != nil
            }, send: { channel.send(.device($0)) })
            deviceControlLinks[socket] = DeviceControlLink(pairingID: device.id, host: host, id: id)
            host.handle(request, from: id)
        }
        return true
    }

    private func closeDeviceLink(_ socket: ObjectIdentifier) {
        if let link = deviceControlLinks.removeValue(forKey: socket) {
            link.host.disconnect(link.id)
        }
    }

    private func claimDeviceMedia(_ ticket: String, connection: RemoteConnection) -> (@MainActor () -> Void)? {
        let socket = ObjectIdentifier(connection)
        guard connection.isOpenForDeviceMedia, connections[socket] === connection, let host = servingDeviceHost,
              let session = host.claimMedia(ticket: ticket, write: { [weak connection] data, onWritten in
                  connection?.sendDeviceMedia(data, onWritten: onWritten)
              }, close: { [weak connection] in connection?.cancel() },
              isOpen: { [weak connection] in connection?.isOpenForDeviceMedia == true }) else { return nil }
        deviceMediaLinks[socket] = DeviceMediaLink(host: host, session: session)
        return { [weak self, weak connection] in
            guard let self, let connection, self.connections[socket] === connection,
                  let link = self.deviceMediaLinks[socket], self.servingDeviceHost === link.host else {
                connection?.cancel()
                return
            }
            link.host.startMedia(link.session)
        }
    }

    private func accept(_ stream: any TCPStream) {
        guard connections.count < maxConnections else { stream.cancel()
        return }
        let identity = self.identityProvider
        let signer = self.signer
        // Both the pairing reply and the socket sign with the SAME key over
        // the SAME `serverId` this server advertises, so a record pinned at
        // pairing time is exactly what later sockets are checked against.
        let proveIdentity: @MainActor (String) -> RemoteIdentityProof? = { challenge in
            signer?.proof(challenge: challenge, serverId: identity().serverId)
        }
        var configured = RemoteHTTPResponder(
            pairing: pairing,
            assets: assets,
            diagnostics: { self.diagnosticsSnapshot() },
            originPolicy: originPolicy
        )
        configured.onPeerPaired = { [weak self] request in self?.onPeerPaired?(request) }
        configured.pairsBackWithPeers = pairsBackWithPeers
        configured.admitsInboundOnlyPeer = admitsInboundOnlyPeer
        configured.onApprovedPeerPaired = { [weak self] request, requestID, localPeer in
            self?.onApprovedPeerPaired?(request, requestID, localPeer)
        }
        configured.identity = identity
        configured.identityProof = proveIdentity
        if let coordinator = approvalCoordinator {
            configured.approval = RemotePairingApprovalHTTP(coordinator: coordinator, enabled: { [weak self] in
                self?.pairingApprovalVersion == 1
            })
        }
        let responder = configured   // immutable copy so the escaping closure below captures a value
        let host = self.host
        let federation = self.federation
        let conn = RemoteConnection(
            conn: stream,
            queue: queue,
            // The CORS echo follows the current origin policy, as the
            // connection's own gate does.
            responder: { [weak self] req, body in
                var current = responder
                current.originPolicy = self?.originPolicy ?? responder.originPolicy
                return current.response(for: req, body: body)
            },
            authorize: { [weak self] token in
                guard let self, let id = self.pairing.validate(token: token) else { return nil }
                self.pairing.touch(deviceId: id)
                return id
            },
            accessPolicy: accessPolicy,
            originPolicy: originPolicy,
            makeGateway: { [weak self] channel in
                // Consoles are served only to paired Alas instances and the
                // native phone app, never to browsers; revocation closes the
                // socket and the link.
                let device = self?.pairing.devices.first { $0.id == channel.deviceId }
                // A device gone since it authenticated is about to be cut
                // off; until then it gets the least.
                let scope = device?.scope ?? .delegation
                let consoleLink = device.flatMap { device -> PeerConsoleLink? in
                    guard device.kind == .alasInstance || device.kind == .phone, device.scope == .full else { return nil }
                    let sendTracked = channel.sendTracked
                    return PeerConsoleLink(peerName: device.name) { event, onWritten in
                        sendTracked(.console(event), onWritten)
                    }
                }
                let gateway = RemoteSessionGateway(
                    host: host, federation: federation, consoleLink: consoleLink,
                    caller: .remotePeer(deviceID: channel.deviceId), scope: scope, sendTracked: channel.sendTracked,
                    send: channel.send)
                if scope == .full { gateway.presenter = self?.presenter }
                if device?.kind == .alasInstance || device?.kind == .phone {
                    gateway.receivePeerDeviceRequest = { [weak self] request in
                        self?.handleDeviceRequest(request, channel: channel) ?? false
                    }
                }
                gateway.delegationPairing = self?.pairing
                let deviceId = channel.deviceId
                let socket = channel.socket
                gateway.onPeerHostReply = { [weak self] reply in
                    guard let self else { return }
                    onPeerHostReply?(deviceId, socket.flatMap { self.acknowledged[$0]?.order }, reply)
                }
                self?.configureGateway?(gateway)
                return gateway
            },
            // A delegation-only device is not told which other Macs are
            // paired here.
            makeHello: { [weak self] deviceId in
                self?.hello(identity: identity(), pairingID: deviceId)
            },
            identityProof: proveIdentity,
            onAuthenticated: { [weak self] conn, did in
                Task { @MainActor in
                    guard let self, self.connections[ObjectIdentifier(conn)] === conn, conn.isOpenForDeviceMedia else { return }
                    self.connectionDevice[ObjectIdentifier(conn)] = did
                    self.onConnectionDeviceCountsChange?(self.connectedDeviceCounts())
                    // `authorize` can pass while the device is still valid,
                    // but this registration lands via a LATER queue →
                    // MainActor hop. If the device is revoked in that window
                    // (the user clicked Forget), `disconnectDevice` cannot
                    // find this socket yet — it isn't in `connectionDevice` —
                    // and misses it. Recheck now that registration has
                    // actually happened, closing the gap regardless of how
                    // the hops interleaved.
                    if !self.pairing.devices.contains(where: { $0.id == did }) {
                        conn.cancel()
                    }
                }
            },
            onCapabilitiesAcknowledged: { [weak self] conn, capabilities in
                let oid = ObjectIdentifier(conn)
                guard let self, self.connections[oid] != nil, let deviceId = self.connectionDevice[oid] else { return }
                self.acknowledgements += 1
                self.acknowledged[oid] = (self.acknowledgements, Set(capabilities))
                self.onAcknowledgedCapabilitiesChange?(deviceId)
            },
            onClose: { [weak self] conn in
                Task { @MainActor in
                    guard let self else { return }
                    let oid = ObjectIdentifier(conn)
                    guard self.connections[oid] === conn else { return }
                    self.closeDeviceLink(oid)
                    if let media = self.deviceMediaLinks.removeValue(forKey: oid) { media.host.mediaClosed(media.session) }
                    let deviceId = self.connectionDevice[oid]
                    self.connections[oid] = nil
                    self.connectionDevice[oid] = nil
                    let hadAcknowledged = self.acknowledged.removeValue(forKey: oid) != nil
                    self.onConnectionDeviceCountsChange?(self.connectedDeviceCounts())
                    if hadAcknowledged, let deviceId { self.onAcknowledgedCapabilitiesChange?(deviceId) }
                }
            })
        conn.authorizeDeviceMedia = { [weak self] ticket, connection in
            self?.claimDeviceMedia(ticket, connection: connection)
        }
        connections[ObjectIdentifier(conn)] = conn
        conn.start()
    }
}
