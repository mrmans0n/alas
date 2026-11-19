import AlasCore
import Foundation
import Observation
import SwiftUI

/// Remembers which worktree last used each simulator or emulator, so the
/// sidebar can show the device on that worktree's row. A new use moves
/// ownership; nothing is persisted.
@MainActor
@Observable
final class DeviceUseTracker {
    /// Device id (simulator UDID, Android serial or `avd:<name>`) to the worktree that last used it.
    private(set) var owners: [String: String] = [:]

    /// `aliases` are the device's other ids, such as a running emulator's
    /// serial for `avd:<name>`. They move with it, so the previous user of an
    /// alias stops showing the device.
    func noteUse(deviceID: String, aliases: [String] = [], worktreeID: String) {
        for id in [deviceID] + aliases where owners[id] != worktreeID {
            owners[id] = worktreeID
        }
    }

    /// The devices `worktreeID` used last, sorted so the order is stable.
    func devices(ownedBy worktreeID: String) -> [String] {
        owners.filter { $0.value == worktreeID }.map(\.key).sorted()
    }

    /// A running emulator's other id: its serial for `avd:<name>`, its
    /// `avd:<name>` for its serial. Simulators and phones have none.
    nonisolated static func aliases(of deviceID: String, running: [AndroidDevice]) -> [String] {
        if deviceID.hasPrefix("avd:") {
            let avd = String(deviceID.dropFirst(4))
            return running.filter { $0.avdName == avd }.map(\.serial)
        }
        return running.filter { $0.serial == deviceID }.compactMap(\.avdName).map(AndroidListing.avdID)
    }
}

extension AppState {
    /// Notes that `worktreeID` used a device, moving its emulator aliases too.
    func noteDeviceUse(_ deviceID: String, worktreeID: String) {
        deviceUseTracker.noteUse(
            deviceID: deviceID,
            aliases: DeviceUseTracker.aliases(of: deviceID, running: androidPane.devices ?? []),
            worktreeID: worktreeID
        )
    }
}

/// Keeps the device lists current while the sidebar shows owned devices.
/// The Devices tab polls only while it is on screen, so without this a
/// simulator shut down or an emulator closed elsewhere would keep its row
/// glyph until the tab opened again. Its own view, so only it observes the
/// tracker.
struct DeviceStatusKeeper: View {
    let state: AppState

    private struct Kinds: Equatable {
        var simulators = false
        var androids = false
    }

    private var kinds: Kinds {
        var kinds = Kinds()
        for id in state.deviceUseTracker.owners.keys {
            if AgentDevice.isSimulatorID(id) { kinds.simulators = true } else { kinds.androids = true }
        }
        return kinds
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .task(id: kinds) {
                let kinds = kinds
                guard kinds != Kinds() else { return }
                while !Task.isCancelled {
                    // Slower than the tab's poll: a glyph a few seconds late is fine.
                    try? await Task.sleep(for: .seconds(5))
                    guard !Task.isCancelled else { return }
                    if kinds.simulators { await state.devicePane.refresh() }
                    if kinds.androids { await state.androidPane.refresh() }
                }
            }
    }
}
