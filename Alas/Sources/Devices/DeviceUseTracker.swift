import Foundation
import Observation

/// Remembers which worktree last used each simulator or emulator, so the
/// sidebar can show the device on that worktree's row. A new use moves
/// ownership; nothing is persisted.
@MainActor
@Observable
final class DeviceUseTracker {
    /// Device id (simulator UDID, Android serial or `avd:<name>`) to the worktree that last used it.
    private(set) var owners: [String: String] = [:]

    func noteUse(deviceID: String, worktreeID: String) {
        guard owners[deviceID] != worktreeID else { return }
        owners[deviceID] = worktreeID
    }

    /// The devices `worktreeID` used last, sorted so the order is stable.
    func devices(ownedBy worktreeID: String) -> [String] {
        owners.filter { $0.value == worktreeID }.map(\.key).sorted()
    }
}
