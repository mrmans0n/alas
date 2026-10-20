import Foundation
import AlasFoundation
import AlasModel

/// The time source local-text inference schedules unloads and retries against.
public struct LocalTextClock: Sendable {
    public var now: @Sendable () -> ContinuousClock.Instant = { .now }
    public var sleep: @Sendable (ContinuousClock.Instant) async throws -> Void = {
        try await ContinuousClock().sleep(until: $0)
    }

    public init(now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }, sleep: @escaping @Sendable (ContinuousClock.Instant) async throws -> Void = {
        try await ContinuousClock().sleep(until: $0)
    }) {
        self.now = now
        self.sleep = sleep
    }
}
