import Foundation

public enum SessionRecapPolicy {
    public static let minimumCompleteTurns = 3

    /// `lastSeenAt` nil falls back to `updatedAt`.
    public static func shouldOffer(
        lastSeenAt: Date?,
        updatedAt: Date,
        now: Date,
        threshold: SessionRecapThreshold,
        isIdle: Bool,
        completeTurnCount: Int
    ) -> Bool {
        guard let duration = threshold.duration, isIdle,
              completeTurnCount >= minimumCompleteTurns else { return false }
        let components = duration.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        return now.timeIntervalSince(lastSeenAt ?? updatedAt) >= seconds
    }
}
