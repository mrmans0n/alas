import AlasCore
import SwiftUI

/// The right pane's Devices tab: every running simulator, Android device and
/// VM of this worktree in a stack, each movable to a center tab and back.
struct DevicesRailView: View {
    let state: AppState
    let worktree: Worktree
    @Bindable var rps: RightPaneState

    var body: some View {
        // Each second, for the agent's driving window.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let devices = state.devicesTabState(worktree: worktree, lastUsed: rps.devicesLastUsed)
            if let empty = devices.empty {
                emptyState(empty)
            } else {
                rail(devices, now: context.date)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .devicesPolling(state)
    }

    private func rail(_ devices: DevicesTabState, now: Date) -> some View {
        let centered = state.centerDeviceTabs(worktreeID: worktree.id, running: devices.running)
        return DevicesRailList(
            entries: DevicesRail.entries(devices.running, collapsed: rps.devicesCollapsed, inCenter: Set(centered.keys)),
            scrollRequest: $rps.devicesScrollRequest,
            onToggleCollapsed: { target in
                if rps.devicesCollapsed.remove(target) == nil { rps.devicesCollapsed.insert(target) }
            },
            onOpenInTab: { state.openDeviceInTab($0, worktree: worktree) },
            onBringBack: { target in
                guard let tabID = centered[target] else { return }
                state.bringDeviceToRail(target, tabID: tabID, worktreeID: worktree.id)
            },
            onUse: { state.useDevice($0, worktreeID: worktree.id) },
            aspect: { state.devicesRailAspect($0) },
            stage: { device in
                DeviceEntryStage(
                    state: state, worktree: worktree, screen: device.screen, now: now,
                    onUse: { state.useDevice(device.id, worktreeID: worktree.id) }
                )
            },
            actions: { DeviceEntryLiveActions(state: state, worktree: worktree, device: $0) }
        )
    }

    @ViewBuilder
    private func emptyState(_ empty: DevicesTabState.Empty) -> some View {
        switch empty {
        case .loading:
            DevicesEmptyState(title: "Looking for devices…")
        case .unavailable:
            DevicesEmptyState(
                symbol: "iphone.slash", title: "iOS simulators need Xcode",
                detail: "Install it, or select it with `sudo xcode-select -s /Applications/Xcode.app`."
            )
        case .noSimulators:
            DevicesEmptyState(
                symbol: "iphone", title: "No iOS simulators",
                detail: "Create one in Xcode under Window › Devices and Simulators."
            )
        case .nothingRunning(let suggested):
            let error = state.bootError(suggested?.target)
            DevicesEmptyState(
                symbol: "iphone", title: "No devices running",
                detail: error ?? "Boot one here, or from + Add in the toolbar.",
                detailTone: error == nil ? "fg-dim" : "warn",
                action: suggested.map(offer)
            )
        }
    }

    /// Boots a simulator or AVD, or opens a VM's tab.
    private func offer(_ row: DevicesTabState.Row) -> DevicesEmptyState.Action {
        if case .vm(let guest) = row.platform {
            return .init(title: "Open \(row.title)", icon: DeviceStyle.glyph(row.platform)) {
                state.useDevice(row.target, worktreeID: worktree.id)
                state.openVirtualMachine(in: worktree, guest: guest)
            }
        }
        return .init(title: "Boot \(row.title)", icon: "power") {
            state.bootDevice(row.target, worktreeID: worktree.id)
        }
    }
}
