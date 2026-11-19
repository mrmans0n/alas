import AlasCore
import SwiftUI

/// The Devices tab's flow buttons: Record Flow, which saves what you do on the
/// device to `.maestro/<name>.yaml` in the worktree, and Run Flow, which
/// replays one of those files on the device.
struct DeviceFlowButtons: View {
    let udid: String
    let backend: (any DeviceBackend)?
    let control: DeviceAgentControl
    let recorder: DeviceFlowRecorder
    let worktree: URL
    /// Booted, and no agent drives it.
    let enabled: Bool
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale
    /// A recording waiting for its name.
    @State private var recorded: DeviceFlow?
    @State private var name = ""
    @State private var saveError: String?
    /// What the last run you started answered.
    @State private var result: String?

    private var folder: URL { DeviceFlowFiles.folder(in: worktree) }

    var body: some View {
        let recording = recorder.isRecording(udid)
        ToolbarBtn(icon: "hand.tap", tooltip: recording ? "Stop recording flow" : "Record flow", isActive: recording) {
            if recording {
                recorded = recorder.stop(udid)
                name = DeviceFlowFiles.defaultName(at: Date())
                saveError = nil
            } else if let backend {
                Task { await recorder.start(udid: udid, backend: backend) }
            }
        }
        .disabled(!enabled && !recording)
        .popover(isPresented: Binding(get: { recorded != nil }, set: { if !$0 { recorded = nil } }), arrowEdge: .bottom) {
            saveForm
        }
        // A flow you start runs only on an idle device: taking it from you here would let held agent calls in first.
        let held = control.driver(udid: udid) == .user
        ToolbarMenuButton(iconName: "play.rectangle", help: held ? "Hand the device back to run a flow" : "Run flow") {
            let flows = DeviceFlowFiles.flows(in: folder)
            if flows.isEmpty {
                Text("No flows in .maestro")
            }
            ForEach(flows, id: \.self) { file in
                Button(file.deletingPathExtension().lastPathComponent) { run(file) }
            }
        }
        .disabled(!enabled || recording || held)
        .popover(isPresented: Binding(get: { result != nil }, set: { if !$0 { result = nil } }), arrowEdge: .bottom) {
            Text(result ?? "")
                .font(scale.meta.font)
                .foregroundStyle(theme.color("fg"))
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 280, alignment: .leading)
                .padding(scale.space[4])
        }
    }

    private var saveForm: some View {
        VStack(alignment: .leading, spacing: scale.space[3]) {
            Text("\(recorded?.steps.count ?? 0) steps recorded")
                .font(scale.meta.font(weight: .semibold))
                .foregroundStyle(theme.color("fg"))
            HStack(spacing: 6) {
                TextField("Name", text: $name)
                    .onSubmit(save)
                Text(".yaml").foregroundStyle(theme.color("fg-dim"))
            }
            if let saveError {
                Text(saveError)
                    .foregroundStyle(theme.color("warn"))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Discard", role: .destructive) { recorded = nil }
                Spacer()
                Button("Save", action: save).keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .font(scale.meta.font)
        .padding(scale.space[4])
        .frame(width: 280)
    }

    private func save() {
        guard let recorded else { return }
        if let error = DeviceFlowFiles.save(recorded, name: name, in: folder) {
            saveError = error
        } else {
            self.recorded = nil
        }
    }

    /// Runs as the "flow" session, so the stage shows its progress and Take over stops it.
    private func run(_ file: URL) {
        Task {
            let response = await control.perform(
                .runFlow(udid: udid, path: file.path), sessionID: DeviceAgentControl.userFlowSession
            )
            result = DeviceFlowFiles.summary(response, name: file.deletingPathExtension().lastPathComponent)
        }
    }
}
