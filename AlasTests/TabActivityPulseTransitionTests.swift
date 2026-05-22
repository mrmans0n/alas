import SwiftUI
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct TabActivityPulseTransitionTests {
    @Test func opacityDiffersBetweenBusyAndIdle() {
        let busy = TabActivityPulse(activityState: .busy)
        let idle = TabActivityPulse(activityState: .idle)
        #expect(busy.targetOpacity != idle.targetOpacity)
    }

    @Test func opacityDiffersBetweenAwaitingInputAndBusy() {
        let awaiting = TabActivityPulse(activityState: .awaitingInput)
        let busy = TabActivityPulse(activityState: .busy)
        #expect(awaiting.targetOpacity != busy.targetOpacity)
    }

    @Test func nilStateMatchesIdleOpacity() {
        let nilState = TabActivityPulse(activityState: nil)
        let idle = TabActivityPulse(activityState: .idle)
        #expect(nilState.targetOpacity == idle.targetOpacity)
    }
}
