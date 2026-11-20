import AlasCore
import SwiftUI

/// The Devices rail's toolbar + Add. A running device scrolls into view; a
/// shut-down simulator or AVD boots and joins the stack; a VM opens its tab,
/// where it starts or is set up.
struct AddDeviceButton: View {
    let state: AppState
    let worktree: Worktree
    @Bindable var rps: RightPaneState
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale
    @State private var showsPanel = false

    var body: some View {
        ToolbarBtn(icon: "plus", tooltip: "Add a device") { showsPanel = true }
            .accessibilityIdentifier("devices-add")
            .popover(isPresented: $showsPanel, arrowEdge: .bottom) {
                DevicesAddPanel(
                    state: state.devicesTabState(worktree: worktree, lastUsed: rps.devicesLastUsed),
                    onSelect: { target in
                        pick(target)
                        showsPanel = false
                    },
                    onBoot: { target in
                        boot(target)
                        showsPanel = false
                    },
                    onClose: { showsPanel = false }
                )
                .environment(\.theme, theme)
                .environment(\.designScale, scale)
            }
    }

    private func pick(_ target: DevicesTarget) {
        let devices = state.devicesTabState(worktree: worktree, lastUsed: rps.devicesLastUsed)
        if devices.running.contains(where: { $0.id == target }) {
            state.revealDevice(target, worktreeID: worktree.id)
        } else if case .vm(let guest) = target {
            state.useDevice(target, worktreeID: worktree.id)
            state.openVirtualMachine(in: worktree, guest: guest)
        } else {
            boot(target)
        }
    }

    private func boot(_ target: DevicesTarget) {
        state.bootDevice(target, worktreeID: worktree.id)
        state.revealDevice(target, worktreeID: worktree.id)
    }
}
