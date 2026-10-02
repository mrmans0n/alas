import Testing
@testable import Alas

@MainActor
struct ACPDelayedHoverVisibilityTests {
    @Test("reset clears retained hover immediately", arguments: [false, true])
    func resetClearsImmediately(withPendingHide: Bool) {
        let visibility = ACPDelayedHoverVisibility(hideDelayNanoseconds: 10_000_000_000)
        visibility.enter()
        if withPendingHide { visibility.leave() }

        visibility.reset()

        #expect(!visibility.isVisible)
        visibility.enter()
        #expect(visibility.isVisible)
    }

    @Test func enterShowsImmediately() {
        let visibility = ACPDelayedHoverVisibility(hideDelayNanoseconds: 1_000_000)

        visibility.enter()

        #expect(visibility.isVisible)
    }

    @Test func leaveHidesAfterDelay() async throws {
        let visibility = ACPDelayedHoverVisibility(hideDelayNanoseconds: 5_000_000)
        visibility.enter()

        visibility.leave()
        #expect(visibility.isVisible)

        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(!visibility.isVisible)
    }

    @Test func enterCancelsPendingHide() async throws {
        let visibility = ACPDelayedHoverVisibility(hideDelayNanoseconds: 100_000_000)
        visibility.enter()

        visibility.leave()
        try await Task.sleep(nanoseconds: 10_000_000)
        visibility.enter()

        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(visibility.isVisible)
    }
}
