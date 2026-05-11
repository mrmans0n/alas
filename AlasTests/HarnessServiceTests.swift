import Testing
import Foundation
@testable import Alas

struct HarnessServiceTests {
    @Test func awaitingPingPlaysOnlyWhenEnteringAwaitingState() {
        let service = HarnessService()
        var pingCount = 0
        service.notifications.awaitingPingPlayer = {
            pingCount += 1
        }

        let awaiting = HookEvent(sessionId: "session-1", kind: "awaiting", timestamp: Date(), summary: nil)

        service.handleHookEvent(awaiting, stateLookup: { _ in nil }, shouldNotifyOnAwaiting: { true })
        service.handleHookEvent(awaiting, stateLookup: { _ in nil }, shouldNotifyOnAwaiting: { true })

        #expect(service.stateBySession["session-1"] == "awaiting")
        #expect(pingCount == 1)
    }

    @Test func awaitingPingRespectsPreference() {
        let service = HarnessService()
        var pingCount = 0
        service.notifications.awaitingPingPlayer = {
            pingCount += 1
        }

        let awaiting = HookEvent(sessionId: "session-1", kind: "awaiting", timestamp: Date(), summary: nil)

        service.handleHookEvent(awaiting, stateLookup: { _ in nil }, shouldNotifyOnAwaiting: { false })

        #expect(service.stateBySession["session-1"] == "awaiting")
        #expect(pingCount == 0)
    }
}
