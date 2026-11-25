import SwiftUI
import Virtualization

/// The shared image installer is the same whether a worktree VM or a project draft needs it.
struct SharedMacOSSetupView: View {
    @ObservedObject var installer: GoldenImageInstaller
    let vms: WorktreeVMManager
    let build: String?
    let display: VZVirtualMachineView
    let finishing: Bool
    let start: (String) -> Void
    let finish: (String) -> Void
    @Environment(\.designScale) private var scale

    var body: some View {
        if let build {
            manual(build)
        } else if let position = VMSetupSteps.position(of: installer.phase) {
            VMEmptyStateCard(icon: "desktopcomputer", title: "Setting up the shared macOS base",
                             subtitle: "Projects without a saved base use this image.") {
                VMSetupSteps(current: position.current, fraction: position.fraction)
            }
        } else {
            if case .failed(let message) = installer.phase {
                VMCallout(title: "macOS setup couldn't finish", message: message)
            }
            VMEmptyStateCard(icon: "desktopcomputer", title: "Set up macOS",
                             subtitle: "Alas downloads macOS and prepares the shared base image.") {
                EmptyView()
            } actions: {
                AlasButton(title: "Set up", style: .primary) { Task { await installer.start() } }
            }
        }
    }

    @ViewBuilder
    private func manual(_ build: String) -> some View {
        let customized = vms.isGoldenCustomized(build: build)
        if let note = installer.failureNote {
            VMCallout(title: "Automatic setup stopped", message: note)
        }
        VMCallout(tone: .info, title: customized ? "Customize the base image" : "Finish the setup by hand") {
            VMNumberedSteps(steps: customized ? Self.customizeSteps : Self.manualSteps)
                .padding(.top, scale.space[0])
        } actions: {
            if !customized {
                AlasButton(title: "Set up automatically", compact: true) { Task { await installer.start() } }
                    .vmDisabled(finishing || vms.isGoldenRunning(build: build))
            }
            AlasButton(title: "Done", style: .primary, compact: true) { finish(build) }
                .vmDisabled(finishing)
        }
        if let golden = vms.runningGolden() {
            VMDisplaySurface(view: display, virtualMachine: golden.vm)
        } else if vms.isStarting(WorktreeVMManager.goldenIDPrefix + build) || finishing {
            Spinner().frame(width: 16, height: 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VMEmptyStateCard(icon: "desktopcomputer", title: "The setup VM is off",
                             subtitle: customized ? "Start it to make your changes." : "Start it to finish setting up macOS.") {
                EmptyView()
            } actions: {
                AlasButton(title: "Start VM", icon: "play.fill", style: .primary) { start(build) }
            }
        }
    }

    static func finish(build: String, vms: WorktreeVMManager, installer: GoldenImageInstaller) async throws {
        switch await vms.shutDownGoldenForSealing(build: build) {
        case .clean:
            try await vms.turnOffLeftoverSSH(id: WorktreeVMManager.goldenIDPrefix + build)
            try installer.markSetupDone()
        case .stillRunning:
            throw WorktreeVMManager.VMError(message: "Shut down macOS from the Apple menu, then click Done.")
        case .forcedOff:
            throw WorktreeVMManager.VMError(
                message: "macOS was powered off without shutting down. Start it, shut down macOS from the Apple menu, then click Done.")
        }
    }

    private static let manualSteps = [
        "Create a user that logs in automatically.",
        "Install the helper: open My Shared Files › helper › Install Alas VM Guest.",
        "Allow it in Accessibility and Screen Recording.",
        "Shut down macOS from the Apple menu, then click Done.",
    ]

    private static let customizeSteps = [
        "Make your changes in the VM.",
        "Shut down macOS from the Apple menu, then click Done. New VMs using the shared base start from your changes.",
    ]
}
