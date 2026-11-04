import AlasCore
import Testing

struct StreamSubscriptionsTests {
    /// SwiftUI can create the next worktree's Device screen before it removes
    /// the previous one.
    @Test func aStreamStopsOnlyWhenItsLastScreenLeaves() {
        var subscriptions = StreamSubscriptions()
        #expect(subscriptions.add("sim") == .start)
        #expect(subscriptions.add("sim") == .none)
        #expect(subscriptions.remove("sim") == .none)
        #expect(subscriptions.active == ["sim"])
        #expect(subscriptions.remove("sim") == .stop)
        #expect(subscriptions.active.isEmpty)
    }

    @Test func removingAnUnwatchedDeviceChangesNothing() {
        var subscriptions = StreamSubscriptions()
        #expect(subscriptions.add("a") == .start)
        #expect(subscriptions.remove("b") == .none)
        #expect(subscriptions.active == ["a"])
    }
}
