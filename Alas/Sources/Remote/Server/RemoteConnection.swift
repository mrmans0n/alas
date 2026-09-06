import Foundation
import Network
import CryptoKit

/// Drives one `NWConnection`: reads HTTP, then either serves a response and
/// closes, or (for an authorized WebSocket upgrade) switches to frame mode and
/// bridges decoded client messages to a `RemoteSessionGateway`.
///
/// Concurrency model: all mutable state (`inbound`, `isWebSocket`, `gateway`,
/// `closed`, `isClosing`) is confined to the single serial `queue` the connection runs on.
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
    private let authorize: @MainActor (String) -> String?   // token → deviceId (nil = reject)
    private let accessPolicy: RemoteAccessPolicy
    private let onAuthenticated: ((RemoteConnection, String) -> Void)?
    private let onClose: (RemoteConnection) -> Void

    // Queue-confined state.
    private var inbound = Data()
    private var isWebSocket = false
    private var gateway: RemoteSessionGateway?
    private var closed = false
    /// Set once a terminal response has been queued. This closes the gap between
    /// queueing the response and the send completion, so pipelined bytes cannot
    /// re-drive `drain()` against the same rejected request.
    private var isClosing = false
    /// Tail of the per-connection message-processing chain. Each decoded frame's
    /// `gateway.handle` awaits the previous one, so messages are processed in
    /// arrival order — clients rely on this (e.g. a `takeOver` must land before
    /// the `sendPrompt` that follows it). Mutated only on `queue`.
    private var processingTail: MessageProcessingTask?
    /// Task of the most recently dispatched `isDriveOrdering` message
    /// (sendPrompt/takeOver). A following `stop` awaits exactly this —
    /// narrower than the full `processingTail` — so it lands after a turn
    /// the user just started without being blocked by unrelated queued read
    /// work (subscribe/fetchOlder/list*/etc). Mutated only on `queue`.
    private var lastDriveActionTail: Task<Void, Never>?
    private var lastDriveActionID: UUID?
    /// Reassembles fragmented WebSocket messages before they're decoded.
    private var reassembler = WebSocketReassembler()
    /// The device this connection authenticated as, set on `queue` once the WS
    /// upgrade succeeds. Queue-confined; the server learns it via the
    /// `onAuthenticated` hop rather than reading this cross-queue.
    private var deviceId: String?

    init(conn: NWConnection,
         queue: DispatchQueue,
         responder: @escaping @MainActor (HTTPRequest, Data) -> Data,
         authorize: @escaping @MainActor (String) -> String?,
         accessPolicy: RemoteAccessPolicy,
         makeGateway: @escaping @MainActor (@escaping (RemoteServerMessage) -> Void) -> RemoteSessionGateway,
         onAuthenticated: ((RemoteConnection, String) -> Void)? = nil,
         onClose: @escaping (RemoteConnection) -> Void = { _ in }) {
        self.conn = conn
        self.queue = queue
        self.responder = responder
        self.authorize = authorize
        self.accessPolicy = accessPolicy
        self.makeGateway = makeGateway
        self.onAuthenticated = onAuthenticated
        self.onClose = onClose
    }

    // Bounds on the unauthenticated HTTP path (auth happens at WS upgrade).
    private static let maxHeaderBytes = 64 * 1024
    private static let maxBodyBytes = 1 << 20   // 1 MB

    /// Cap on how long a control message (stop) waits for a preceding drive
    /// action's own task — which itself waits on whatever ordered read work
    /// preceded IT — before running anyway regardless of whether that chain
    /// finished. Generous for normal-speed reads/lease-confirms; short
    /// enough that stop remains a reliable emergency brake if something
    /// ahead of it is genuinely stuck.
    private static let stopDriveActionWaitNanos: UInt64 = 1_000_000_000

    func start() {
        conn.start(queue: queue)
        receive()
    }

    /// External request to close this connection (e.g. server `stop()`). Hops
    /// onto the serial queue so teardown touches queue-confined state safely.
    func cancel() {
        onQueue { [weak self] in self?.teardown() }
    }

    /// Hops a block back onto the connection's serial queue so it can safely
    /// touch the queue-confined state after a `@MainActor` round-trip.
    private func onQueue(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard !self.isClosing else { return }
            if let data, !data.isEmpty {
                self.inbound.append(data)
                self.drain()
            }
            if isComplete || error != nil {
                self.teardown()
            } else if !self.closed && !self.isClosing {
                self.receive()
            }
        }
    }

    // MARK: HTTP / upgrade

    private func drain() {
        if isWebSocket { drainFrames()
        return }

        // Peek headers on a copy WITHOUT consuming `inbound`, so we can wait for
        // the full Content-Length body before committing. Parse once, here.
        var peek = inbound
        let req: HTTPRequest?
        do {
            req = try HTTPRequestParser.parse(&peek)
        } catch {
            // Malformed request line/headers — refuse and close.
            sendAndClose(RemoteHTTPResponder.http(status: "400 Bad Request", contentType: "text/plain", body: Data()))
            return
        }
        guard let req else {
            // Headers not complete yet; keep buffering — but bound the header
            // block so an unauthenticated peer can't grow memory by dribbling
            // bytes with no CRLFCRLF terminator.
            if inbound.count > Self.maxHeaderBytes {
                sendAndClose(RemoteHTTPResponder.http(status: "431 Request Header Fields Too Large",
                                                      contentType: "text/plain", body: Data()))
            }
            return
        }

        guard accessPolicy.allows(hostHeader: req.headers["host"]) else {
            sendAndClose(RemoteHTTPResponder.http(
                status: "403 Forbidden",
                contentType: "text/plain",
                body: Data("forbidden".utf8)
            ))
            return
        }

        let headerByteCount = inbound.count - peek.count   // bytes through CRLFCRLF
        if req.headers["upgrade"]?.lowercased() == "websocket" {
            inbound.removeFirst(headerByteCount)
            guard req.method == "GET", req.path == "/ws" else {
                sendAndClose(RemoteHTTPResponder.http(
                    status: "404 Not Found",
                    contentType: "text/plain",
                    body: Data("not found".utf8)
                ))
                return
            }
            handleUpgrade(req)
            return
        }

        // Non-upgrade request: wait until the full declared body is buffered,
        // then consume headers + body in one shot and parse the body once.
        let needed = Int(req.headers["content-length"] ?? "0") ?? 0
        // A negative Content-Length parses as a valid Int but would later trap in
        // `inbound.prefix(needed)`. Reject it (and it's reachable unauthenticated).
        guard needed >= 0 else {
            inbound.removeFirst(headerByteCount)
            sendAndClose(RemoteHTTPResponder.http(status: "400 Bad Request",
                                                  contentType: "text/plain", body: Data()))
            return
        }
        // Reject an oversized declared (or already-buffered) body before we
        // commit to buffering it — auth only happens at WS upgrade, so this is
        // reachable unauthenticated.
        if needed > Self.maxBodyBytes || inbound.count - headerByteCount > Self.maxBodyBytes {
            inbound.removeFirst(headerByteCount)
            sendAndClose(RemoteHTTPResponder.http(status: "413 Payload Too Large",
                                                  contentType: "text/plain", body: Data()))
            return
        }
        guard inbound.count - headerByteCount >= needed else { return }   // wait for more
        inbound.removeFirst(headerByteCount)
        let body = Data(inbound.prefix(needed))
        inbound.removeFirst(min(needed, inbound.count))

        Task { @MainActor [weak self] in
            guard let self else { return }
            let out = self.responder(req, body)
            self.onQueue { [weak self] in
                self?.sendAndClose(out)
            }
        }
    }

    private func handleUpgrade(_ req: HTTPRequest) {
        // Token from Sec-WebSocket-Protocol (web client sends it as a
        // subprotocol) or, as a fallback, a ?token= query parameter.
        let token = req.headers["sec-websocket-protocol"] ?? req.query["token"] ?? ""
        guard let key = req.headers["sec-websocket-key"] else { teardown()
        return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let deviceId = self.authorize(token)
            self.onQueue { [weak self] in
                guard let self else { return }
                guard let deviceId else {
                    self.sendAndClose(RemoteHTTPResponder.http(status: "401 Unauthorized",
                                                               contentType: "text/plain", body: Data()))
                    return
                }
                self.deviceId = deviceId
                self.onAuthenticated?(self, deviceId)
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
            case .text, .binary, .continuation:
                // Reassemble fragmented messages (RFC 6455 §5.4) before decoding;
                // a single message may arrive split across continuation frames.
                switch reassembler.accept(frame) {
                case .message(let payload): dispatchMessage(payload)
                case .incomplete: break
                case .violation:
                    teardown()
                    return
                }
            case .ping:
                send(WebSocketFrame.encode(opcode: .pong, payload: frame.payload)) {}
            case .close:
                teardown()
                return
            case .pong:
                break
            }
        }
    }

    /// Decode a (reassembled) message payload and chain its handling onto the
    /// per-connection tail so messages run in strict arrival order — each awaits
    /// the previous. Independent tasks could otherwise interleave and, e.g., run
    /// a `sendPrompt` before the `takeOver` the client sent just before it.
    private func dispatchMessage(_ payload: Data) {
        guard let msg = try? JSONDecoder().decode(RemoteClientMessage.self, from: payload),
              let gateway else { return }
        // Control messages (stop) are idempotent and latency-critical: they
        // don't extend `processingTail`, so messages arriving AFTER stop are
        // never blocked behind it. They still await the most recent DRIVE
        // action (sendPrompt/takeOver) specifically — not the whole ordered
        // queue — so a still-in-flight prompt/takeover is allowed to land
        // first (or stop could find no active turn to cancel and the
        // just-submitted prompt would stream anyway right after the user
        // pressed Stop).
        //
        // That drive action's own task still chains behind whatever ordered
        // read work (subscribe/fetchOlder/list*/etc.) preceded IT, though —
        // `await previous?.value` inside its body is unavoidable, since the
        // drive action genuinely cannot run before its predecessor. If that
        // predecessor is stuck (not just normally slow), waiting on it here
        // would block stop indefinitely too, defeating its purpose as an
        // always-available emergency brake. Bound the wait: ordered read
        // work is fast under normal conditions (Task 4/6 fixed the
        // MainActor-saturating case), so this window is generous for the
        // common case but still guarantees stop is never stuck for good.
        if msg.isControl {
            let previous = lastDriveActionTail
            Task { @MainActor in
                if let previous {
                    // `Task<Void, Never>.value` cannot be interrupted by
                    // cancellation (it has no error channel to abort
                    // through), so a `withTaskGroup` race here would still
                    // block at the group's implicit exit-reap until
                    // `previous` itself finishes — defeating the bound
                    // entirely. Race via a manually-resumed continuation
                    // instead: whichever finishes first resumes it, and the
                    // loser keeps running independently in the background,
                    // its own eventual resume attempt becoming a no-op.
                    let timedOut = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                        let resume = SingleResume(continuation)
                        Task { @MainActor in
                            await previous.value
                            resume.fire(false)
                        }
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: Self.stopDriveActionWaitNanos)
                            resume.fire(true)
                        }
                    }
                    if timedOut {
                        // The drive action never finished in time. It's still
                        // queued and WILL eventually run once its own
                        // predecessor clears — cancel it so the dispatch
                        // below (which checks isCancelled before calling
                        // gateway.handle) skips it instead of submitting a
                        // prompt/takeover after the user already pressed
                        // Stop, silently defeating the emergency brake.
                        previous.cancel()
                    }
                }
                await gateway.handle(msg)
            }
            return
        }
        let task = MessageProcessingTask(previous: processingTail)
        task.start(
            operation: { await gateway.handle(msg) },
            onFinish: { [weak self] id in
                self?.onQueue { [weak self] in self?.finishProcessingTask(id: id) }
            }
        )
        processingTail = task
        if msg.isDriveOrdering {
            lastDriveActionTail = task.task
            lastDriveActionID = task.id
        }
    }

    private func sendServerMessage(_ msg: RemoteServerMessage) {
        // Encode on the connection's serial queue, not the caller's
        // MainActor context — outbound serialization must never compete
        // with ACP state mutation for main-thread time.
        onQueue { [weak self] in
            guard let self, let data = try? JSONEncoder().encode(msg) else { return }
            self.send(WebSocketFrame.encode(opcode: .text, payload: data)) {}
        }
    }

    // MARK: lifecycle / io

    private func sendAndClose(_ data: Data) {
        guard !isClosing else { return }
        isClosing = true
        send(data) { [weak self] in self?.teardown() }
    }

    private func send(_ data: Data, completion: @escaping @Sendable () -> Void) {
        // NWConnection delivers this completion on our serial queue. On a send
        // error, tear down rather than running the follow-up (which would touch
        // a dead connection).
        conn.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.teardown() } else { completion() }
        })
    }

    private func teardown() {
        guard !closed else { return }
        closed = true
        isClosing = true
        processingTail?.cancelForTeardown()
        processingTail = nil
        lastDriveActionTail = nil
        lastDriveActionID = nil
        if let gateway { Task { @MainActor in gateway.close() } }
        gateway = nil
        conn.cancel()
        onClose(self)
    }

    private func finishProcessingTask(id: UUID) {
        guard let tail = processingTail, let completed = tail.task(withID: id) else { return }
        completed.markFinished()
        if tail.isFinished {
            processingTail = nil
        } else {
            tail.pruneFinishedPredecessors()
        }
        if lastDriveActionID == id {
            lastDriveActionTail = nil
            lastDriveActionID = nil
        }
    }

    /// Queue-confined node in the ordered message chain. The task only captures
    /// its predecessor's task handle, never this node, so node/task references
    /// cannot form a cycle. Completion is reported to `RemoteConnection`, which
    /// marks and unlinks this node on the connection queue.
    final class MessageProcessingTask: @unchecked Sendable {
        let id = UUID()
        private(set) var task: Task<Void, Never>!
        private(set) var previous: MessageProcessingTask?
        private(set) var isFinished = false

        init(previous: MessageProcessingTask?) {
            self.previous = previous
        }

        func start(
            operation: @escaping @MainActor @Sendable () async -> Void,
            onFinish: @escaping @Sendable (UUID) -> Void = { _ in }
        ) {
            precondition(task == nil)
            let previousTask = previous?.task
            let id = id
            task = Task { @MainActor in
                defer { onFinish(id) }
                await previousTask?.value
                guard !Task.isCancelled else { return }
                await operation()
            }
        }

        func cancelForTeardown() {
            var current: MessageProcessingTask? = self
            while let node = current, !node.isFinished {
                node.task.cancel()
                current = node.previous
            }
        }

        func task(withID id: UUID) -> MessageProcessingTask? {
            var current: MessageProcessingTask? = self
            while let node = current {
                if node.id == id { return node }
                current = node.previous
            }
            return nil
        }

        func markFinished() {
            isFinished = true
        }

        func pruneFinishedPredecessors() {
            var current: MessageProcessingTask? = self
            while let node = current {
                while let previous = node.previous, previous.isFinished {
                    node.previous = previous.previous
                }
                current = node.previous
            }
        }

        var hasPredecessor: Bool {
            previous != nil
        }
    }

    static func acceptKey(for key: String) -> String {
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data((key + magic).utf8))
        return Data(digest).base64EncodedString()
    }
}

/// Resumes a `CheckedContinuation<T, Never>` at most once with the given
/// value. Used to race two independent tasks (e.g. "did the prior work
/// finish" vs. "did the timeout elapse") where whichever finishes first
/// wins — its value is what the continuation resumes with — and the other
/// is simply abandoned rather than cancelled.
@MainActor
private final class SingleResume<T> {
    private var fired = false
    private let continuation: CheckedContinuation<T, Never>

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func fire(_ value: T) {
        guard !fired else { return }
        fired = true
        continuation.resume(returning: value)
    }
}
