import AlasCore
import SwiftUI

/// A simulator's or Android device's screen in a center tab: the same header,
/// screen and driver pill as its entry in the Devices rail, at full size.
struct DeviceTabView: View {
    let state: AppState
    let worktree: Worktree
    let tab: DeviceTabState

    var body: some View {
        // Each second, for the agent's driving window.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(state.devicesTabState(worktree: worktree, lastUsed: nil), now: context.date)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .devicesPolling(state)
    }

    @ViewBuilder
    private func content(_ devices: DevicesTabState, now: Date) -> some View {
        if let device = DevicesRail.device(forTab: tab.deviceID, avdName: tab.avdName, in: devices.running) {
            VStack(spacing: 0) {
                DeviceEntryHeader(
                    row: device.row, move: .toRail,
                    onMove: { state.bringDeviceToRail(device.id, tabID: tab.id, worktreeID: worktree.id) }
                ) {
                    DeviceEntryLiveActions(state: state, worktree: worktree, device: device)
                }
                .padding(.horizontal, 8) // design-literal: matches the rail's padding
                .simultaneousGesture(TapGesture().onEnded { state.useDevice(device.id, worktreeID: worktree.id) })
                Divider()
                DeviceEntryStage(
                    state: state, worktree: worktree, screen: device.screen, now: now,
                    onUse: { state.useDevice(device.id, worktreeID: worktree.id) }
                )
            }
        } else {
            notRunning(devices)
        }
    }

    /// Its device shut down or went away: Boot it, or say it's gone.
    @ViewBuilder
    private func notRunning(_ devices: DevicesTabState) -> some View {
        let rows = devices.simulatorRows + devices.androidRows
        // An emulator's tab is its AVD's: its old serial may be another AVD's by now.
        let row = if let avd = tab.avdName {
            rows.first { $0.target == .android(AndroidListing.avdID(avd)) }
        } else {
            rows.first { $0.target == tab.target }
        }
        let symbol = tab.platform == .ios ? "iphone" : "candybarphone"
        if let row, row.canBoot {
            let error = state.bootError(row.target)
            DevicesEmptyState(
                symbol: symbol, title: "\(tab.deviceName) is shut down",
                detail: error ?? row.detail, detailTone: error == nil ? "fg-dim" : "warn",
                action: .init(title: "Boot", icon: "power") { state.bootDevice(row.target, worktreeID: worktree.id) }
            )
        } else {
            DevicesEmptyState(
                symbol: symbol, title: "\(tab.deviceName) isn't available",
                detail: "Connect it again, or close this tab."
            )
        }
    }
}
