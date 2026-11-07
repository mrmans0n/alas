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
                control: state.deviceControl, agentName: { state.computerUseAgentName($0) }, now: now
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
                    Task { await model.boot(device) }
                }
            )
        case .vm(let guest, let status):
            vmCard(guest, status: status, now: now)
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
            driver: VMDriverStatus.make(driver: driver, agentName: agentName, now: now), now: now,
            onOpen: { state.openVirtualMachine(in: worktree, guest: guest) },
            onTakeOver: { Task { await state.takeOverVM(recordID: recordID) } },
            onHandBack: { state.handBackVM(recordID: recordID) }
        )
    }
}
