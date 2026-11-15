#if canImport(Network)
import Foundation
import Network

/// `TCPStream` over `NWConnection`.
final class NetworkTCPStream: TCPStream, @unchecked Sendable {
    private let connection: NWConnection

    init(connection: NWConnection) {
        self.connection = connection
    }

    convenience init(host: String, port: UInt16) {
        self.init(connection: NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? .any,
            using: .tcp
        ))
    }

    func start(queue: DispatchQueue, onState: @escaping @Sendable (TCPStreamState) -> Void) {
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: onState(.ready)
            case .waiting(let error), .failed(let error): onState(.failed(error))
            case .cancelled: onState(.cancelled)
            default: break
            }
        }
        connection.start(queue: queue)
    }

    func receive(maximumLength: Int, completion: @escaping @Sendable (Data?, Bool, Error?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { data, _, isComplete, error in
            completion(data, isComplete, error)
        }
    }

    func send(_ data: Data, completion: @escaping @Sendable (Error?) -> Void) {
        connection.send(content: data, completion: .contentProcessed { completion($0) })
    }

    func finish(completion: @escaping @Sendable () -> Void) {
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            completion()
        })
    }

    func cancel() {
        connection.cancel()
    }
}

/// `TCPListener` over `NWListener`. Also carries the Bonjour advertisement,
/// which only exists here.
final class NetworkTCPListener: TCPListener, @unchecked Sendable {
    let listener: NWListener

    init(host: TCPHost, port: UInt16) throws {
        let parameters = NWParameters.tcp
        // Without it `127.0.0.1` and `::1` can't share a port. A port another
        // listener holds, on that address or a wildcard, still fails.
        parameters.allowLocalEndpointReuse = true
        let endpointPort = NWEndpoint.Port(rawValue: port) ?? .any
        switch host {
        case .any:
            listener = try NWListener(using: parameters, on: endpointPort)
        case .loopbackV4:
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: endpointPort)
            listener = try NWListener(using: parameters)
        case .loopbackV6:
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv6(.loopback), port: endpointPort)
            listener = try NWListener(using: parameters)
        }
    }

    func start(
        queue: DispatchQueue,
        onState: @escaping @Sendable (TCPListenerState) -> Void,
        onConnection: @escaping @Sendable (any TCPStream) -> Void
    ) {
        let listener = listener
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                // A listener with no port bound is no use to anyone.
                guard let port = listener.port?.rawValue, port != 0 else { return onState(.failed(POSIXError(.EADDRNOTAVAIL))) }
                onState(.ready(port: port))
            case .waiting(let error), .failed(let error): onState(.failed(error))
            case .cancelled: onState(.cancelled)
            default: break
            }
        }
        listener.newConnectionHandler = { onConnection(NetworkTCPStream(connection: $0)) }
        listener.start(queue: queue)
    }

    func cancel() {
        listener.cancel()
    }
}
#endif
