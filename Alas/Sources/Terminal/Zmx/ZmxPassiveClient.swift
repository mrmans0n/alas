import Foundation

/// Read-only attachment to one zmx session daemon.
///
/// Connects to the session socket without sending `Init`, so the client
/// never joins terminal leadership, is never asked for dimensions, and never
/// resizes the PTY. zmx still broadcasts `Output` to it. The initial state
/// and every resynchronization come from `Capture`; input goes through
/// `Send`, which writes to the PTY without changing leadership. This type
/// never sends `Init`, `Input`, or `Resize`.
///
/// A dedicated thread drains the socket continuously regardless of how fast
/// `onEvent` consumers forward data, so zmx never accumulates a backlog for
/// this client. `onEvent` runs on that thread and must not block; it fires
/// `.closed` exactly once, last.
final class ZmxPassiveClient: @unchecked Sendable {
    enum Event: Equatable, Sendable {
        case snapshot(Data)
        case output(Data)
        case closed(CloseReason)
    }

    enum CloseReason: Equatable, Sendable {
        /// `close()` was called.
        case detached
        /// The daemon closed the socket: the session or its process exited.
        case targetExited
        /// No response to the first `Capture` before the deadline: the
        /// running daemon predates `Capture` and must be restarted.
        case captureUnsupported
        /// A frame declared a payload above `ZmxIPC.maxPayloadLength`.
        case overflow
        /// Invalid framing or a capture timeout after the first.
        case protocolError(String)
    }

    private let socket: ZmxIPCSocket
    private let scrollbackRows: UInt32
    private let captureTimeout: DispatchTimeInterval
    private let onEvent: @Sendable (Event) -> Void
    private let lock = NSLock()
    /// Serializes `onEvent` so `.closed` is always last. Recursive so a
    /// handler may call `close()` from inside a callback.
    private let delivery = NSRecursiveLock()
    private var gate = ZmxSnapshotGate()
    private var captureCount = 0
    private var isClosed = false

    init(
        socket: ZmxIPCSocket,
        scrollbackRows: UInt32,
        captureTimeout: DispatchTimeInterval = .seconds(3),
        onEvent: @escaping @Sendable (Event) -> Void
    ) {
        self.socket = socket
        self.scrollbackRows = scrollbackRows
        self.captureTimeout = captureTimeout
        self.onEvent = onEvent
    }

    /// Starts draining and requests the initial snapshot. Call once.
    func start() {
        let thread = Thread { [self] in readLoop() }
        thread.name = "zmx-passive-reader"
        thread.start()
        sendCapture()
    }

    /// Requests a replacement snapshot. Returns false while another capture
    /// is in flight or after close. Output is withheld until it arrives.
    @discardableResult
    func requestResync() -> Bool {
        lock.lock()
        let started = !isClosed && gate.beginCapture()
        lock.unlock()
        if started { sendCapture() }
        return started
    }

    /// Writes bytes to the session PTY via zmx `Send`.
    @discardableResult
    func send(_ input: Data) -> Bool {
        lock.lock()
        let closed = isClosed
        lock.unlock()
        guard !closed, !input.isEmpty else { return false }
        return socket.write(ZmxIPC.encode(.send, input))
    }

    /// Detaches this client only; the session and its process keep running.
    func close() {
        finish(.detached)
    }

    private func sendCapture() {
        lock.lock()
        captureCount += 1
        let token = captureCount
        lock.unlock()
        guard socket.write(ZmxIPC.captureRequest(scrollbackRows: scrollbackRows)) else {
            finish(.targetExited)
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + captureTimeout) { [weak self] in
            self?.captureDeadlinePassed(token: token)
        }
    }

    private func captureDeadlinePassed(token: Int) {
        lock.lock()
        let timedOut = !isClosed && gate.isCaptureInFlight && captureCount == token
        lock.unlock()
        guard timedOut else { return }
        finish(token == 1 ? .captureUnsupported : .protocolError("capture timed out"))
    }

    private func readLoop() {
        var decoder = ZmxFrameDecoder()
        while true {
            guard let chunk = socket.read(), !chunk.isEmpty else {
                finish(.targetExited)
                return
            }
            let frames: [ZmxFrame]
            do {
                frames = try decoder.push(chunk)
            } catch {
                finish(.overflow)
                return
            }
            delivery.lock()
            defer { delivery.unlock() }
            for frame in frames {
                lock.lock()
                let event = isClosed ? nil : gate.accept(frame)
                let closed = isClosed
                lock.unlock()
                if closed { return }
                switch event {
                case .snapshot(let data)?: onEvent(.snapshot(data))
                case .output(let data)?: onEvent(.output(data))
                case nil: break
                }
            }
        }
    }

    private func finish(_ reason: CloseReason) {
        lock.lock()
        let first = !isClosed
        isClosed = true
        lock.unlock()
        guard first else { return }
        socket.shutdown()
        delivery.lock()
        onEvent(.closed(reason))
        delivery.unlock()
    }
}
