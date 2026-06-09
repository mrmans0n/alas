import Foundation
import Testing
@testable import Alas

@Suite
struct OpenSessionsTests {
    // MARK: - relativeAge

    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func relativeAgeNilWhenNoTimestamp() {
        #expect(relativeAge(createdEpoch: nil, now: now) == nil)
    }

    @Test func relativeAgeNilWhenInFuture() {
        #expect(relativeAge(createdEpoch: 1_000_100, now: now) == nil)
    }

    @Test func relativeAgeJustNowUnderAMinute() {
        #expect(relativeAge(createdEpoch: 1_000_000 - 30, now: now) == "just now")
    }

    @Test func relativeAgeMinutes() {
        #expect(relativeAge(createdEpoch: 1_000_000 - 5 * 60, now: now) == "5m ago")
    }

    @Test func relativeAgeHours() {
        #expect(relativeAge(createdEpoch: 1_000_000 - 3 * 3600, now: now) == "3h ago")
    }

    @Test func relativeAgeDays() {
        #expect(relativeAge(createdEpoch: 1_000_000 - 2 * 86_400, now: now) == "2d ago")
    }
}
