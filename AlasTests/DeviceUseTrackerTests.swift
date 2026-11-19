import AlasCore
import Testing
@testable import Alas

@MainActor
struct DeviceUseTrackerTests {
    @Test func deviceBelongsToItsLastUser() {
        let tracker = DeviceUseTracker()
        tracker.noteUse(deviceID: "A-udid", worktreeID: "wt-a")
        tracker.noteUse(deviceID: "A-udid", worktreeID: "wt-b")
        tracker.noteUse(deviceID: "P-1", worktreeID: "wt-a")
        #expect(tracker.devices(ownedBy: "wt-a") == ["P-1"])
        #expect(tracker.devices(ownedBy: "wt-b") == ["A-udid"])
    }

    /// An emulator used by its AVD name and then by its serial belongs to the
    /// second user under both ids, whichever came first.
    @Test(arguments: [("avd:Pixel_9", "emulator-5554"), ("emulator-5554", "avd:Pixel_9")])
    func emulatorAliasesMoveTogether(first: String, second: String) {
        let running = [AndroidDevice(serial: "emulator-5554", state: .ready, model: nil, avdName: "Pixel_9")]
        let tracker = DeviceUseTracker()
        tracker.noteUse(deviceID: first, aliases: DeviceUseTracker.aliases(of: first, running: running), worktreeID: "wt-a")
        tracker.noteUse(deviceID: second, aliases: DeviceUseTracker.aliases(of: second, running: running), worktreeID: "wt-b")
        #expect(tracker.devices(ownedBy: "wt-a").isEmpty)
        #expect(tracker.devices(ownedBy: "wt-b") == ["avd:Pixel_9", "emulator-5554"])
    }
}
