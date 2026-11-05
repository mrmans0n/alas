import AlasCore
import Foundation
import Observation

/// The simulators on this Mac, shared by every worktree's Devices tab, and
/// what each looks like. Which device a tab shows is the worktree's own
/// (`RightPaneState.devicesSelection`).
@MainActor
@Observable
final class DevicePaneModel {
    private(set) var devices: [SimulatorDevice]?
    private(set) var listError: String?
    private(set) var bootingUDIDs: Set<String> = []
    /// The last boot or shutdown failure of each simulator.
    private(set) var errors: [String: String] = [:]
    /// Whether Xcode's `simctl` was found; nil until `checkTools()` finishes.
    private(set) var simulatorToolsFound: Bool?
    /// Screen shapes by device type identifier, read once.
    private(set) var shapes: [String: DeviceScreenShape] = [:]

    @ObservationIgnored private var toolsCheck: Task<Void, Never>?

    func shape(for device: SimulatorDevice) -> DeviceScreenShape? {
        device.deviceTypeIdentifier.flatMap { shapes[$0] }
    }

    func refresh() async {
        do {
            devices = try await SimulatorControl.devices()
            listError = nil
        } catch {
            listError = error.localizedDescription
        }
    }

    /// Keeps the list current while a Devices tab is visible, so a device shut
    /// down or deleted elsewhere does not leave a frozen screen.
    func pollWhileVisible() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(3))
        }
    }

    func boot(_ device: SimulatorDevice) async {
        errors[device.udid] = nil
        bootingUDIDs.insert(device.udid)
        do {
            try await SimulatorControl.boot(udid: device.udid)
        } catch {
            errors[device.udid] = error.localizedDescription
        }
        await refresh()
        bootingUDIDs.remove(device.udid)
    }

    func shutDown(_ device: SimulatorDevice) async {
        errors[device.udid] = nil
        do {
            try await SimulatorControl.shutdown(udid: device.udid)
        } catch {
            errors[device.udid] = error.localizedDescription
        }
        await refresh()
    }

    /// Looks for the simulator tools and reads the device shapes, once.
    func checkTools() async {
        if toolsCheck == nil { toolsCheck = Task { await loadTools() } }
        await toolsCheck?.value
    }

    private func loadTools() async {
        let found = await SimulatorControl.isAvailable()
        simulatorToolsFound = found
        guard found, let bundles = try? await SimulatorControl.deviceTypeBundles() else { return }
        // Small plist and JSON reads, off the main actor.
        shapes = await Task.detached {
            bundles.compactMapValues { DeviceScreenShape.load(bundle: $0) }
        }.value
    }
}
