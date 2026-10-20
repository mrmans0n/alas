import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform

/// Polling cadence for shepherd records.
public enum ShepherdSchedule {
    /// One timer evaluates which records are due.
    public static let tick: TimeInterval = 30
    public static let maxConcurrentFetches = 2

    private static let activeInterval: TimeInterval = 30
    private static let watchingInterval: TimeInterval = 120
    private static let stalledInterval: TimeInterval = 300
    private static let maxBackoff: TimeInterval = 600

    /// 30 s while CI runs or a fix or merge is in flight, 2 min while
    /// watching a settled PR, 5 min when escalated or paused, nil for
    /// terminal records (not polled).
    public static func interval(for record: ShepherdRecord, checksPending: Bool) -> TimeInterval? {
        switch record.phase {
        case .merged, .closed:
            nil
        case .escalated, .paused:
            stalledInterval
        case .fixing, .awaitingPush, .merging, .queued:
            activeInterval
        case .watching:
            checksPending ? activeInterval : watchingInterval
        }
    }

    /// Delay after `count` consecutive provider errors: 30 s * 2^(count-1),
    /// capped at 10 min. Zero failures means no delay.
    public static func backoff(afterFailures count: Int) -> TimeInterval {
        guard count > 0 else { return 0 }
        let exponent = min(count - 1, 5)
        return min(tick * Double(1 << exponent), maxBackoff)
    }
}
