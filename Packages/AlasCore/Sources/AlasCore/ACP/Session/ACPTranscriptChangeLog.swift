import Foundation

/// Records which transcript message indices mutated so remote-web gateways
/// can send incremental deltas instead of full re-snapshots.
///
/// Indices recorded here never go stale: every index-shifting operation
/// (prepend, removal, wholesale replacement) is recorded as *structural*,
/// which bumps `epoch`, clears the log, and forces consumers to take a
/// fresh tail snapshot. Recording is refcount-gated so the transcript pays
/// zero diff cost when no remote client is subscribed.
@MainActor
public final class ACPTranscriptChangeLog {
    public enum Changes: Equatable, Sendable {
        case none
        case resync
        case dirty([Int])   // distinct dirty message indices, ascending
    }

    /// Transcript generation. Bumped on any structural change; a consumer
    /// holding a stale epoch must re-snapshot.
    public private(set) var epoch: Int = 0
    /// Monotonic mutation counter. Consumers read "changes since version".
    public private(set) var latestVersion: Int = 0
    /// Ring of (version, index) entries; consecutive records of the same
    /// index coalesce by bumping the tail entry's version in place, so a
    /// streaming burst occupies one slot.
    private var entries: [(version: Int, index: Int)] = []
    /// Highest version dropped from `entries`; a consumer behind this
    /// cannot be served incrementally.
    private var prunedThrough: Int = 0
    private var trackingRefCount = 0

    public static let maxEntries = 1024

    public var isTracking: Bool { trackingRefCount > 0 }

    public func retainTracking() { trackingRefCount += 1 }

    public func releaseTracking() {
        trackingRefCount = max(0, trackingRefCount - 1)
        if trackingRefCount == 0 {
            // Untracked changes move no version, so a revision from before
            // this point would look current; a new epoch makes it stale.
            epoch += 1
            entries.removeAll()
            prunedThrough = latestVersion
        }
    }

    public func record(index: Int) {
        guard isTracking else { return }
        latestVersion += 1
        if let last = entries.last, last.index == index {
            entries[entries.count - 1].version = latestVersion
        } else {
            entries.append((latestVersion, index))
            if entries.count > Self.maxEntries {
                prunedThrough = entries.removeFirst().version
            }
        }
    }

    public func recordStructural() {
        guard isTracking else { return }
        epoch += 1
        latestVersion += 1
        entries.removeAll()
        prunedThrough = latestVersion
    }

    public func changes(since: Int) -> Changes {
        if since >= latestVersion { return .none }
        if since < prunedThrough { return .resync }
        let dirty = Set(entries.filter { $0.version > since }.map(\.index))
        // Defensive: a consumer inside the retained window should always
        // find entries; an empty result means bookkeeping drifted — resync.
        return dirty.isEmpty ? .resync : .dirty(dirty.sorted())
    }

    public init() {}
}
