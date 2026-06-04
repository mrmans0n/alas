import Foundation
import Network
import CryptoKit

/// Drives one `NWConnection`: reads HTTP, then either serves a response and
/// closes, or (for an authorized WebSocket upgrade) switches to frame mode and
/// bridges decoded client messages to a `RemoteSessionGateway`.
///
/// Concurrency model: all mutable state (`inbound`, `isWebSocket`, `gateway`,
/// `closed`) is confined to the single serial `queue` the connection runs on.
/// `NWConnection` delivers every `receive`/`send` completion on that queue, so
/// those callbacks touch state directly. Work that must reach ACP/pairing state
/// (the responder/authorize/makeGateway closures) hops to `@MainActor`, and any
/// resulting state mutation hops back onto `queue` via `onQueue` before touching
/// the buffer. The class is `@unchecked Sendable` solely because of this strict
/// queue confinement; it adds no locks because there is no cross-queue sharing.
final class RemoteConnection: @unchecked Sendable {
    private let conn: NWConnection
    private let queue: DispatchQueue
    private let makeGateway: @MainActor (@escaping (RemoteServerMessage) -> Void) -> RemoteSessionGateway
    private let responder: @MainActor (HTTPRequest, Data) -> Data
    private let authorize: @MainActor (String) -> Bool   // token → ok
    private let onClose: (RemoteConnection) -> Void

    // Queue-confined state.
    private var inbound = Data()
    private var isWebSocket = false
    private var gateway: RemoteSessionGateway?
    private var closed = false

    init(conn: NWConnection,
         queue: DispatchQueue,
         responder: @escaping @MainActor (HTTPRequest, Data) -> Data,
         authorize: @escaping @MainActor (String) -> Bool,
         makeGateway: @escaping @MainActor (@escaping (RemoteServerMessage) -> Void) -> RemoteSessionGateway,
         onClose: @escaping (RemoteConnection) -> Void = { _ in }) {
        self.conn = conn
        self.queue = queue
        self.responder = responder
        self.authorize = authorize
        self.makeGateway = makeGateway
        self.onClose = onClose
    }

    func start() {
        conn.start(queue: queue)
        receive()
    }

    /// Hops a block back onto the connection's serial queue so it can safely
    /// touch the queue-confined state after a `@MainActor` round-trip.
    private func onQueue(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.inbound.append(data)
                self.drain()
            }
            if isComplete || error != nil {
                self.teardown()
            } else if !self.closed {
                self.receive()
            }
        }
    }

    // MARK: HTTP / upgrade

    private func drain() {
        if isWebSocket { drainFrames(); return }

        // Peek headers on a copy WITHOUT consuming `inbound`, so we can wait for
        // the full Content-Length body before committing. Parse once, here.
        var peek = inbound
        let req: HTTPRequest?
        do {
            req = try HTTPRequestParser.parse(&peek)
        } catch {
            // Malformed request line/headers — refuse and close.
            send(RemoteHTTPResponder.http(status: "400 Bad Request", contentType: "text/plain", body: Data())) {
                [weak self] in self?.teardown()
            }
            return
        }
        guard let req else { return }   // headers not complete yet; keep buffering

        let headerByteCount = inbound.count - peek.count   // bytes through CRLFCRLF
        if req.headers["upgrade"]?.lowercased() == "websocket" {
            inbound.removeFirst(headerByteCount)
            handleUpgrade(req)
            return
        }

        // Non-upgrade request: wait until the full declared body is buffered,
        // then consume headers + body in one shot and parse the body once.
        let needed = Int(req.headers["content-length"] ?? "0") ?? 0
        guard inbound.count - headerByteCount >= needed else { return }   // wait for more
        inbound.removeFirst(headerByteCount)
        let body = Data(inbound.prefix(needed))
        inbound.removeFirst(min(needed, inbound.count))

        Task { @MainActor [weak self] in
            guard let self else { return }
            let out = self.responder(req, body)
            self.onQueue { [weak self] in
                self?.send(out) { [weak self] in self?.teardown() }
            }
        }
    }

    private func handleUpgrade(_ req: HTTPRequest) {
        // Token from Sec-WebSocket-Protocol (web client sends it as a
        // subprotocol) or, as a fallback, a ?token= query parameter.
        let token = req.headers["sec-websocket-protocol"] ?? req.query["token"] ?? ""
        guard let key = req.headers["sec-websocket-key"] else { teardown(); return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let ok = self.authorize(token)
            self.onQueue { [weak self] in
                guard let self else { return }
                guard ok else {
                    self.send(RemoteHTTPResponder.http(status: "401 Unauthorized",
                                                       contentType: "text/plain", body: Data())) {
                        [weak self] in self?.teardown()
                    }
                    return
                }
                self.completeUpgrade(token: token, key: key)
            }
        }
    }

    /// Runs on `queue` after a successful `authorize`. Builds the gateway (on
    /// MainActor), sends the 101 handshake, then begins the frame loop.
    private func completeUpgrade(token: String, key: String) {
        let accept = Self.acceptKey(for: key)
        let proto = token.isEmpty ? "" : "Sec-WebSocket-Protocol: \(token)\r\n"
        // Built as an immutable `let` so it can be captured into the @MainActor
        // Task below without tripping strict-concurrency's "captured var" error.
        let head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(accept)\r\n"
            + proto
            + "\r\n"
        isWebSocket = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            let gateway = self.makeGateway { [weak self] msg in self?.sendServerMessage(msg) }
            self.onQueue { [weak self] in
                guard let self else { return }
                self.gateway = gateway
                self.send(Data(head.utf8)) { [weak self] in self?.drainFrames() }
            }
        }
    }

    // MARK: WebSocket frames

    private func drainFrames() {
        while true {
            var buffer = inbound
            let frame: WebSocketFrame?
            do {
                frame = try WebSocketFrame.decode(from: &buffer)
            } catch {
                // Protocol violation in a frame — close per RFC 6455.
                teardown()
                return
            }
            guard let frame else { break }   // partial frame; wait for more bytes
            inbound = buffer

            switch frame.opcode {
            case .text, .binary:
                if let msg = try? JSONDecoder().decode(RemoteClientMessage.self, from: frame.payload),
                   let gateway {
                    Task { @MainActor in await gateway.handle(msg) }
                }
            case .ping:
                send(WebSocketFrame.encode(opcode: .pong, payload: frame.payload)) {}
            case .close:
                teardown()
                return
            case .continuation, .pong:
                break
            }
        }
    }

    private func sendServerMessage(_ msg: RemoteServerMessage) {
        guard let data = try? JSONEncoder().encode(msg) else { return }
        onQueue { [weak self] in
            self?.send(WebSocketFrame.encode(opcode: .text, payload: data)) {}
        }
    }

    // MARK: lifecycle / io

    private func send(_ data: Data, completion: @escaping @Sendable () -> Void) {
        conn.send(content: data, completion: .contentProcessed { _ in completion() })
    }

    private func teardown() {
        guard !closed else { return }
        closed = true
        if let gateway { Task { @MainActor in gateway.close() } }
        gateway = nil
        conn.cancel()
        onClose(self)
    }

    static func acceptKey(for key: String) -> String {
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data((key + magic).utf8))
        return Data(digest).base64EncodedString()
    }
}
