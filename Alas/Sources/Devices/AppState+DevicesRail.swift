import AlasCore
import Foundation
import SwiftUI

extension AppState {
    /// This worktree's center tabs that show a running device, by device. A
    /// device tab follows its emulator to a new serial.
    func centerDeviceTabs(worktreeID: String, running: [DevicesTabState.Running]) -> [DevicesTarget: TabID] {
        var tabsByDevice: [DevicesTarget: TabID] = [:]
        for tab in tabs.tabs(forWorktree: worktreeID) {
            switch tab {
            case .device(let state):
                if let device = DevicesRail.device(forTab: state.deviceID, avdName: state.avdName, in: running) {
                    tabsByDevice[device.id] = state.id
                }
            case .virtualMachine(let state):
                tabsByDevice[.vm(state.guest)] = state.id
            default:
                continue
            }
        }
        return tabsByDevice
    }

    /// Moves a running device from the rail to a center tab, or focuses its tab.
    func openDeviceInTab(_ device: DevicesTabState.Running, worktree: Worktree) {
        useDevice(device.id, worktreeID: worktree.id)
        let state: DeviceTabState
        switch device.screen {
        case .vm(let guest, _):
            openVirtualMachine(in: worktree, guest: guest)
            return
        case .simulator(let simulator, _):
            state = DeviceTabState(worktreeId: worktree.id, deviceID: simulator.udid, platform: .ios, deviceName: simulator.name)
        case .android(let target, _):
            state = DeviceTabState(
                worktreeId: worktree.id, deviceID: target.id, platform: .android, deviceName: target.title,
                avdName: target.avdName
            )
        }
        let tab = tabs.openOrFocusDeviceTab(worktreeId: worktree.id, state: state)
        activateWorktreeCenterTab(worktreeId: worktree.id, tabId: tab.id)
    }

    /// Closes a device's center tab and shows the device, expanded, in the rail.
    func bringDeviceToRail(_ target: DevicesTarget, tabID: TabID, worktreeID: String) {
        closeTab(worktreeId: worktreeID, tabId: tabID)
        revealDevice(target, worktreeID: worktreeID)
    }

    /// Shows `target` and makes it last used: its center tab when it has one,
    /// else the worktree's Devices rail, expanded and scrolled to. An AVD that
    /// has booted is shown as its emulator.
    func revealDevice(_ target: DevicesTarget, worktreeID: String) {
        let target = runningDevice(for: target)
        useDevice(target, worktreeID: worktreeID)
        let avdName = avdName(of: target)
        if let tab = tabs.tabs(forWorktree: worktreeID).first(where: { Self.tab($0, shows: target, avdName: avdName) }) {
            activateWorktreeCenterTab(worktreeId: worktreeID, tabId: tab.id)
            return
        }
        guard let pane = rightPaneStore.activeState(worktreeId: worktreeID) else { return }
        pane.devicesCollapsed.remove(target)
        pane.devicesScrollRequest = target
        pane.activeTab = .device
        if !config.rightPaneVisible {
            config.rightPaneVisible = true
            saveConfig()
        }
    }

    /// Marks a device as the worktree's last used, and its owner for the sidebar.
    func useDevice(_ target: DevicesTarget, worktreeID: String) {
        rightPaneStore.activeState(worktreeId: worktreeID)?.devicesLastUsed = target
        switch target {
        case .simulator(let id), .android(let id): noteDeviceUse(id, worktreeID: worktreeID)
        case .vm: break
        }
    }

    /// Boots a shut-down simulator or AVD.
    func bootDevice(_ target: DevicesTarget, worktreeID: String) {
        useDevice(target, worktreeID: worktreeID)
        switch target {
        case .simulator(let udid):
            guard let device = devicePane.devices?.first(where: { $0.udid == udid }) else { return }
            Task { await devicePane.boot(device) }
        case .android(let id) where id.hasPrefix("avd:"):
            Task { await androidPane.boot(avd: String(id.dropFirst(4))) }
        default:
            break
        }
    }

    /// Why the last boot of `target` failed.
    func bootError(_ target: DevicesTarget?) -> String? {
        switch target {
        case .simulator(let udid)?: devicePane.errors[udid]
        case .android(let id)?: androidPane.errors[id]
        default: nil
        }
    }

    /// A running device's screen height over width as the rail shows it; nil
    /// before an Android device's first frame.
    func devicesRailAspect(_ device: DevicesTabState.Running) -> Double? {
        switch device.screen {
        case .simulator(let simulator, _):
            guard let shape = devicePane.shape(for: simulator), shape.widthPoints > 0, shape.heightPoints > 0 else { return nil }
            let landscape = simulatorStreams.lastFrame(udid: simulator.udid)?.orientation.isLandscape ?? false
            return Double(landscape ? shape.widthPoints / shape.heightPoints : shape.heightPoints / shape.widthPoints)
        case .android(let target, _):
            guard let serial = target.device?.serial, let size = androidStreams.videoSizes[serial], size.width > 0 else {
                return nil
            }
            return Double(size.height / size.width)
        case .vm:
            return 10.0 / 16.0
        }
    }

    /// An AVD's emulator by serial once it runs; any other target as it is.
    private func runningDevice(for target: DevicesTarget) -> DevicesTarget {
        guard case .android(let id) = target, id.hasPrefix("avd:") else { return target }
        let name = String(id.dropFirst(4))
        return androidPane.devices?.first { $0.avdName == name }.map { .android($0.serial) } ?? target
    }

    /// The AVD an Android target runs or names.
    private func avdName(of target: DevicesTarget) -> String? {
        guard case .android(let id) = target else { return nil }
        if id.hasPrefix("avd:") { return String(id.dropFirst(4)) }
        return androidPane.devices?.first { $0.serial == id }?.avdName
    }

    /// An emulator's tab follows its AVD, not a serial another AVD may have taken since.
    private static func tab(_ tab: Tab, shows target: DevicesTarget, avdName: String?) -> Bool {
        switch tab {
        case .device(let state):
            if let tabAVD = state.avdName { tabAVD == avdName } else { state.target == target }
        case .virtualMachine(let state): target == .vm(state.guest)
        default: false
        }
    }
}

extension View {
    /// Keeps the simulator and Android lists current while this view is on screen.
    func devicesPolling(_ state: AppState) -> some View {
        task {
            await state.devicePane.checkTools()
            guard state.devicePane.simulatorToolsFound == true else { return }
            await state.devicePane.pollWhileVisible()
        }
        .task {
            guard state.androidPane.control != nil else { return }
            await state.androidPane.pollWhileVisible()
        }
    }
}
