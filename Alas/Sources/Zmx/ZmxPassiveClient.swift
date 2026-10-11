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
    /// Every write goes through this serial queue, so a daemon that stops
    /// draining blocks this queue, never the caller (the main actor).
    private let writer = DispatchQueue(label: "io.nlopez.alas.zmx-passive-writer")
    private var queuedInputBytes = 0
    /// Bumped by `discardQueuedInput`; queued input from an older epoch is
    /// dropped instead of written.
    private var inputEpoch = 0
    static let maxQueuedInputBytes = 4 * 1024 * 1024

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

    /// Queues bytes for the session PTY via zmx `Send`, in order. Returns
    /// false, without queueing, after close or once `maxQueuedInputBytes`
    /// are waiting behind the frame being written to a daemon that is not
    /// draining.
    @discardableResult
    func send(_ input: Data) -> Bool {
        guard !input.isEmpty else { return false }
        let epoch: Int? = lock.withLock {
            guard !isClosed, queuedInputBytes + input.count <= Self.maxQueuedInputBytes else { return nil }
            queuedInputBytes += input.count
            return inputEpoch
        }
        guard let epoch else { return false }
        let frame = ZmxIPC.encode(.send, input)
        writer.async { [self] in
            let current = lock.withLock { () -> Bool in
                // Discarded input already gave its bytes back.
                guard inputEpoch == epoch else { return false }
                queuedInputBytes -= input.count
                return !isClosed
            }
            guard current else { return }
            if !socket.write(frame) { finish(.targetExited) }
        }
        return true
    }

    /// Drops input accepted but not yet written. A revoked lease must not
    /// deliver input queued under it; a write already in progress completes.
    func discardQueuedInput() {
        lock.withLock {
            inputEpoch += 1
            queuedInputBytes = 0
        }
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
        let frame = ZmxIPC.captureRequest(scrollbackRows: scrollbackRows)
        writer.async { [self] in
            if !socket.write(frame) { finish(.targetExited) }
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
