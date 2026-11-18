import AlasCore
import SwiftUI

/// The right pane's Devices tab: the device chosen in the toolbar's switcher,
/// a simulator's live screen or a card for one of the worktree's VMs.
struct DevicesTabView: View {
    let state: AppState
    let worktree: Worktree
    @Bindable var rps: RightPaneState

    private var model: DevicePaneModel { state.devicePane }

    var body: some View {
        // Each second, for "n s ago", saved-state ages and the agent's driving window.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            stage(state.devicesTabState(worktree: worktree, selection: rps.devicesSelection).stage, now: context.date)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await model.checkTools()
            guard model.simulatorToolsFound == true else { return }
            await model.pollWhileVisible()
        }
        .task {
            guard state.androidPane.control != nil else { return }
            await state.androidPane.pollWhileVisible()
        }
    }

    @ViewBuilder
    private func stage(_ stage: DevicesTabState.Stage, now: Date) -> some View {
        switch stage {
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
        case .simulator(let device, .booted):
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
                flowRecorder: state.deviceFlowRecorder
            )
            .id(device.udid)
        case .simulator(let device, .booting):
            DevicesEmptyState(title: "Booting \(device.name)…", detail: "The first boot can take a minute.")
        case .simulator(let device, .shutDown):
            let error = model.errors[device.udid]
            DevicesEmptyState(
                symbol: "iphone", title: "\(device.name) is shut down",
                detail: error ?? device.runtimeName, detailTone: error == nil ? "fg-dim" : "warn",
                action: .init(title: "Boot", icon: "power") {
                    rps.devicesSelection = .simulator(device.udid)
                    state.deviceUseTracker.noteUse(deviceID: device.udid, worktreeID: worktree.id)
                    Task { await model.boot(device) }
                }
            )
        case .vm(let guest, let status):
            vmCard(guest, status: status, now: now)
        case .android(let target, .ready):
            if let device = target.device {
                AndroidDeviceStage(
                    device: device, client: state.androidStreams, pane: state.androidPane, control: state.deviceControl,
                    agentName: { state.computerUseAgentName($0) }, now: now, flowRecorder: state.deviceFlowRecorder
                )
                    .id(device.serial)
            }
        case .android(let target, .booting):
            DevicesEmptyState(title: "Booting \(target.title)…", detail: "A cold boot takes about 20 seconds.")
        case .android(let target, .shutDown):
            let error = state.androidPane.errors[target.id]
            DevicesEmptyState(
                symbol: "candybarphone", title: "\(target.title) is shut down",
                detail: error ?? "Android emulator", detailTone: error == nil ? "fg-dim" : "warn",
                action: .init(title: "Boot", icon: "power") {
                    rps.devicesSelection = .android(target.id)
                    state.deviceUseTracker.noteUse(deviceID: target.id, worktreeID: worktree.id)
                    if let avd = target.avdName { Task { await state.androidPane.boot(avd: avd) } }
                }
            )
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
        }
    }

    private func vmCard(_ guest: VMGuestOS, status: VMDeviceStatus, now: Date) -> some View {
        let recordID = VMIdentity.recordID(worktree: worktree.id, guest: guest)
        let driver = state.vmDriver(recordID: recordID)
        let agentName: String = if case .agent(let sessionID, _, _) = driver {
            state.computerUseAgentName(sessionID)
        } else {
            ""
        }
        return VMDeviceCard(
            guest: guest, status: status,
            driver: VMDriverStatus.make(
                driver: driver, agentName: agentName, now: now,
                waiting: state.vmHolds.waiting(recordID).map { state.computerUseAgentName($0) }
            ),
            now: now,
            onOpen: { state.openVirtualMachine(in: worktree, guest: guest) },
            onTakeOver: { Task { await state.takeOverVM(recordID: recordID) } },
            onHandBack: { state.handBackVM(recordID: recordID) }
        )
    }
}
