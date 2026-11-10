import AlasCore
import Foundation

extension AppState {
    /// Installs and launches the app a run script declares (`# alas-app:`)
    /// after a successful run: on the worktree's simulator, which its Devices
    /// tab then shows. Remote worktrees are skipped; their simulators would be
    /// on another Mac.
    func installRunScriptApp(_ appPath: String, worktree: Worktree) async {
        guard !RemotePath.isReserved(worktree.id), webPreviewRemoteHost(for: worktree) == nil else { return }
        await devicePane.checkTools()
        guard devicePane.simulatorToolsFound == true else { return }
        await devicePane.refresh()
        let app = appPath.hasPrefix("/")
            ? URL(fileURLWithPath: appPath)
            : worktree.path.appendingPathComponent(appPath)
        let appName = app.deletingPathExtension().lastPathComponent
        let pane = rightPaneStore.activeState(worktreeId: worktree.id)
        guard let device = SimulatorTarget.choose(selection: pane?.devicesSelection, simulators: devicePane.devices ?? []) else {
            inAppNotifications.post("No iOS simulator to open \(appName) on", severity: .error, worktreeID: worktree.id)
            return
        }
        if let pane {
            pane.devicesSelection = .simulator(device.udid)
            pane.activeTab = .device
        }
        if !config.rightPaneVisible {
            config.rightPaneVisible = true
            saveConfig()
        }
        if case .agent(let sessionID, _, _) = deviceControl.driver(udid: device.udid) {
            devicePane.failAppInstall(
                udid: device.udid,
                message: "\(computerUseAgentName(sessionID)) is driving \(device.name). Take over to install \(appName)."
            )
            return
        }
        if device.state != .booted {
            await devicePane.boot(device)
            guard devicePane.devices?.first(where: { $0.udid == device.udid })?.state == .booted else { return }
        }
        await devicePane.installAndLaunch(app, on: device)
    }
}
