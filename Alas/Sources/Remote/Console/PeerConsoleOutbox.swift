import Foundation

/// Bounded, sequenced output queue between one passive zmx client and one
/// peer connection.
///
/// The zmx reader appends without ever blocking, so local draining never
/// depends on the peer. When pending output exceeds its byte or message
/// limit, it is discarded and the attachment needs a fresh snapshot. The
/// `Capture` is requested only once nothing is in flight to the peer, and at
/// most one capture is outstanding at a time. Sequences are contiguous per
/// attachment; a snapshot restarts the run.
struct PeerConsoleOutbox {
    struct Limits: Sendable {
        var maxPendingBytes = 2 * 1024 * 1024
        var maxPendingMessages = 4096
        /// Bytes handed to the connection but not yet written to the socket.
        var maxInFlightBytes = 512 * 1024
        var maxChunkBytes = 64 * 1024
    }

    enum Action: Equatable, Sendable {
        case snapshot(sequence: Int, reason: PeerConsoleSnapshotReason, data: Data)
        case output(sequence: Int, data: Data)
        case requestCapture
    }

    private let limits: Limits
    private var nextSequence = 0
    private var pending: [Data] = []
    private var pendingBytes = 0
    private(set) var inFlightBytes = 0
    /// The passive client requests the initial capture on start.
    private var captureInFlight = true
    private var resyncReason: PeerConsoleSnapshotReason?
    private var snapshotReason = PeerConsoleSnapshotReason.initial

    init(limits: Limits = Limits()) {
        self.limits = limits
    }

    mutating func output(_ data: Data) -> [Action] {
        // Until the next snapshot, deltas would only be discarded on arrival.
        guard resyncReason == nil, !captureInFlight else { return [] }
        pending.append(data)
        pendingBytes += data.count
        if pendingBytes > limits.maxPendingBytes || pending.count > limits.maxPendingMessages {
            return requestResync(.peerBackpressure)
        }
        return pump()
    }

    mutating func snapshot(_ data: Data) -> [Action] {
        captureInFlight = false
        resyncReason = nil
        pending.removeAll()
        pendingBytes = 0
        let sequence = nextSequence
        nextSequence += 1
        inFlightBytes += data.count
        return [.snapshot(sequence: sequence, reason: snapshotReason, data: data)] + pump()
    }

    /// The connection finished writing `bytes` of a previous action.
    mutating func delivered(bytes: Int) -> [Action] {
        inFlightBytes = max(0, inFlightBytes - bytes)
        return pump()
    }

    /// Drops pending deltas; a replacement snapshot follows once the peer is
    /// writable. Repeated requests coalesce into one capture.
    mutating func requestResync(_ reason: PeerConsoleSnapshotReason) -> [Action] {
        pending.removeAll()
        pendingBytes = 0
        if resyncReason == nil, !captureInFlight { resyncReason = reason }
        return pump()
    }

    private mutating func pump() -> [Action] {
        if let reason = resyncReason {
            guard inFlightBytes == 0, !captureInFlight else { return [] }
            captureInFlight = true
            snapshotReason = reason
            resyncReason = nil
            return [.requestCapture]
        }
        var actions: [Action] = []
        while !pending.isEmpty, inFlightBytes < limits.maxInFlightBytes {
            var chunk = Data()
            var taken = 0
            for next in pending {
                guard chunk.isEmpty || chunk.count + next.count <= limits.maxChunkBytes else { break }
                chunk.append(next)
                taken += 1
            }
            pending.removeFirst(taken)
            pendingBytes -= chunk.count
            inFlightBytes += chunk.count
            actions.append(.output(sequence: nextSequence, data: chunk))
            nextSequence += 1
        }
        return actions
    }
}
