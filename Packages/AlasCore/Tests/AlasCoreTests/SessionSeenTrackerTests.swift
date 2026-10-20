import Foundation
import Testing
@testable import AlasCore
@testable import AlasHostCore

@MainActor
struct SessionSeenTrackerTests {
    private final class Clock {
        var seconds: TimeInterval = 0
    }

    @MainActor
    private final class Harness {
        private let clock = Clock()
        var events: [SessionSeenTracker.Event] = []
        let tracker: SessionSeenTracker

        var now: TimeInterval {
            get { clock.seconds }
            set { clock.seconds = newValue }
        }

        init(appActive: Bool = true) {
            tracker = SessionSeenTracker(
                now: { [clock] in Date(timeIntervalSince1970: clock.seconds) },
                appActive: appActive
            )
            tracker.onEvent = { [unowned self] in self.events.append($0) }
        }
    }

    private static func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    /// (10, 20) is a normal absence; (1, 2) is rapid tab switching, where the
    /// tracker still reports the absence and the recap policy rejects it.
    @Test(arguments: [(10.0, 20.0), (1.0, 2.0)])
    func hidingThenShowingReportsTheLastSeenInstant(hiddenAt: TimeInterval, shownAt: TimeInterval) {
        let h = Harness()
        h.tracker.setVisible(true, sessionId: "A")
        h.now = hiddenAt
        h.tracker.setVisible(false, sessionId: "A")
        h.now = shownAt
        h.tracker.setVisible(true, sessionId: "A")

        #expect(h.events == [
            .becameSeen(sessionId: "A", awayFrom: nil),
            .becameUnseen(sessionId: "A", at: Self.at(hiddenAt)),
            .becameSeen(sessionId: "A", awayFrom: Self.at(hiddenAt)),
        ])
    }

    @Test func visibleTabIsNotSeenUntilTheAppActivates() {
        let h = Harness(appActive: false)
        h.tracker.setVisible(true, sessionId: "A")
        #expect(h.events.isEmpty)
        #expect(!h.tracker.isSeen("A"))

        h.tracker.setAppActive(true)

        #expect(h.events == [.becameSeen(sessionId: "A", awayFrom: nil)])
        #expect(h.tracker.isSeen("A"))
    }

    @Test func appDeactivationTurnsVisibleSessionsUnseenUntilReactivation() {
        let h = Harness()
        h.tracker.setVisible(true, sessionId: "A")
        h.now = 5
        h.tracker.setAppActive(false)
        h.now = 50_000
        h.tracker.setAppActive(true)

        #expect(h.events == [
            .becameSeen(sessionId: "A", awayFrom: nil),
            .becameUnseen(sessionId: "A", at: Self.at(5)),
            .becameSeen(sessionId: "A", awayFrom: Self.at(5)),
        ])
    }
}
