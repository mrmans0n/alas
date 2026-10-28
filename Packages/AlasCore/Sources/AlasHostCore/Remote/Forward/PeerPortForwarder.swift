import Foundation
import Network
import Synchronization

/// The Mac end of a run's forward: listens on `127.0.0.1` and relays each
/// accepted connection to the host as one `PeerPortForwardRequest` stream.
/// The mirror of `PeerPortForwardHost`, with the same flow control.
///
/// `@unchecked Sendable` because all mutable state, and every `NWListener`
/// and `NWConnection` callback, is confined to `queue`.
public final class PeerPortForwarder: @unchecked Sendable {
    public typealias Send = @Sendable (PeerPortForwardRequest) -> Void

    public enum StartError: Error, Equatable {
        case invalidEndpoint
        case stopped
    }

    private final class Stream: @unchecked Sendable {
        let connection: NWConnection
        var opened = false
        var reading = false
        /// Bytes the host still lets the Mac send.
        var sendWindow: Int
        /// Bytes from the host not yet written to the local socket.
        var unwritten = 0

        init(connection: NWConnection, window: Int) {
            self.connection = connection
            sendWindow = window
        }
    }

    public let runID: String
    public let endpoint: URL
    private let limits: PeerPortForwardLimits
    private let send: Send
    private let queue = DispatchQueue(label: "io.nlopez.alas.peer-port-forwarder")
    private var listener: NWListener?
    private var stopped = false
    private var streams: [UUID: Stream] = [:]

    /// `send` is called on an internal serial queue, in order.
    public init(runID: String, endpoint: URL, limits: PeerPortForwardLimits = PeerPortForwardLimits(), send: @escaping Send) {
        self.runID = runID
        self.endpoint = endpoint
        self.limits = limits
        self.send = send
    }

    deinit {
        listener?.cancel()
        for stream in streams.values {
            stream.connection.cancel()
        }
    }

    /// Listens on `127.0.0.1` at the endpoint's port, or on an ephemeral port
    /// when that one is busy, and returns the endpoint with only the port
    /// replaced by the one bound.
    public func start() async throws -> URL {
        guard let port = endpoint.port.flatMap(UInt16.init(exactly:)).flatMap(NWEndpoint.Port.init(rawValue:)),
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        else { throw StartError.invalidEndpoint }
        let bound: UInt16
        do {
            bound = try await listen(on: port)
        } catch StartError.stopped {
            throw StartError.stopped
        } catch {
            bound = try await listen(on: .any)
        }
        components.port = Int(bound)
        guard let url = components.url else { throw StartError.invalidEndpoint }
        return url
    }

    public func receive(_ event: PeerPortForwardEvent) {
        queue.async { self.handle(event) }
    }

    /// Closes the listener and every stream.
    public func stop() {
        queue.async { self.shutDown() }
    }

    private func listen(on port: NWEndpoint.Port) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        let listener = try NWListener(using: parameters)
        return try await withCheckedThrowingContinuation { continuation in
            let pending = Mutex<CheckedContinuation<UInt16, Error>?>(continuation)
            let finish: @Sendable (Result<UInt16, Error>) -> Void = { result in pending.withLock { $0.take() }?.resume(with: result) }
            queue.async {
                guard !self.stopped else { return finish(.failure(StartError.stopped)) }
                // Held before it's ready so `stop()` cancels a listener still starting.
                self.listener = listener
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        finish(.success(listener.port?.rawValue ?? 0))
                    case .waiting(let error), .failed(let error):
                        if self?.listener === listener { self?.listener = nil }
                        listener.cancel()
                        finish(.failure(error))
                    case .cancelled:
                        finish(.failure(StartError.stopped))
                    default:
                        break
                    }
                }
                listener.start(queue: self.queue)
            }
        }
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped else { return connection.cancel() }
        let id = UUID()
        let stream = Stream(connection: connection, window: limits.window)
        streams[id] = stream
        connection.stateUpdateHandler = { [weak self, weak stream] state in
            guard let self, let stream, self.streams[id] === stream else { return }
            switch state {
            case .waiting, .failed, .cancelled:
                close(id)
            default:
                break
            }
        }
        connection.start(queue: queue)
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
            streams.removeValue(forKey: id)?.connection.cancel()
            if message == PeerPortForwardHost.notRunningMessage { shutDown() }
        case .data(let id, let bytes):
            write(bytes, to: id)
        case .credit(let id, let bytes):
            guard let stream = streams[id], bytes > 0 else { return }
            stream.sendWindow = min(limits.window, stream.sendWindow + bytes)
            read(id, stream)
        case .closed(let id):
            // Flush what the host sent, then end the local socket.
            guard let stream = streams.removeValue(forKey: id) else { return }
            let connection = stream.connection
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    /// Reads the local socket while the host's window has room.
    private func read(_ id: UUID, _ stream: Stream) {
        guard stream.opened, !stream.reading, stream.sendWindow > 0 else { return }
        stream.reading = true
        stream.connection.receive(minimumIncompleteLength: 1, maximumLength: min(limits.maxChunk, stream.sendWindow)) {
            [weak self, weak stream] data, _, isComplete, error in
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
        stream.connection.send(content: bytes, completion: .contentProcessed { [weak self, weak stream] error in
            guard let self, let stream, self.streams[id] === stream else { return }
            guard error == nil else { return close(id) }
            stream.unwritten -= bytes.count
            send(.credit(stream: id, bytes: bytes.count))
        })
    }

    /// Ends a stream from this side. The host doesn't reply.
    private func close(_ id: UUID) {
        guard let stream = streams.removeValue(forKey: id) else { return }
        stream.connection.cancel()
        send(.close(stream: id))
    }

    private func shutDown() {
        stopped = true
        listener?.cancel()
        listener = nil
        for id in streams.keys {
            close(id)
        }
    }
}
