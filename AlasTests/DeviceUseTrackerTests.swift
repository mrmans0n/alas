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
}
