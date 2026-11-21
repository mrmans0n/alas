import Foundation

/// Keeps one request of a kind in flight. Its replies don't say which request they answer, and the
/// host drops a repeat of one still queued, so overlapping requests could leave an older answer showing.
/// A request asked for meanwhile is sent once the reply lands, in place of showing that reply.
public struct RemoteSingleFlight: Sendable {
    /// How long an unanswered request holds the next; a reply lost without a disconnect would otherwise hold them all.
    public static let patience: Duration = .seconds(30)

    private var sentAt: ContinuousClock.Instant?
    private var again = false

    public init() {}

    /// True when the request should go out now; false when it waits for the one in flight.
    public mutating func shouldSend(now: ContinuousClock.Instant = .now) -> Bool {
        if let sentAt, now - sentAt < Self.patience {
            again = true
            return false
        }
        sentAt = now
        again = false
        return true
    }

    /// A reply landed. True when a newer request waited: send it, and don't show this reply.
    public mutating func landed() -> Bool {
        sentAt = nil
        defer { again = false }
        return again
    }

    /// The host forgot what it was asked, as after a reconnect.
    public mutating func reset() { self = Self() }
}
