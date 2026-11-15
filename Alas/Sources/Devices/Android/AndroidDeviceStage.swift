import AlasCore
import AppKit
import SwiftUI

/// A connected Android device's live screen, framed at its video's shape,
/// with Back, Home, Recents, Power, volume and rotation in the gutter.
struct AndroidDeviceStage: View {
    let device: AndroidDevice
    let client: AndroidStreamClient
    let pane: AndroidPaneModel
    @Environment(\.theme) private var theme
    @State private var streamError: String?
    @State private var streamGeneration = 0
    @State private var dropTargeted = false

    var body: some View {
        DeviceStageFrame(shape: shape, landscape: false, dropTargeted: dropTargeted) {
            screen
        } gutter: {
            DeviceGutter(enabled: streamError == nil) {
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

    private var screen: some View {
        ZStack {
            DeviceScreenView(
                udid: device.serial, client: client, onStopped: { streamError = $0 },
                onDropApp: { apk in Task { await pane.installAndLaunch(apk, on: device) } },
                onDropTargeted: { dropTargeted = $0 },
                canDrop: { $0.pathExtension.lowercased() == "apk" },
                onPaste: paste, onCopy: copy
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
        }
        .overlay(alignment: .bottom) {
            if let install = pane.appInstalls[device.serial] {
                DeviceAppInstallPill(install: install) { pane.dismissAppInstall(serial: device.serial) }
            } else if let notice = pane.notices[device.serial] {
                DeviceStagePill { Text(notice).foregroundStyle(theme.color("fg")) }
            }
        }
    }

    private func button(_ icon: String, _ help: String, _ name: String) -> some View {
        DeviceGutterButton(icon: icon, help: help) { client.button(udid: device.serial, name: name) }
    }

    private func rotate(left: Bool) {
        Task { await pane.rotate(device, left: left) }
    }

    private func paste() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            return pane.show("The clipboard has no text to paste.", serial: device.serial)
        }
        client.paste(udid: device.serial, text: text)
    }

    private func copy() {
        Task {
            guard let text = await client.copy(udid: device.serial) else {
                return pane.show("Nothing was copied. Select some text first.", serial: device.serial)
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            pane.show("Copied", serial: device.serial)
        }
    }
}
