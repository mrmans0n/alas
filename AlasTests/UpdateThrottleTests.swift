import Foundation
import Testing
@testable import Alas

struct UpdateThrottleTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func skipsWhenDisabled() {
        #expect(UpdateThrottle.shouldCheck(enabled: false, lastCheckedAt: nil, now: now) == false)
    }

    @Test func checksWhenEnabledAndNeverChecked() {
        #expect(UpdateThrottle.shouldCheck(enabled: true, lastCheckedAt: nil, now: now) == true)
    }

    @Test func skipsWithinInterval() {
        let recent = now.addingTimeInterval(-3600) // 1h ago
        #expect(UpdateThrottle.shouldCheck(enabled: true, lastCheckedAt: recent, now: now) == false)
    }

    @Test func checksAfterInterval() {
        let stale = now.addingTimeInterval(-25 * 3600) // 25h ago
        #expect(UpdateThrottle.shouldCheck(enabled: true, lastCheckedAt: stale, now: now) == true)
    }

    @Test func checksExactlyAtInterval() {
        let exactly = now.addingTimeInterval(-UpdateThrottle.interval)
        #expect(UpdateThrottle.shouldCheck(enabled: true, lastCheckedAt: exactly, now: now) == true)
    }
}
