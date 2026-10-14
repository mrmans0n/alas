import Foundation
import Testing
@testable import AlasCore

private typealias F = ShepherdFixtures

struct ShepherdIntervalCase: Sendable, CustomTestStringConvertible {
    let phase: ShepherdPhase
    let checksPending: Bool
    let expected: TimeInterval?
    var testDescription: String { "\(phase), checks pending: \(checksPending)" }
}

private let intervalCases: [ShepherdIntervalCase] = [
    .init(phase: .watching, checksPending: false, expected: 120),
    .init(phase: .watching, checksPending: true, expected: 30),
    .init(phase: .fixing(dispatchedAt: F.earlier), checksPending: false, expected: 30),
    .init(phase: .awaitingPush(turnEndedAt: F.earlier, pollsWithoutProgress: 1), checksPending: false, expected: 30),
    .init(phase: .merging, checksPending: false, expected: 30),
    .init(phase: .queued, checksPending: false, expected: 30),
    .init(phase: .escalated(.noProgress), checksPending: true, expected: 300),
    .init(phase: .paused, checksPending: false, expected: 300),
    .init(phase: .merged, checksPending: false, expected: nil),
    .init(phase: .closed, checksPending: true, expected: nil),
]

@Suite struct ShepherdScheduleTests {
    @Test("poll interval follows the record phase", arguments: intervalCases)
    func interval(_ c: ShepherdIntervalCase) {
        #expect(ShepherdSchedule.interval(for: F.record(phase: c.phase), checksPending: c.checksPending) == c.expected)
    }

    @Test("provider failures back off exponentially up to ten minutes", arguments: [
        (0, 0.0), (1, 30.0), (2, 60.0), (3, 120.0), (5, 480.0), (6, 600.0), (40, 600.0),
    ] as [(Int, TimeInterval)])
    func backoff(failures: Int, expected: TimeInterval) {
        #expect(ShepherdSchedule.backoff(afterFailures: failures) == expected)
    }
}
