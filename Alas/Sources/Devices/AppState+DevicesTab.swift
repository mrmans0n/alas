import AlasCore
import Foundation

extension AppState {
    /// The Devices tab shows where this worktree can run VMs or the Mac has
    /// Xcode's simulator tools. Peer worktrees use their own pane and never show it.
    func devicesTabAvailable(in worktree: Worktree) -> Bool {
        canOpenVirtualMachine(in: worktree) || devicePane.simulatorToolsFound == true
    }

    func vmDeviceStatus(worktreeID: String, guest: VMGuestOS) -> VMDeviceStatus {
        let id = VMIdentity.recordID(worktree: worktreeID, guest: guest)
        if vmManager.pausing.contains(id) { return .pausing }
        if vmManager.isStarting(id) { return .starting }
        if vmManager.running(worktreeID, guest: guest) != nil { return .running }
        let record = vmManager.recordStatus(worktreeID, guest: guest)
        guard record.hasVM else { return .notCreated }
        if let label = record.runningElsewhere { return .runningElsewhere(label: label) }
        if let savedAt = record.pausedAt { return .paused(savedAt: savedAt) }
        return .stopped
    }

    func openSimulatorLogs(worktreeID: String, device: SimulatorDevice) {
        let tab = tabs.openOrFocusSimulatorLogs(worktreeId: worktreeID, udid: device.udid, deviceName: device.name)
        activateWorktreeCenterTab(worktreeId: worktreeID, tabId: tab.id)
    }

    func devicesTabState(worktree: Worktree, selection: DevicesTarget?) -> DevicesTabState {
        let guests: [VMGuestOS] = canOpenVirtualMachine(in: worktree) ? [.macOS, .linux] : []
        var vms: [VMGuestOS: VMDeviceStatus] = [:]
        var driving: Set<DevicesTarget> = []
        for guest in guests {
            vms[guest] = vmDeviceStatus(worktreeID: worktree.id, guest: guest)
            if case .agent = vmDriver(recordID: VMIdentity.recordID(worktree: worktree.id, guest: guest)) {
                driving.insert(.vm(guest))
            }
        }
        for device in devicePane.devices ?? [] {
            if case .agent = deviceControl.driver(udid: device.udid) { driving.insert(.simulator(device.udid)) }
        }
        let noTools = devicePane.simulatorToolsFound == false
        return .resolve(
            simulators: devicePane.simulatorToolsFound == nil ? nil : devicePane.devices,
            listError: noTools ? "Install Xcode to use iOS simulators." : devicePane.listError,
            vms: vms, selection: selection, bootingUDIDs: devicePane.bootingUDIDs, agentDriving: driving
        )
    }
}
