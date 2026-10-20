import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasIntegrations

package struct ACPTranscriptScrollMemory: Equatable {
    package var anchorMessageId: String?
    /// ACP view ids for persisted text rows are regenerated during hydration;
    /// the transcript index is the durable restore target across eviction.
    package var anchorMessageIndex: Int?
    package var followsTail: Bool

    public init(anchorMessageId: String? = nil, anchorMessageIndex: Int? = nil, followsTail: Bool) {
        self.anchorMessageId = anchorMessageId
        self.anchorMessageIndex = anchorMessageIndex
        self.followsTail = followsTail
    }
}

package enum ACPMirrorRefreshPolicy {
    static package let debounceNanos: UInt64 = 100_000_000
    static package let activePollNanos: UInt64 = 2_500_000_000
    static package let inactivePollNanos: UInt64 = 30_000_000_000
}

package struct ACPMirrorMessageDelta: Sendable {
    package let previousCount: Int
    package let changedRange: Range<Int>?

    static package func compare(
        previous: [ACPMirrorMessageFingerprint],
        current: [ACPMirrorMessageFingerprint]
    ) -> Self {
        var prefixCount = 0
        let sharedCount = min(previous.count, current.count)
        while prefixCount < sharedCount,
              previous[prefixCount] == current[prefixCount] {
            prefixCount += 1
        }
        guard prefixCount != previous.count || prefixCount != current.count else {
            return Self(previousCount: previous.count, changedRange: nil)
        }

        var suffixCount = 0
        while suffixCount < sharedCount - prefixCount,
              previous[previous.count - suffixCount - 1] == current[current.count - suffixCount - 1] {
            suffixCount += 1
        }
        let changedEnd = max(previous.count - suffixCount, current.count - suffixCount)
        return Self(previousCount: previous.count, changedRange: prefixCount..<changedEnd)
    }

    public init(previousCount: Int, changedRange: Range<Int>?) {
        self.previousCount = previousCount
        self.changedRange = changedRange
    }
}

package struct ACPMirrorSnapshotComparison: Sendable {
    package let snapshot: [ACPMirrorMessageFingerprint]
    package let delta: ACPMirrorMessageDelta?

    public init(snapshot: [ACPMirrorMessageFingerprint], delta: ACPMirrorMessageDelta?) {
        self.snapshot = snapshot
        self.delta = delta
    }
}

package struct ACPForkFallbackPersistenceError: LocalizedError {
    let underlying: any Error

    package var errorDescription: String? {
        "Failed to persist fork fallback: \(underlying.localizedDescription)"
    }

    public init(underlying: any Error) {
        self.underlying = underlying
    }
}

public enum ACPSessionForkCreationError: Error, Equatable, Sendable {
    case sourceUnavailable
    case sourceReadOnly
}

/// Decides, exactly once, whether a visual answer's prompt is sent. The send commits right after its
/// lease check; a Stop or the registration timeout cancels first. Whichever transition happens first
/// wins, under the lock, because cancellation runs off the main actor while the task is suspended.
public final class VisualAidAnswerCancellation: @unchecked Sendable {
    private enum State { case pending, committed, cancelled }

    private let lock = NSLock()
    private var state = State.pending

    public var isCancelled: Bool {
        lock.withLock { state == .cancelled }
    }

    /// True when the send may proceed: pending becomes committed, and committed stays committed.
    public func commit() -> Bool {
        lock.withLock {
            switch state {
            case .pending:
                state = .committed
                return true
            case .committed: return true
            case .cancelled: return false
            }
        }
    }

    /// True when the send is now (or already) cancelled; false when it had already committed.
    public func cancelIfNotCommitted() -> Bool {
        lock.withLock {
            switch state {
            case .pending:
                state = .cancelled
                return true
            case .committed: return false
            case .cancelled: return true
            }
        }
    }

    public init() {}
}

/// Thread-safe ring of stderr bytes from the agent process. Keeps the last
/// ~2 KB so we can surface useful context when initialize/new fails.
package final class StderrBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private let cap = 2048
    package func append(_ d: Data) {
        lock.lock()
        defer { lock.unlock() }
        bytes.append(d)
        if bytes.count > cap {
            bytes.removeSubrange(0..<(bytes.count - cap))
        }
    }
    package func tail() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: bytes, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    public init() {}
}
