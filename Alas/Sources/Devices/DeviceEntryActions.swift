import AlasCore
import AppKit
import SwiftUI

/// A simulator's or Android device's actions in its Devices header: a lit Stop
/// for a recording or flow recording under way, a screenshot, then the rest in
/// a menu. Popovers the menu opens hang off it.
struct DeviceEntryActions: View {
    enum Kind {
        case simulator(SimulatorDevice)
        case android(AndroidDevice)
    }

    let kind: Kind
    /// It has a screen: a booted simulator, a ready Android device.
    let ready: Bool
    let control: DeviceAgentControl
    let recorder: DeviceRecorder
    let flowRecorder: DeviceFlowRecorder
    let worktree: URL
    let accessibilityOverlay: Bool
    let onToggleAccessibilityOverlay: () -> Void
    let onOpenLogs: () -> Void
    /// Saves a screenshot to the Desktop and says how it went.
    let onScreenshot: () async -> String
    /// Nil where Alas can't shut it down: a USB phone.
    let onShutDown: (() -> Void)?
    /// A short message over the bottom of the screen.
    let onNotice: (String) -> Void
    /// Names the agent session recording the device.
    var agentName: (String) -> String = { _ in "An agent" }
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale
    @State private var showsSettings = false
    /// A flow recording waiting for its name.
    @State private var recordedFlow: DeviceFlow?
    @State private var flowName = ""
    @State private var flowSaveError: String?
    /// What the last flow you ran answered.
    @State private var flowResult: String?

    private var udid: String {
        switch kind {
        case .simulator(let device): device.udid
        case .android(let device): device.serial
        }
    }

    private var platform: AgentDevice.Platform {
        if case .simulator = kind { .ios } else { .android }
    }

    /// It has a screen, and no agent drives it.
    private var canChange: Bool { ready && VMDriver.allowsViewInput(control.driver(udid: udid)) }

    private var flowFolder: URL { DeviceFlowFiles.folder(in: worktree) }

    var body: some View {
        HStack(spacing: 2) {
            switch recorder.owner(udid: udid) {
            case .user?:
                ToolbarBtn(icon: "stop.circle.fill", tooltip: "Stop recording", isActive: true) {
                    Task { await stopRecording() }
                }
            case .agent(let sessionID)?:
                ToolbarBtn(icon: "record.circle", tooltip: "\(agentName(sessionID)) is recording", isActive: true) {}
                    .disabled(true)
            case nil:
                EmptyView()
            }
            if flowRecorder.isRecording(udid) {
                ToolbarBtn(icon: "hand.tap", tooltip: "Stop recording flow", isActive: true, action: stopFlowRecording)
            }
            ToolbarBtn(icon: "camera", tooltip: "Save screenshot to Desktop") {
                Task { onNotice(await onScreenshot()) }
            }
            .disabled(!ready)
            ToolbarMenuButton(iconName: "ellipsis", help: "More") { menu }
                // One popover per view: each hangs off its own clear background.
                .background { Color.clear.popover(isPresented: $showsSettings, arrowEdge: .bottom) { settings } }
                .background { Color.clear.popover(isPresented: savingFlow, arrowEdge: .bottom) { flowSaveForm } }
                .background { Color.clear.popover(isPresented: showingFlowResult, arrowEdge: .bottom) { flowResultText } }
        }
        .fixedSize()
    }

    @ViewBuilder
    private var menu: some View {
        Button("Settings…") { showsSettings = true }
            .disabled(!canChange)
        Button("Logs", action: onOpenLogs)
            .disabled(!ready)
        if case .simulator = kind {
            Button(
                accessibilityOverlay ? "Hide Accessibility Overlay" : "Show Accessibility Overlay",
                action: onToggleAccessibilityOverlay
            )
            .disabled(!ready)
        }
        Divider()
        recordItem
        flowItems
        if let onShutDown {
            Divider()
            Button("Shut Down", action: onShutDown)
                .disabled(!ready)
        }
    }

    @ViewBuilder
    private var recordItem: some View {
        switch recorder.owner(udid: udid) {
        case nil:
            Button(platform == .ios ? "Record Screen" : "Record Screen (up to 3 Minutes)", action: startRecording)
                .disabled(!ready)
        case .user:
            Button("Stop Recording") { Task { await stopRecording() } }
        case .agent(let sessionID):
            Button("\(agentName(sessionID)) Is Recording") {}
                .disabled(true)
        }
    }

    @ViewBuilder
    private var flowItems: some View {
        let recording = flowRecorder.isRecording(udid)
        if recording {
            Button("Stop Recording Flow…", action: stopFlowRecording)
        } else {
            Button("Record Flow") {
                guard let backend = control.backend(for: platform) else { return }
                Task { await flowRecorder.start(udid: udid, backend: backend) }
            }
            .disabled(!canChange)
        }
        // A flow you start runs only on an idle device: taking it from you here would let held agent calls in first.
        let held = control.driver(udid: udid) == .user
        Menu(held ? "Run Flow (Hand the Device Back First)" : "Run Flow") {
            let flows = DeviceFlowFiles.flows(in: flowFolder)
            if flows.isEmpty {
                Text("No flows in .maestro")
            }
            ForEach(flows, id: \.self) { file in
                Button(file.deletingPathExtension().lastPathComponent) { runFlow(file) }
            }
        }
        .disabled(!canChange || recording || held)
    }

    @ViewBuilder
    private var settings: some View {
        if let backend = control.backend(for: platform) {
            DeviceSettingsPopover(udid: udid, backend: backend, control: control)
        }
    }

    private var savingFlow: Binding<Bool> {
        Binding(get: { recordedFlow != nil }, set: { if !$0 { recordedFlow = nil } })
    }

    private var showingFlowResult: Binding<Bool> {
        Binding(get: { flowResult != nil }, set: { if !$0 { flowResult = nil } })
    }

    private var flowSaveForm: some View {
        VStack(alignment: .leading, spacing: scale.space[3]) {
            Text("\(recordedFlow?.steps.count ?? 0) steps recorded")
                .font(scale.meta.font(weight: .semibold))
                .foregroundStyle(theme.color("fg"))
            HStack(spacing: 6) {
                TextField("Name", text: $flowName)
                    .onSubmit(saveFlow)
                Text(".yaml").foregroundStyle(theme.color("fg-dim"))
            }
            if let flowSaveError {
                Text(flowSaveError)
                    .foregroundStyle(theme.color("warn"))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Discard", role: .destructive) { recordedFlow = nil }
                Spacer()
                Button("Save", action: saveFlow).keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .font(scale.meta.font)
        .padding(scale.space[4])
        .frame(width: 280)
    }

    private var flowResultText: some View {
        Text(flowResult ?? "")
            .font(scale.meta.font)
            .foregroundStyle(theme.color("fg"))
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 280)
            .padding(scale.space[4])
    }

    private func startRecording() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-recording-\(UUID().uuidString).\(platform == .ios ? "mov" : "mp4")")
        do throws(DeviceRecorder.Failure) {
            try recorder.start(udid: udid, owner: .user, file: file)
        } catch {
            onNotice("Couldn't start recording")
        }
    }

    private func stopRecording() async {
        do {
            // The recorder saves it to the Desktop (AppState's onUserRecordingEnded).
            _ = try await recorder.stop(udid: udid, owner: .user)
            onNotice("Saved to Desktop")
        } catch DeviceRecorder.Failure.notSaved {
            onNotice("Couldn't save to the Desktop; it's shown in Finder")
        } catch {
            onNotice("Couldn't save the recording")
        }
    }

    private func stopFlowRecording() {
        recordedFlow = flowRecorder.stop(udid)
        flowName = DeviceFlowFiles.defaultName(at: Date())
        flowSaveError = nil
    }

    private func saveFlow() {
        guard let recordedFlow else { return }
        if let error = DeviceFlowFiles.save(recordedFlow, name: flowName, in: flowFolder) {
            flowSaveError = error
        } else {
            self.recordedFlow = nil
        }
    }

    /// Runs as the "flow" session, so the screen shows its progress and Take over stops it.
    private func runFlow(_ file: URL) {
        Task {
            let response = await control.perform(
                .runFlow(udid: udid, path: file.path), sessionID: DeviceAgentControl.userFlowSession
            )
            flowResult = DeviceFlowFiles.summary(response, name: file.deletingPathExtension().lastPathComponent)
        }
    }
}

/// A running device's header actions, wired to the app.
struct DeviceEntryLiveActions: View {
    let state: AppState
    let worktree: Worktree
    let device: DevicesTabState.Running

    var body: some View {
        switch device.screen {
        case .simulator(let simulator, let stage):
            DeviceEntryActions(
                kind: .simulator(simulator), ready: stage == .booted, control: state.deviceControl,
                recorder: state.deviceRecorder, flowRecorder: state.deviceFlowRecorder, worktree: worktree.path,
                accessibilityOverlay: state.devicePane.accessibilityOverlays.contains(simulator.udid),
                onToggleAccessibilityOverlay: { state.devicePane.toggleAccessibilityOverlay(udid: simulator.udid) },
                onOpenLogs: {
                    state.openDeviceLogs(worktreeID: worktree.id, udid: simulator.udid, name: simulator.name, platform: .ios)
                },
                onScreenshot: { Self.saveScreenshot(state.simulatorStreams.lastFrame(udid: simulator.udid), name: simulator.name) },
                onShutDown: { Task { await state.devicePane.shutDown(simulator) } },
                onNotice: { state.devicePane.show($0, udid: simulator.udid) },
                agentName: { state.computerUseAgentName($0) }
            )
        case .android(let target, let stage):
            if let android = target.device {
                DeviceEntryActions(
                    kind: .android(android), ready: stage == .ready, control: state.deviceControl,
                    recorder: state.deviceRecorder, flowRecorder: state.deviceFlowRecorder, worktree: worktree.path,
                    accessibilityOverlay: false, onToggleAccessibilityOverlay: {},
                    onOpenLogs: {
                        state.openDeviceLogs(worktreeID: worktree.id, udid: android.serial, name: android.title, platform: .android)
                    },
                    onScreenshot: { await Self.saveScreenshot(android, pane: state.androidPane) },
                    onShutDown: android.isEmulator ? {
                        Task {
                            // Saves a recording before the device goes.
                            await state.deviceRecorder.simulatorStopped(udid: android.serial)
                            await state.androidPane.shutDown(android)
                        }
                    } : nil,
                    onNotice: { state.androidPane.show($0, serial: android.serial) },
                    agentName: { state.computerUseAgentName($0) }
                )
            }
        case .vm(let guest, let status):
            // A VM still booting can be stopped too, as its tab allows.
            VMEntryActions(canStop: status == .running || status == .starting) {
                Task { await state.vmManager.stopVM(worktreeID: worktree.id, guest: guest) }
            }
        }
    }

    static func saveScreenshot(_ frame: DeviceFrame?, name: String) -> String {
        guard let frame else { return "No frame yet" }
        do {
            _ = try DeviceScreenshot.saveToDesktop(frame, deviceName: name)
            return "Saved to Desktop"
        } catch {
            return "Couldn't save the screenshot"
        }
    }

    static func saveScreenshot(_ device: AndroidDevice, pane: AndroidPaneModel) async -> String {
        do {
            guard let control = pane.control else { throw AndroidControlError("No Android SDK.") }
            let png = try await control.screenshot(serial: device.serial)
            _ = try DeviceScreenshot.savePNGToDesktop(png, kind: "Android Screenshot", deviceName: device.title)
            return "Saved to Desktop"
        } catch {
            return "Couldn't save the screenshot"
        }
    }
}

/// A VM's actions in its Devices header: Stop, in a menu.
struct VMEntryActions: View {
    let canStop: Bool
    let onStop: () -> Void

    var body: some View {
        ToolbarMenuButton(iconName: "ellipsis", help: "More") {
            Button("Stop VM", action: onStop)
                .disabled(!canStop)
        }
        .fixedSize()
    }
}
