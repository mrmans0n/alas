import AlasCore
import SwiftUI

/// A booted simulator's screen, framed at its real shape, with the hardware
/// buttons in a gutter on the right and who drives it on top.
struct DeviceStage: View {
    let device: SimulatorDevice
    let shape: DeviceScreenShape?
    let client: SimulatorStreamClient
    let control: DeviceAgentControl
    /// Names the agent session driving the device.
    let agentName: (String) -> String
    let now: Date
    /// The app the user dropped on this simulator, while it installs or after it failed.
    let appInstall: DevicePaneModel.AppInstall?
    let onDropApp: (URL) -> Void
    let onDismissAppInstall: () -> Void
    /// A short message after a copy or paste.
    let notice: String?
    let onPaste: () -> Void
    let onCopy: () -> Void
    /// Outline the screen's accessibility elements.
    let accessibilityOverlay: Bool
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale
    @State private var streamError: String?
    @State private var streamGeneration = 0
    @State private var pulse = false
    @State private var dropTargeted = false
    /// The interface orientation of the frames shown; nil until one arrives.
    @State private var frameOrientation: DeviceScreenOrientation?
    /// The pointer over the screen, while the overlay shows.
    @State private var hover: CGPoint?
    /// Bumped by the user's input and rotations, so the overlay reads the screen again.
    @State private var overlayReadKey = 0

    var body: some View {
        let driver = control.driver(udid: device.udid, at: now)
        let allowsInput = VMDriver.allowsViewInput(driver)
        let landscape = (frameOrientation ?? client.lastFrame(udid: device.udid)?.orientation ?? .portrait).isLandscape
        DeviceStageFrame(shape: shape, landscape: landscape, dropTargeted: dropTargeted) {
            screen(allowsInput: allowsInput, driver: driver, landscape: landscape)
        } gutter: {
            controls(enabled: allowsInput)
        }
    }

    private func screen(allowsInput: Bool, driver: VMDriver, landscape: Bool) -> some View {
        ZStack(alignment: .top) {
            DeviceScreenView(
                udid: device.udid, client: client, onStopped: { streamError = $0 },
                allowsInput: allowsInput, onBlockedClick: pulsePill,
                onDropApp: onDropApp, onDropTargeted: { dropTargeted = $0 },
                onPaste: onPaste, onCopy: onCopy,
                onOrientation: { orientation in
                    frameOrientation = orientation
                    overlayReadKey += 1
                },
                onHover: accessibilityOverlay ? { hover = $0 } : nil,
                onUserInput: { overlayReadKey += 1 }
            )
            // A new identity unsubscribes and subscribes again, which restarts the stream.
            .id("\(device.udid):\(streamGeneration)")
            if accessibilityOverlay, streamError == nil {
                DeviceAccessibilityOverlay(
                    udid: device.udid, client: client, readKey: overlayReadKey, landscape: landscape, hover: hover
                )
            }
            if let streamError {
                theme.color("bg-2").opacity(0.92)
                DevicesEmptyState(
                    symbol: "exclamationmark.triangle", title: "The screen stopped", detail: streamError,
                    action: .init(title: "Retry", icon: "arrow.clockwise") {
                        self.streamError = nil
                        streamGeneration += 1
                    }
                )
            } else if driver != .idle {
                driverPill(driver)
                    .padding(.top, scale.space[2])
            }
        }
        .overlay(alignment: .bottom) {
            if let appInstall {
                DeviceAppInstallPill(install: appInstall, onDismiss: onDismissAppInstall)
                    .padding(.bottom, scale.space[3])
            } else if let notice {
                DeviceStagePill { Text(notice).foregroundStyle(theme.color("fg")) }
                    .padding(.bottom, scale.space[3])
            }
        }
    }

    private func driverPill(_ driver: VMDriver) -> some View {
        // The one-line strip, or the same texts and button on two lines when the
        // screen is too narrow for it.
        ViewThatFits(in: .horizontal) {
            driverPillContent(driver, stacked: false)
            driverPillContent(driver, stacked: true)
        }
        .font(scale.caption.font)
        .background(.ultraThinMaterial, in: Capsule())
        .background(theme.color("bg-2").opacity(0.6), in: Capsule())
        .overlay(Capsule().strokeBorder(theme.color("line"), lineWidth: 0.5))
        .scaleEffect(pulse ? 1.06 : 1)
        .animation(.easeOut(duration: 0.2), value: pulse)
    }

    @ViewBuilder
    private func driverPillContent(_ driver: VMDriver, stacked: Bool) -> some View {
        let status = HStack(spacing: 6) {
            switch driver {
            case .agent(let sessionID, _, _):
                Circle().fill(theme.color(DevicesSwitcher.colorToken(.busy))).frame(width: 6, height: 6)
                Text("\(agentName(sessionID)) is driving")
                    .foregroundStyle(theme.color("fg"))
                    .fixedSize()
            case .user, .idle:
                Text("You're driving")
                    .foregroundStyle(theme.color("fg"))
                    .fixedSize()
                if let waiting = control.waitingSessions(udid: device.udid).first {
                    Text("· \(agentName(waiting)) is waiting")
                        .foregroundStyle(theme.color("fg-dim"))
                        .fixedSize()
                }
            }
        }
        let action = Group {
            switch driver {
            case .agent:
                Button("Take over") { control.takeOver(udid: device.udid) }
            case .user, .idle:
                Button("Hand back") { control.handBack(udid: device.udid) }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.color("accent"))
        .fixedSize()
        if stacked {
            VStack(alignment: .trailing, spacing: scale.space[1]) {
                status
                action
            }
            .padding(.horizontal, scale.space[3])
            .padding(.vertical, scale.space[1])
        } else {
            HStack(spacing: 6) {
                status
                action
            }
            .padding(.horizontal, scale.space[3])
            .frame(height: 24)
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

    private func controls(enabled: Bool) -> some View {
        DeviceGutter(enabled: enabled) {
            hardwareButton("house", help: "Home", name: "home")
            hardwareButton("square.stack", help: "App switcher", name: "app_switcher")
            hardwareButton("lock", help: "Lock", name: "lock")
            hardwareButton("mic", help: "Siri", name: "siri")
            rotateButton("rotate.left", help: "Rotate left") { $0.rotatedLeft }
            rotateButton("rotate.right", help: "Rotate right") { $0.rotatedRight }
        }
    }

    private func hardwareButton(_ symbol: String, help: String, name: String) -> some View {
        DeviceGutterButton(icon: symbol, help: help) {
            client.button(udid: device.udid, name: name)
            overlayReadKey += 1
        }
    }

    private func rotateButton(
        _ symbol: String, help: String, turn: @escaping (DeviceScreenOrientation) -> DeviceScreenOrientation
    ) -> some View {
        DeviceGutterButton(icon: symbol, help: help) {
            let udid = device.udid
            let next = turn(client.deviceOrientation(udid: udid))
            Task { try? await client.rotate(udid: udid, to: next) }
            overlayReadKey += 1
        }
    }
}
