import Foundation
import Network
import Synchronization

/// The HTTP CONNECT proxy a remote-owned web preview's data store uses, so
/// every connection its page opens by name is checked against the address it
/// actually connects to. Each name is resolved once, every answer is vetted
/// by `WebPreviewEgressPolicy`, and the proxy connects to the answers in
/// order as numeric addresses, so DNS rebinding has nothing to act on.
///
/// One proxy per browser, on `127.0.0.1` at an ephemeral port. WebKit sends
/// IP literals for loopback and this Mac's own addresses around any proxy;
/// the preview's content rules block those.
///
/// Every CONNECT must carry `username` and this proxy's random `password` as
/// Basic proxy credentials, so other processes on this Mac cannot tunnel
/// through it. Without them it answers `407`, which WebKit retries with the
/// credentials its proxy configuration was given.
///
/// It holds at most `maxTunnels` connections, answering `503` beyond, and
/// resolves at most `maxResolutions` names at once; further CONNECTs wait
/// their turn, in order.
///
/// `@unchecked Sendable` because all mutable state, and every `NWListener`
/// and `NWConnection` callback, is confined to `queue`.
public final class WebPreviewEgressProxy: @unchecked Sendable {
    public typealias Resolve = @Sendable (String) async -> [String]?
    public typealias OnBlocked = @Sendable (_ host: String, _ port: Int, _ refusal: WebPreviewEgressPolicy.Refusal) -> Void

    public enum StartError: Error {
        case stopped
    }

    private final class Tunnel {
        let client: NWConnection
        var upstream: NWConnection?
        var established = false
        var head = Data()
        var timeout: DispatchWorkItem?

        init(client: NWConnection) { self.client = client }
    }

    static let headLimit = 8 * 1024
    public static let username = "alas-preview"
    public static let maxResolutions = 4
    private static let headTimeout: DispatchTimeInterval = .seconds(5)
    private let maxTunnels: Int
    /// How long a tunnel whose upstream ended waits for the client to close.
    private let linger: DispatchTimeInterval
    private let resolve: Resolve
    private let localAddresses: @Sendable () -> Set<Data>
    private let onBlocked: OnBlocked
    private let queue = DispatchQueue(label: "io.nlopez.alas.web-preview-egress-proxy")
    private var listener: NWListener?
    private var stopped = false
    private var tunnels: [ObjectIdentifier: Tunnel] = [:]
    private var resolving = 0
    /// CONNECTs waiting for a resolution slot, in arrival order.
    private var awaitingResolution: [() -> Void] = []
    private let listening = Mutex(false)
    /// The secret every CONNECT must present, random per proxy.
    public let password: String = {
        var generator = SystemRandomNumberGenerator()
        return (0..<4).map { _ in String(format: "%016llx", generator.next() as UInt64) }.joined()
    }()
    /// Where the proxy connects for a vetted address and port. Tests stand in
    /// other endpoints; set it before `start()`.
    var upstreamEndpoint: (Data, Int) -> NWEndpoint? = { address, port in
        let host: NWEndpoint.Host? = address.count == 4
            ? IPv4Address(address).map { .ipv4($0) } : IPv6Address(address).map { .ipv6($0) }
        guard let host, let port = NWEndpoint.Port(rawValue: UInt16(port)) else { return nil }
        return .hostPort(host: host, port: port)
    }

    /// `localAddresses` is read for every CONNECT. `onBlocked` is called on
    /// an internal queue.
    public init(
        resolve: @escaping Resolve, localAddresses: @escaping @Sendable () -> Set<Data>,
        maxTunnels: Int = 128, linger: DispatchTimeInterval = .seconds(15), onBlocked: @escaping OnBlocked
    ) {
        self.maxTunnels = maxTunnels
        self.linger = linger
        self.resolve = resolve
        self.localAddresses = localAddresses
        self.onBlocked = onBlocked
    }

    deinit {
        listener?.cancel()
        for tunnel in tunnels.values {
            tunnel.client.cancel()
            tunnel.upstream?.cancel()
        }
    }

    /// Whether the listener is up. False before `start()` returns, after
    /// `stop()`, and once the listener fails.
    public var isListening: Bool { listening.withLock { $0 } }

    /// Listens on `127.0.0.1` and returns the port.
    public func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        return try await withCheckedThrowingContinuation { continuation in
            let pending = Mutex<CheckedContinuation<UInt16, Error>?>(continuation)
            let finish: @Sendable (Result<UInt16, Error>) -> Void = { result in pending.withLock { $0.take() }?.resume(with: result) }
            queue.async { [weak self] in
                guard let self, !stopped else { return finish(.failure(StartError.stopped)) }
                self.listener = listener
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        guard let port = listener.port?.rawValue, port != 0 else { return listener.cancel() }
                        self?.listening.withLock { $0 = true }
                        finish(.success(port))
                    case .waiting(let error), .failed(let error):
                        self?.listening.withLock { $0 = false }
                        listener.cancel()
                        finish(.failure(error))
                    case .cancelled:
                        self?.listening.withLock { $0 = false }
                        finish(.failure(StartError.stopped))
                    default:
                        break
                    }
                }
                listener.start(queue: self.queue)
            }
        }
    }

    /// Closes the listener and every tunnel.
    public func stop() {
        queue.async {
            self.stopped = true
            self.listening.withLock { $0 = false }
            self.listener?.cancel()
            for id in Array(self.tunnels.keys) {
                self.close(id)
            }
        }
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped else { return connection.cancel() }
        let full = tunnels.count >= maxTunnels
        let tunnel = Tunnel(client: connection)
        let id = ObjectIdentifier(tunnel)
        tunnels[id] = tunnel
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .waiting, .failed, .cancelled: self?.close(id)
            default: break
            }
        }
        connection.start(queue: queue)
        if full { return respond(id, "503 Service Unavailable") }
        let timeout = DispatchWorkItem { [weak self] in self?.close(id) }
        tunnel.timeout = timeout
        queue.asyncAfter(deadline: .now() + Self.headTimeout, execute: timeout)
        readHead(id)
    }

    private func readHead(_ id: ObjectIdentifier) {
        guard let tunnel = tunnels[id] else { return }
        tunnel.client.receive(minimumIncompleteLength: 1, maximumLength: Self.headLimit) { [weak self] data, _, isComplete, error in
            guard let self, let tunnel = tunnels[id] else { return }
            tunnel.head.append(data ?? Data())
            if let end = tunnel.head.range(of: Data("\r\n\r\n".utf8)) {
                tunnel.timeout?.cancel()
                let rest = Data(tunnel.head[end.upperBound...])
                return route(id, head: Data(tunnel.head[..<end.lowerBound]), rest: rest)
            }
            if tunnel.head.count >= Self.headLimit { return respond(id, "400 Bad Request") }
            if isComplete || error != nil { return close(id) }
            readHead(id)
        }
    }

    private func route(_ id: ObjectIdentifier, head: Data, rest: Data) {
        guard Self.presents(head, credentials: Data("\(Self.username):\(password)".utf8)) else {
            return respond(id, "407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"Alas web preview\"")
        }
        let target: (host: String, port: Int)
        switch Self.connectTarget(head) {
        case .failure(let status): return respond(id, status.rawValue)
        case .success(let value): target = value
        }
        awaitingResolution.append { [weak self] in self?.resolve(id, target: target, rest: rest) }
        resolveNext()
    }

    private func resolveNext() {
        guard resolving < Self.maxResolutions, !awaitingResolution.isEmpty else { return }
        awaitingResolution.removeFirst()()
    }

    private func resolve(_ id: ObjectIdentifier, target: (host: String, port: Int), rest: Data) {
        // A tunnel that closed while waiting needs no lookup.
        guard tunnels[id] != nil else { return resolveNext() }
        resolving += 1
        let resolve = resolve
        Task { [weak self] in
            let answers = await resolve(target.host)
            self?.queue.async { [weak self] in
                guard let self else { return }
                resolving -= 1
                resolveNext()
                vet(id, target: target, answers: answers, rest: rest)
            }
        }
    }

    private func vet(_ id: ObjectIdentifier, target: (host: String, port: Int), answers: [String]?, rest: Data) {
        guard tunnels[id] != nil else { return }
        let addresses = answers?.compactMap(WebPreviewEgressPolicy.address) ?? []
        guard !addresses.isEmpty, addresses.count == answers?.count else { return respond(id, "502 Bad Gateway") }
        if let refusal = WebPreviewEgressPolicy.refusal(forAny: addresses, localAddresses: localAddresses()) {
            onBlocked(target.host, target.port, refusal)
            return respond(id, "403 Forbidden")
        }
        connect(id, to: addresses[...], port: target.port, rest: rest)
    }

    /// Connects to the first address, falling back to the next on failure.
    private func connect(_ id: ObjectIdentifier, to addresses: ArraySlice<Data>, port: Int, rest: Data) {
        guard let tunnel = tunnels[id] else { return }
        guard let address = addresses.first else { return respond(id, "502 Bad Gateway") }
        guard let endpoint = upstreamEndpoint(address, port) else {
            return connect(id, to: addresses.dropFirst(), port: port, rest: rest)
        }
        let options = NWProtocolTCP.Options()
        options.connectionTimeout = 30
        let parameters = NWParameters(tls: nil, tcp: options)
        // The vetted address is the destination; no system proxy may stand in.
        parameters.preferNoProxies = true
        let upstream = NWConnection(to: endpoint, using: parameters)
        tunnel.upstream = upstream
        upstream.stateUpdateHandler = { [weak self] state in
            guard let self, let tunnel = tunnels[id], tunnel.upstream === upstream else { return }
            switch state {
            case .ready:
                tunnel.established = true
                let established = Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)
                tunnel.client.send(content: established, completion: .contentProcessed { _ in })
                if !rest.isEmpty { upstream.send(content: rest, completion: .contentProcessed { _ in }) }
                pump(id, from: tunnel.client, to: upstream)
                pump(id, from: upstream, to: tunnel.client)
            case .waiting, .failed, .cancelled:
                guard !tunnel.established else { return close(id) }
                upstream.stateUpdateHandler = nil
                upstream.cancel()
                tunnel.upstream = nil
                connect(id, to: addresses.dropFirst(), port: port, rest: rest)
            default:
                break
            }
        }
        upstream.start(queue: queue)
    }

    /// Copies one direction, reading only once the last chunk was written.
    /// The client ending closes the tunnel, since WebKit never half-closes.
    /// The upstream ending is passed on once what it sent is flushed, and
    /// the tunnel then closes when the client does, or after `linger`.
    private func pump(_ id: ObjectIdentifier, from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, tunnels[id] != nil else { return }
            let ended = isComplete || error != nil
            let next: NWConnection.SendCompletion = .contentProcessed { [weak self] sendError in
                guard let self, let tunnel = tunnels[id] else { return }
                if sendError != nil { return close(id) }
                guard ended else { return pump(id, from: source, to: destination) }
                if source === tunnel.client { return close(id) }
                let expiry = DispatchWorkItem { [weak self] in self?.close(id) }
                tunnel.timeout = expiry
                queue.asyncAfter(deadline: .now() + linger, execute: expiry)
            }
            if let data, !data.isEmpty {
                destination.send(content: data, completion: ended ? .idempotent : next)
            } else if !ended {
                return pump(id, from: source, to: destination)
            }
            // Sent separately: a final message carrying data may never complete.
            if ended { destination.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: next) }
        }
    }

    private func respond(_ id: ObjectIdentifier, _ status: String) {
        guard let tunnel = tunnels[id] else { return }
        let response = Data("HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        tunnel.client.send(content: response, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.close(id)
        })
    }

    private func close(_ id: ObjectIdentifier) {
        guard let tunnel = tunnels.removeValue(forKey: id) else { return }
        tunnel.timeout?.cancel()
        tunnel.client.cancel()
        tunnel.upstream?.cancel()
    }

    enum Status: String, Error {
        case badRequest = "400 Bad Request"
        case methodNotAllowed = "405 Method Not Allowed"
    }

    /// Whether a request head carries `Proxy-Authorization: Basic` with
    /// exactly these credentials, compared in constant time.
    static func presents(_ head: Data, credentials: Data) -> Bool {
        guard let text = String(data: head, encoding: .utf8) else { return false }
        let expected = Array(credentials)
        for line in text.split(separator: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":"),
                  line[..<colon].lowercased() == "proxy-authorization" else { continue }
            let value = line[line.index(after: colon)...].split(whereSeparator: \.isWhitespace)
            guard value.count == 2, value[0].lowercased() == "basic",
                  let presented = Data(base64Encoded: String(value[1])).map(Array.init),
                  presented.count == expected.count else { return false }
            return zip(presented, expected).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
        }
        return false
    }

    /// The host and port of a `CONNECT host:port HTTP/1.x` request head.
    static func connectTarget(_ head: Data) -> Result<(host: String, port: Int), Status> {
        guard let text = String(data: head, encoding: .utf8),
              let line = text.split(separator: "\r\n", omittingEmptySubsequences: false).first
        else { return .failure(.badRequest) }
        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return .failure(.badRequest) }
        guard parts[0] == "CONNECT" else { return .failure(.methodNotAllowed) }
        let authority = parts[1]
        guard let colon = authority.lastIndex(of: ":"), let port = Int(authority[authority.index(after: colon)...]),
              (1...65535).contains(port) else { return .failure(.badRequest) }
        var host = authority[..<colon]
        if host.hasPrefix("[") {
            guard host.hasSuffix("]") else { return .failure(.badRequest) }
            host = host.dropFirst().dropLast()
        } else if host.contains(":") {
            return .failure(.badRequest)
        }
        guard !host.isEmpty else { return .failure(.badRequest) }
        return .success((String(host), port))
    }
}
