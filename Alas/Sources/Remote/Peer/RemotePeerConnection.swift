import Foundation

@MainActor
protocol RemotePeerConnecting: AnyObject {
    var state: RemotePeerConnection.State { get }
    func connect()
    func disconnect()
    func send(_ message: RemoteClientMessage)
}

/// One outbound WebSocket to a paired Mac. Mirrors `hub-links.js`: try the
/// last good origin then the rest with a handshake timeout, expect `hello`
/// first, answer `helloAck`, tell "revoked" from "unreachable" with a
/// `/health` probe, and back off between attempts. On top of that it refuses
/// any socket whose `hello` reports an identity other than `expectedServerId`.
///
/// **The owner must call `disconnect()`.** Dropping the last reference is not
/// enough: an in-flight `run()` resolves its weak `self` to a strong one for
/// the whole call and stays suspended in `pump` for the entire online
/// lifetime, so a connected link cannot deallocate, and there is no `deinit`
/// to close the socket. Releasing an owner without disconnecting leaks the
/// object, its task, and an open socket to the peer.
@MainActor
final class RemotePeerConnection: RemotePeerConnecting {
    enum State: Equatable, Sendable {
        case idle
        case connecting
        case online
        case offline
        case unauthorized
        case incompatible(remoteVersion: Int)
        /// The socket's `hello` reported an identity other than the one this
        /// link was created for. Terminal for the whole link — the remaining
        /// origins are not tried and no reconnect is armed — because the
        /// record now describes a Mac that is not there, which only the user
        /// can resolve by forgetting the peer and pairing again.
        case identityMismatch(expected: String, actual: String)
    }

    enum Event {
        case stateChanged(State)
        case hello(serverId: String, name: String, protocolVersion: Int, federationEnabled: Bool)
        case originChanged(String)
        case message(RemoteServerMessage)
    }

    struct Config {
        var handshakeTimeout: TimeInterval = 4
        var initialBackoff: TimeInterval = 1.5
        var maxBackoff: TimeInterval = 30
        var localProtocolVersion: Int = RemoteProtocolVersion.current
    }

    private(set) var state: State = .idle
    private(set) var lastOrigin: String?

    private let origins: [String]
    /// The peer's token. Travels only as the WebSocket subprotocol; it is
    /// never logged, never part of an error, and never in the URL.
    private let token: String
    /// The `serverId` this peer is expected to report. When set, a `/health`
    /// probe only counts as proof the paired Mac is up if it reports this id,
    /// and a socket whose `hello` reports a different id is refused outright
    /// rather than adopted.
    private let expectedServerId: String?
    private let config: Config
    private let session: URLSession
    private let onEvent: @MainActor (Event) -> Void
    private var socket: URLSessionWebSocketTask?
    private var runner: Task<Void, Never>?
    private var reconnectTimer: Task<Void, Never>?
    private var backoff: TimeInterval

    init(origins: [String], lastOrigin: String?, token: String, expectedServerId: String? = nil,
         config: Config = Config(), session: URLSession = .shared,
         onEvent: @escaping @MainActor (Event) -> Void) {
        self.origins = origins
        self.lastOrigin = lastOrigin
        self.token = token
        self.expectedServerId = expectedServerId
        self.config = config
        self.session = session
        self.onEvent = onEvent
        self.backoff = config.initialBackoff
    }

    func connect() {
        guard runner == nil else { return }
        // A pending reconnect belongs to an attempt this call supersedes.
        // Letting it go without cancelling would orphan it: `disconnect()`
        // only knows about the newest timer, so a dropped one would still
        // fire and redial a link the owner had torn down.
        reconnectTimer?.cancel()
        reconnectTimer = nil
        runner = Task { [weak self] in await self?.run() }
    }

    func disconnect() {
        runner?.cancel()
        runner = nil
        reconnectTimer?.cancel()
        reconnectTimer = nil
        closeSocket(.goingAway)
        setState(.idle)
    }

    func send(_ message: RemoteClientMessage) {
        guard state == .online, let socket, let data = try? JSONEncoder().encode(message) else { return }
        socket.send(.data(data)) { _ in }
    }

    // MARK: - Lifecycle

    private func run() async {
        // This body does not start until the main actor yields, so a
        // `disconnect()` can land first. Announcing `.connecting` then would
        // strand the link there: the task returns immediately afterwards with
        // `runner` already nil, and nothing would ever move the state again.
        if Task.isCancelled { return }
        setState(.connecting)
        // An origin whose `hello` proves it is not the peer is skipped, not
        // fatal: a stale advertised address can have been reassigned while a
        // later origin still reaches the real peer. Remembered so that, if no
        // origin ultimately works, the reported state is the more actionable
        // "wrong Mac answered" rather than a bare "offline".
        var lastMismatch: (expected: String, actual: String)?
        var ordered: [String] = []
        for origin in [lastOrigin].compactMap({ $0 }) + origins where !ordered.contains(origin) {
            ordered.append(origin)
        }
        for origin in ordered {
            if Task.isCancelled { return }
            guard let url = Self.socketURL(for: origin) else { continue }
            let candidate = session.webSocketTask(with: url, protocols: [token])
            candidate.resume()
            let first: RemoteServerMessage
            switch await receive(from: candidate, timeout: config.handshakeTimeout) {
            case .message(let message):
                first = message
            case .failed:
                if Task.isCancelled { return }
                // A dropped receive here can mean either the upgrade was
                // refused outright, or that it actually succeeded (a genuine
                // 101 reply) and the connection then closed before any frame
                // arrived — a server restart, a transient network blip, or a
                // proxy interruption mid-handshake. Only the former is
                // evidence the credential was specifically rejected; a
                // confirmed 101 means the token was fine, so treat this
                // exactly like `.noUsableFrame` — an ordinary retryable
                // disconnect — rather than probing `/health` at all, since a
                // reachable peer there would otherwise be misread as having
                // revoked a token it never actually refused.
                if (candidate.response as? HTTPURLResponse)?.statusCode == 101 {
                    continue
                }
                let peerFederationEnabled = await healthCheck(origin)
                // A disconnect() during the probe already moved us to .idle;
                // reporting .unauthorized on top of it would resurrect a link
                // the caller just tore down.
                if Task.isCancelled { return }
                if peerFederationEnabled == true {
                    // The Mac answers HTTP, confirms its identity, and
                    // federation is CURRENTLY on there — so a refused upgrade
                    // really does mean our token is gone.
                    setState(.unauthorized)
                    runner = nil
                    return
                }
                // Either unreachable/unconfirmed (nil), or the Mac is real and
                // reachable but has federation off right now (false) — the
                // owner there can flip it back on at any time, so this must
                // stay retryable rather than becoming the same terminal state
                // as an actual revocation.
                continue
            case .noUsableFrame:
                // The upgrade itself succeeded, so the token is fine — the
                // peer was merely slow or opened with a frame this build
                // cannot read. Probing `/health` here would call a live
                // pairing revoked; move on and let backoff retry instead.
                if Task.isCancelled { return }
                continue
            }
            // disconnect() cannot close this socket — it is not `self.socket`
            // until the handshake succeeds — so close it here rather than
            // leaving it open and flipping a torn-down link back online.
            if Task.isCancelled {
                candidate.cancel(with: .goingAway, reason: nil)
                return
            }
            guard case .hello(let version, let serverId, let name, _, let federationEnabled) = first else {
                candidate.cancel(with: .protocolError, reason: nil)
                continue
            }
            // The `hello` on the socket that carries traffic — not only the
            // `/health` probe — has to prove this is the Mac the record was
            // written for. Whoever answers the origin would otherwise decide
            // the link's identity, and the manager would adopt it: a reused
            // address or a squatter could silently take a peer's place.
            // Checked BEFORE the protocol-version check below: a stale
            // origin reassigned to an unrelated Alas instance running an
            // incompatible version must not make the WHOLE attempt terminal
            // on the strength of a version mismatch alone — only an
            // instance CONFIRMED to be our actual peer can be genuinely
            // incompatible. Only THIS origin is disqualified here: a
            // reassigned address does not mean every address is bad, and
            // giving up on the whole list would strand a link whose real
            // peer is still reachable elsewhere in it.
            if let expectedServerId, serverId != expectedServerId {
                candidate.cancel(with: .policyViolation, reason: nil)
                lastMismatch = (expected: expectedServerId, actual: serverId)
                continue
            }
            // This origin's identity checked out, so any mismatch seen at an
            // EARLIER origin in this same attempt no longer describes what's
            // wrong: it would misreport a normal disconnect later in this
            // block as an identity problem with the Mac we are, in fact,
            // correctly talking to.
            lastMismatch = nil
            // Identity is confirmed at this point, so an incompatible
            // version genuinely means THIS peer cannot be talked to yet —
            // unlike the identity check above, this is fatal for the whole
            // attempt rather than just this origin.
            if version != config.localProtocolVersion {
                candidate.cancel(with: .goingAway, reason: nil)
                setState(.incompatible(remoteVersion: version))
                runner = nil
                return
            }
            socket = candidate
            if origin != lastOrigin {
                lastOrigin = origin
                onEvent(.originChanged(origin))
            }
            onEvent(.hello(serverId: serverId, name: name, protocolVersion: version, federationEnabled: federationEnabled))
            if let ack = try? JSONEncoder().encode(RemoteClientMessage.helloAck(protocolVersion: config.localProtocolVersion)) {
                candidate.send(.data(ack)) { _ in }
            }
            backoff = config.initialBackoff
            setState(.online)
            await pump(candidate)
            // A runner cancelled by disconnect() can reach here long after a
            // newer runner adopted a socket of its own, so close only the one
            // this attempt owns — never whatever happens to be current.
            closeSocket(.goingAway, ifCurrent: candidate)
            if Task.isCancelled { return }
            scheduleReconnect(reportedState: lastMismatch.map { State.identityMismatch(expected: $0.expected, actual: $0.actual) } ?? .offline)
            return
        }
        if Task.isCancelled { return }
        scheduleReconnect(reportedState: lastMismatch.map { State.identityMismatch(expected: $0.expected, actual: $0.actual) } ?? .offline)
    }

    private func pump(_ socket: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            guard let raw = try? await socket.receive() else { return }
            let payload: Data
            switch raw {
            case .data(let d): payload = d
            case .string(let s): payload = Data(s.utf8)
            @unknown default: continue
            }
            // Messages this build does not know are skipped, so a newer peer
            // never kills the link.
            guard let message = try? JSONDecoder().decode(RemoteServerMessage.self, from: payload) else { continue }
            onEvent(.message(message))
        }
    }

    /// What a handshake's first frame produced. `failed` is kept apart from
    /// `noUsableFrame` because only a failed receive can mean the peer refused
    /// the upgrade: a timeout or an unreadable frame both prove the socket was
    /// accepted, so probing `/health` on those would report a slow peer — or
    /// one a protocol revision ahead — as having revoked our pairing.
    private enum Handshake {
        case message(RemoteServerMessage)
        case failed
        case noUsableFrame
    }

    private func receive(from socket: URLSessionWebSocketTask, timeout: TimeInterval) async -> Handshake {
        await withTaskGroup(of: Handshake.self) { group in
            group.addTask {
                guard let raw = try? await socket.receive() else { return .failed }
                let payload: Data
                switch raw {
                case .data(let d): payload = d
                case .string(let s): payload = Data(s.utf8)
                @unknown default: return .noUsableFrame
                }
                guard let message = try? JSONDecoder().decode(RemoteServerMessage.self, from: payload) else {
                    return .noUsableFrame
                }
                return .message(message)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return .noUsableFrame
            }
            let first = await group.next() ?? .failed
            switch first {
            case .message:
                break
            case .failed, .noUsableFrame:
                // `URLSessionWebSocketTask.receive()` does not observe task
                // cancellation, so on the timeout branch the group would wait
                // on it forever against a peer that upgraded and then went
                // quiet. Cancelling the socket is what ends that wait; the
                // caller discards this socket on every non-message outcome.
                socket.cancel(with: .goingAway, reason: nil)
            }
            group.cancelAll()
            return first
        }
    }

    /// Whether `origin` answers as the paired Mac, and if so, whether
    /// federation is CURRENTLY on there. A 2xx alone only proves that
    /// *something* serves HTTP at this address, which is why `/health`
    /// reports a `serverId`: when this link knows which one to expect, an
    /// unrelated Alas — or any web server — on a reused address must not be
    /// read as "the paired Mac refused us", since that state is terminal.
    /// `federationEnabled` then separates a real revocation from the far
    /// side merely having the experiment flag off right now, which is not:
    /// a missing key (an older Alas build) defaults to `true` so an old
    /// server is never mistaken for one that toggled the flag.
    /// Returns `nil` when the probe fails or answers as someone else.
    private func healthCheck(_ origin: String) async -> Bool? {
        struct Health: Decodable { let serverId: String?
        let federationEnabled: Bool? }
        guard let normalized = RemotePairingLink.normalizeOrigin(origin),
              let url = URL(string: normalized + "/health") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = config.handshakeTimeout
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        guard let expectedServerId else { return true }
        guard let health = try? JSONDecoder().decode(Health.self, from: data),
              health.serverId == expectedServerId else { return nil }
        return health.federationEnabled ?? true
    }

    private func scheduleReconnect(reportedState: State = .offline) {
        setState(reportedState)
        runner = nil
        let delay = backoff
        backoff = min(backoff * 2, config.maxBackoff)
        // Never overwrite a live timer without cancelling it; the field is
        // all `disconnect()` has to reach them by.
        reconnectTimer?.cancel()
        reconnectTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.reconnectTimer = nil
            self.connect()
        }
    }

    /// Closes the adopted socket. `ifCurrent` guards callers that own a
    /// particular socket: passing it makes the close a no-op unless that is
    /// still the adopted one, so a stale runner cannot cancel a live link's.
    private func closeSocket(_ code: URLSessionWebSocketTask.CloseCode,
                             ifCurrent expected: URLSessionWebSocketTask? = nil) {
        if let expected, socket !== expected { return }
        socket?.cancel(with: code, reason: nil)
        socket = nil
    }

    private func setState(_ new: State) {
        guard state != new else { return }
        state = new
        onEvent(.stateChanged(new))
    }

    static func socketURL(for origin: String) -> URL? {
        // Origins reach a peer link from a stored record whose address the
        // peer itself advertised, so normalize before dialing: anything but
        // a bare http(s) origin is refused, and no path, query or userinfo
        // can be smuggled into the request target.
        guard let normalized = RemotePairingLink.normalizeOrigin(origin),
              var components = URLComponents(string: normalized) else { return nil }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/ws"
        return components.url
    }
}
