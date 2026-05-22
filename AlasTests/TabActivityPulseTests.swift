import SwiftUI
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct TabActivityPulseTests {
    @Test func busyStateAppliesOpacityAnimation() {
        let modifier = TabActivityPulse(activityState: .busy)
        #expect(modifier.activityState == .busy)
    }

    @Test func idleStateHasNoAnimation() {
        let modifier = TabActivityPulse(activityState: .idle)
        #expect(modifier.activityState == .idle)
    }

    @Test func nilStateHasNoAnimation() {
        let modifier = TabActivityPulse(activityState: nil)
        #expect(modifier.activityState == nil)
    }
}
