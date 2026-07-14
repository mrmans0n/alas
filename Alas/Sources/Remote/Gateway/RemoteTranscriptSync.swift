import Foundation

/// Per-connection, per-session sync bookkeeping for incremental transcript
/// delivery: tracks how much of the change log this connection has already
/// been sent (`sentVersion`), which transcript epoch/outgoing delta counter
/// the client is on, and a small FIFO cache of fetched full tool-call content
/// so repeated dirty ticks on other messages don't re-fetch it.
@MainActor
final class RemoteTranscriptSync {
    static let tailWindow = ACPTranscript.maxVisibleRows        // 90
    static let pageLimitRange = 1...200
    /// Above this many dirty messages, a tail re-snapshot is cheaper than a delta.
    static let dirtyResnapshotThreshold = 200
    static let toolContentCacheLimit = 128

    var sentVersion = 0     // change-log version covered by the last send
    var epoch = 0           // transcript epoch the client knows
    var revision = 0        // per-connection outgoing delta counter
    /// Bumped every time `sendSnapshot` runs, regardless of whether `epoch`
    /// itself changed. A same-epoch snapshot (e.g. from `takeOver` or a
    /// client resubscribe with no intervening structural change) still
    /// resets `revision`/`sentVersion` out from under a concurrently
    /// suspended dirty delta — an epoch-only guard would miss that case, so
    /// callers that suspend mid-serialize must capture and re-check this
    /// instead of (or in addition to) `epoch`.
    var generation = 0
    private var toolContent: [String: String] = [:]            // toolCallId → full content
    private var toolContentOrder: [String] = []                 // FIFO eviction

    func cachedToolContent(_ id: String) -> String? { toolContent[id] }
    func storeToolContent(_ id: String, _ content: String) {
        if toolContent[id] == nil {
            toolContentOrder.append(id)
            if toolContentOrder.count > Self.toolContentCacheLimit {
                toolContent[toolContentOrder.removeFirst()] = nil
            }
        }
        toolContent[id] = content
    }
    func invalidateToolContent(_ id: String) { toolContent[id] = nil }
}
