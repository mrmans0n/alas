import Foundation

/// Pure decision for whether an automatic update check should run.
enum UpdateThrottle {
    /// Minimum spacing between automatic checks (24h).
    static let interval: TimeInterval = 24 * 60 * 60

    static func shouldCheck(
        enabled: Bool,
        lastCheckedAt: Date?,
        now: Date,
        interval: TimeInterval = UpdateThrottle.interval
    ) -> Bool {
        guard enabled else { return false }
        guard let last = lastCheckedAt else { return true }
        return now.timeIntervalSince(last) >= interval
    }
}
