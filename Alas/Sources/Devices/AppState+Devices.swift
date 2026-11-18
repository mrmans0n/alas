import AlasCore
import Foundation

extension AppState {
    /// Runs a `device_*` tool call from an agent session in `worktreeID`.
    func performDeviceCommand(_ command: DeviceCommand, sessionID: String, worktreeID: String?) async -> AlasCLIResponse {
        guard config.deviceAgentsEnabled else { return .error(DeviceAgentControl.disabled) }
        if let udid = command.udid, let worktreeID { deviceUseTracker.noteUse(deviceID: udid, worktreeID: worktreeID) }
        let response = await deviceControl.perform(command, sessionID: sessionID)
        if case .open(let udid) = command, case .text = response {
            showDevice(udid, in: worktreeID)
        }
        return response
    }

    /// Selects the device in the agent's worktree and shows its Devices tab.
    func showDevice(_ udid: String, in worktreeID: String?) {
        Task { await devicePane.refresh() }
        guard let worktreeID, let pane = rightPaneStore.activeState(worktreeId: worktreeID) else { return }
        deviceUseTracker.noteUse(deviceID: udid, worktreeID: worktreeID)
        pane.devicesSelection = AgentDevice.isSimulatorID(udid) ? .simulator(udid) : .android(udid)
        pane.activeTab = .device
        if !config.rightPaneVisible {
            config.rightPaneVisible = true
            saveConfig()
        }
    }
}

extension LiveSimulatorSettings {
    /// Settings with the app's bundled accessibility helper, and the user's simslim.
    static var bundled: LiveSimulatorSettings {
        LiveSimulatorSettings(
            accessibilityHelper: Bundle.main.resourceURL?.appendingPathComponent("sim-ax-settings/alas-sim-ax-settings"),
            simslim: {
                // Homebrew or `go install`; a GUI app's PATH has neither.
                AgentPath.resolveExecutable(
                    named: "simslim", base: ProcessInfo.processInfo.environment["PATH"],
                    wellKnown: AgentPath.wellKnownDirectories + ["~/go/bin"]
                )
            }
        )
    }
}

extension HomebrewInstallController {
    /// The simulator settings' "Install simslim…".
    static func simslim() -> HomebrewInstallController {
        HomebrewInstallController(formula: SimulatorSlim.formula, tool: "simslim") {
            LiveSimulatorSettings.bundled.simslim() != nil
        }
    }
}
