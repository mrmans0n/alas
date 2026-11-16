import AlasCore
import SwiftUI

/// The Devices tab's toolbar actions for an Android device: a screen
/// recording, a screenshot to the Desktop, and Shut Down for an emulator.
struct AndroidActions: View {
    let device: AndroidDevice
    let pane: AndroidPaneModel
    let control: DeviceAgentControl
    let recorder: DeviceRecorder
    let flowRecorder: DeviceFlowRecorder
    let worktree: URL
    let onOpenLogs: () -> Void
    let onShutDown: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale
    @State private var notice: String?
    @State private var showsSettings = false

    var body: some View {
        HStack(spacing: 2) {
            if let notice {
                Text(notice)
                    .font(scale.caption.font(weight: .regular))
                    .foregroundStyle(theme.color("fg-dim"))
                    .lineLimit(1)
                    .transition(.opacity)
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(2))
                        withAnimation { self.notice = nil }
                    }
            }
            ToolbarBtn(icon: "doc.text.magnifyingglass", tooltip: "Logs", action: onOpenLogs)
            ToolbarBtn(icon: "slider.horizontal.3", tooltip: "Device settings") { showsSettings = true }
                .disabled(!VMDriver.allowsViewInput(control.driver(udid: device.serial)))
                .popover(isPresented: $showsSettings, arrowEdge: .bottom) {
                    if let backend = control.backend(for: .android) {
                        DeviceSettingsPopover(udid: device.serial, backend: backend, control: control)
                    }
                }
            DeviceFlowButtons(
                udid: device.serial, backend: control.backend(for: .android), control: control, recorder: flowRecorder,
                worktree: worktree, enabled: VMDriver.allowsViewInput(control.driver(udid: device.serial))
            )
            recordButton
            ToolbarBtn(icon: "camera", tooltip: "Save screenshot to Desktop") { Task { await saveScreenshot() } }
            if device.isEmulator {
                ToolbarMenuButton(iconName: "ellipsis", help: "More") {
                    Button("Shut Down", action: onShutDown)
                }
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private var recordButton: some View {
        switch recorder.owner(udid: device.serial) {
        case nil:
            ToolbarBtn(icon: "record.circle", tooltip: "Record screen (up to 3 minutes)") {
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("alas-recording-\(UUID().uuidString).mp4")
                do throws(DeviceRecorder.Failure) {
                    try recorder.start(udid: device.serial, owner: .user, file: file)
                } catch {
                    withAnimation { notice = "Couldn't start recording" }
                }
            }
        case .user:
            ToolbarBtn(icon: "stop.circle.fill", tooltip: "Stop recording", isActive: true) {
                Task { await stopRecording() }
            }
        case .agent:
            ToolbarBtn(icon: "record.circle", tooltip: "An agent is recording", isActive: true) {}
                .disabled(true)
        }
    }

    private func stopRecording() async {
        let text: String
        do {
            _ = try await recorder.stop(udid: device.serial, owner: .user)
            text = "Saved to Desktop"
        } catch DeviceRecorder.Failure.notSaved {
            text = "Couldn't save to the Desktop; it's shown in Finder"
        } catch {
            text = "Couldn't save the recording"
        }
        withAnimation { notice = text }
    }

    private func saveScreenshot() async {
        let text: String
        do {
            guard let control = pane.control else { throw AndroidControlError("No Android SDK.") }
            let png = try await control.screenshot(serial: device.serial)
            _ = try DeviceScreenshot.savePNGToDesktop(png, kind: "Android Screenshot", deviceName: device.title)
            text = "Saved to Desktop"
        } catch {
            text = "Couldn't save the screenshot"
        }
        withAnimation { notice = text }
    }
}
