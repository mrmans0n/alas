import AlasCore
import AppKit
import SwiftUI

/// A running device's screen as the Devices rail and its center tab show it:
/// the live stage once it's up, else what it's waiting for.
struct DeviceEntryStage: View {
    let state: AppState
    let worktree: Worktree
    let screen: DevicesTabState.Screen
    let now: Date
    /// The user clicked or typed into the screen.
    var onUse: () -> Void = {}

    private var model: DevicePaneModel { state.devicePane }

    var body: some View {
        if let waiting = Self.waitingState(for: screen) {
            waiting
        } else {
            live
        }
    }

    /// What a device coming up or going away shows instead of its screen.
    static func waitingState(for screen: DevicesTabState.Screen) -> DevicesEmptyState? {
        switch screen {
        case .simulator(let device, .booting):
            DevicesEmptyState(title: "Booting \(device.name)…", detail: "The first boot can take a minute.")
        case .android(let target, .booting):
            DevicesEmptyState(title: "Booting \(target.title)…", detail: "A cold boot takes about 20 seconds.")
        case .vm(let guest, .starting):
            DevicesEmptyState(title: "Starting the \(guest == .macOS ? "macOS" : "Linux") VM…")
        case .vm(let guest, .pausing):
            DevicesEmptyState(title: "Saving the \(guest == .macOS ? "macOS" : "Linux") VM's state…")
        default:
            nil
        }
    }

    @ViewBuilder
    private var live: some View {
        switch screen {
        case .simulator(let device, _):
            DeviceStage(
                device: device, shape: model.shape(for: device), client: state.simulatorStreams,
                control: state.deviceControl, agentName: { state.computerUseAgentName($0) }, now: now,
                appInstall: model.appInstalls[device.udid],
                onDropApp: { url in Task { await state.installAppForUser(url, on: device) } },
                onDismissAppInstall: { model.dismissAppInstall(udid: device.udid) },
                notice: model.notices[device.udid],
                onPaste: {
                    let text = NSPasteboard.general.string(forType: .string)
                    Task {
                        if await model.paste(text, udid: device.udid, pasteboard: state.devicePasteboard), let text {
                            state.deviceFlowRecorder.pasted(device.udid, text)
                        }
                    }
                },
                onCopy: { Task { await model.copy(udid: device.udid, pasteboard: state.devicePasteboard) } },
                accessibilityOverlay: model.accessibilityOverlays.contains(device.udid),
                flowRecorder: state.deviceFlowRecorder,
                onUse: onUse
            )
            .id(device.udid)
        case .android(let target, .unauthorized):
            DevicesEmptyState(
                symbol: "lock", title: "Allow USB debugging on the phone",
                detail: "Unlock \(target.title) and allow this Mac when it asks.",
                action: .init(title: "Retry", icon: "arrow.clockwise") { Task { await state.androidPane.refresh() } }
            )
        case .android(let target, .offline):
            DevicesEmptyState(
                symbol: "candybarphone", title: "\(target.title) is offline",
                detail: "Reconnect it, or restart adb with `adb kill-server`.",
                action: .init(title: "Retry", icon: "arrow.clockwise") { Task { await state.androidPane.refresh() } }
            )
        case .android(let target, _):
            if let device = target.device {
                AndroidDeviceStage(
                    device: device, client: state.androidStreams, pane: state.androidPane, control: state.deviceControl,
                    agentName: { state.computerUseAgentName($0) }, now: now, flowRecorder: state.deviceFlowRecorder,
                    onUse: onUse
                )
                .id(device.serial)
            }
        case .vm(let guest, _):
            VMEntryScreen(state: state, worktreeID: worktree.id, guest: guest, onUse: onUse)
        }
    }
}
