import AlasCore
import SwiftUI

/// The Devices tab's toolbar chip: the selected device, and a menu of the
/// Mac's simulators and this worktree's VMs.
struct DevicesSwitcher: View {
    let state: DevicesTabState
    let onSelect: (DevicesTarget) -> Void
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale
    @State private var hovering = false

    var body: some View {
        let selected = (state.simulatorRows + state.vmRows).first { $0.target == state.selected }
        Menu {
            Section("Simulators") {
                if let note = state.simulatorsNote {
                    Text(note)
                }
                ForEach(state.simulatorRows) { item($0) }
            }
            if !state.vmRows.isEmpty {
                Section("This worktree's VMs") {
                    ForEach(state.vmRows) { item($0) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(theme.color(Self.colorToken(selected?.tone ?? .idle)))
                    .frame(width: 8, height: 8)
                Text(selected?.title ?? "Devices")
                    .font(scale.meta.font(weight: .semibold))
                    .foregroundStyle(theme.color("fg"))
                if let detail = selected?.detail {
                    Text(detail)
                        .font(scale.meta.font)
                        .foregroundStyle(theme.color("fg-dim"))
                }
                Image(systemName: "chevron.down")
                    .font(scale.glyphFont)
                    .foregroundStyle(theme.color("fg-muted"))
            }
            .lineLimit(1)
            .padding(.horizontal, scale.space[2])
            .frame(height: 22)
            .background(hovering ? theme.color("bg-3") : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.toolbarControl)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help("Choose a device")
        .accessibilityIdentifier("devices-switcher")
    }

    private func item(_ row: DevicesTabState.Row) -> some View {
        Toggle(isOn: Binding(get: { row.target == state.selected }, set: { _ in onSelect(row.target) })) {
            Text(row.title)
            Text(row.detail)
        }
    }

    static func colorToken(_ tone: DevicesTabState.Tone) -> String {
        switch tone {
        case .live: "add"
        case .busy: "warn"
        case .idle: "fg-faint"
        }
    }
}

/// The Devices tab's toolbar actions for a simulator: its logs and settings,
/// a screen recording and a screenshot to the Desktop, and Shut Down.
struct DevicesActions: View {
    let device: SimulatorDevice
    let booted: Bool
    let client: SimulatorStreamClient
    let control: DeviceAgentControl
    /// Booted, and no agent drives it.
    let canChangeSettings: Bool
    let onShutDown: () -> Void
    let onOpenLogs: () -> Void
    let recorder: DeviceRecorder
    /// Names the agent session recording the device.
    let agentName: (String) -> String
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale
    /// "Saved to Desktop", or why it wasn't, for a moment after a click.
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
                .disabled(!booted)
            ToolbarBtn(icon: "slider.horizontal.3", tooltip: "Simulator settings") { showsSettings = true }
                .disabled(!canChangeSettings)
                .popover(isPresented: $showsSettings, arrowEdge: .bottom) {
                    DeviceSettingsPopover(udid: device.udid, settings: LiveSimulatorSettings(), control: control)
                }
            recordButton
            ToolbarBtn(icon: "camera", tooltip: "Save screenshot to Desktop", action: saveScreenshot)
                .disabled(!booted)
            ToolbarMenuButton(iconName: "ellipsis", help: "More") {
                Button("Shut Down", action: onShutDown)
                    .disabled(!booted)
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private var recordButton: some View {
        switch recorder.owner(udid: device.udid) {
        case nil:
            ToolbarBtn(icon: "record.circle", tooltip: "Record screen") {
                do throws(DeviceRecorder.Failure) {
                    try recorder.start(udid: device.udid, owner: .user, file: Self.userRecordingFile())
                } catch {
                    withAnimation { notice = "Couldn't start recording" }
                }
            }
            .disabled(!booted)
        case .user:
            ToolbarBtn(icon: "stop.circle.fill", tooltip: "Stop recording", isActive: true) {
                Task { await stopRecording() }
            }
        case .agent(let sessionID):
            ToolbarBtn(icon: "record.circle", tooltip: "\(agentName(sessionID)) is recording", isActive: true) {}
                .disabled(true)
        }
    }

    /// A temporary file; stopping moves it to the Desktop.
    private static func userRecordingFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("alas-recording-\(UUID().uuidString).mov")
    }

    private func stopRecording() async {
        let text: String
        do {
            // The recorder saves it to the Desktop (AppState's onUserRecordingEnded).
            _ = try await recorder.stop(udid: device.udid, owner: .user)
            text = "Saved to Desktop"
        } catch {
            text = "Couldn't save the recording"
        }
        withAnimation { notice = text }
    }

    private func saveScreenshot() {
        let text: String
        if let frame = client.lastFrame(udid: device.udid) {
            do {
                _ = try DeviceScreenshot.saveToDesktop(frame, deviceName: device.name)
                text = "Saved to Desktop"
            } catch {
                text = "Couldn't save the screenshot"
            }
        } else {
            text = "No frame yet"
        }
        withAnimation { notice = text }
    }
}
