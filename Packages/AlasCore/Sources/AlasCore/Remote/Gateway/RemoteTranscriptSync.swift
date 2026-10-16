import Foundation

/// Per-connection, per-session sync bookkeeping for incremental transcript
/// delivery: tracks how much of the change log this connection has already
/// been sent (`sentVersion`), which transcript epoch/outgoing delta counter
/// the client is on, and a small FIFO cache of fetched full tool-call content
/// so repeated dirty ticks on other messages don't re-fetch it.
@MainActor
public final class RemoteTranscriptSync {
    public static let tailWindow = ACPTranscript.maxVisibleRows        // 90
    public static let pageLimitRange = 1...200
    /// Above this many dirty messages, a tail re-snapshot is cheaper than a delta.
    public static let dirtyResnapshotThreshold = 200
    public static let toolContentCacheLimit = 128
    /// Leave headroom below the native receiver's 16 MB cap. These budgets
    /// apply to JSON bytes, including escaping of structured message content.
    public static let maxFrameBytes = 8 * 1024 * 1024
    public static let maxMessageBytes = 4 * 1024 * 1024

    public static func payloadBudget(sessionId: String) -> Int {
        // Reserve envelope keys, integer fields, array separators and a
        // federation prefix. Session IDs may require JSON escaping too.
        maxFrameBytes - 1024 - 6 * sessionId.utf8.count
    }

    public var sentVersion = 0     // change-log version covered by the last send
    public var epoch = 0           // transcript epoch the client knows
    public var revision = 0        // per-connection outgoing delta counter
    public var sentBackgroundWorkCancellable = false
    public var sentSupersededBackgroundRows: Set<Int> = []
    /// Bumped every time `sendSnapshot` runs, regardless of whether `epoch`
    /// itself changed. A same-epoch snapshot (e.g. from `takeOver` or a
    /// client resubscribe with no intervening structural change) still
    /// resets `revision`/`sentVersion` out from under a concurrently
    /// suspended dirty delta — an epoch-only guard would miss that case, so
    /// callers that suspend mid-serialize must capture and re-check this
    /// instead of (or in addition to) `epoch`.
    public var generation = 0
    /// The transcript as the gateway has received it from its follow, by
    /// index: the newest messages since the last reset, and older pages the
    /// client fetched. ponytail: never trimmed, so it grows to what the
    /// client has scrolled through; trim to a window if memory matters.
    public var messages: [Int: ACPMessage] = [:]
    public var messageCount = 0
    public var streamingState: ACPSession.StreamingState = .idle
    /// The session's last state from the follow; nil until the first.
    public var sessionState: HostSessionState?
    /// Whether the client has had a snapshot, which deltas build on.
    public var snapshotSent = false
    /// The agent's ids for the requests surfaced under integer wire ids.
    public var requestIDs: [Int: JSONRPCID] = [:]
    private var nextRequestWireID = -2
    private var toolContent: [String: String] = [:]            // toolCallId → full content
    private var toolContentOrder: [String] = []                 // FIFO eviction

    public func cachedToolContent(_ id: String) -> String? { toolContent[id] }
    public func storeToolContent(_ id: String, _ content: String) {
        if toolContent[id] == nil {
            toolContentOrder.append(id)
            if toolContentOrder.count > Self.toolContentCacheLimit {
                toolContent[toolContentOrder.removeFirst()] = nil
            }
        }
        toolContent[id] = content
    }
    public func invalidateToolContent(_ id: String) { toolContent[id] = nil }

    /// The integer a client answers `requestID` by: the agent's own number
    /// when it is one, otherwise a stable negative stand-in.
    public func wireID(for requestID: JSONRPCID) -> Int {
        if case .number(let number) = requestID {
            requestIDs[number] = requestID
            return number
        }
        if let known = requestIDs.first(where: { $0.value == requestID })?.key { return known }
        let wireID = nextRequestWireID
        nextRequestWireID -= 1
        requestIDs[wireID] = requestID
        return wireID
    }

    public init() {}
}
