#if DEBUG
import AlasCore
import AppKit
import IOSurface
import SwiftUI

/// Design-capture targets for the Devices tab. The real tab lists the Mac's simulators through
/// `simctl`, streams a booted one over XPC and reads VM state from the VM manager, none of which a
/// capture may touch. Each target draws a gallery of tab states in a panel over the main window,
/// from the tab's own views (`DevicesRailList`, `DeviceEntryHeader`, `DeviceEntryActions`,
/// `DeviceStage`, `DevicesEmptyState`, `DevicesAddPanel`, `DeviceSettingsPopover`) and the same
/// `DevicesTabState` resolver, over scripted devices and an in-memory `DeviceAgentControl`. A
/// scripted simulator's screen is a painted placeholder (`DesignCaptureDevices.demoScreen`) and a
/// VM's a gradient; no frame is streamed, no simulator is booted, no VM is read. Debug builds
/// only, and only on a capture profile.
///
/// - devices: one simulator an agent drives while an app launches; one you drive while an agent
///   waits and an install failed; a simulator and the macOS VM, at 300 and 420 pt; three devices
///   with one collapsed and the VM in a tab.
/// - devices-empty: loading, no Xcode, no simulators, nothing running with a boot error, a
///   simulator booting, a VM starting.
/// - devices-settings: the simulator settings popover over scripted values.
/// - devices-switcher: + Add's popover: as it opens, filtered, and hovering a shut-down row.
@MainActor
enum DesignCaptureDevices {
    static let targets: Set<String> = ["devices", "devices-empty", "devices-settings", "devices-switcher"]

    /// A scripted simulator's UDID starts with this; no real one does.
    static let demoUDIDPrefix = "DEMO-SIM-"

    static func isDemoUDID(_ udid: String) -> Bool {
        DesignCaptureWorkspace.isCaptureInstance && udid.hasPrefix(demoUDIDPrefix)
    }

    private static let phone = SimulatorDevice(
        udid: demoUDIDPrefix + "PHONE", name: "iPhone 17 Pro", runtimeName: "iOS 26.5", state: .booted,
        deviceTypeIdentifier: "demo.phone")
    private static let air = SimulatorDevice(
        udid: demoUDIDPrefix + "AIR", name: "iPhone Air", runtimeName: "iOS 26.5", state: .shutdown,
        deviceTypeIdentifier: "demo.phone")
    private static let pad = SimulatorDevice(
        udid: demoUDIDPrefix + "PAD", name: "iPad Pro 13-inch (M5)", runtimeName: "iOS 26.5", state: .shutdown,
        deviceTypeIdentifier: "demo.pad")
    private static let shape = DeviceScreenShape(widthPoints: 402, heightPoints: 874, cornerRadiusPoints: 62)

    static func open(_ target: String, state: AppState) {
        guard DesignCaptureWorkspace.isCaptureInstance, targets.contains(target) else { return }
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(30)
            while state.projects.isEmpty {
                guard Date() < deadline else { return }
                try? await Task.sleep(for: .milliseconds(200))
            }
            let theme = state.themeStore.current
            let scale = DesignScale.resolved(for: state.config.density)
            if target == "devices-settings" {
                let popover = SettingsPanel(control: makeControl())
                    .environment(\.theme, theme).environment(\.designScale, scale)
                DesignCaptureWorkspace.present(popover)
                return
            }
            if target == "devices-switcher" {
                let gallery = Gallery(cells: switcherCells(), columns: 3, height: 470)
                    .environment(\.theme, theme).environment(\.designScale, scale)
                DesignCaptureWorkspace.present(gallery)
                return
            }
            let control = makeControl()
            var cells: [Cell] = []
            if target == "devices" {
                cells = await driverCells(control: control)
            } else {
                cells = emptyCells()
            }
            let gallery = Gallery(cells: cells, columns: target == "devices" ? 4 : 3)
                .environment(\.theme, theme).environment(\.designScale, scale)
            DesignCaptureWorkspace.present(gallery)
        }
    }

    // MARK: - Scripted collaborators

    @MainActor
    private final class FakeInput: DeviceInput {
        func subscribe(
            udid: String, onFrame: @escaping @MainActor (DeviceFrame) -> Void, onStop: @escaping @MainActor (String) -> Void
        ) -> UUID { UUID() }
        func unsubscribe(udid: String, token: UUID) {}
        func touch(udid: String, phase: String, point: DeviceScreenPoint) {}
        func key(udid: String, usage: UInt32, down: Bool) {}
        func button(udid: String, name: String) {}
        func describe(udid: String) async throws -> Data { Data() }
        func lastFrame(udid: String) -> DeviceFrame? { nil }
        func rotate(udid: String, to orientation: DeviceScreenOrientation) async throws {}
    }

    private struct FakeSettings: SimulatorSettingsControl {
        private static let display = SimulatorDisplaySettings(
            appearance: .value(.dark), textSize: .value(.large), increaseContrast: .value(false))
        func display(udid: String) async throws -> SimulatorDisplaySettings { Self.display }
        func setDisplay(
            udid: String, appearance: SimulatorAppearance?, textSize: SimulatorTextSize?, increaseContrast: Bool?
        ) async throws -> SimulatorDisplaySettings { Self.display }
        func setPermission(udid: String, bundleID: String, service: SimulatorPrivacyService, action: SimulatorPrivacyAction) async throws {}
        func setLocation(udid: String, _ location: SimulatorLocation?) async throws {}
        func startRoute(udid: String, _ route: DeviceRoute) async throws {}
        func push(udid: String, bundleID: String, payload: Data) async throws {}
        func openURL(udid: String, url: String) async throws {}
        func userApps(udid: String) async throws -> [SimulatorApp] {
            [SimulatorApp(bundleID: "io.example.lantern", name: "Lantern"), SimulatorApp(bundleID: "io.example.lantern.beta", name: "Lantern Beta")]
        }
        func isInstalled(udid: String, bundleID: String) async -> Bool { true }
        private static let accessibility = SimulatorAccessibility(
            voiceOver: .value(false), reduceMotion: .value(true), buttonShapes: .value(false),
            reduceTransparency: .value(false), colorFilter: .value(.none), liquidGlass: .value(.clear))
        func accessibility(udid: String) async throws -> SimulatorAccessibility { Self.accessibility }
        func setAccessibility(udid: String, _ change: SimulatorAccessibilityChange) async throws -> SimulatorAccessibility {
            Self.accessibility
        }
        private static let slimState = SimulatorSlimState(
            servicesOff: 149, services: 173, persistent: true, memoryBytes: 998_579_814, processes: 76)
        func slim(udid: String) async throws -> SimulatorSlimState { Self.slimState }
        func setSlim(udid: String, on: Bool) async throws -> SimulatorSlimState { Self.slimState }
    }

    private struct FakeLogs: SimulatorLogsControl {
        func frontmostApp(udid: String) async -> String? { nil }
        func executables(udid: String) async throws -> [String: String] { [:] }
        func logShow(udid: String, query: SimulatorLogQuery, seconds: Int) async throws -> [SimulatorLogLine] { [] }
        func crashReports(udid: String, bundleID: String?, since: Date) async -> [SimulatorCrashReport] { [] }
    }

    private struct FakePasteboard: SimulatorPasteboardControl {
        func read(udid: String) async throws -> String { "" }
        func write(udid: String, text: String) async throws {}
        func access(udid: String, bundleID: String) async -> SimulatorPasteAccess { .allowed }
        func setAccess(udid: String, bundleID: String, _ action: SimulatorPrivacyAction) async throws {}
    }

    private static func fakeRecorder() -> DeviceRecorder {
        DeviceRecorder { _, _ in throw CocoaError(.featureUnsupported) }
    }

    private static func fakePasteboard() -> DevicePasteboard {
        DevicePasteboard(input: FakeInput(), pasteboard: FakePasteboard(), frontmostApp: { _ in nil })
    }

    private static func makeControl() -> DeviceAgentControl {
        DeviceAgentControl(
            backends: [SimulatorBackend(
                input: FakeInput(), devices: { [phone, air, pad] }, boot: { _ in }, install: { _, _ in },
                launch: { _, _ in 0 }, settings: FakeSettings(), logs: FakeLogs(), pasteboard: fakePasteboard())],
            recorder: fakeRecorder())
    }

    // MARK: - Gallery

    private struct Cell: Identifiable {
        let id = UUID()
        let label: String
        let content: AnyView
        /// The cell's width, when not the gallery's.
        let width: CGFloat?
        init(_ label: String, _ content: some View, width: CGFloat? = nil) {
            self.label = label
            self.content = AnyView(content)
            self.width = width
        }
    }

    private struct Gallery: View {
        let cells: [Cell]
        let columns: Int
        /// Cell height when not four columns.
        var height: CGFloat = 300
        @Environment(\.theme) private var theme

        var body: some View {
            let rows = stride(from: 0, to: cells.count, by: columns).map { Array(cells[$0..<min($0 + columns, cells.count)]) }
            VStack(spacing: 12) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: 12) { ForEach(row) { cell($0) } }
                }
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
                    .frame(width: cell.width ?? (columns == 4 ? 340 : 360), height: columns == 4 ? 560 : height)
                    .background(theme.color("bg-1"))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.color("line"), lineWidth: 0.5))
            }
        }
    }

    private struct SettingsPanel: View {
        let control: DeviceAgentControl
        @Environment(\.theme) private var theme

        var body: some View {
            DeviceSettingsPopover(
                udid: DesignCaptureDevices.phone.udid,
                backend: SimulatorBackend(
                    input: FakeInput(), devices: { [DesignCaptureDevices.phone] }, boot: { _ in }, install: { _, _ in },
                    launch: { _, _ in 0 }, settings: FakeSettings(), logs: FakeLogs(), pasteboard: fakePasteboard()
                ),
                control: control
            )
                .frame(height: 780, alignment: .top)
                .background(theme.color("bg-2"))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.color("line"), lineWidth: 0.5))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    /// The rail as the pane shows it: the toolbar's + Add over the stack.
    private static func railChrome(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Devices")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondary)
                Spacer(minLength: 0)
                ToolbarBtn(icon: "plus", tooltip: "Add a device") {}
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
            Divider()
            content()
        }
    }

    /// What a scripted VM shows: no VM runs in a capture.
    private static var vmScreen: some View {
        LinearGradient(
            colors: [Color(red: 0.16, green: 0.2, blue: 0.3), Color(red: 0.32, green: 0.42, blue: 0.56)],
            startPoint: .top, endPoint: .bottom
        )
        .overlay(Text("macOS VM").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.8)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(12)
    }

    @ViewBuilder
    private static func actions(_ device: DevicesTabState.Running, control: DeviceAgentControl) -> some View {
        switch device.screen {
        case .simulator(let simulator, let stage):
            DeviceEntryActions(
                kind: .simulator(simulator), ready: stage == .booted, control: control, recorder: fakeRecorder(),
                flowRecorder: DeviceFlowRecorder(), worktree: FileManager.default.temporaryDirectory,
                accessibilityOverlay: false, onToggleAccessibilityOverlay: {}, onOpenLogs: {},
                onScreenshot: { "" }, onShutDown: {}, onNotice: { _ in }
            )
        case .vm(_, let status):
            VMEntryActions(canStop: status == .running) {}
        case .android:
            EmptyView()
        }
    }

    private static func resolve(
        simulators: [SimulatorDevice]?, listError: String? = nil, vms: [VMGuestOS: VMDeviceStatus] = [:],
        lastUsed: DevicesTarget?, booting: Set<String> = [], driving: Set<DevicesTarget> = []
    ) -> DevicesTabState {
        .resolve(
            simulators: simulators, listError: listError, vms: vms, lastUsed: lastUsed, bootingUDIDs: booting,
            agentDriving: driving)
    }

    // MARK: - devices-switcher

    private static func switcherCells() -> [Cell] {
        func sim(_ id: String, _ name: String, _ runtime: String, _ state: SimulatorDevice.State = .shutdown) -> SimulatorDevice {
            SimulatorDevice(udid: demoUDIDPrefix + id, name: name, runtimeName: runtime, state: state, deviceTypeIdentifier: "demo.phone")
        }
        let simulators = [
            phone, air, pad, sim("SE", "iPhone 17", "iOS 26.5"),
            sim("MINI", "iPad mini (A17 Pro)", "iOS 26.0"), sim("16E", "iPhone 16e", "iOS 26.0"),
            sim("OLD", "iPhone 16 Pro", "iOS 18.6"), sim("OLDPAD", "iPad Air 11-inch (M2)", "iOS 18.6"),
        ]
        let emulator = AndroidDevice(
            serial: "emulator-5554", state: .ready, model: "sdk_gphone64_arm64", avdName: "Medium_Phone", release: "16")
        let state = DevicesTabState.resolve(
            simulators: simulators, listError: nil, vms: [.macOS: .stopped, .linux: .notCreated],
            lastUsed: .simulator(phone.udid), bootingUDIDs: [], agentDriving: [.android(emulator.serial)],
            android: AndroidListing(devices: [emulator], avds: ["Medium_Phone", "Pixel_9", "Pixel_Tablet"], bootingAVDs: [], note: nil),
            agentNames: [.android(emulator.serial): "Claude"]
        )
        func open(query: String = "", hovered: DevicesTarget? = nil) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                DevicesAddPanel(state: state, query: query, hovered: hovered, onSelect: { _ in }, onBoot: { _ in }, onClose: {})
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.gray.opacity(0.35), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        return [
            Cell("open", open()),
            Cell("filter \"ipad\"", open(query: "ipad")),
            Cell("hover a shut-down simulator", open(hovered: .simulator(air.udid))),
        ]
    }

    // MARK: - devices

    private static func driverCells(control: DeviceAgentControl) async -> [Cell] {
        let phoneUDID = phone.udid
        let air = Self.air
        // An agent's call is what makes it the driver, so run one through the in-memory control.
        _ = await control.perform(.button(udid: phoneUDID, name: .home, includeScreenshot: false), sessionID: "demo-agent")
        // A second simulator the user drives: the agent's call waits for the hand back.
        let userDevice = SimulatorDevice(
            udid: demoUDIDPrefix + "USER", name: "iPhone 17", runtimeName: "iOS 26.5", state: .booted, deviceTypeIdentifier: "demo.phone")
        let userControl = DeviceAgentControl(
            backends: [SimulatorBackend(
                input: FakeInput(), devices: { [userDevice] }, boot: { _ in }, install: { _, _ in },
                launch: { _, _ in 0 }, settings: FakeSettings(), logs: FakeLogs(), pasteboard: fakePasteboard())],
            recorder: fakeRecorder())
        userControl.takeOver(udid: userDevice.udid)
        Task { _ = await userControl.perform(.button(udid: userDevice.udid, name: .home, includeScreenshot: false), sessionID: "demo-agent") }
        try? await Task.sleep(for: .milliseconds(300))

        let now = Date()
        let client = SimulatorStreamClient()
        let second = SimulatorDevice(
            udid: demoUDIDPrefix + "SECOND", name: "iPhone 17", runtimeName: "iOS 26.5", state: .booted,
            deviceTypeIdentifier: "demo.phone")
        func phoneStage(_ device: SimulatorDevice, control: DeviceAgentControl, install: DevicePaneModel.AppInstall?) -> some View {
            DeviceStage(
                device: device, shape: shape, client: client, control: control, agentName: { _ in "Claude" }, now: now,
                appInstall: install, onDropApp: { _ in }, onDismissAppInstall: {}, notice: nil, onPaste: {}, onCopy: {},
                accessibilityOverlay: false, flowRecorder: DeviceFlowRecorder())
        }
        func rail(
            _ devices: DevicesTabState, collapsed: Set<DevicesTarget> = [], inCenter: Set<DevicesTarget> = [],
            control: DeviceAgentControl, install: DevicePaneModel.AppInstall? = nil
        ) -> some View {
            railChrome {
                DevicesRailList(
                    entries: DevicesRail.entries(devices.running, collapsed: collapsed, inCenter: inCenter),
                    scrollRequest: .constant(nil), onToggleCollapsed: { _ in }, onOpenInTab: { _ in },
                    onBringBack: { _ in }, onUse: { _ in },
                    aspect: { device in
                        if case .vm = device.screen { return 10.0 / 16.0 }
                        return Double(shape.heightPoints / shape.widthPoints)
                    },
                    stage: { device in
                        switch device.screen {
                        case .simulator(let simulator, .booted): phoneStage(simulator, control: control, install: install)
                        case .vm(_, .running): vmScreen
                        default: DeviceEntryStage.waitingState(for: device.screen)
                        }
                    },
                    actions: { actions($0, control: control) }
                )
            }
        }
        let phoneTarget = DevicesTarget.simulator(phoneUDID)
        let withVM = resolve(
            simulators: [phone, air], vms: [.macOS: .running, .linux: .stopped], lastUsed: nil, driving: [phoneTarget])
        return [
            Cell("one simulator: agent driving, app launching", rail(
                resolve(simulators: [phone, air, pad], vms: [.macOS: .stopped], lastUsed: nil, driving: [phoneTarget]),
                control: control, install: .launching("Lantern")
            ), width: 300),
            Cell("you drive, agent waiting, install failed", rail(
                resolve(simulators: [userDevice, air], lastUsed: nil), control: userControl,
                install: .failed("Couldn't open Lantern: the app was built for a device.")
            ), width: 300),
            Cell("simulator and macOS VM", rail(withVM, control: control), width: 300),
            Cell("simulator and macOS VM, 420 pt", rail(withVM, control: control), width: 420),
            Cell("three: one collapsed, the VM in a tab", rail(
                resolve(simulators: [phone, second], vms: [.macOS: .running], lastUsed: nil, driving: [phoneTarget]),
                collapsed: [.simulator(second.udid)], inCenter: [.vm(.macOS)], control: control
            ), width: 300),
        ]
    }

    // MARK: - devices-empty

    private static func emptyCells() -> [Cell] {
        let control = makeControl()
        func rail(_ devices: DevicesTabState) -> some View {
            railChrome {
                DevicesRailList(
                    entries: DevicesRail.entries(devices.running, collapsed: [], inCenter: []),
                    scrollRequest: .constant(nil), onToggleCollapsed: { _ in }, onOpenInTab: { _ in },
                    onBringBack: { _ in }, onUse: { _ in }, aspect: { _ in nil },
                    stage: { DeviceEntryStage.waitingState(for: $0.screen) },
                    actions: { actions($0, control: control) }
                )
            }
        }
        let shutDown = SimulatorDevice(
            udid: demoUDIDPrefix + "OFF", name: "iPhone 17 Pro", runtimeName: "iOS 26.5", state: .shutdown, deviceTypeIdentifier: "demo.phone")
        return [
            Cell("loading", railChrome { DevicesEmptyState(title: "Looking for devices…") }),
            Cell("no Xcode", railChrome {
                DevicesEmptyState(
                    symbol: "iphone.slash", title: "iOS simulators need Xcode",
                    detail: "Install it, or select it with `sudo xcode-select -s /Applications/Xcode.app`.")
            }),
            Cell("no simulators", railChrome {
                DevicesEmptyState(
                    symbol: "iphone", title: "No iOS simulators",
                    detail: "Create one in Xcode under Window › Devices and Simulators.")
            }),
            Cell("nothing running, boot failed", railChrome {
                DevicesEmptyState(
                    symbol: "iphone", title: "No devices running",
                    detail: "Unable to boot device in current state: Booting", detailTone: "warn",
                    action: .init(title: "Boot \(shutDown.name)", icon: "power") {})
            }),
            Cell("simulator booting", rail(resolve(simulators: [shutDown, air], lastUsed: nil, booting: [shutDown.udid]))),
            Cell("VM starting", rail(resolve(simulators: [], vms: [.macOS: .starting], lastUsed: nil))),
        ]
    }

    // MARK: - Painted screen

    /// What a scripted simulator shows instead of a stream: a wallpaper and a grid of app icons.
    static let demoScreen: CGImage? = {
        let size = CGSize(width: 804, height: 1748)
        let image = NSImage(size: size, flipped: false) { rect in
            NSGradient(colors: [
                NSColor(red: 0.10, green: 0.16, blue: 0.34, alpha: 1), NSColor(red: 0.42, green: 0.26, blue: 0.55, alpha: 1),
                NSColor(red: 0.93, green: 0.55, blue: 0.42, alpha: 1),
            ])?.draw(in: rect, angle: -80)
            let palette: [NSColor] = [
                .systemTeal, .systemOrange, .systemPink, .systemGreen, .systemIndigo, .systemYellow, .systemBlue, .systemRed,
            ]
            let icon: CGFloat = 132, gap: CGFloat = 60, left = (size.width - 4 * icon - 3 * gap) / 2
            for index in 0..<20 {
                let column = CGFloat(index % 4), row = CGFloat(index / 4)
                let frame = NSRect(x: left + column * (icon + gap), y: size.height - 320 - row * (icon + 96), width: icon, height: icon)
                palette[index % palette.count].withAlphaComponent(0.92).setFill()
                NSBezierPath(roundedRect: frame, xRadius: 30, yRadius: 30).fill()
            }
            NSColor.white.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: NSRect(x: 40, y: 56, width: size.width - 80, height: 170), xRadius: 56, yRadius: 56).fill()
            return true
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }()
}
#endif
