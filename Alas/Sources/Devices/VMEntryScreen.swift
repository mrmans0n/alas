import AlasCore
import SwiftUI

/// A running worktree VM's live screen in the Devices rail, with who drives it
/// on top. It borrows the VM tab's cached screen view, so moving the VM between
/// the rail and its tab moves one view, never two.
struct VMEntryScreen: View {
    let state: AppState
    let worktreeID: String
    let guest: VMGuestOS
    var onUse: () -> Void = {}
    @State private var pulse = false

    private var recordID: String { VMIdentity.recordID(worktree: worktreeID, guest: guest) }
    private var tabID: TabID { VirtualMachineTabState(ownerKey: worktreeID, guest: guest).id }

    var body: some View {
        let driver = state.vmDriver(recordID: recordID)
        ZStack(alignment: .top) {
            VMDisplaySurface(
                view: state.tabs.vmView(tabID: tabID), virtualMachine: state.vmManager.running(worktreeID, guest: guest)?.vm,
                allowsInput: VMDriver.allowsViewInput(driver), capturesSystemKeys: driver == .user,
                reconfiguresDisplay: false, takesKeyboardOnShow: false,
                onBlockedClick: pulsePill,
                onUserInput: { [state, recordID, onUse] in
                    state.noteVMUserInput(recordID: recordID)
                    onUse()
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 6)) // design-literal: VM screen corners
            if driver != .idle {
                DeviceDriverPill(
                    driver: driver, waiting: state.vmHolds.waiting(recordID).first,
                    agentName: { state.computerUseAgentName($0) }, pulse: pulse,
                    onTakeOver: { Task { await state.takeOverVM(recordID: recordID) } },
                    onHandBack: { state.handBackVM(recordID: recordID) }
                )
                .padding(.top, 8) // design-literal: pill inset, as on a phone screen
            }
        }
        .padding(12) // design-literal: DevicesRailLayout's VM chrome
        .onDisappear {
            // The VM's tab keeps the view while it's open; otherwise the screen goes, and the VM runs on.
            if !state.tabs.tabs(forWorktree: worktreeID).contains(where: { $0.id == tabID }) {
                state.tabs.releaseVMView(tabID: tabID)
            }
        }
    }

    /// A click while an agent drives: draw the eye to Take over.
    private func pulsePill() {
        pulse = true
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            pulse = false
        }
    }
}
