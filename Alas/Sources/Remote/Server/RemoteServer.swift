import Foundation
import Network

/// In-process HTTP + WebSocket server. Listens on a loopback TCP port, serves
/// the static web client and `POST /pair` over HTTP, and upgrades authorized
/// `/ws` requests to WebSocket, bridging each to a `RemoteSessionGateway`.
///
/// `@MainActor`-confined for its public surface (start/stop/port and the
/// connection table); `NWListener`/`NWConnection` callbacks arrive on the
/// serial `queue` and hop back to MainActor before touching state.
@MainActor
final class RemoteServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "io.alas.remote.server")
    private var connections: [ObjectIdentifier: RemoteConnection] = [:]
    /// Maps each authenticated connection to the device it logged in as, so a
    /// revoked device's live sockets can be closed. Populated via the
    /// connection's `onAuthenticated` hop (MainActor), never by reading
    /// queue-confined connection state cross-queue.
    private var connectionDevice: [ObjectIdentifier: String] = [:]
    /// Cap on simultaneous sockets. An unauthenticated peer can open a socket
    /// (auth only happens at WS upgrade), so bound the count defensively.
    private let maxConnections = 64

    let pairing: RemotePairingService
    private let assets: RemoteWebAssets
    private let provider: RemoteSessionsProvider
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
    private(set) var port: UInt16?
    /// Set once we've already retried on an OS-assigned port after a fixed-port
    /// bind failure, so we don't loop.
    private var didFallback = false
    /// Invoked on the main actor when the bound port changes — set when the
    /// listener becomes ready, nil when it fails/cancels. Lets observers (the
    /// Settings pane via AppState) react, since `port` itself isn't observable.
    var onPortChange: ((UInt16?) -> Void)?
    /// Invoked on the main actor whenever authenticated remote socket counts
    /// change. AppState snapshots this so Settings observes live disconnects.
    var onConnectionDeviceCountsChange: (([String: Int]) -> Void)?
    /// Fired on the main actor after another Alas instance paired here.
    var onPeerPaired: (@MainActor (RemotePeerPairingRequest) -> Void)?
    /// Bonjour advertisement applied to the live listener, and to any listener
    /// `start()` creates later (a port-fallback restart must keep advertising).
    /// Nil means not discoverable.
    private(set) var advertisement: RemoteBonjourAdvertisement?

    /// Callers with app state should pass a diagnostics closure; the default is
    /// a safe empty fallback for contexts that do not have app state available.
    init(
        pairing: RemotePairingService,
        assets: RemoteWebAssets,
        provider: RemoteSessionsProvider,
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
            RemoteServerIdentity(serverId: "", name: "Alas", hubEnabled: false)
        },
        signer: (any RemoteIdentitySigning)? = nil
    ) {
        self.pairing = pairing
        self.assets = assets
        self.provider = provider
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
    func start(port desired: UInt16 = 0) throws {
        stop()
        if desired != 0 { didFallback = false }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let endpointPort: NWEndpoint.Port = desired == 0 ? .any : (NWEndpoint.Port(rawValue: desired) ?? .any)
        let listener = try NWListener(using: params, on: endpointPort)
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                let assigned = listener.port?.rawValue
                Task { @MainActor in
                    // Ignore events from a superseded listener (e.g. the old one's
                    // late `.cancelled` after a port-fallback) so they can't wipe
                    // the live port/address.
                    guard let self, self.listener === listener else { return }
                    self.port = assigned
                    self.onPortChange?(assigned)
                }
            case .failed:
                Task { @MainActor in
                    guard let self, self.listener === listener else { return }
                    if desired != 0 && !self.didFallback {
                        self.didFallback = true
                        try? self.start(port: 0)   // preferred port taken — fall back to OS-assigned
                    } else {
                        self.port = nil
                        self.onPortChange?(nil)
                    }
                }
            case .cancelled:
                Task { @MainActor in
                    guard let self, self.listener === listener else { return }
                    self.port = nil
                    self.onPortChange?(nil)
                }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] nwConn in
            Task { @MainActor in self?.accept(nwConn) }
        }
        listener.service = advertisement?.service
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
        // Deterministically close in-flight sockets rather than relying on ARC
        // to drop the NWConnections when the table clears.
        for conn in connections.values { conn.cancel() }
        connections.removeAll()
        connectionDevice.removeAll()
        onConnectionDeviceCountsChange?([:])
    }

    /// Registers (or, with nil, withdraws) this listener's Bonjour service.
    /// `NWListener.service` may be reassigned on a running listener, so this
    /// never restarts the server or touches live connections.
    func advertise(_ advertisement: RemoteBonjourAdvertisement?) {
        guard self.advertisement != advertisement else { return }
        self.advertisement = advertisement
        listener?.service = advertisement?.service
    }

    /// Immediately closes every live connection authenticated as `deviceId`.
    /// `cancel()` tears the connection down, whose `onClose` clears both maps.
    func disconnectDevice(_ deviceId: String) {
        for (oid, did) in connectionDevice where did == deviceId {
            connections[oid]?.cancel()
        }
    }

    /// Closes every live connection authenticated as an `.alasInstance`
    /// device, leaving browser/phone devices untouched. Called when
    /// federation is turned off while remote control stays on, so an
    /// already-open peer socket does not outlive the flag that gated it: the
    /// `authorize` closure in `accept(_:)` only stops a NEW upgrade from a
    /// peer device, it does nothing to one that opened before the toggle
    /// flipped.
    func disconnectAllPeerDevices() {
        for device in pairing.devices where device.kind == .alasInstance {
            disconnectDevice(device.id)
        }
    }

    /// Pushes a fresh `hello` to every authenticated connection — e.g. after
    /// the "Remote hub" toggle changes, so already-connected browsers pick up
    /// the new `hubEnabled` without waiting for a reconnect.
    func broadcastHello() {
        for (oid, conn) in connections where connectionDevice[oid] != nil {
            conn.sendHello()
        }
    }

    func connectedDeviceCounts() -> [String: Int] {
        var counts: [String: Int] = [:]
        for deviceId in connectionDevice.values {
            counts[deviceId, default: 0] += 1
        }
        return counts
    }

    func updateAccessPolicy(_ policy: RemoteAccessPolicy) {
        accessPolicy = policy
        // Pre-refresh unauthenticated sockets hold their original policy copy;
        // close them so their first request cannot run under stale host rules.
        for (oid, conn) in connections where connectionDevice[oid] == nil {
            conn.cancel()
        }
    }

    func updateOriginPolicy(_ policy: RemoteOriginPolicy) {
        originPolicy = policy
        for (oid, conn) in connections where connectionDevice[oid] == nil {
            conn.cancel()
        }
    }

    private func accept(_ nwConn: NWConnection) {
        guard connections.count < maxConnections else { nwConn.cancel()
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
            diagnostics: { self.diagnosticsProvider(self.port) },
            originPolicy: originPolicy
        )
        configured.acceptsPeers = { identity().federationEnabled }
        configured.onPeerPaired = { [weak self] request in self?.onPeerPaired?(request) }
        configured.identity = identity
        configured.identityProof = proveIdentity
        let responder = configured   // immutable copy so the escaping closure below captures a value
        let provider = self.provider   // captured strongly; the server owns it for its lifetime
        let conn = RemoteConnection(
            conn: nwConn,
            queue: queue,
            responder: { req, body in responder.response(for: req, body: body) },
            authorize: { [weak self] token in
                guard let self, let id = self.pairing.validate(token: token) else { return nil }
                // A valid token alone is not enough for an Alas peer while
                // federation is off: without this, an already-issued
                // `.alasInstance` token keeps working across the toggle, and
                // `disconnectAllPeerDevices()` at the moment of disabling
                // would only be a one-time sweep a reconnect could undo.
                // Browser/phone devices are unaffected by the flag either way.
                if !identity().federationEnabled,
                   self.pairing.devices.first(where: { $0.id == id })?.kind == .alasInstance {
                    return nil
                }
                self.pairing.touch(deviceId: id)
                return id
            },
            accessPolicy: accessPolicy,
            originPolicy: originPolicy,
            makeGateway: { send in
                RemoteSessionGateway(provider: provider, send: send)
            },
            makeHello: { RemoteServerMessage.hello(identity()) },
            identityProof: proveIdentity,
            onAuthenticated: { [weak self] conn, did in
                Task { @MainActor in
                    guard let self else { return }
                    self.connectionDevice[ObjectIdentifier(conn)] = did
                    self.onConnectionDeviceCountsChange?(self.connectedDeviceCounts())
                    // `authorize` can pass while the device is still valid
                    // and federation is on, but this registration lands via
                    // a LATER queue → MainActor hop. If the device is
                    // revoked in that window (the user clicked Forget),
                    // `disconnectDevice` cannot find this socket yet — it
                    // isn't in `connectionDevice` — and misses it. If
                    // federation turns off in that same window for an
                    // `.alasInstance` device, `disconnectAllPeerDevices()`
                    // misses it for the same reason. Recheck both now that
                    // registration has actually happened, closing the gap
                    // regardless of how the hops interleaved.
                    let device = self.pairing.devices.first(where: { $0.id == did })
                    if device == nil || (!identity().federationEnabled && device?.kind == .alasInstance) {
                        conn.cancel()
                    }
                }
            },
            onClose: { [weak self] conn in
                Task { @MainActor in
                    guard let self else { return }
                    let oid = ObjectIdentifier(conn)
                    self.connections[oid] = nil
                    self.connectionDevice[oid] = nil
                    self.onConnectionDeviceCountsChange?(self.connectedDeviceCounts())
                }
            })
        connections[ObjectIdentifier(conn)] = conn
        conn.start()
    }
}
