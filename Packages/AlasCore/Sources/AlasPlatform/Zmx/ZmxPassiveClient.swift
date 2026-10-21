import Foundation
import AlasFoundation
import AlasModel

/// Read-only attachment to one zmx session daemon.
///
/// Connects to the session socket without sending `Init`, so the client
/// never joins terminal leadership, is never asked for dimensions, and never
/// resizes the PTY. zmx still broadcasts `Output` to it. The initial state
/// and every resynchronization come from `Capture`; input goes through
/// `Send`, which writes to the PTY without changing leadership. This type
/// never sends `Init`, `Input`, or `Resize`.
///
/// The daemon's wire format is probed on a separate connection before
/// anything is written to or decoded from this socket.
///
/// A dedicated thread drains the socket regardless of how fast `onEvent`
/// consumers forward data. It starts reading only once the probe resolves
/// (bounded by the probe's timeout), so zmx may buffer output for this client
/// until then; after that it never accumulates a backlog. `onEvent` runs on
/// that thread and must not block; it fires `.closed` exactly once, last.
public final class ZmxPassiveClient: @unchecked Sendable {
    public enum Event: Equatable, Sendable {
        case snapshot(Data)
        case output(Data)
        case closed(CloseReason)
    }

    public enum CloseReason: Equatable, Sendable {
        /// `close()` was called.
        case detached
        /// The daemon closed the socket: the session or its process exited.
        case targetExited
        /// No response to the first `Capture` before the deadline: the
        /// running daemon predates `Capture` and must be restarted.
        case captureUnsupported
        /// A frame declared a payload above `ZmxIPC.maxPayloadLength`.
        case overflow
        /// The wire probe got no recognizable answer from the daemon.
        case unreachable
        /// Invalid framing or a capture timeout after the first.
        case protocolError(String)
    }

    private let socket: ZmxIPCSocket
    private let probe: @Sendable () -> ZmxDaemonStatus
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
    /// Set by the probe, which runs first on `writer`, so every later writer
    /// block sees it. Nil until then and forever if the probe fails.
    private var wire: ZmxIPC.Wire?
    /// Signaled once the probe resolves or the client closes; the reader
    /// waits on it before decoding anything.
    private let wireResolved = DispatchSemaphore(value: 0)
    /// Every write goes through this serial queue, so a daemon that stops
    /// draining blocks this queue, never the caller (the main actor).
    private let writer = DispatchQueue(label: "io.nlopez.alas.zmx-passive-writer")
    private var queuedInputBytes = 0
    /// Bumped by `discardQueuedInput`; queued input from an older epoch is
    /// dropped instead of written.
    private var inputEpoch = 0
    public static let maxQueuedInputBytes = 4 * 1024 * 1024

    public init(
        socket: ZmxIPCSocket,
        probe: @escaping @Sendable () -> ZmxDaemonStatus,
        scrollbackRows: UInt32,
        captureTimeout: DispatchTimeInterval = .seconds(3),
        onEvent: @escaping @Sendable (Event) -> Void
    ) {
        self.socket = socket
        self.probe = probe
        self.scrollbackRows = scrollbackRows
        self.captureTimeout = captureTimeout
        self.onEvent = onEvent
    }

    /// Probes the daemon's wire, then starts draining and requests the
    /// initial snapshot. Returns immediately; the blocking probe runs on the
    /// writer queue. Call once.
    public func start() {
        let thread = Thread { [self] in readLoop() }
        thread.name = "zmx-passive-reader"
        thread.start()
        writer.async { [self] in resolveWire() }
        sendCapture()
    }

    /// Requests a replacement snapshot. Returns false while another capture
    /// is in flight or after close. Output is withheld until it arrives.
    @discardableResult
    public func requestResync() -> Bool {
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
    public func send(_ input: Data) -> Bool {
        guard !input.isEmpty else { return false }
        let epoch: Int? = lock.withLock {
            guard !isClosed, queuedInputBytes + input.count <= Self.maxQueuedInputBytes else { return nil }
            queuedInputBytes += input.count
            return inputEpoch
        }
        guard let epoch else { return false }
        writer.async { [self] in
            let wire = lock.withLock { () -> ZmxIPC.Wire? in
                // Discarded input already gave its bytes back.
                guard inputEpoch == epoch else { return nil }
                queuedInputBytes -= input.count
                return isClosed ? nil : self.wire
            }
            guard let wire else { return }
            if !socket.write(ZmxIPC.encode(.send, input, wire: wire)) { finish(.targetExited) }
        }
        return true
    }

    /// Drops input accepted but not yet written. A revoked lease must not
    /// deliver input queued under it; a write already in progress completes.
    public func discardQueuedInput() {
        lock.withLock {
            inputEpoch += 1
            queuedInputBytes = 0
        }
    }

    /// Detaches this client only; the session and its process keep running.
    public func close() {
        finish(.detached)
    }

    /// Runs first on `writer`, so no frame is encoded before the wire is known.
    private func resolveWire() {
        guard !lock.withLock({ isClosed }) else { return }
        let detected: ZmxIPC.Wire
        switch probe() {
        case .v1: detected = .v1
        case .preFreeze: detected = .preFreeze
        case .unreachable:
            finish(.unreachable)
            return
        }
        lock.withLock { self.wire = detected }
        wireResolved.signal()
    }

    private func sendCapture() {
        lock.lock()
        captureCount += 1
        let token = captureCount
        lock.unlock()
        // Resyncs only start after the first snapshot, so the wire is known
        // and their deadline can run from now. The first capture's deadline
        // starts once the probe is done, so a slow probe never eats it.
        if token > 1 { scheduleCaptureDeadline(token: token) }
        writer.async { [self] in
            guard let wire = lock.withLock({ isClosed ? nil : self.wire }) else { return }
            if token == 1 { scheduleCaptureDeadline(token: token) }
            let frame = ZmxIPC.captureRequest(scrollbackRows: scrollbackRows, wire: wire)
            if !socket.write(frame) { finish(.targetExited) }
        }
    }

    private func scheduleCaptureDeadline(token: Int) {
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
        wireResolved.wait()
        // No wire means the client already finished (unreachable or closed
        // during the probe) and delivered `.closed`.
        guard let wire = lock.withLock({ isClosed ? nil : self.wire }) else { return }
        var decoder = ZmxFrameDecoder(wire: wire)
        while true {
            guard let chunk = socket.read(), !chunk.isEmpty else {
                finish(.targetExited)
                return
            }
            let frames: [ZmxFrame]
            do {
                frames = try decoder.push(chunk)
            } catch ZmxFrameDecoder.Failure.unsupportedVersion(let version) {
                finish(.protocolError("unsupported zmx protocol version \(version)"))
                return
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
        // Unblocks a reader still waiting for the probe.
        wireResolved.signal()
        socket.shutdown()
        delivery.lock()
        onEvent(.closed(reason))
        delivery.unlock()
    }
}
