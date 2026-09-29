import Testing
import Foundation
@testable import Alas

@MainActor
struct RemoteKeepAwakeControllerTests {
    @Test func followsPowerAndServerAvailabilityWithoutDuplicateAssertions() {
        let power = PowerState()
        var created = 0
        var released: [UInt32] = []
        let controller = RemoteKeepAwakeController(
            isOnExternalPower: { power.external },
            createAssertion: {
                created += 1
                return UInt32(created)
            },
            releaseAssertion: { released.append($0) },
            createPowerSource: { _ in Self.powerSource() }
        )
        controller.update(enabled: true, serverRunning: true)
        #expect(created == 0)
        power.external = true
        controller.powerSourceChanged()
        controller.update(enabled: true, serverRunning: true)
        #expect(created == 1)
        power.external = false
        controller.powerSourceChanged()
        #expect(released == [1])
        power.external = true
        controller.powerSourceChanged()
        #expect(created == 2)
        controller.update(enabled: true, serverRunning: false)
        #expect(released == [1, 2])
        controller.powerSourceChanged()
        #expect(created == 2)
        controller.update(enabled: true, serverRunning: true)
        controller.update(enabled: false, serverRunning: true)
        #expect(released == [1, 2, 3])
    }

    @Test func failedAssertionCanRetryAndTeardownReleasesIt() {
        var attempts = 0
        var released: [UInt32] = []
        var controller: RemoteKeepAwakeController? = RemoteKeepAwakeController(
            isOnExternalPower: { true },
            createAssertion: {
                attempts += 1
                return attempts == 1 ? nil : 42
            },
            releaseAssertion: { released.append($0) },
            createPowerSource: { _ in Self.powerSource() }
        )
        controller?.update(enabled: true, serverRunning: true)
        #expect(released.isEmpty)
        controller?.update(enabled: true, serverRunning: true)
        #expect(attempts == 2)
        controller = nil
        #expect(released == [42])
    }

    @Test func unavailablePowerNotificationsNeverPreventSleep() {
        var attempts = 0
        let controller = RemoteKeepAwakeController(
            isOnExternalPower: { true },
            createAssertion: {
                attempts += 1
                return 1
            },
            releaseAssertion: { _ in },
            createPowerSource: { _ in nil }
        )
        controller.update(enabled: true, serverRunning: true)
        #expect(attempts == 0)
    }

    private static func powerSource() -> CFRunLoopSource? {
        var context = CFRunLoopSourceContext()
        return CFRunLoopSourceCreate(nil, 0, &context)
    }

    @MainActor private final class PowerState {
        var external = false
    }
}
