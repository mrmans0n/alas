import Testing
import Foundation
@testable import AlasCore
@testable import AlasHostCore

struct SessionRecapPolicyTests {
    struct Case: Sendable {
        let name: String
        let lastSeenAgo: TimeInterval?
        let updatedAgo: TimeInterval
        let threshold: SessionRecapThreshold
        let idle: Bool
        let turns: Int
        let expected: Bool
    }

    static let minute: TimeInterval = 60
    static let hour: TimeInterval = 3600

    static let cases: [Case] = [
        Case(name: "just under threshold", lastSeenAgo: 2 * hour - minute, updatedAgo: 5 * hour,
             threshold: .twoHours, idle: true, turns: 5, expected: false),
        Case(name: "exactly at threshold is inclusive", lastSeenAgo: 2 * hour, updatedAgo: 5 * hour,
             threshold: .twoHours, idle: true, turns: 5, expected: true),
        Case(name: "off never offers", lastSeenAgo: 100 * hour, updatedAgo: 100 * hour,
             threshold: .off, idle: true, turns: 5, expected: false),
        Case(name: "busy session never offers", lastSeenAgo: 5 * hour, updatedAgo: 5 * hour,
             threshold: .twoHours, idle: false, turns: 5, expected: false),
        Case(name: "too few turns", lastSeenAgo: 5 * hour, updatedAgo: 5 * hour,
             threshold: .twoHours, idle: true, turns: 2, expected: false),
        Case(name: "minimum turns offers", lastSeenAgo: 5 * hour, updatedAgo: 5 * hour,
             threshold: .twoHours, idle: true, turns: 3, expected: true),
        Case(name: "nil lastSeenAt falls back to updatedAt", lastSeenAgo: nil, updatedAgo: 3 * hour,
             threshold: .twoHours, idle: true, turns: 5, expected: true),
        Case(name: "nil lastSeenAt and recent update", lastSeenAgo: nil, updatedAgo: hour,
             threshold: .twoHours, idle: true, turns: 5, expected: false),
        Case(name: "lastSeenAt wins over old updatedAt", lastSeenAgo: hour, updatedAgo: 10 * hour,
             threshold: .twoHours, idle: true, turns: 5, expected: false),
        Case(name: "thirty minutes", lastSeenAgo: 31 * minute, updatedAgo: 31 * minute,
             threshold: .thirtyMinutes, idle: true, turns: 5, expected: true),
        Case(name: "eight hours", lastSeenAgo: 7 * hour, updatedAgo: 7 * hour,
             threshold: .eightHours, idle: true, turns: 5, expected: false),
    ]

    @Test(arguments: cases)
    func shouldOffer(_ c: Case) {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let result = SessionRecapPolicy.shouldOffer(
            lastSeenAt: c.lastSeenAgo.map { now.addingTimeInterval(-$0) },
            updatedAt: now.addingTimeInterval(-c.updatedAgo),
            now: now,
            threshold: c.threshold,
            isIdle: c.idle,
            completeTurnCount: c.turns
        )
        #expect(result == c.expected, "\(c.name)")
    }
}
