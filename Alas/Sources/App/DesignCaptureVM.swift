#if DEBUG
import AlasCore
import SwiftUI

/// Design-capture targets for the VM tab. The real tab is driven by the VM registry, the golden
/// image installer and a live `Virtualization` machine, none of which a capture may touch, so
/// each target draws a 2x2 gallery of tab states from the same chrome the tab uses
/// (`VMStatusBar`, `VMEmptyStateCard`, `VMCallout`, `VMNumberedSteps`, `VMSetupSteps`,
/// `VMSlotCard`) with the tab's own copy. Nothing is created, started or read. The display
/// of a running VM is a placeholder. Debug builds only, and only on a capture profile.
///
/// - vm-setup: no VM yet, a base image to set up, setup under way, setup failed.
/// - vm-stopped: stopped with disk and clean point, paused, stopped while customizing, running elsewhere.
/// - vm-running: running (an agent driving, you driving), stopping, starting, no slot free.
/// - vm-attention: callouts: setup stopped, manual steps, clean point and setup script failures, agent cards.
@MainActor
enum DesignCaptureVM {
    static let targets: Set<String> = ["vm-setup", "vm-stopped", "vm-running", "vm-attention"]

    static func open(_ target: String, state: AppState) {
        guard DesignCaptureWorkspace.isCaptureInstance else { return }
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(30)
            while state.projects.isEmpty {
                guard Date() < deadline else { return }
                try? await Task.sleep(for: .milliseconds(200))
            }
            let gallery = Gallery(target: target)
                .environment(\.theme, state.themeStore.current)
                .environment(\.designScale, .resolved(for: state.config.density))
            DesignCaptureWorkspace.present(gallery)
        }
    }

    private struct Gallery: View {
        let target: String
        @Environment(\.theme) private var theme

        var body: some View {
            let cells = Self.cells(for: target)
            VStack(spacing: 12) {
                HStack(spacing: 12) { cell(cells[0])
                cell(cells[1]) }
                HStack(spacing: 12) { cell(cells[2])
                cell(cells[3]) }
            }
            .padding(14)
            .background(theme.color("bg-0"))
        }

        private func cell(_ cell: Cell) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(cell.label)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(theme.color("fg-dim"))
                VStack(spacing: 0) { cell.content }
                    .frame(width: 520, height: 385)
                    .background(theme.color("bg-1"))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.color("line"), lineWidth: 0.5))
            }
        }

        struct Cell {
            let label: String
            let content: AnyView
            init(_ label: String, @ViewBuilder _ content: () -> some View) {
                self.label = label
                self.content = AnyView(content())
            }
        }

        // swiftlint:disable:next function_body_length
        static func cells(for target: String) -> [Cell] {
            switch target {
            case "vm-setup": [
                Cell("createVM: no VM for this worktree") {
                    VMStatusBar(tone: .off, title: "No VM")
                    VMEmptyStateCard(
                        icon: "desktopcomputer", title: "No VM for this worktree",
                        subtitle: "Create one from the base image. Agents can drive it with computer use while your desktop stays untouched."
                    ) { EmptyView() } actions: {
                        AlasButton(title: "Create VM", icon: "plus", style: .primary) {}
                    }
                },
                Cell("setup: no base image yet") {
                    VMStatusBar(tone: .off, title: "No base image")
                    VMEmptyStateCard(
                        icon: "desktopcomputer", title: "Set up a macOS VM",
                        subtitle: "Alas downloads macOS once and prepares a base image. Every worktree VM starts from it."
                    ) { EmptyView() } actions: {
                        AlasButton(title: "Set up", style: .primary) {}
                    }
                },
                Cell("setup: preparing (installing)") {
                    VMStatusBar(tone: .busy, title: "Preparing macOS", details: ["macOS 26.1", "installing 42%"]) {
                        AlasButton(title: "Cancel", style: .subtle, compact: true) {}
                    }
                    VMEmptyStateCard(
                        icon: "desktopcomputer", title: "Setting up the base image",
                        subtitle: "This happens once. Every worktree VM starts from it."
                    ) {
                        VMSetupSteps(current: 1, fraction: 0.42)
                    }
                },
                Cell("setup: failed") {
                    VMStatusBar(tone: .attention, title: "Needs attention")
                    VMCallout(title: "macOS setup couldn't finish", message: "The download was interrupted: the network connection was lost.")
                    VMEmptyStateCard(
                        icon: "desktopcomputer", title: "Set up a macOS VM",
                        subtitle: "Alas downloads macOS once and prepares a base image. Every worktree VM starts from it."
                    ) { EmptyView() } actions: {
                        AlasButton(title: "Set up", style: .primary) {}
                    }
                },
            ]
            case "vm-stopped": [
                Cell("stopped: disk size and clean point") {
                    VMStatusBar(tone: .off, title: "Stopped", details: ["14.2 GB", "clean point Nov 10, 2026 at 9:41 AM"]) { moreMenu() }
                    VMEmptyStateCard(
                        icon: "desktopcomputer", title: "This worktree's VM is off",
                        subtitle: "Agents can drive it with computer use once it's running. Your desktop stays untouched."
                    ) { EmptyView() } actions: {
                        AlasButton(title: "Start VM", icon: "play.fill", style: .primary) {}
                    }
                },
                Cell("paused") {
                    VMStatusBar(tone: .off, title: "Paused", details: ["saved 12 min ago", "14.2 GB", "clean point Nov 10, 2026 at 9:41 AM"]) { moreMenu() }
                    VMEmptyStateCard(
                        icon: "desktopcomputer", title: "This worktree's VM is paused",
                        subtitle: "Paused after 15 minutes idle to free its slot. It resumes where it was, in seconds, when you or an agent use it."
                    ) { EmptyView() } actions: {
                        AlasButton(title: "Resume", icon: "play.fill", style: .primary) {}
                    }
                },
                Cell("stopped while customizing the base image") {
                    VMStatusBar(tone: .off, title: "Stopped", details: ["base image being customized", "14.2 GB"]) { moreMenu() }
                    VMEmptyStateCard(
                        icon: "desktopcomputer", title: "This worktree's VM is off",
                        subtitle: "The base image is being customized. Finish customizing it here, or start this VM."
                    ) { EmptyView() } actions: {
                        AlasButton(title: "Start VM", icon: "play.fill", style: .primary) {}
                        AlasButton(title: "Finish customizing") {}
                    }
                },
                Cell("running in another Alas") {
                    VMStatusBar(tone: .running, title: "Running in Alas Dev")
                    VMEmptyStateCard(
                        icon: "desktopcomputer", title: "Running in another Alas",
                        subtitle: "Alas Dev is running this VM. Stop it there to use it here."
                    ) { EmptyView() } actions: {
                        AlasButton(title: "Start VM", icon: "play.fill", style: .primary) {}
                    }
                },
            ]
            case "vm-running": [
                Cell("running: an agent is driving") {
                    runningBar(.agent(sessionID: "s", tool: "click", at: Date().addingTimeInterval(-4)), agent: "Claude")
                    display
                },
                Cell("running: you're driving") {
                    runningBar(.user, agent: "")
                    display.overlay(Rectangle().strokeBorder(Color.accentColor, lineWidth: 2))
                },
                Cell("starting") {
                    VMStatusBar(tone: .busy, title: "Starting")
                    VMEmptyStateCard(icon: "desktopcomputer", title: "Starting the VM", subtitle: "macOS is booting.", busy: true) {
                        EmptyView()
                    } actions: {
                        AlasButton(title: "Stop") {}
                    }
                },
                Cell("no VM slot free") {
                    VMStatusBar(tone: .attention, title: "No VM slot free")
                    VMEmptyStateCard(
                        icon: "rectangle.on.rectangle", title: "Both VM slots are busy",
                        subtitle: "macOS runs two VMs at a time. Pause one to start this VM."
                    ) { EmptyView() } actions: {
                        AlasButton(title: "Pause api-gateway") {}
                        AlasButton(title: "Pause checkout-redesign") {}
                        AlasButton(title: "Cancel", style: .subtle) {}
                    }
                },
            ]
            default: [
                Cell("running: stopping, with failed clean point") {
                    VMStatusBar(tone: .busy, title: "Stopping", details: ["14.2 GB", "clean point Nov 10, 2026 at 9:41 AM"])
                    VMCallout(message: "Couldn't save this VM's clean point: not enough free disk space.", onDismiss: {}) {
                        EmptyView()
                    } actions: {
                        AlasButton(title: "Save clean point now", compact: true) {}
                    }
                    display
                },
                Cell("running: setup script failed") {
                    VMStatusBar(tone: .running, title: "Running", details: ["14.2 GB"]) { moreMenu() }
                    VMCallout(message: VMTabScreen.setupFailureMessage(exitCode: 1)) {
                        EmptyView()
                    } actions: {
                        AlasButton(title: "Run again", compact: true) {}
                        AlasButton(title: "Skip and save clean point", compact: true) {}
                    }
                    display
                },
                Cell("base image: finish setup by hand") {
                    VMStatusBar(tone: .attention, title: "Needs attention", details: ["macOS 26.1", "off"]) { moreMenu() }
                    VMCallout(
                        tone: .info, title: "Finish the setup by hand",
                        content: {
                            VMNumberedSteps(steps: [
                                "Create a user that logs in automatically.",
                                "Install the helper: open My Shared Files › helper › Install Alas VM Guest.",
                                "Allow it in Accessibility and Screen Recording.",
                                "Shut down macOS from the Apple menu, then click Done.",
                            ])
                            .padding(.top, 2)
                        },
                        actions: {
                            AlasButton(title: "Set up automatically", compact: true) {}
                            AlasButton(title: "Done", style: .primary, compact: true) {}
                        })
                    VMEmptyStateCard(
                        icon: "desktopcomputer", title: "The setup VM is off", subtitle: "Start it to finish setting up macOS."
                    ) { EmptyView() } actions: {
                        AlasButton(title: "Start VM", icon: "play.fill", style: .primary) {}
                    }
                },
                Cell("in a session: slot and starting cards") {
                    VStack(spacing: 10) {
                        VMSlotCard(
                            request: VMSlotRequest(
                                id: UUID(), sessionID: "demo", recordID: "c",
                                candidates: [
                                    .init(recordID: "a", name: "api-gateway"),
                                    .init(recordID: "b", name: "checkout-redesign"),
                                ]),
                            onAnswer: { _ in })
                        VMStartingCard()
                    }
                    .padding(14)
                    Spacer(minLength: 0)
                },
            ]
            }
        }

        private static func runningBar(_ driver: VMDriver, agent: String) -> some View {
            let status = VMDriverStatus.make(driver: driver, agentName: agent, now: Date())
            return VMStatusBar(
                tone: status.tone, title: status.title,
                details: driver == .idle ? ["14.2 GB"] : status.details
            ) {
                switch status.action {
                case .takeOver: AlasButton(title: "Take over", compact: true) {}
                case .handBack: AlasButton(title: "Hand back", style: .primary, compact: true) {}
                }
                ToolbarBtn(icon: "stop.fill", tooltip: "Stop VM", metrics: .vmStatusBar) {}
                moreMenu()
            }
        }

        private static func moreMenu() -> some View {
            ToolbarMenuButton(iconName: "ellipsis", metrics: .vmStatusBar, restingColorToken: "fg-muted", help: "More VM actions") {
                Button("Reset to clean") {}
                Button("Delete VM…", role: .destructive) {}
            }
        }

        /// Stands in for the live VM display, which a capture never starts.
        private static var display: some View {
            Rectangle().fill(Color(red: 0.13, green: 0.16, blue: 0.24))
                .overlay(Text("VM display").font(.system(size: 12)).foregroundColor(.white.opacity(0.5)))
        }
    }
}
#endif
