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
    private(set) var port: UInt16?
    /// Set once we've already retried on an OS-assigned port after a fixed-port
    /// bind failure, so we don't loop.
    private var didFallback = false
    /// Invoked on the main actor when the bound port changes — set when the
    /// listener becomes ready, nil when it fails/cancels. Lets observers (the
    /// Settings pane via AppState) react, since `port` itself isn't observable.
    var onPortChange: ((UInt16?) -> Void)?

    init(pairing: RemotePairingService, assets: RemoteWebAssets, provider: RemoteSessionsProvider) {
        self.pairing = pairing
        self.assets = assets
        self.provider = provider
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
    }

    /// Immediately closes every live connection authenticated as `deviceId`.
    /// `cancel()` tears the connection down, whose `onClose` clears both maps.
    func disconnectDevice(_ deviceId: String) {
        for (oid, did) in connectionDevice where did == deviceId {
            connections[oid]?.cancel()
        }
    }

    private func accept(_ nwConn: NWConnection) {
        guard connections.count < maxConnections else { nwConn.cancel()
        return }
        let responder = RemoteHTTPResponder(pairing: pairing, assets: assets)
        let provider = self.provider   // captured strongly; the server owns it for its lifetime
        let conn = RemoteConnection(
            conn: nwConn,
            queue: queue,
            responder: { req, body in responder.response(for: req, body: body) },
            authorize: { [weak self] token in
                guard let self, let id = self.pairing.validate(token: token) else { return nil }
                self.pairing.touch(deviceId: id)
                return id
            },
            makeGateway: { send in
                RemoteSessionGateway(provider: provider, send: send)
            },
            onAuthenticated: { [weak self] conn, did in
                Task { @MainActor in self?.connectionDevice[ObjectIdentifier(conn)] = did }
            },
            onClose: { [weak self] conn in
                Task { @MainActor in
                    let oid = ObjectIdentifier(conn)
                    self?.connections[oid] = nil
                    self?.connectionDevice[oid] = nil
                }
            })
        connections[ObjectIdentifier(conn)] = conn
        conn.start()
    }
}
