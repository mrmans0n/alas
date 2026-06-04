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

    let pairing: RemotePairingService
    private let assets: RemoteWebAssets
    private let provider: RemoteSessionsProvider
    private(set) var port: UInt16?

    init(pairing: RemotePairingService, assets: RemoteWebAssets, provider: RemoteSessionsProvider) {
        self.pairing = pairing
        self.assets = assets
        self.provider = provider
    }

    /// Starts listening on the given port (0 = OS-assigned). Throws if bind fails.
    func start(port desired: UInt16 = 0) throws {
        stop()
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let endpointPort: NWEndpoint.Port = desired == 0 ? .any : (NWEndpoint.Port(rawValue: desired) ?? .any)
        let listener = try NWListener(using: params, on: endpointPort)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                let assigned = listener.port?.rawValue
                Task { @MainActor in self?.port = assigned }
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
        connections.removeAll()
    }

    private func accept(_ nwConn: NWConnection) {
        let responder = RemoteHTTPResponder(pairing: pairing, assets: assets)
        let conn = RemoteConnection(
            conn: nwConn,
            queue: queue,
            responder: { req, body in responder.response(for: req, body: body) },
            authorize: { [weak self] token in
                guard let self, let id = self.pairing.validate(token: token) else { return false }
                self.pairing.touch(deviceId: id)
                return true
            },
            makeGateway: { [weak self] send in
                // Provider is only nil-checked here defensively; the server owns
                // it for its whole lifetime, so this closure is never reached
                // after deinit (connections are dropped in stop()).
                RemoteSessionGateway(provider: self!.provider, send: send)
            },
            onClose: { [weak self] conn in
                Task { @MainActor in self?.connections[ObjectIdentifier(conn)] = nil }
            })
        connections[ObjectIdentifier(conn)] = conn
        conn.start()
    }
}
