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

    private var folder: URL { worktree.appendingPathComponent(".maestro", isDirectory: true) }

    var body: some View {
        let recording = recorder.isRecording(udid)
        ToolbarBtn(icon: "hand.tap", tooltip: recording ? "Stop recording flow" : "Record flow", isActive: recording) {
            if recording {
                recorded = recorder.stop(udid)
                name = "flow-\(Self.stamp.string(from: Date()))"
                saveError = nil
            } else if let backend {
                Task { await recorder.start(udid: udid, backend: backend) }
            }
        }
        .disabled(!enabled && !recording)
        .popover(isPresented: Binding(get: { recorded != nil }, set: { if !$0 { recorded = nil } }), arrowEdge: .bottom) {
            saveForm
        }
        ToolbarMenuButton(iconName: "play.rectangle", help: "Run flow") {
            let flows = Self.flows(in: folder)
            if flows.isEmpty {
                Text("No flows in .maestro")
            }
            ForEach(flows, id: \.self) { file in
                Button(file.deletingPathExtension().lastPathComponent) { run(file) }
            }
        }
        .disabled(!enabled || recording)
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
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 64,
              trimmed.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            saveError = "Use letters, digits, - and _."
            return
        }
        let file = folder.appendingPathComponent("\(trimmed).yaml")
        guard !FileManager.default.fileExists(atPath: file.path) else {
            saveError = "\(trimmed).yaml already exists."
            return
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try recorded.yaml.write(to: file, atomically: true, encoding: .utf8)
            self.recorded = nil
        } catch {
            saveError = error.localizedDescription
        }
    }

    /// Runs as the "flow" session, so the stage shows its progress and Take over stops it.
    private func run(_ file: URL) {
        // Running a flow hands the device to it.
        if case .user = control.driver(udid: udid) { control.handBack(udid: udid) }
        Task {
            let response = await control.perform(
                .runFlow(udid: udid, path: file.path), sessionID: DeviceAgentControl.userFlowSession
            )
            result = Self.summary(response, name: file.deletingPathExtension().lastPathComponent)
        }
    }

    static func summary(_ response: AlasCLIResponse, name: String) -> String {
        switch response {
        case .text(let parts):
            guard let reply = (try? JSONSerialization.jsonObject(with: Data(parts.joined().utf8))) as? [String: Any] else {
                return parts.joined()
            }
            if reply["passed"] as? Bool == true { return "\(name) passed: \(reply["steps"] as? Int ?? 0) steps." }
            let step = reply["failed_step"] as? Int ?? 0
            let line = reply["line"] as? Int ?? 0
            return "\(name) failed at step \(step) (line \(line)): \(reply["reason"] as? String ?? "")"
        case .error(let message):
            return message
        default:
            return "\(name) ran."
        }
    }

    private static func flows(in folder: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { ["yaml", "yml"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter
    }()
}
