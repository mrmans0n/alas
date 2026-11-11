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
        let pane = rightPaneStore.activeState(worktreeId: worktree.id)
        guard let device = SimulatorTarget.choose(selection: pane?.devicesSelection, simulators: devicePane.devices ?? []) else {
            let appName = app.deletingPathExtension().lastPathComponent
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
        await installAppForUser(app, on: device)
    }

    /// Installs and launches an app for the user (a drop, or a run script's
    /// app), booting the simulator first if needed. It holds the simulator's
    /// input turn throughout, so an agent's calls wait for it instead of
    /// tapping into the app it relaunches.
    func installAppForUser(_ app: URL, on device: SimulatorDevice) async {
        let ran = await deviceControl.whileUserHoldsInput(udid: device.udid) {
            if device.state != .booted {
                await devicePane.boot(device)
                guard devicePane.devices?.first(where: { $0.udid == device.udid })?.state == .booted else { return }
            }
            await devicePane.installAndLaunch(app, on: device)
        }
        guard !ran else { return }
        let agent: String = if case .agent(let sessionID, _, _) = deviceControl.driver(udid: device.udid) {
            computerUseAgentName(sessionID)
        } else {
            "An agent"
        }
        let appName = app.deletingPathExtension().lastPathComponent
        devicePane.failAppInstall(
            udid: device.udid, message: "\(agent) is driving \(device.name). Take over to install \(appName)."
        )
    }
}
