import Testing
@testable import AlasCore

@MainActor
struct ChangeTrackingTests {
    private final class Owner: ChangeTracking {
        nonisolated(unsafe) let willChange = ChangeSignal<Void>()
        @Tracked var count = 0
    }

    @Test func announcesOwnerThenValueBeforeStoring() {
        let owner = Owner()
        var events: [String] = []
        let ownerChange = owner.willChange.observe { events.append("owner:\(owner.count)") }
        let valueChange = owner.$count.signal.observe { events.append("value:\($0) stored:\(owner.count)") }

        owner.count = 1

        #expect(events == ["owner:0", "value:1 stored:0"])
        #expect(owner.count == 1)
        _ = (ownerChange, valueChange)
    }

    @Test func cancelledOrReleasedSubscriptionsStopObserving() {
        let owner = Owner()
        var cancelledCalls = 0
        var releasedCalls = 0
        let cancelled = owner.willChange.observe { cancelledCalls += 1 }
        var released: ChangeSubscription? = owner.willChange.observe { releasedCalls += 1 }
        owner.count = 1

        cancelled.cancel()
        released = nil
        owner.count = 2

        #expect(cancelledCalls == 1)
        #expect(releasedCalls == 1)
        _ = released
    }
}
