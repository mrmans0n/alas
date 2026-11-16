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
                DeviceDriverPill(
                    driver: driver, waiting: control.waitingSessions(udid: device.udid).first, agentName: agentName,
                    pulse: pulse, onTakeOver: { control.takeOver(udid: device.udid) },
                    onHandBack: { control.handBack(udid: device.udid) }
                )
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
