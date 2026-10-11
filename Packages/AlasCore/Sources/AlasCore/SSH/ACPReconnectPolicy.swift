import Foundation

/// Bounded retry schedule for remote ACP sessions whose SSH channel drops.
public enum ACPReconnectPolicy: Sendable {
    public static let delays: [TimeInterval] = [2, 5, 15, 30, 60]

    public static func delay(forAttempt attempt: Int) -> TimeInterval? {
        guard attempt >= 0, attempt < delays.count else { return nil }
        return delays[attempt]
    }
}
