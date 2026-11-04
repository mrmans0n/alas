import AlasCore
import Foundation
import Observation

/// The simulators on this Mac and the one the Device tab shows. Simulators
/// belong to the Mac, so every worktree's pane shares this model.
@MainActor
@Observable
final class DevicePaneModel {
    private(set) var devices: [SimulatorDevice]?
    private(set) var listError: String?
    var selectedUDID: String?
    private(set) var bootingUDIDs: Set<String> = []
    private(set) var bootError: String?

    var status: DevicePaneStatus {
        .resolve(devices: devices, listError: listError, selectedUDID: selectedUDID, bootingUDIDs: bootingUDIDs)
    }

    func refresh() async {
        do {
            devices = try await SimulatorControl.devices()
            listError = nil
        } catch {
            listError = error.localizedDescription
        }
    }

    /// Keeps the list current while the tab is visible, so a device shut down
    /// or deleted elsewhere does not leave a frozen screen.
    func pollWhileVisible() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(3))
        }
    }

    func boot(_ device: SimulatorDevice) async {
        selectedUDID = device.udid
        bootError = nil
        bootingUDIDs.insert(device.udid)
        do {
            try await SimulatorControl.boot(udid: device.udid)
        } catch {
            bootError = error.localizedDescription
        }
        await refresh()
        bootingUDIDs.remove(device.udid)
    }
}
