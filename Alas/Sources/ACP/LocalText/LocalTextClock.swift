import Foundation

/// The time source local-text inference schedules unloads and retries against.
struct LocalTextClock: Sendable {
    var now: @Sendable () -> ContinuousClock.Instant = { .now }
    var sleep: @Sendable (ContinuousClock.Instant) async throws -> Void = {
        try await ContinuousClock().sleep(until: $0)
    }
}
