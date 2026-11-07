import AlasCore
import Foundation

extension AppState {
    /// Runs a `device_*` tool call from an agent session in `worktreeID`.
    func performDeviceCommand(_ command: DeviceCommand, sessionID: String, worktreeID: String?) async -> AlasCLIResponse {
        guard config.deviceAgentsEnabled else { return .error(DeviceAgentControl.disabled) }
        let response = await deviceControl.perform(command, sessionID: sessionID)
        if case .open(let udid) = command, case .text = response {
            showDevice(udid, in: worktreeID)
        }
        return response
    }

    /// Selects the device in the agent's worktree and shows its Devices tab.
    private func showDevice(_ udid: String, in worktreeID: String?) {
        Task { await devicePane.refresh() }
        guard let worktreeID, let pane = rightPaneStore.activeState(worktreeId: worktreeID) else { return }
        pane.devicesSelection = .simulator(udid)
        pane.activeTab = .device
        if !config.rightPaneVisible {
            config.rightPaneVisible = true
            saveConfig()
        }
    }
}
