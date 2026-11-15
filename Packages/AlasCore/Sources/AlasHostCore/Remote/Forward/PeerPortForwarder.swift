import AlasRemoteKit
import Foundation
import AlasFeatures
import Synchronization

/// The Mac end of a run's forward: listens on `127.0.0.1` and relays each
/// accepted connection to the host as one `PeerPortForwardRequest` stream.
/// The mirror of `PeerPortForwardHost`, with the same flow control.
///
/// `@unchecked Sendable` because all mutable state, and every listener and
/// connection callback, is confined to `queue`.
public final class PeerPortForwarder: @unchecked Sendable {
    public typealias Send = @Sendable (PeerPortForwardRequest) -> Void

    public enum StartError: Error, Equatable {
        case invalidEndpoint
        case stopped
    }

    private final class Stream: @unchecked Sendable {
        let connection: any TCPStream
        var opened = false
        var reading = false
        /// Bytes the host still lets the Mac send.
        var sendWindow: Int
        /// Bytes from the host not yet written to the local socket.
        var unwritten = 0

        init(connection: any TCPStream, window: Int) {
            self.connection = connection
            sendWindow = window
        }
    }

    public let runID: String
    public let endpoint: URL
    private let limits: PeerPortForwardLimits
    private let send: Send
    private let onRefused: @Sendable (_ message: String) -> Void
    private let queue = DispatchQueue(label: "io.nlopez.alas.peer-port-forwarder")
    private var listeners: [any TCPListener] = []
    private var stopped = false
    private var streams: [UUID: Stream] = [:]
    /// Local sockets the host closed, still writing out what it sent.
    private var draining: [UUID: any TCPStream] = [:]

    /// `send` and `onRefused`, given the host's message for a refused
    /// stream this forwarder opened, are called on an internal serial queue,
    /// in order.
    public init(
        runID: String, endpoint: URL, limits: PeerPortForwardLimits = PeerPortForwardLimits(),
        onRefused: @escaping @Sendable (_ message: String) -> Void = { _ in }, send: @escaping Send
    ) {
        self.runID = runID
        self.endpoint = endpoint
        self.limits = limits
        self.onRefused = onRefused
        self.send = send
    }

    deinit {
        for listener in listeners {
            listener.cancel()
        }
        for stream in streams.values {
            stream.connection.cancel()
        }
        for connection in draining.values {
            connection.cancel()
        }
    }

    /// Listens on the endpoint's loopback at its port, or on an ephemeral
    /// port when that one is busy, and returns the endpoint with only the
    /// port replaced by the one bound. `[::1]` listens on IPv6, `localhost` on
    /// both `127.0.0.1` and `::1` so a browser trying either lands here, and
    /// anything else on `127.0.0.1`.
    public func start() async throws -> URL {
        guard let port = endpoint.runEndpointPort.flatMap(UInt16.init(exactly:)),
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        else { throw StartError.invalidEndpoint }
        // Port 0 lets the system choose.
        let attempts: [([TCPHost], UInt16)]
        switch endpoint.host.map(PeerPortForwardEndpoint.dialHost) {
        case "::1":
            attempts = [([.loopbackV6], port), ([.loopbackV6], 0)]
        case "localhost":
            // An ephemeral IPv4 port may be taken on IPv6, so try a few, then
            // settle for IPv4 alone.
            let both: [TCPHost] = [.loopbackV4, .loopbackV6]
            attempts = [(both, port)] + Array(repeating: (both, 0), count: 3) + [([.loopbackV4], 0)]
        default:
            attempts = [([.loopbackV4], port), ([.loopbackV4], 0)]
        }
        var lastError: Error = StartError.invalidEndpoint
        for (addresses, port) in attempts {
            do {
                let bound = try await Int(listen(on: addresses, port: port))
                // An implicit 80 or 443 that was free stays implicit.
                components.port = endpoint.port == nil && bound == endpoint.runEndpointPort ? nil : bound
                guard let url = components.url else { throw StartError.invalidEndpoint }
                return url
            } catch StartError.stopped {
                throw StartError.stopped
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    public func receive(_ event: PeerPortForwardEvent) {
        queue.async { self.handle(event) }
    }

    /// Closes the listener and every stream.
    public func stop() {
        queue.async { self.shutDown() }
    }

    /// Binds every address at one port: `port`, or the first address's
    /// ephemeral port. Binds none if any fails.
    private func listen(on addresses: [TCPHost], port: UInt16) async throws -> UInt16 {
        var bound: [any TCPListener] = []
        var port = port
        do {
            for address in addresses {
                let (listener, boundPort) = try await listen(on: address, port: port)
                bound.append(listener)
                port = boundPort
            }
            return port
        } catch {
            let bound = bound
            queue.async {
                for listener in bound {
                    listener.cancel()
                }
                self.listeners.removeAll { listener in bound.contains { $0 === listener } }
            }
            throw error
        }
    }

    private func listen(on address: TCPHost, port: UInt16) async throws -> (any TCPListener, UInt16) {
        let listener = try TCP.listener(host: address, port: port)
        return try await withCheckedThrowingContinuation { continuation in
            let pending = Mutex<CheckedContinuation<(any TCPListener, UInt16), Error>?>(continuation)
            let finish: @Sendable (Result<(any TCPListener, UInt16), Error>) -> Void = { result in
                pending.withLock { $0.take() }?.resume(with: result)
            }
            queue.async {
                guard !self.stopped else { return finish(.failure(StartError.stopped)) }
                // Held before it's ready so `stop()` cancels a listener still starting.
                self.listeners.append(listener)
                listener.start(queue: self.queue, onState: { [weak self] state in
                    switch state {
                    case .ready(let port):
                        finish(.success((listener, port)))
                    case .failed(let error):
                        self?.listeners.removeAll { $0 === listener }
                        listener.cancel()
                        finish(.failure(error))
                    case .cancelled:
                        finish(.failure(StartError.stopped))
                    }
                }, onConnection: { [weak self] connection in self?.accept(connection) })
            }
        }
    }

    private func accept(_ connection: any TCPStream) {
        guard !stopped else { return connection.cancel() }
        let id = UUID()
        let stream = Stream(connection: connection, window: limits.window)
        streams[id] = stream
        connection.start(queue: queue) { [weak self, weak stream] state in
            guard let self, let stream, self.streams[id] === stream else { return }
            switch state {
            case .failed, .cancelled:
                close(id)
            case .ready:
                break
            }
        }
        // Nothing is read from the socket before `opened`.
        send(.open(stream: id, runID: runID))
    }

    private func handle(_ event: PeerPortForwardEvent) {
        switch event {
        case .opened(let id):
            guard let stream = streams[id], !stream.opened else { return }
            stream.opened = true
            read(id, stream)
        case .refused(let id, let message):
            // Another forward's stream on the same peer is none of ours.
            guard let stream = streams.removeValue(forKey: id) else { return }
            stream.connection.cancel()
            onRefused(message)
            // A backstop: the app stops the forward itself when the run
            // changes or the host disconnects.
            if message == PeerPortForwardHost.notRunningMessage { shutDown() }
        case .data(let id, let bytes):
            write(bytes, to: id)
        case .credit(let id, let bytes):
            guard let stream = streams[id], bytes > 0 else { return }
            stream.sendWindow += min(bytes, limits.window - stream.sendWindow)
            read(id, stream)
        case .closed(let id):
            // Flush what the host sent, then end the local socket.
            guard let stream = streams.removeValue(forKey: id) else { return }
            let connection = stream.connection
            draining[id] = connection
            connection.finish { [weak self] in
                self?.draining[id] = nil
                connection.cancel()
            }
        }
    }

    /// Reads the local socket while the host's window has room.
    private func read(_ id: UUID, _ stream: Stream) {
        guard stream.opened, !stream.reading, stream.sendWindow > 0 else { return }
        stream.reading = true
        stream.connection.receive(maximumLength: min(limits.maxChunk, stream.sendWindow)) {
            [weak self, weak stream] data, isComplete, error in
            guard let self, let stream, self.streams[id] === stream else { return }
            stream.reading = false
            if let data, !data.isEmpty {
                stream.sendWindow -= data.count
                send(.data(stream: id, bytes: data))
            }
            if isComplete || error != nil { return close(id) }
            read(id, stream)
        }
    }

    /// Writes host bytes to the local socket and returns their credit once
    /// written. A host that sends beyond its window loses the stream.
    private func write(_ bytes: Data, to id: UUID) {
        // Unknown ids are streams this side already closed.
        guard let stream = streams[id] else { return }
        guard stream.opened, bytes.count <= limits.maxChunk, stream.unwritten + bytes.count <= limits.window else {
            return close(id)
        }
        stream.unwritten += bytes.count
        stream.connection.send(bytes) { [weak self, weak stream] error in
            guard let self, let stream, self.streams[id] === stream else { return }
            guard error == nil else { return close(id) }
            stream.unwritten -= bytes.count
            send(.credit(stream: id, bytes: bytes.count))
        }
    }

    /// Ends a stream from this side. The host doesn't reply.
    private func close(_ id: UUID) {
        guard let stream = streams.removeValue(forKey: id) else { return }
        stream.connection.cancel()
        send(.close(stream: id))
    }

    private func shutDown() {
        stopped = true
        for listener in listeners {
            listener.cancel()
        }
        listeners = []
        for id in streams.keys {
            close(id)
        }
        for connection in draining.values {
            connection.cancel()
        }
        draining = [:]
    }
}
