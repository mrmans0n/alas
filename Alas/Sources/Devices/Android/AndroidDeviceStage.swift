import AlasCore
import AppKit
import SwiftUI

/// A connected Android device's live screen, framed at its video's shape,
/// with Back, Home, Recents, Power, volume and rotation in the gutter.
struct AndroidDeviceStage: View {
    let device: AndroidDevice
    let client: AndroidStreamClient
    let pane: AndroidPaneModel
    let control: DeviceAgentControl
    /// Names the agent session driving the device.
    let agentName: (String) -> String
    let now: Date
    let flowRecorder: DeviceFlowRecorder
    let remoteDriverName: String?
    let onReclaimRemote: () -> Void
    /// The user clicked or typed into the screen.
    var onUse: () -> Void = {}
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale
    @State private var streamError: String?
    @State private var streamGeneration = 0
    @State private var dropTargeted = false
    @State private var pulse = false

    var body: some View {
        let driver = control.driver(udid: device.serial, at: now)
        let remoteInputReserved = control.remoteInputOwner(udid: device.serial) != nil
        let allowsInput = !remoteInputReserved && VMDriver.allowsViewInput(driver)
        DeviceStageFrame(shape: shape, landscape: false, dropTargeted: dropTargeted) {
            screen(driver: driver, remoteInputReserved: remoteInputReserved, allowsInput: allowsInput)
        } gutter: {
            DeviceGutter(enabled: streamError == nil && allowsInput) {
                button("arrow.uturn.backward", "Back", "back")
                button("circle", "Home", "home")
                button("square.on.square", "Recents", "app_switch")
                button("power", "Power", "power")
                button("speaker.wave.3", "Volume up", "volume_up")
                button("speaker.wave.1", "Volume down", "volume_down")
                DeviceGutterButton(icon: "rotate.left", help: "Rotate left") { rotate(left: true) }
                DeviceGutterButton(icon: "rotate.right", help: "Rotate right") { rotate(left: false) }
            }
        }
    }

    /// The video's own shape, upright, with corners like a phone's.
    private var shape: DeviceScreenShape? {
        client.videoSizes[device.serial].map {
            DeviceScreenShape(widthPoints: $0.width, heightPoints: $0.height, cornerRadiusPoints: min($0.width, $0.height) * 0.06)
        }
    }

    private func screen(driver: VMDriver, remoteInputReserved: Bool, allowsInput: Bool) -> some View {
        ZStack(alignment: .top) {
            DeviceScreenView(
                udid: device.serial, client: client, onStopped: { streamError = $0 },
                allowsInput: allowsInput, remoteInputGate: control, onBlockedClick: pulsePill,
                onDropApp: install,
                onDropTargeted: { dropTargeted = $0 },
                canDrop: { $0.pathExtension.lowercased() == "apk" },
                onPaste: paste, onCopy: copy,
                onUserInput: onUse,
                onGesture: flowRecorder.isRecording(device.serial) ? { flowRecorder.gesture(device.serial, from: $0, to: $1) } : nil,
                onText: flowRecorder.isRecording(device.serial) ? { flowRecorder.typed(device.serial, $0) } : nil,
                onScroll: flowRecorder.isRecording(device.serial) ? { flowRecorder.scrolled(device.serial, dx: $0, dy: $1) } : nil
            )
            .id("\(device.serial):\(streamGeneration)")
            if let streamError {
                theme.color("bg-2").opacity(0.92)
                DevicesEmptyState(
                    symbol: "exclamationmark.triangle", title: "The screen stopped", detail: streamError,
                    action: .init(title: "Retry", icon: "arrow.clockwise") {
                        self.streamError = nil
                        streamGeneration += 1
                    }
                )
            }
            if remoteInputReserved {
                DeviceStagePill {
                    Text(remoteDriverName.map { "\($0) is driving" } ?? "Switching device control…")
                        .foregroundStyle(theme.color("fg"))
                    Button("Reclaim") {
                        control.reclaimRemoteInput(udid: device.serial)
                        onReclaimRemote()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.color("accent"))
                }
                .scaleEffect(pulse ? 1.06 : 1)
                .animation(.easeOut(duration: 0.2), value: pulse)
                .padding(.top, scale.space[2])
            } else if streamError == nil, driver != .idle {
                DeviceDriverPill(
                    driver: driver, waiting: control.waitingSessions(udid: device.serial).first, agentName: agentName,
                    flow: control.flowRuns[device.serial], pulse: pulse, onTakeOver: { control.takeOver(udid: device.serial) },
                    onHandBack: { control.handBack(udid: device.serial) }
                )
                .padding(.top, scale.space[2])
            }
        }
        .overlay(alignment: .bottom) {
            if let install = pane.appInstalls[device.serial] {
                DeviceAppInstallPill(install: install) { pane.dismissAppInstall(serial: device.serial) }
            } else if let notice = pane.notices[device.serial] {
                DeviceStagePill { Text(notice).foregroundStyle(theme.color("fg")) }
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

    private func button(_ icon: String, _ help: String, _ name: String) -> some View {
        DeviceGutterButton(icon: icon, help: help) {
            guard control.allowsLocalInput(udid: device.serial, at: now) else { return }
            client.button(udid: device.serial, name: name)
            if let key = ["home": DeviceFlow.Key.home, "back": .back][name] { flowRecorder.pressed(device.serial, key) }
        }
    }

    private func rotate(left: Bool) {
        Task {
            _ = await control.whileUserHoldsInput(udid: device.serial) { await pane.rotate(device, left: left) }
        }
    }

    private func install(_ apk: URL) {
        Task {
            _ = await control.whileUserHoldsInput(udid: device.serial) { await pane.installAndLaunch(apk, on: device) }
        }
    }

    private func paste() {
        guard control.allowsLocalInput(udid: device.serial, at: now) else { return }
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            return pane.show("The clipboard has no text to paste.", serial: device.serial)
        }
        client.paste(udid: device.serial, text: text)
        flowRecorder.pasted(device.serial, text)
    }

    private func copy() {
        Task {
            _ = await control.whileUserHoldsInput(udid: device.serial) {
                guard let text = await client.copy(udid: device.serial) else {
                    return pane.show("Nothing was copied. Select some text first.", serial: device.serial)
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                pane.show("Copied", serial: device.serial)
            }
        }
    }
}
