import Foundation
import Network

/// Serves `PeerPortForwardRequest`s: each stream is a TCP connection from
/// the host to a running run's loopback port, relayed to the Mac that opened
/// it. Streams belong to the peer connection that opened them and end with
/// it.
///
/// `@unchecked Sendable` because all mutable state, and every `NWConnection`
/// callback, is confined to `queue`.
public final class PeerPortForwardHost: @unchecked Sendable {
    public typealias Send = @Sendable (_ connectionID: UUID, _ event: PeerPortForwardEvent) -> Void

    public static let notRunningMessage = "This run is no longer running on the host."
    public static let limitReachedMessage = "Too many forwarded connections are open to this host."
    public static let protocolErrorMessage = "The forwarded connection broke the forwarding protocol."

    private struct Key: Hashable {
        let connection: UUID
        let stream: UUID
    }

    private final class Stream: @unchecked Sendable {
        let runID: String
        var connection: NWConnection?
        var opened = false
        var reading = false
        /// Bytes the Mac still lets the host send.
        var sendWindow: Int
        /// Bytes from the Mac not yet written to the run's socket.
        var unwritten = 0

        init(runID: String, window: Int) {
            self.runID = runID
            sendWindow = window
        }
    }

    private let limits: PeerPortForwardLimits
    private let resolve: @Sendable (_ runID: String) async -> (host: String, port: Int)?
    private let send: Send
    private let queue = DispatchQueue(label: "io.nlopez.alas.peer-port-forward")
    private var streams: [Key: Stream] = [:]
    /// Run sockets the Mac closed, still writing out what it sent.
    private var draining: [Key: NWConnection] = [:]

    /// `resolve` returns the endpoint host and port of `runID` only while it
    /// is the current active `.running` run of its worktree with a loopback
    /// endpoint. The host is dialled as declared, so `localhost` tries both
    /// `::1` and `127.0.0.1`; anything `PeerPortForwardEndpoint` doesn't
    /// accept as loopback is refused. `send` is called on an internal serial queue, in order.
    public init(
        limits: PeerPortForwardLimits = PeerPortForwardLimits(),
        resolve: @escaping @Sendable (_ runID: String) async -> (host: String, port: Int)?,
        send: @escaping Send
    ) {
        self.limits = limits
        self.resolve = resolve
        self.send = send
    }

    deinit {
        for stream in streams.values {
            stream.connection?.cancel()
        }
        for connection in draining.values {
            connection.cancel()
        }
    }

    /// Requests from one connection must be passed in the order they arrived.
    public func receive(_ request: PeerPortForwardRequest, from connectionID: UUID) {
        queue.async { self.handle(request, from: connectionID) }
    }

    /// Drops every stream the connection opened, without telling it.
    public func connectionClosed(_ connectionID: UUID) {
        queue.async {
            for key in self.streams.keys where key.connection == connectionID {
                self.drop(key)
            }
            for (key, connection) in self.draining where key.connection == connectionID {
                self.draining[key] = nil
                connection.cancel()
            }
        }
    }

    /// Closes every stream to the run.
    public func runEnded(_ runID: String) {
        queue.async {
            for (key, stream) in self.streams where stream.runID == runID {
                self.close(key, refusal: Self.notRunningMessage)
            }
        }
    }

    private func handle(_ request: PeerPortForwardRequest, from connectionID: UUID) {
        switch request {
        case .open(let id, let runID):
            open(Key(connection: connectionID, stream: id), runID: runID)
        case .data(let id, let bytes):
            write(bytes, to: Key(connection: connectionID, stream: id))
        case .credit(let id, let bytes):
            let key = Key(connection: connectionID, stream: id)
            guard let stream = streams[key], bytes > 0 else { return }
            stream.sendWindow = min(limits.window, stream.sendWindow + bytes)
            read(key, stream)
        case .close(let id):
            finish(Key(connection: connectionID, stream: id))
        }
    }

    private func open(_ key: Key, runID: String) {
        // A reused stream id is a protocol error; the stream it names ends.
        guard streams[key] == nil else { return close(key) }
        let own = streams.keys.count { $0.connection == key.connection }
        let run = streams.values.count { $0.runID == runID }
        guard streams.count < limits.maxStreamsTotal, own < limits.maxStreamsPerConnection, run < limits.maxStreamsPerRun else {
            return send(key.connection, .refused(stream: key.stream, message: Self.limitReachedMessage))
        }
        let stream = Stream(runID: runID, window: limits.window)
        streams[key] = stream
        Task {
            let target = await resolve(runID)
            queue.async { self.dial(key, stream, target: target) }
        }
    }

    private func dial(_ key: Key, _ stream: Stream, target: (host: String, port: Int)?) {
        // Closed while resolving.
        guard streams[key] === stream else { return }
        guard let target, PeerPortForwardEndpoint.isLoopbackHost(target.host), target.port > 0,
              let nwPort = UInt16(exactly: target.port).flatMap(NWEndpoint.Port.init(rawValue:))
        else {
            streams[key] = nil
            return send(key.connection, .refused(stream: key.stream, message: Self.notRunningMessage))
        }
        let port = target.port
        let host = NWEndpoint.Host(PeerPortForwardEndpoint.dialHost(target.host))
        let connection = NWConnection(host: host, port: nwPort, using: .tcp)
        stream.connection = connection
        connection.stateUpdateHandler = { [weak self, weak stream] state in
            guard let self, let stream, self.streams[key] === stream else { return }
            switch state {
            case .ready where !stream.opened:
                stream.opened = true
                send(key.connection, .opened(stream: key.stream))
                read(key, stream)
            case .waiting, .failed:
                guard stream.opened else {
                    drop(key)
                    return send(key.connection, .refused(stream: key.stream, message: "The run isn't accepting connections on port \(port)."))
                }
                close(key)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    /// Reads the run's socket while the Mac's window has room.
    private func read(_ key: Key, _ stream: Stream) {
        guard stream.opened, !stream.reading, stream.sendWindow > 0, let connection = stream.connection else { return }
        stream.reading = true
        connection.receive(minimumIncompleteLength: 1, maximumLength: min(limits.maxChunk, stream.sendWindow)) {
            [weak self, weak stream] data, _, isComplete, error in
            guard let self, let stream, self.streams[key] === stream else { return }
            stream.reading = false
            if let data, !data.isEmpty {
                stream.sendWindow -= data.count
                send(key.connection, .data(stream: key.stream, bytes: data))
            }
            if isComplete || error != nil { return close(key) }
            read(key, stream)
        }
    }

    /// Writes Mac bytes to the run's socket and returns their credit once
    /// written. A Mac that sends beyond its window loses the stream.
    private func write(_ bytes: Data, to key: Key) {
        guard let stream = streams[key] else { return }
        guard stream.opened, let connection = stream.connection, bytes.count <= limits.maxChunk,
              stream.unwritten + bytes.count <= limits.window
        else { return close(key) }
        stream.unwritten += bytes.count
        connection.send(content: bytes, completion: .contentProcessed { [weak self, weak stream] error in
            guard let self, let stream, self.streams[key] === stream else { return }
            guard error == nil else { return close(key) }
            stream.unwritten -= bytes.count
            send(key.connection, .credit(stream: key.stream, bytes: bytes.count))
        })
    }

    /// Ends a stream. One that never opened is refused, so the Mac doesn't
    /// wait for an `opened` that won't come.
    private func close(_ key: Key, refusal: String = protocolErrorMessage) {
        guard let stream = streams[key] else { return }
        drop(key)
        send(key.connection, stream.opened ? .closed(stream: key.stream) : .refused(stream: key.stream, message: refusal))
    }

    /// Ends a stream the Mac closed once what it sent is written.
    private func finish(_ key: Key) {
        guard let stream = streams[key] else { return }
        guard stream.opened, let connection = stream.connection else { return drop(key) }
        streams[key] = nil
        draining[key] = connection
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.draining[key] = nil
            connection.cancel()
        })
    }

    private func drop(_ key: Key) {
        streams.removeValue(forKey: key)?.connection?.cancel()
    }
}
